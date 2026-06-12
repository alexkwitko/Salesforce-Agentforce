/**
 * RecommendationStrategyService — the deterministic "strategy brain".
 * Profiles the buyer (New / Recurrent / VIP), builds the EXCLUDE set (never repeat purchased or
 * already-recommended), picks a PRIMARY buy-again coffee + a COMPLEMENTARY gear item via
 * co-purchase affinity (with best-seller / most-stocked fallbacks), and resolves the discount from
 * the Discount_Rule__mdt matrix (buyer type x channel). Returns a "strategy packet".
 *
 * The agent (Product_Advisor / Post_Purchase / Inside_Sales) phrases this — it never decides the
 * product, quantity, or discount. Deterministic on purpose.
 *
 * Profile source: CRM real-time facts plus Account-level Data Cloud augmentation fallback.
 */
public without sharing class RecommendationStrategyService {

    private static final Set<String> BEAN_FAMILIES = new Set<String>{
        'Single-Origin','Blends','Espresso','Decaf','Flavored','Subscriptions','Gift Sets'};
    // Drinkable-coffee families only (carry the structured attribute axes). Excludes subscriptions/gift sets.
    private static final Set<String> COFFEE_BEAN_FAMILIES = new Set<String>{
        'Single-Origin','Blends','Espresso','Decaf','Flavored'};
    private static final Set<String> GEAR_FAMILIES = new Set<String>{
        'Grinders','Filters','Pour-Over & Drippers','Kettles','French Press & AeroPress',
        'Scales','Espresso Machines','Mugs & Cups','Storage','Cleaning'};

    private static final Decimal VIP_LTV = 300;            // lifetime value threshold for VIP
    private static final Integer VIP_FREQ_12MO = 5;        // 5+ purchases in last 12 months => VIP
    private static final Integer RECURRENT_MIN_12MO = 3;   // 3-4 purchases in last 12 months => Recurrent

    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Channel' description='post_purchase | abandoned_cart | chat' required=true) public String channel;
        @InvocableVariable(label='Order Id (optional)') public String orderId;
        @InvocableVariable(label='Cart Product Ids CSV (optional)') public String cartProductIdsCsv;
        @InvocableVariable(label='Preferred Quantity (optional)') public Decimal preferredQuantity;
        @InvocableVariable(label='Dislike Keywords CSV (e.g. decaf,flavored) — never recommend products whose name matches') public String dislikeKeywordsCsv;
        @InvocableVariable(label='Exclude Product Ids CSV (rejected this chat — never re-offer)') public String excludeProductIdsCsv;
        @InvocableVariable(label='Preferred Family (e.g. Single-Origin, Espresso) — bias the primary pick') public String preferredFamily;
        // --- independent coffee preference axes (hard filters when set; orthogonal to each other) ---
        @InvocableVariable(label='Preferred Bean Type (Single-Origin | Blend)') public String preferredBeanType;
        @InvocableVariable(label='Preferred Brew Style (Espresso | Cold Brew | All-Purpose)') public String preferredBrewStyle;
        @InvocableVariable(label='Preferred Roast (Light | Medium | Dark)') public String preferredRoast;
        @InvocableVariable(label='Wants Decaf (true=only decaf, false=only regular, leave blank=no preference)') public Boolean wantsDecaf;
        @InvocableVariable(label='Avoid Flavored (true=never recommend flavored coffee)') public Boolean avoidFlavored;
        @InvocableVariable(label='Skip Journey Write (true=do NOT log recommended ids — keeps this callout-safe for callers that callout afterward)') public Boolean skipJourneyWrite;
        @InvocableVariable(label='Active Coupon Code (the shopper\'s existing unredeemed coupon, from the context packet — pass it so we do NOT stack a new discount)') public String activeCouponCode;
        @InvocableVariable(label='Active Coupon Percent (the percent off of their existing unredeemed coupon)') public Decimal activeCouponPercent;
    }

    public class Result {
        @InvocableVariable public String buyerType;
        @InvocableVariable public Integer orderCount;
        @InvocableVariable public Integer purchasesLast12Mo;
        @InvocableVariable public Decimal lifetimeValue;
        @InvocableVariable public String favoriteCategory;
        @InvocableVariable public String primaryProductId;
        @InvocableVariable public String primaryProductName;
        @InvocableVariable public Decimal primaryQuantity;
        @InvocableVariable public String complementaryProductId;
        @InvocableVariable public String complementaryProductName;
        @InvocableVariable public Decimal complementaryQuantity;
        @InvocableVariable public Decimal discountPercent;
        @InvocableVariable public Boolean addsPerk;
        @InvocableVariable public String discountRationale;
        @InvocableVariable public String excludedIdsCsv;
        @InvocableVariable public String relaxedAxesCsv;   // axes that had to be relaxed to find a match (transparency)
        @InvocableVariable public String webSignal;        // live browsing signal behind the pick (lets the agent say "you were looking at...")
        @InvocableVariable public String dataCloudSegment;
        @InvocableVariable public String dataCloudChurnRisk;
        @InvocableVariable public String dataCloudNextBestAction;
        @InvocableVariable public Boolean couponEligible;
        @InvocableVariable public Boolean serviceRecoveryRequired;
        @InvocableVariable public String serviceRecoveryReason;
        @InvocableVariable public String packetJson;
        @InvocableVariable public Boolean success;
        @InvocableVariable public String summary;
    }

    @InvocableMethod(label='Build Recommendation Strategy'
        description='Profiles the buyer, picks products + quantities (excluding purchased/recommended), and resolves the discount from the Discount_Rule__mdt matrix. Deterministic.')
    public static List<Result> buildStrategy(List<Request> reqs) {
        List<Result> out = new List<Result>();
        for (Request r : reqs) out.add(build(r));
        return out;
    }

    private static Result build(Request r) {
        Result res = new Result();
        res.success = false;
        res.couponEligible = true;
        res.serviceRecoveryRequired = false;
        String channel = String.isBlank(r.channel) ? 'chat' : r.channel.toLowerCase();

        // --- profile (CRM) ---
        List<Account> accs = String.isBlank(r.email) ? new List<Account>()
            : [SELECT Id, Name, Data_Cloud_Segment__c, Data_Cloud_Churn_Risk__c,
                      Data_Cloud_Next_Best_Action__c, Data_Cloud_Order_Count__c,
                      Data_Cloud_Lifetime_Value__c, Data_Cloud_Favorite_Category__c,
                      Data_Cloud_Return_Count__c, Has_Returned_Order__c, Return_Count__c,
                      Winback_Needed__c
               FROM Account WHERE PersonEmail = :r.email LIMIT 1];
        Id accountId = accs.isEmpty() ? null : accs[0].Id;
        Account profileAccount = accs.isEmpty() ? null : accs[0];

        Integer orderCount = 0;
        Integer orders12mo = 0;
        Decimal ltv = 0;
        Map<String, Decimal> qtyByFamily = new Map<String, Decimal>();
        Set<Id> purchased = new Set<Id>();
        if (accountId != null) {
            orderCount = [SELECT count() FROM Order WHERE AccountId = :accountId];
            orders12mo = [SELECT count() FROM Order WHERE AccountId = :accountId AND CreatedDate = LAST_N_DAYS:365];
            for (AggregateResult ar : [SELECT SUM(TotalAmount) s FROM Order WHERE AccountId = :accountId]) {
                ltv = (Decimal) (ar.get('s') == null ? 0 : ar.get('s'));
            }
            for (OrderItem oi : [SELECT Product2Id, Product2.Family, Quantity FROM OrderItem WHERE Order.AccountId = :accountId]) {
                if (oi.Product2Id != null) purchased.add(oi.Product2Id);
                String fam = String.isBlank(oi.Product2.Family) ? 'Coffee' : oi.Product2.Family;
                qtyByFamily.put(fam, (qtyByFamily.get(fam) == null ? 0 : qtyByFamily.get(fam)) + oi.Quantity);
            }
        }
        if (profileAccount != null) {
            res.dataCloudSegment = profileAccount.Data_Cloud_Segment__c;
            res.dataCloudChurnRisk = profileAccount.Data_Cloud_Churn_Risk__c;
            res.dataCloudNextBestAction = profileAccount.Data_Cloud_Next_Best_Action__c;
            if (orderCount == 0 && profileAccount.Data_Cloud_Order_Count__c != null) {
                orderCount = profileAccount.Data_Cloud_Order_Count__c.intValue();
            }
            if (ltv == 0 && profileAccount.Data_Cloud_Lifetime_Value__c != null) {
                ltv = profileAccount.Data_Cloud_Lifetime_Value__c;
            }
            if (String.isBlank(res.favoriteCategory) && String.isNotBlank(profileAccount.Data_Cloud_Favorite_Category__c)) {
                res.favoriteCategory = profileAccount.Data_Cloud_Favorite_Category__c;
            }
        }

        // journey memory (purchased + already-recommended)
        Set<Id> alreadyRecommended = new Set<Id>();
        if (String.isNotBlank(r.email)) {
            for (Customer_Journey__c j : [SELECT Purchased_Product_Ids__c, Recommended_Product_Ids__c
                                          FROM Customer_Journey__c WHERE Email__c = :r.email LIMIT 1]) {
                purchased.addAll(toIdSet(j.Purchased_Product_Ids__c));
                alreadyRecommended.addAll(toIdSet(j.Recommended_Product_Ids__c));
            }
        }

        // --- live web engagement (stitched Web_Event__c): what they actually browsed, dwell-weighted ---
        Map<String, Decimal> webScoreByWooId = new Map<String, Decimal>();
        if (accountId != null) {
            Datetime newestAt = null; String newestName = null; Decimal newestDwell = 0;
            for (Web_Event__c we : [SELECT Event_Type__c, Product_Id__c, Product_Name__c,
                                           Time_On_Page__c, Occurred_At__c
                                    FROM Web_Event__c
                                    WHERE Account__c = :accountId AND Occurred_At__c = LAST_N_DAYS:30
                                    ORDER BY Occurred_At__c DESC LIMIT 200]) {
                if (String.isBlank(we.Product_Id__c)) continue;
                Decimal w = 10 + (we.Time_On_Page__c == null ? 0 : we.Time_On_Page__c); // a view + every dwell second
                Decimal prev = webScoreByWooId.get(we.Product_Id__c);
                webScoreByWooId.put(we.Product_Id__c, (prev == null ? 0 : prev) + w);
                if (newestName == null && String.isNotBlank(we.Product_Name__c)) {
                    newestAt = we.Occurred_At__c; newestName = we.Product_Name__c;
                    newestDwell = we.Time_On_Page__c == null ? 0 : we.Time_On_Page__c;
                }
            }
            if (newestName != null) {
                res.webSignal = 'Browsed "' + newestName + '" on ' + newestAt.date().format()
                    + (newestDwell >= 30 ? ' (' + newestDwell.intValue() + 's on the page)' : '');
            }
        }

        // buyer type — recurrence from TRAILING-12-MONTH purchases + lifetime value (not all-time count)
        String buyerType = classifyBuyer(orderCount, ltv, orders12mo);
        res.buyerType = buyerType;
        res.orderCount = orderCount;
        res.purchasesLast12Mo = orders12mo;
        res.lifetimeValue = ltv;

        // favorite category
        String favCat = String.isBlank(res.favoriteCategory) ? 'Coffee' : res.favoriteCategory;
        Decimal best = -1;
        for (String fam : qtyByFamily.keySet()) {
            if (qtyByFamily.get(fam) > best) { best = qtyByFamily.get(fam); favCat = fam; }
        }
        res.favoriteCategory = favCat;

        // exclude set + anchor
        Set<Id> cartIds = toIdSet(r.cartProductIdsCsv);
        Set<Id> orderItemIds = new Set<Id>();
        Decimal basketTotal = 0;
        if (String.isNotBlank(r.orderId)) {
            try {
                Id oid = (Id) r.orderId;
                for (OrderItem oi : [SELECT Product2Id FROM OrderItem WHERE OrderId = :oid]) {
                    if (oi.Product2Id != null) orderItemIds.add(oi.Product2Id);
                }
                for (Order o : [SELECT TotalAmount FROM Order WHERE Id = :oid LIMIT 1]) {
                    basketTotal = o.TotalAmount == null ? 0 : o.TotalAmount;
                }
            } catch (Exception e) {}
        }
        // preference-driven filters
        List<String> dislikeKw = lowerList(r.dislikeKeywordsCsv);   // e.g. ["decaf"] — never recommend by name
        Set<Id> extraExclude = toIdSet(r.excludeProductIdsCsv);     // products rejected this chat
        String prefFam = String.isBlank(r.preferredFamily) ? null : r.preferredFamily.trim();

        Set<Id> exclude = new Set<Id>();
        exclude.addAll(purchased); exclude.addAll(alreadyRecommended);
        exclude.addAll(orderItemIds); exclude.addAll(cartIds); exclude.addAll(extraExclude);
        // NEVER re-recommend a product this customer has returned (real-time CRM guardrail).
        if (accountId != null) exclude.addAll(returnedProductIds(accountId));
        if (exclude.isEmpty()) exclude.add(null); // guard for NOT IN

        Set<Id> anchor = (channel == 'abandoned_cart' && !cartIds.isEmpty()) ? cartIds : purchased;

        // resolve browsed Woo product ids -> Product2, best-scored first; browsed products also
        // strengthen the co-purchase affinity anchors (except abandoned_cart, which stays cart-pure)
        List<Product2> webBrowsed = new List<Product2>();
        if (!webScoreByWooId.isEmpty()) {
            Set<String> wooIds = webScoreByWooId.keySet();
            Map<Id, Product2> byId = new Map<Id, Product2>();
            Map<Id, Decimal> score = new Map<Id, Decimal>();
            for (Product2 p : [SELECT Id, Name, Family, Woo_Product_Id__c, Image_URL__c, Description, Stock_On_Hand__c
                               FROM Product2
                               WHERE Woo_Product_Id__c IN :wooIds AND IsActive = true AND Stock_On_Hand__c > 0]) {
                byId.put(p.Id, p);
                score.put(p.Id, webScoreByWooId.get(p.Woo_Product_Id__c));
                if (channel != 'abandoned_cart') anchor.add(p.Id);
            }
            List<Id> ordered = new List<Id>(byId.keySet());
            for (Integer i = 0; i < ordered.size(); i++) {       // tiny set: simple selection sort
                for (Integer j = i + 1; j < ordered.size(); j++) {
                    if (score.get(ordered[j]) > score.get(ordered[i])) {
                        Id tmp = ordered[i]; ordered[i] = ordered[j]; ordered[j] = tmp;
                    }
                }
            }
            for (Id pid : ordered) webBrowsed.add(byId.get(pid));
        }

        // normalize the independent preference axes (null = no preference on that axis)
        String prefBean  = normBean(r.preferredBeanType);
        String prefBrew  = normBrew(r.preferredBrewStyle);
        String prefRoast = normRoast(r.preferredRoast);
        Boolean wantsDecaf = r.wantsDecaf;            // null = no preference
        Boolean avoidFlavored = (r.avoidFlavored == true);
        Boolean hasAxisPrefs = prefBean != null || prefBrew != null || prefRoast != null
            || wantsDecaf != null || avoidFlavored;

        List<String> relaxed = new List<String>();

        // --- PRIMARY (a buy-again coffee) ---
        Product2 primary = null;
        Boolean axisError = false;
        if (hasAxisPrefs) {
            // honor each set axis as a HARD filter; relax least-important first (roast → brew → bean);
            // NEVER relax the caffeine (decaf) or flavored constraints. If the axis code errors for any
            // reason, fall back to the affinity picker rather than fail the whole recommendation.
            try {
                primary = pickCoffeeByAxes(exclude, dislikeKw, prefBean, prefBrew, prefRoast,
                                           wantsDecaf, avoidFlavored, relaxed);
            } catch (Exception e) { axisError = true; }
        }
        if (!hasAxisPrefs && primary == null) {
            // browsed-but-not-bought beats generic affinity: they already showed us what they want
            for (Product2 cand : webBrowsed) {
                if (exclude.contains(cand.Id)) continue;
                if (nameHasDislike(cand.Name, dislikeKw)) continue;
                primary = cand;
                break;
            }
        }
        if (!hasAxisPrefs && primary == null || (primary == null && axisError)) {
            // legacy affinity-based picker (no coffee axes, or a safe fallback if axis pick errored)
            Set<Id> exP = new Set<Id>(exclude);
            for (Integer i = 0; i < 12 && primary == null; i++) {
                Product2 cand = primaryCandidate(anchor, exP, prefFam, favCat);
                if (cand == null) break;
                if (nameHasDislike(cand.Name, dislikeKw)) { exP.add(cand.Id); continue; }
                primary = cand;
            }
        }
        if (primary == null) {
            res.relaxedAxesCsv = String.join(relaxed, ',');
            res.summary = 'No in-stock coffee matches the stated preferences'
                + (wantsDecaf == false ? ' (regular, non-flavored constraints kept).'
                   : (wantsDecaf == true ? ' (decaf required).' : '.'));
            return res;
        }
        res.primaryProductId = primary.Id;
        res.primaryProductName = primary.Name;
        res.primaryQuantity = (r.preferredQuantity != null && r.preferredQuantity > 0) ? r.preferredQuantity : 1;

        // --- COMPLEMENTARY (gear) — also dislike-aware ---
        Set<Id> excludeComp = new Set<Id>(exclude); excludeComp.add(primary.Id);
        Product2 comp = null;
        for (Integer i = 0; i < 8 && comp == null; i++) {
            Product2 cand = coPurchaseAffinity(anchor, excludeComp, GEAR_FAMILIES);
            if (cand == null) cand = bestSellerInFamilies(GEAR_FAMILIES, excludeComp);
            if (cand == null) cand = mostStockedInFamilies(GEAR_FAMILIES, excludeComp);
            if (cand == null) break;
            if (nameHasDislike(cand.Name, dislikeKw)) { excludeComp.add(cand.Id); continue; }
            comp = cand;
        }
        if (comp != null) {
            res.complementaryProductId = comp.Id;
            res.complementaryProductName = comp.Name;
            res.complementaryQuantity = 1;
        }

        // --- discount from Discount_Rule__mdt ---
        Decimal pct = 10; Boolean perk = false; Decimal bump = 0; Decimal minBasket = null;
        for (Discount_Rule__mdt d : [SELECT Percent__c, Adds_Perk__c, Basket_Bump_Percent__c, Min_Basket__c
                                     FROM Discount_Rule__mdt
                                     WHERE Buyer_Type__c = :buyerType AND Channel__c = :channel LIMIT 1]) {
            pct = d.Percent__c == null ? pct : d.Percent__c;
            perk = d.Adds_Perk__c == true;
            bump = d.Basket_Bump_Percent__c == null ? 0 : d.Basket_Bump_Percent__c;
            minBasket = d.Min_Basket__c;
        }
        String rationale = buyerType + ' buyer on ' + channel + ' → ' + pct.intValue() + '%';
        if (minBasket != null && basketTotal >= minBasket && bump > 0) {
            pct = pct + bump;
            rationale += ' +' + bump.intValue() + '% (basket ≥ ' + minBasket.intValue() + ')';
        }
        if (requiresServiceRecoveryBeforeCoupon(profileAccount)) {
            res.couponEligible = false;
            res.serviceRecoveryRequired = true;
            res.serviceRecoveryReason = serviceRecoveryCouponHoldMessage(profileAccount);
            pct = 0;
            perk = false;
            rationale = 'Service recovery guardrail: ' + res.serviceRecoveryReason;
        }
        // COUPON-AWARE: never stack on top of an unredeemed coupon the shopper already holds.
        // Honor the better of the two (their held coupon vs. the engine offer); don't issue a new code.
        else if (String.isNotBlank(r.activeCouponCode)) {
            Decimal held = (r.activeCouponPercent == null ? 0 : r.activeCouponPercent);
            res.couponEligible = false;
            if (held >= pct) {
                pct = held;
                rationale = 'Honoring your existing coupon ' + r.activeCouponCode.trim() + ' (' + held.intValue()
                    + '% off, unredeemed) — we don\'t stack discounts, so use that one.';
            } else {
                rationale = rationale + '. Note: you also hold coupon ' + r.activeCouponCode.trim() + ' ('
                    + held.intValue() + '% off) — this offer is better, and we never stack the two.';
            }
        }
        res.discountPercent = pct;
        res.addsPerk = perk;
        res.discountRationale = rationale;

        // exclude (drop null guard for display)
        List<String> exStr = new List<String>();
        for (Id id : exclude) if (id != null) exStr.add(String.valueOf(id));
        res.excludedIdsCsv = String.join(exStr, ',');

        res.relaxedAxesCsv = String.join(relaxed, ',');

        // --- conversion tracking + cross-agent memory ---
        // Best-effort: a failure here must NEVER break the recommendation the shopper is waiting on.
        try {
            if (String.isNotBlank(r.email) && r.skipJourneyWrite != true) {
                List<String> recIds = new List<String>();
                if (res.primaryProductId != null) recIds.add(res.primaryProductId);
                if (res.complementaryProductId != null) recIds.add(res.complementaryProductId);
                if (!recIds.isEmpty()) {
                    String recCsv = String.join(recIds, ',');
                    JourneyService.recordInteraction(
                        r.email,
                        agentForChannel(channel),
                        'build_strategy',
                        recCsv,
                        r.orderId,
                        'Recommended ' + res.primaryProductName
                            + (String.isBlank(res.complementaryProductName) ? '' : ' + ' + res.complementaryProductName)
                            + (res.couponEligible == false ? ' with no sales coupon because service recovery is required'
                                : ' at ' + pct.intValue() + '% on ' + channel),
                        channel,
                        recCsv,
                        null
                    );
                }
            }
        } catch (Exception e) { /* swallow: tracking is non-critical */ }

        res.success = true;
        res.summary = buyerType + ' buyer → ' + res.primaryProductName
            + (comp != null ? ' + ' + res.complementaryProductName : '')
            + (res.couponEligible == false
                ? ' with no sales coupon (' + channel + ') until the return/service issue is resolved.'
                : ' at ' + pct.intValue() + '% (' + channel + ').')
            + (String.isBlank(res.dataCloudNextBestAction) ? '' : ' Data Cloud next action: ' + res.dataCloudNextBestAction + '.')
            + (relaxed.isEmpty() ? '' : ' [relaxed: ' + String.join(relaxed, ', ') + ']');
        res.packetJson = JSON.serialize(new Map<String, Object>{
            'buyerType' => buyerType, 'orderCount' => orderCount, 'lifetimeValue' => ltv,
            'dataCloudSegment' => res.dataCloudSegment, 'dataCloudChurnRisk' => res.dataCloudChurnRisk,
            'dataCloudNextBestAction' => res.dataCloudNextBestAction,
            'couponEligible' => res.couponEligible, 'serviceRecoveryRequired' => res.serviceRecoveryRequired,
            'serviceRecoveryReason' => res.serviceRecoveryReason,
            'favoriteCategory' => favCat, 'discountPercent' => pct, 'addsPerk' => perk,
            'primary' => new Map<String, Object>{ 'id' => res.primaryProductId, 'name' => res.primaryProductName, 'qty' => res.primaryQuantity },
            'complementary' => (comp == null ? null : new Map<String, Object>{ 'id' => res.complementaryProductId, 'name' => res.complementaryProductName, 'qty' => 1 }),
            'discountRationale' => rationale });
        return res;
    }

    public static Boolean requiresServiceRecoveryBeforeCoupon(Account a) {
        if (a == null) return false;
        if (a.Winback_Needed__c == true) return true;
        String nba = String.isBlank(a.Data_Cloud_Next_Best_Action__c) ? '' : a.Data_Cloud_Next_Best_Action__c.toLowerCase();
        if (nba.contains('resolve') && (nba.contains('return') || nba.contains('service'))) return true;
        String risk = String.isBlank(a.Data_Cloud_Churn_Risk__c) ? '' : a.Data_Cloud_Churn_Risk__c.trim().toLowerCase();
        Integer returnCount = 0;
        if (a.Return_Count__c != null) returnCount = Math.max(returnCount, a.Return_Count__c.intValue());
        if (a.Data_Cloud_Return_Count__c != null) returnCount = Math.max(returnCount, a.Data_Cloud_Return_Count__c.intValue());
        return risk == 'high' && (returnCount > 0 || a.Has_Returned_Order__c == true);
    }

    public static String serviceRecoveryCouponHoldMessage(Account a) {
        if (a == null) return 'Resolve active service recovery before issuing a sales coupon.';
        if (a.Winback_Needed__c == true) return 'A return winback is pending; resolve that service recovery before issuing a normal sales coupon.';
        if (String.isNotBlank(a.Data_Cloud_Next_Best_Action__c)) return a.Data_Cloud_Next_Best_Action__c;
        return 'High return/service risk is present; resolve the customer issue before issuing a normal sales coupon.';
    }

    // ---- buyer segmentation (shared): recurrence from trailing-12-month purchases + LTV ----
    // Less recurrent buyers are LESS loyal => the discount matrix gives them a BIGGER, more aggressive
    // discount to win/keep them; recurrent/VIP buyers need less incentive (VIP gets a perk instead).
    //   New        = no orders ever
    //   Lapsed     = bought before, but 0 in the last 12 months  (most aggressive — reactivate)
    //   Occasional = 1-2 purchases in the last 12 months
    //   Recurrent  = 3-4 purchases in the last 12 months
    //   VIP        = 5+ in the last 12 months OR lifetime value >= VIP_LTV
    public static String classifyBuyer(Integer orderCountAll, Decimal ltv, Integer orders12mo) {
        Integer all = orderCountAll == null ? 0 : orderCountAll;
        Integer o12 = orders12mo == null ? 0 : orders12mo;
        Decimal v = ltv == null ? 0 : ltv;
        if (v >= VIP_LTV || o12 >= VIP_FREQ_12MO) return 'VIP';
        if (all == 0) return 'New';
        if (o12 == 0) return 'Lapsed';
        if (o12 >= RECURRENT_MIN_12MO) return 'Recurrent';
        return 'Occasional';
    }

    private static String agentForChannel(String channel) {
        if (channel == 'abandoned_cart') return 'Inside_Sales';
        if (channel == 'post_purchase') return 'Post_Purchase_Growth';
        if (channel == 'chat') return 'Kwitko_Concierge';
        return 'Product_Advisor';
    }

    /** Products this customer has returned — never recommend them again (real-time CRM guardrail). */
    private static Set<Id> returnedProductIds(Id accountId) {
        Set<Id> ids = new Set<Id>();
        if (accountId == null) return ids;
        for (ReturnOrderLineItem li : [SELECT Product2Id FROM ReturnOrderLineItem
                                       WHERE ReturnOrder.AccountId = :accountId AND Product2Id != null]) {
            ids.add(li.Product2Id);
        }
        return ids;
    }

    /** Account-based overload so other services (e.g. PostPurchaseService) classify identically. */
    public static String classifyBuyer(Id accountId) {
        if (accountId == null) return 'New';
        Account a = [SELECT Data_Cloud_Order_Count__c, Data_Cloud_Lifetime_Value__c
                     FROM Account WHERE Id = :accountId LIMIT 1];
        Integer all = [SELECT count() FROM Order WHERE AccountId = :accountId];
        Integer o12 = [SELECT count() FROM Order WHERE AccountId = :accountId AND CreatedDate = LAST_N_DAYS:365];
        Decimal v = 0;
        for (AggregateResult ar : [SELECT SUM(TotalAmount) s FROM Order WHERE AccountId = :accountId]) {
            v = (Decimal) (ar.get('s') == null ? 0 : ar.get('s'));
        }
        if (all == 0 && a.Data_Cloud_Order_Count__c != null) {
            all = a.Data_Cloud_Order_Count__c.intValue();
        }
        if (v == 0 && a.Data_Cloud_Lifetime_Value__c != null) {
            v = a.Data_Cloud_Lifetime_Value__c;
        }
        return classifyBuyer(all, v, o12);
    }

    // ---- preference-aware primary picker (prefers preferredFamily, then affinity/best-seller/stock) ----
    private static Product2 primaryCandidate(Set<Id> anchor, Set<Id> exclude, String prefFam, String favCat) {
        Product2 p;
        if (String.isNotBlank(prefFam)) {
            p = bestSellerInFamilies(new Set<String>{ prefFam }, exclude); if (p != null) return p;
            p = mostStockedInFamilies(new Set<String>{ prefFam }, exclude); if (p != null) return p;
        }
        p = coPurchaseAffinity(anchor, exclude, BEAN_FAMILIES); if (p != null) return p;
        p = bestSellerInFamilies(new Set<String>{ favCat }, exclude); if (p != null) return p;
        p = bestSellerInFamilies(BEAN_FAMILIES, exclude); if (p != null) return p;
        p = mostStockedInFamilies(BEAN_FAMILIES, exclude); if (p != null) return p;
        return mostStockedInFamilies(null, exclude);
    }
    // ---- axis-aware coffee picker: each set axis is a HARD filter; relax least-important first ----
    // Relaxation order: roast → brew → bean type. Caffeine (decaf) and flavored are NEVER relaxed.
    private static Product2 pickCoffeeByAxes(Set<Id> exclude, List<String> dislikeKw,
            String prefBean, String prefBrew, String prefRoast, Boolean wantsDecaf, Boolean avoidFlavored,
            List<String> relaxed) {
        String rBean = prefBean, rBrew = prefBrew, rRoast = prefRoast;
        for (Integer guard = 0; guard < 5; guard++) {
            for (Product2 cand : coffeeByAxes(exclude, rBean, rBrew, rRoast, wantsDecaf, avoidFlavored)) {
                if (!nameHasDislike(cand.Name, dislikeKw)) return cand;
            }
            // nothing matched — relax the least-important still-active axis
            if (rRoast != null)      { relaxed.add('roast');     rRoast = null; }
            else if (rBrew != null)  { relaxed.add('brew style'); rBrew = null; }
            else if (rBean != null)  { relaxed.add('bean type');  rBean = null; }
            else return null; // only caffeine/flavored constraints remain — do not violate them
        }
        return null;
    }

    private static List<Product2> coffeeByAxes(Set<Id> exclude, String beanType, String brew,
            String roast, Boolean wantsDecaf, Boolean avoidFlavored) {
        Set<String> beanFams = COFFEE_BEAN_FAMILIES;
        String q = 'SELECT Id, Name, Family, Roast_Level__c, Bean_Type__c, Brew_Style__c, Is_Decaf__c, '
            + 'Is_Flavored__c, Woo_Product_Id__c, Image_URL__c, Description, Stock_On_Hand__c FROM Product2 '
            + 'WHERE IsActive = true AND Stock_On_Hand__c > 0 AND Woo_Product_Id__c != null '
            + 'AND Family IN :beanFams AND Id NOT IN :exclude ';
        if (beanType != null)     q += 'AND Bean_Type__c = :beanType ';
        if (brew != null)         q += 'AND Brew_Style__c = :brew ';
        if (roast != null)        q += 'AND Roast_Level__c = :roast ';
        if (wantsDecaf != null)   q += 'AND Is_Decaf__c = :wantsDecaf ';
        if (avoidFlavored == true) q += 'AND Is_Flavored__c = false ';
        q += 'ORDER BY Stock_On_Hand__c DESC, Name ASC LIMIT 25';
        return Database.query(q);
    }

    private static String normBean(String s) {
        if (String.isBlank(s)) return null;
        String t = s.trim().toLowerCase();
        if (t.startsWith('single') || t.contains('origin')) return 'Single-Origin';
        if (t.contains('blend')) return 'Blend';
        return null;
    }
    private static String normBrew(String s) {
        if (String.isBlank(s)) return null;
        String t = s.trim().toLowerCase();
        if (t.contains('espresso')) return 'Espresso';
        if (t.contains('cold')) return 'Cold Brew';
        if (t.contains('all') || t.contains('drip') || t.contains('pour') || t.contains('filter')) return 'All-Purpose';
        return null;
    }
    private static String normRoast(String s) {
        if (String.isBlank(s)) return null;
        String t = s.trim().toLowerCase();
        if (t.contains('light') || t.contains('blonde')) return 'Light';
        if (t.contains('dark') || t.contains('french') || t.contains('italian')) return 'Dark';
        if (t.contains('medium') || t.contains('amber')) return 'Medium';
        return null;
    }

    private static Boolean nameHasDislike(String name, List<String> kws) {
        if (String.isBlank(name) || kws == null || kws.isEmpty()) return false;
        String n = name.toLowerCase();
        for (String k : kws) if (String.isNotBlank(k) && n.contains(k)) return true;
        return false;
    }
    private static List<String> lowerList(String csv) {
        List<String> out = new List<String>();
        if (String.isBlank(csv)) return out;
        for (String s : csv.split(',')) { String t = s.trim().toLowerCase(); if (String.isNotBlank(t)) out.add(t); }
        return out;
    }

    // ---- affinity helpers (co-purchase over OrderItem; bean vs gear scoped) ----
    private static Product2 coPurchaseAffinity(Set<Id> anchor, Set<Id> exclude, Set<String> families) {
        if (anchor == null || anchor.isEmpty()) return null;
        Set<Id> coOrders = new Set<Id>();
        for (AggregateResult ar : [SELECT OrderId oid FROM OrderItem WHERE Product2Id IN :anchor GROUP BY OrderId]) {
            coOrders.add((Id) ar.get('oid'));
        }
        if (coOrders.isEmpty()) return null;
        List<AggregateResult> ars = [
            SELECT Product2Id pid, COUNT(Id) c FROM OrderItem
            WHERE OrderId IN :coOrders AND Product2Id NOT IN :exclude AND Product2.Family IN :families
              AND Product2.IsActive = true AND Product2.Stock_On_Hand__c > 0 AND Product2.Woo_Product_Id__c != null
            GROUP BY Product2Id ORDER BY COUNT(Id) DESC LIMIT 1];
        if (ars.isEmpty()) return null;
        return loadProduct((Id) ars[0].get('pid'));
    }
    private static Product2 bestSellerInFamilies(Set<String> families, Set<Id> exclude) {
        String fam = families == null ? '' : ' AND Product2.Family IN :families ';
        List<AggregateResult> ars = Database.query(
            'SELECT Product2Id pid, SUM(Quantity) q FROM OrderItem WHERE Product2.IsActive = true ' +
            'AND Product2.Stock_On_Hand__c > 0 AND Product2.Woo_Product_Id__c != null AND Product2Id NOT IN :exclude ' +
            fam + 'GROUP BY Product2Id ORDER BY SUM(Quantity) DESC LIMIT 1');
        if (ars.isEmpty()) return null;
        return loadProduct((Id) ars[0].get('pid'));
    }
    private static Product2 mostStockedInFamilies(Set<String> families, Set<Id> exclude) {
        String fam = families == null ? '' : ' AND Family IN :families ';
        List<Product2> ps = Database.query(
            'SELECT Id, Name, Family, Woo_Product_Id__c, Image_URL__c, Description FROM Product2 ' +
            'WHERE IsActive = true AND Stock_On_Hand__c > 0 AND Woo_Product_Id__c != null AND Id NOT IN :exclude ' +
            fam + 'ORDER BY Stock_On_Hand__c DESC LIMIT 1');
        return ps.isEmpty() ? null : ps[0];
    }
    private static Product2 loadProduct(Id pid) {
        return [SELECT Id, Name, Family, Woo_Product_Id__c, Image_URL__c, Description FROM Product2 WHERE Id = :pid LIMIT 1];
    }
    private static Set<Id> toIdSet(String csv) {
        Set<Id> out = new Set<Id>();
        if (String.isBlank(csv)) return out;
        for (String s : csv.split(',')) { String t = s.trim(); if (String.isNotBlank(t)) { try { out.add((Id) t); } catch (Exception e) {} } }
        return out;
    }
}
