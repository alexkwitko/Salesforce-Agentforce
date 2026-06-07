/**
 * LeadNurtureService — the intelligence behind Agent 1 (Inside Sales) cart recovery.
 * For an abandoned-cart Lead it:
 *   1. Reconstructs the EXACT abandoned cart (Cart_Item__c) and shows it back to the shopper.
 *   2. Runs the deterministic RecommendationStrategyService (channel=abandoned_cart) to add a
 *      personalized "complete the ritual" cross-sell + resolve the right discount for the buyer.
 *   3. Has the Inside Sales AGENT write persuasive copy grounded in those real items + picks
 *      (deterministic persuasive fallback if the agent is unavailable, so delivery never breaks).
 *   4. Builds a ONE-CLICK "restore my cart" link (abandoned items + picks + coupon) so nothing the
 *      shopper lost is gone — the cart is saved server-side and re-addable.
 *   5. Issues the coupon (idempotent), sends via the consent-gated EmailService, marks the lead
 *      contacted, and LOGS an Agent_Interaction__c so every other agent (Concierge/Service/Growth)
 *      is context-aware of the recovery + coupon.
 * Callout ordering: read-only work (recs/links) + callouts (agent copy, Woo coupon) run BEFORE any DML.
 */
public without sharing class LeadNurtureService {

    private static final String AGENT = 'Inside_Sales';
    private static final String CART_URL = 'https://deepskyblue-deer-920559.hostingersite.com/cart';

    public class Request {
        @InvocableVariable(label='Lead ID' required=true) public Id leadId;
    }
    public class Result {
        @InvocableVariable public String couponCode;
        @InvocableVariable public String message;
        @InvocableVariable public Boolean success;
    }

    @InvocableMethod(label='Send Cart Recovery Offer'
        description='Inside Sales agent: reconstructs the abandoned cart, adds a personalized recommendation, writes persuasive copy, issues a coupon, sends a one-click restore email, and logs cross-agent context.')
    public static List<Result> sendRecovery(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request r : requests) out.add(run(r.leadId));
        return out;
    }

    public static Result run(Id leadId) {
        Result res = new Result();
        res.success = false;

        Lead l = [SELECT Id, Name, FirstName, Email, Status, Email_Consent__c, Person_Account__c, Last_Cart_Value__c
                  FROM Lead WHERE Id = :leadId LIMIT 1];
        if (l.Email_Consent__c != true) {
            res.message = 'Lead has not consented to email; cannot send a recovery offer. No coupon, no email.';
            return res;
        }
        if (String.isBlank(l.Email)) { res.message = 'Lead has no email; cannot send recovery offer.'; return res; }
        String firstName = String.isBlank(l.FirstName) ? 'there' : l.FirstName;

        // ── 1. Reconstruct the abandoned cart (grounding) ──
        List<Cart_Item__c> items = new List<Cart_Item__c>();
        List<Cart__c> carts = [SELECT Id FROM Cart__c WHERE Lead__c = :leadId ORDER BY LastModifiedDate DESC LIMIT 1];
        if (!carts.isEmpty()) {
            items = [SELECT Quantity__c, Unit_Price__c, SKU__c, Product__c, Product__r.Name
                     FROM Cart_Item__c WHERE Cart__c = :carts[0].Id ORDER BY Line_Total__c DESC];
        }
        List<Id> cartProdIds = new List<Id>();
        for (Cart_Item__c it : items) if (it.Product__c != null) cartProdIds.add(it.Product__c);
        String cartProdCsv = idsToCsv(cartProdIds);

        // ── 2. Real recommendation engine (callout-safe: skipJourneyWrite) ──
        RecommendationStrategyService.Request rq = new RecommendationStrategyService.Request();
        rq.email = l.Email; rq.channel = 'abandoned_cart'; rq.cartProductIdsCsv = cartProdCsv; rq.skipJourneyWrite = true;
        RecommendationStrategyService.Result rec;
        try { rec = RecommendationStrategyService.buildStrategy(new List<RecommendationStrategyService.Request>{ rq })[0]; }
        catch (Exception e) { System.debug('reco failed: ' + e.getMessage()); }

        Integer pct = (rec != null && rec.discountPercent != null && rec.discountPercent > 0) ? Integer.valueOf(rec.discountPercent) : 10;
        Date expiry = Date.today().addDays(7);
        String code = 'COMEBACK' + String.valueOf(Math.mod(Math.abs(leadId.hashCode()), 10000));
        res.couponCode = code;

        // recommendation display + ids to add to the restore link
        List<Id> recIds = new List<Id>();
        List<String> recNames = new List<String>();
        if (rec != null) {
            if (rec.complementaryProductId != null) { recIds.add(rec.complementaryProductId); recNames.add(rec.complementaryProductName); }
            if (rec.primaryProductId != null && !cartProdIds.contains(rec.primaryProductId)) { recIds.add(rec.primaryProductId); recNames.add(rec.primaryProductName); }
        }
        String itemsText = itemsText(items);
        String itemsHtml = itemsHtml(items);
        String recsHtml = recsHtml(recNames);
        String heroImg = heroImage(cartProdIds);

        // ── 3. One-click "restore my cart" link: abandoned items + picks + coupon (read-only) ──
        List<Id> restoreIds = new List<Id>(cartProdIds);
        restoreIds.addAll(recIds);
        String restoreUrl = buildRestoreUrl(restoreIds, code);

        // ── 4. CALLOUTS (agent copy → Woo coupon) — before any DML ──
        Map<String, String> copy = agentCopy(firstName, itemsText, recNames, pct, code, expiry);
        String emailBody = assemble(
            copy.containsKey('headline') ? copy.get('headline') : ('Your cart is still warm, ' + firstName + ' ☕'),
            copy.containsKey('pitch') ? copy.get('pitch') : persuasiveFallback(firstName, itemsText, recNames),
            heroImg, itemsHtml, recsHtml, pct, code, expiry, restoreUrl);

        String wooId = WooCouponService.createPercentCoupon(code, pct, expiry, l.Email, null);

        // ── 5. DML (coupon, email, lead, cross-agent context log) ──
        if ([SELECT count() FROM Coupon__c WHERE Code__c = :code] == 0) {
            insert new Coupon__c(Name=code, Code__c=code, Discount_Percent__c=pct,
                Expiry_Date__c=expiry, Status__c='Issued', Woo_Coupon_Id__c=wooId,
                Recommendation_Summary__c='Cart recovery for ' + l.Name + (rec != null ? ' (' + rec.buyerType + ')' : ''));
        }

        EmailService.Request er = new EmailService.Request();
        er.toEmail = l.Email;
        er.subject = 'You left something brewing, ' + firstName + ' — ' + pct + '% off + your cart saved';
        er.htmlBody = emailBody;
        er.recordId = l.Id;
        EmailService.send(new List<EmailService.Request>{ er });

        update new Lead(Id = l.Id, Status = 'Working - Contacted');

        // Cross-agent context: record the recovery + coupon + recommended picks on the journey.
        try {
            JourneyLogger.LogRequest lr = new JourneyLogger.LogRequest();
            lr.email = l.Email; lr.agent = AGENT; lr.action = 'cart_recovery'; lr.stage = 'Abandoned';
            lr.productIds = cartProdCsv;
            lr.result = 'Sent ' + code + ' (' + pct + '% off); recommended: ' + (recNames.isEmpty() ? 'none' : String.join(recNames, ', '));
            lr.addRecommendedProductIds = idsToCsv(recIds);
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{ lr });
        } catch (Exception e) { System.debug('journey log failed: ' + e.getMessage()); }

        res.success = true;
        res.message = 'Recovery ' + code + ' (' + pct + '% off) sent to ' + l.Email
            + ' | items=' + items.size() + ' | recs=' + recNames.size()
            + (copy.containsKey('headline') ? ' | agent-authored' : ' | fallback copy');
        return res;
    }

    /** Inside Sales agent authors persuasive copy grounded in the real cart items + recommendations. */
    private static Map<String, String> agentCopy(String firstName, String itemsText, List<String> recNames, Integer pct, String code, Date expiry) {
        Map<String, String> out = new Map<String, String>();
        try {
            String recs = recNames.isEmpty() ? 'a barista favorite' : String.join(recNames, ' and ');
            String prompt =
                'You are the Inside Sales agent for "Kwitko Coffee Co." A shopper named ' + firstName +
                ' left these items in their cart without checking out: ' + (String.isBlank(itemsText) ? 'fresh-roasted coffee' : itemsText) + '. ' +
                'We also think they would love: ' + recs + '. They have a one-time ' + pct + '% off code "' + code + '" expiring ' + expiry.format() + '. ' +
                'Write WARM, PERSUASIVE recovery copy that: references their ACTUAL items, gives a concrete reason to finish now ' +
                '(small-batch freshly roasted, peak flavor, the ritual waiting for them), reassures them their cart is SAVED, and nudges the upsell gently. ' +
                'Do NOT invent prices or products not listed. Return ONLY JSON (no code fences): {"headline": "<max 8 words, gently urgent, one emoji max>", "pitch": "<2-3 short irresistible sentences>"}.';
            AgentInvoker.Response r = AgentInvoker.callAgent(AGENT, prompt);
            if (r == null || r.success != true || String.isBlank(r.agentResponse)) return out;
            String text = r.agentResponse.trim();
            if (text.startsWith('```')) { text = text.replaceFirst('(?s)^```[a-zA-Z]*',''); if (text.endsWith('```')) text = text.substring(0, text.length()-3); }
            Integer s = text.indexOf('{'), e = text.lastIndexOf('}');
            if (s < 0 || e <= s) return out;
            Map<String, Object> j = (Map<String, Object>) JSON.deserializeUntyped(text.substring(s, e+1));
            if (j.get('headline') != null && j.get('pitch') != null) {
                out.put('headline', String.valueOf(j.get('headline')));
                out.put('pitch', String.valueOf(j.get('pitch')));
            }
        } catch (Exception ex) { System.debug('agentCopy failed, fallback: ' + ex.getMessage()); }
        return out;
    }

    private static String persuasiveFallback(String firstName, String itemsText, List<String> recNames) {
        String base = 'Your ' + (String.isBlank(itemsText) ? 'coffee' : itemsText)
            + ' is still in your cart — freshly roasted in small batches and ready to ship the moment you check out. '
            + 'We saved everything for you, so you won’t lose a thing.';
        if (!recNames.isEmpty()) base += ' Want to make it perfect? Add ' + String.join(recNames, ' or ') + ' on your way out.';
        return base;
    }

    private static String idsToCsv(List<Id> ids) {
        List<String> s = new List<String>();
        for (Id i : ids) if (i != null) s.add(String.valueOf(i));
        return String.join(s, ',');
    }

    private static String buildRestoreUrl(List<Id> productIds, String coupon) {
        try {
            if (productIds.isEmpty()) return CART_URL;
            CartLinkService.Request cr = new CartLinkService.Request();
            cr.productIdsCsv = idsToCsv(productIds);
            cr.couponCode = coupon;
            CartLinkService.Result lr = CartLinkService.build(new List<CartLinkService.Request>{ cr })[0];
            return String.isNotBlank(lr.addToCartUrl) ? lr.addToCartUrl : CART_URL;
        } catch (Exception e) { return CART_URL; }
    }

    private static String itemsText(List<Cart_Item__c> items) {
        if (items == null || items.isEmpty()) return '';
        List<String> parts = new List<String>();
        for (Cart_Item__c it : items) {
            String nm = (it.Product__r != null && it.Product__r.Name != null) ? it.Product__r.Name : (String.isBlank(it.SKU__c) ? 'coffee' : it.SKU__c);
            Integer q = it.Quantity__c == null ? 1 : it.Quantity__c.intValue();
            parts.add(q + '× ' + nm);
        }
        return String.join(parts, ', ');
    }

    private static String itemsHtml(List<Cart_Item__c> items) {
        if (items == null || items.isEmpty()) return '';
        String rows = '';
        for (Cart_Item__c it : items) {
            String nm = (it.Product__r != null && it.Product__r.Name != null) ? it.Product__r.Name : (String.isBlank(it.SKU__c) ? 'Coffee' : it.SKU__c);
            Integer q = it.Quantity__c == null ? 1 : it.Quantity__c.intValue();
            rows += '<tr><td style="padding:6px 0;color:#3a2a1a;font-size:15px">' + esc(nm) + '</td>' +
                    '<td style="padding:6px 0;color:#7a6a58;font-size:15px;text-align:right">×' + q + '</td></tr>';
        }
        return '<p style="color:#6f4e37;font-size:14px;margin:0 0 4px;font-weight:bold">Still in your cart (saved for you):</p>' +
               '<table style="width:100%;border-collapse:collapse;margin:4px 0 18px;border-top:1px solid #ece3d8;border-bottom:1px solid #ece3d8">' + rows + '</table>';
    }

    private static String recsHtml(List<String> recNames) {
        if (recNames == null || recNames.isEmpty()) return '';
        String lis = '';
        for (String n : recNames) if (String.isNotBlank(n)) lis += '<li style="margin:2px 0">' + esc(n) + '</li>';
        if (String.isBlank(lis)) return '';
        return '<p style="color:#6f4e37;font-size:14px;margin:14px 0 4px;font-weight:bold">Complete the ritual — you might also love:</p>' +
               '<ul style="color:#444;font-size:15px;margin:0 0 14px;padding-left:20px">' + lis + '</ul>';
    }

    private static String heroImage(List<Id> prodIds) {
        if (prodIds != null && !prodIds.isEmpty()) {
            List<Product2> p = [SELECT Image_URL__c FROM Product2 WHERE Id IN :prodIds AND Image_URL__c != null LIMIT 1];
            if (!p.isEmpty()) return p[0].Image_URL__c;
        }
        List<Product2> heroes = [SELECT Image_URL__c FROM Product2
            WHERE Family IN ('Single-Origin','Blends') AND Image_URL__c != null AND Stock_On_Hand__c > 0
            ORDER BY Stock_On_Hand__c DESC LIMIT 1];
        return heroes.isEmpty() ? null : heroes[0].Image_URL__c;
    }

    private static String assemble(String headline, String pitch, String heroImg, String itemsHtml, String recsHtml,
                                   Integer pct, String code, Date expiry, String restoreUrl) {
        String hero = String.isBlank(heroImg) ? '' :
            '<img src="' + heroImg + '" width="100%" alt="Kwitko Coffee" style="width:100%;max-width:560px;height:auto;border-radius:10px;display:block;margin:0 0 14px"/>';
        return
        '<div style="margin:0;padding:0;background:#f4efe9"><div style="font-family:Georgia,serif;max-width:600px;margin:0 auto;background:#fffdfb;border-radius:14px;overflow:hidden;border:1px solid #ece3d8">' +
        '<div style="background:#6f4e37;padding:22px 28px"><span style="color:#f4efe9;font-size:20px;letter-spacing:1px">☕ Kwitko Coffee Co.</span></div>' +
        '<div style="padding:28px">' +
        '<h1 style="color:#6f4e37;font-size:26px;line-height:1.2;margin:0 0 14px">' + esc(headline) + '</h1>' + hero +
        '<p style="color:#444;font-size:16px;line-height:1.6;margin:0 0 18px">' + esc(pitch) + '</p>' + itemsHtml + recsHtml +
        '<div style="background:#f7f1ea;border:1px dashed #c9a87f;border-radius:10px;padding:18px;text-align:center;margin:8px 0 4px">' +
        '<div style="color:#6f4e37;font-size:14px;margin-bottom:6px">Come back and save <strong>' + pct + '% off</strong></div>' +
        '<div style="font-size:26px;font-weight:bold;letter-spacing:2px;color:#3a2a1a">' + esc(code) + '</div>' +
        '<div style="color:#999;font-size:12px;margin-top:6px">Hurry — expires ' + expiry.format() + '</div></div>' +
        '<div style="text-align:center;margin:24px 0 8px"><a href="' + restoreUrl + '" style="display:inline-block;background:#6f4e37;color:#fff;font-family:Arial,sans-serif;font-size:16px;font-weight:bold;padding:14px 34px;border-radius:30px;text-decoration:none">Restore my cart &amp; check out ➔</a></div>' +
        '<p style="text-align:center;color:#b3a695;font-size:12px;font-family:Arial,sans-serif;margin:6px 0 0">One click puts everything back — your cart is saved.</p>' +
        '</div><div style="background:#faf6f1;padding:16px 28px;color:#b3a695;font-size:12px;font-family:Arial,sans-serif">Roasted fresh in small batches · Kwitko Coffee Co.</div></div></div>';
    }

    private static String esc(String s) { return s == null ? '' : s.escapeHtml4(); }
}
