/**
 * PostPurchaseService
 * Core offer engine (used by the headless automation AND the assisted agent).
 * Given an Order, it:
 *   1. CONSENT GATE first — does nothing if the customer hasn't opted in.
 *   2. Finds the customer's favorite category (Product Family bought most).
 *   3. Picks the BEST-SELLING in-stock product in that same category they didn't buy
 *      (falls back to most-stocked if there's no sales history yet).
 *   4. Adds a COMPLEMENTARY cross-sell (e.g. bought beans -> suggest a grinder/filter).
 *   5. Creates a one-time % coupon (Coupon__c) valid 30 days, scoped to those products.
 *   6. Pushes the coupon to WooCommerce (enforcement) via the WooCommerce Named Credential.
 *   7. Emails the customer a personalized "buy again" recommendation.
 * Deterministic on purpose: the code always decides the product + coupon (never an LLM).
 * `without sharing`: this is trusted back-end automation (coupons/email) that must run
 * regardless of who triggered it (e.g. the locked-down Site guest user behind the webhook),
 * so it must not be limited by the running user's record visibility.
 */
public without sharing class PostPurchaseService {

    // Coffee/"bean" families get a complementary equipment/accessory cross-sell.
    private static final Set<String> BEAN_FAMILIES = new Set<String>{
        'Single-Origin','Blends','Espresso','Decaf','Flavored','Subscriptions','Gift Sets'
    };
    private static final Set<String> GEAR_FAMILIES = new Set<String>{
        'Grinders','Filters','Pour-Over & Drippers','Kettles','French Press & AeroPress',
        'Scales','Espresso Machines','Mugs & Cups','Storage','Cleaning'
    };

    public class Request {
        @InvocableVariable(label='Order ID' required=true)
        public Id orderId;
    }

    public class Result {
        @InvocableVariable(label='Coupon Code') public String couponCode;
        @InvocableVariable(label='Discount Percent') public Decimal discountPercent;
        @InvocableVariable(label='Recommended Product') public String recommendedProduct;
        @InvocableVariable(label='Complementary Product') public String complementaryProduct;
        @InvocableVariable(label='Favorite Category') public String favoriteCategory;
        @InvocableVariable(label='Summary') public String summary;
        @InvocableVariable(label='Success') public Boolean success;
    }

    @InvocableMethod(label='Generate Post-Purchase Offer'
        description='Analyzes an order, creates a personalized coupon, pushes it to WooCommerce, and emails the customer.')
    public static List<Result> generateOffer(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(buildOffer(req.orderId));
        }
        return results;
    }

    /** Single-order pipeline (callout BEFORE dml to avoid uncommitted-work error). */
    public static Result buildOffer(Id orderId) {
        Result res = new Result();
        res.success = false;

        Order ord = [
            SELECT Id, OrderNumber, AccountId, Account.Name, Account.PersonEmail,
                   Account.PersonContactId, Account.Email_Consent__c, TotalAmount, Coupon_Code__c,
                   Status, Woo_Status__c, Fulfillment_Status__c,
                   Account.Data_Cloud_Churn_Risk__c, Account.Data_Cloud_Next_Best_Action__c,
                   Account.Data_Cloud_Return_Count__c, Account.Has_Returned_Order__c,
                   Account.Return_Count__c, Account.Winback_Needed__c
            FROM Order WHERE Id = :orderId LIMIT 1
        ];

        // ── CONSENT GATE (FIRST — before any analysis, recommendation, coupon, callout, or email) ──
        if (ord.Account.Email_Consent__c != true) {
            res.summary = 'No email consent on file for ' + ord.Account.Name
                + ' — skipped. No offer generated, no coupon created, no email sent.';
            return res;
        }

        if (!isEligibleForOffer(ord)) {
            res.summary = 'Order ' + ord.OrderNumber + ' is not eligible for a post-purchase offer because its order/fulfillment status is '
                + String.valueOf(ord.Status) + '/' + String.valueOf(ord.Fulfillment_Status__c) + '. No offer generated, no coupon created, no email sent.';
            return res;
        }

        if (RecommendationStrategyService.requiresServiceRecoveryBeforeCoupon(ord.Account)) {
            res.summary = 'Order ' + ord.OrderNumber + ' is not eligible for a normal post-purchase sales offer because the customer has active return/service recovery risk: '
                + RecommendationStrategyService.serviceRecoveryCouponHoldMessage(ord.Account)
                + ' No offer generated, no coupon created, no email sent.';
            return res;
        }

        // Idempotency: skip only if a POST-PURCHASE Coupon__c already exists for this order.
        // (Do NOT guard on Order.Coupon_Code__c — ingestion fills that with the coupon the customer
        // REDEEMED at checkout, which is unrelated to whether we've sent a post-purchase offer.)
        if ([SELECT count() FROM Coupon__c WHERE Order__c = :orderId] > 0) {
            res.summary = 'Order ' + ord.OrderNumber + ' already has a post-purchase offer; skipping.';
            res.success = true;
            return res;
        }

        List<OrderItem> items = [
            SELECT Quantity, Product2Id, Product2.Name, Product2.Family
            FROM OrderItem WHERE OrderId = :orderId
        ];

        // 1. Favorite category = family with greatest purchased quantity.
        Map<String, Decimal> qtyByCategory = new Map<String, Decimal>();
        Set<Id> purchasedProductIds = new Set<Id>();
        for (OrderItem oi : items) {
            purchasedProductIds.add(oi.Product2Id);
            String fam = String.isBlank(oi.Product2.Family) ? 'Coffee' : oi.Product2.Family;
            qtyByCategory.put(fam, (qtyByCategory.get(fam) == null ? 0 : qtyByCategory.get(fam)) + oi.Quantity);
        }
        if (purchasedProductIds.isEmpty()) purchasedProductIds.add(null); // guard for NOT IN
        String favCategory = 'Coffee';
        Decimal best = -1;
        for (String fam : qtyByCategory.keySet()) {
            if (qtyByCategory.get(fam) > best) { best = qtyByCategory.get(fam); favCategory = fam; }
        }
        res.favoriteCategory = favCategory;

        // 2. Primary recommendation, best signal first:
        //    (a) co-purchase affinity ("customers who bought this also bought ..."),
        //    (b) best-seller in the same category, (c) most-stocked in category, (d) any in-stock.
        // Primary is always a COFFEE/consumable (a buy-again item), not gear.
        Product2 rec = coPurchaseAffinity(purchasedProductIds, purchasedProductIds, BEAN_FAMILIES);
        if (rec == null) rec = bestSellerInFamilies(new Set<String>{ favCategory }, purchasedProductIds);
        if (rec == null) rec = bestSellerInFamilies(BEAN_FAMILIES, purchasedProductIds);
        if (rec == null) rec = mostStockedInFamilies(BEAN_FAMILIES, purchasedProductIds);
        if (rec == null) rec = mostStockedInFamilies(null, purchasedProductIds); // last resort: any in-stock
        if (rec == null) {
            res.summary = 'No in-stock recommendation available for order ' + ord.OrderNumber + '.';
            return res;
        }
        res.recommendedProduct = rec.Name;
        Set<Id> excludeForComp = new Set<Id>(purchasedProductIds);
        excludeForComp.add(rec.Id);

        // 3. Complementary cross-sell (beans -> gear). Best-seller among gear, else null.
        Product2 comp = null;
        if (BEAN_FAMILIES.contains(favCategory)) {
            comp = coPurchaseAffinity(purchasedProductIds, excludeForComp, GEAR_FAMILIES);
            if (comp == null) comp = bestSellerInFamilies(GEAR_FAMILIES, excludeForComp);
            if (comp == null) comp = mostStockedInFamilies(GEAR_FAMILIES, excludeForComp);
        }
        if (comp != null) res.complementaryProduct = comp.Name;

        // 4. Discount = buyer-aware, from the Discount_Rule__mdt matrix (post_purchase channel).
        //    Recurrence is based on trailing-12-month purchases + LTV; LESS recurrent buyers get a
        //    bigger, more aggressive discount. Falls back to an order-value tier if no rule is found.
        String buyerType = RecommendationStrategyService.classifyBuyer(ord.AccountId);
        Decimal pct = (ord.TotalAmount != null && ord.TotalAmount >= 100) ? 20 : 15; // fallback
        for (Discount_Rule__mdt d : [SELECT Percent__c FROM Discount_Rule__mdt
                                     WHERE Buyer_Type__c = :buyerType AND Channel__c = 'post_purchase' LIMIT 1]) {
            if (d.Percent__c != null) pct = d.Percent__c;
        }
        res.discountPercent = pct;
        Date expiry = Date.today().addDays(30);
        String code = generateCode(favCategory, ord.OrderNumber);
        res.couponCode = code;

        String summary = 'Because you loved our ' + favCategory + ', enjoy ' + pct.intValue()
            + '% off ' + rec.Name + (comp != null ? ' (and ' + comp.Name + ')' : '')
            + ' with code ' + code + ' — valid through ' + expiry.format() + '. Stock up and brew again!';
        res.summary = summary;

        // Build the email body FIRST (AI copy + product photos). Both this and the Woo
        // coupon push are callouts, so they must happen BEFORE any DML in this transaction.
        String emailBody = PostPurchaseCopy.generate(
            ord.Account.Name, favCategory,
            rec.Name, rec.Image_URL__c, rec.Description,
            comp != null ? comp.Name : null, comp != null ? comp.Image_URL__c : null,
            code, pct, expiry);

        // Coupon scoped to the recommended (+ complementary) product(s).
        List<String> wooIds = new List<String>();
        if (String.isNotBlank(rec.Woo_Product_Id__c)) wooIds.add(rec.Woo_Product_Id__c);
        if (comp != null && String.isNotBlank(comp.Woo_Product_Id__c)) wooIds.add(comp.Woo_Product_Id__c);
        String wooCouponId = pushCouponToWoo(code, pct, expiry, ord.Account.PersonEmail, wooIds);

        // Persist Coupon__c + stamp order (DML now that callouts are done).
        insert new Coupon__c(
            Name = code, Code__c = code, Account__c = ord.AccountId, Order__c = ord.Id,
            Recommended_Product__c = rec.Id, Discount_Percent__c = pct, Expiry_Date__c = expiry,
            Status__c = 'Issued', Woo_Coupon_Id__c = wooCouponId, Recommendation_Summary__c = summary
        );
        if (String.isBlank(ord.Coupon_Code__c)) {
            update new Order(Id = ord.Id, Coupon_Code__c = code);
        }

        // Email the customer (Messaging.sendEmail is not a callout; safe after DML).
        sendEmail(ord, 'Your ' + pct.intValue() + '% off is waiting, ' + ord.Account.Name + ' ☕', emailBody);

        // Cross-agent context: Growth generated an offer, so Service/Concierge/Inside Sales should know.
        try {
            List<String> recIds = new List<String>{ String.valueOf(rec.Id) };
            if (comp != null) recIds.add(String.valueOf(comp.Id));
            JourneyService.recordInteraction(
                ord.Account.PersonEmail,
                'Post_Purchase_Growth',
                'generate_offer',
                String.join(recIds, ','),
                String.valueOf(ord.Id),
                'Sent ' + code + ' (' + pct.intValue() + '% off); recommended '
                    + rec.Name + (comp == null ? '' : ' + ' + comp.Name),
                'Post-Purchase',
                String.join(recIds, ','),
                String.valueOf(ord.Id)
            );
        } catch (Exception e) {
            System.debug('journey log failed: ' + e.getMessage());
        }

        res.success = true;
        return res;
    }

    private static Boolean isEligibleForOffer(Order ord) {
        if (ord == null) return false;
        if (ord.Status != 'Activated') return false;
        String woo = String.isBlank(ord.Woo_Status__c) ? '' : ord.Woo_Status__c.trim().toLowerCase();
        String fulfillment = String.isBlank(ord.Fulfillment_Status__c) ? '' : ord.Fulfillment_Status__c.trim().toLowerCase();
        Set<String> blocked = new Set<String>{ 'cancelled', 'canceled', 'returned', 'refunded', 'failed' };
        if (blocked.contains(woo) || blocked.contains(fulfillment)) return false;
        return true;
    }

    /**
     * Co-purchase affinity: "customers who bought {their items} also bought ...".
     * Finds the product most frequently appearing in OTHER orders that contain what
     * this customer bought (excluding what they already have), in stock + active.
     */
    private static Product2 coPurchaseAffinity(Set<Id> purchased, Set<Id> exclude, Set<String> families) {
        if (purchased == null || purchased.isEmpty()) return null;
        Set<Id> coOrders = new Set<Id>();
        for (AggregateResult ar : [
            SELECT OrderId oid FROM OrderItem WHERE Product2Id IN :purchased GROUP BY OrderId
        ]) coOrders.add((Id) ar.get('oid'));
        if (coOrders.isEmpty()) return null;
        List<AggregateResult> ars = [
            SELECT Product2Id pid, COUNT(Id) c FROM OrderItem
            WHERE OrderId IN :coOrders AND Product2Id NOT IN :exclude AND Product2.Family IN :families
              AND Product2.IsActive = true AND Product2.Stock_On_Hand__c > 0 AND Product2.Woo_Product_Id__c != null
            GROUP BY Product2Id ORDER BY COUNT(Id) DESC LIMIT 1
        ];
        if (ars.isEmpty()) return null;
        Id pid = (Id) ars[0].get('pid');
        return [SELECT Id, Name, Woo_Product_Id__c, Image_URL__c, Description FROM Product2 WHERE Id = :pid LIMIT 1];
    }

    /** Best-selling (most units ordered all-time) in-stock, active product in the given families. */
    private static Product2 bestSellerInFamilies(Set<String> families, Set<Id> exclude) {
        String famClause = families == null ? '' : ' AND Product2.Family IN :families ';
        List<AggregateResult> ars = Database.query(
            'SELECT Product2Id pid, SUM(Quantity) q FROM OrderItem ' +
            'WHERE Product2.IsActive = true AND Product2.Stock_On_Hand__c > 0 ' +
            'AND Product2.Woo_Product_Id__c != null AND Product2Id NOT IN :exclude ' + famClause +
            'GROUP BY Product2Id ORDER BY SUM(Quantity) DESC LIMIT 1'
        );
        if (ars.isEmpty()) return null;
        Id pid = (Id) ars[0].get('pid');
        return [SELECT Id, Name, Woo_Product_Id__c, Image_URL__c, Description FROM Product2 WHERE Id = :pid LIMIT 1];
    }

    /** Fallback: most-stocked in-stock active product in the given families (or any if null). */
    private static Product2 mostStockedInFamilies(Set<String> families, Set<Id> exclude) {
        String famClause = families == null ? '' : ' AND Family IN :families ';
        List<Product2> ps = Database.query(
            'SELECT Id, Name, Woo_Product_Id__c, Image_URL__c, Description FROM Product2 ' +
            'WHERE IsActive = true AND Stock_On_Hand__c > 0 AND Woo_Product_Id__c != null ' +
            'AND Id NOT IN :exclude ' + famClause + 'ORDER BY Stock_On_Hand__c DESC LIMIT 1'
        );
        return ps.isEmpty() ? null : ps[0];
    }

    private static String generateCode(String category, String orderNumber) {
        String catTag = category.replaceAll('[^A-Za-z]', '').toUpperCase();
        catTag = catTag.length() >= 3 ? catTag.substring(0, 3) : catTag;
        String suffix = orderNumber.replaceAll('[^0-9]', '');
        suffix = suffix.length() >= 4 ? suffix.substring(suffix.length() - 4) : suffix;
        return 'BREW' + catTag + suffix;
    }

    /** WooCommerce coupon create. Returns Woo coupon id (string) or null on failure. */
    private static String pushCouponToWoo(String code, Decimal pct, Date expiry, String email, List<String> wooProductIds) {
        Map<String, Object> body = new Map<String, Object>{
            'code' => code, 'discount_type' => 'percent', 'amount' => String.valueOf(pct.intValue()),
            'individual_use' => true, 'usage_limit' => 1, 'usage_limit_per_user' => 1,
            'date_expires' => String.valueOf(expiry) + 'T23:59:59'
        };
        if (String.isNotBlank(email)) body.put('email_restrictions', new List<String>{ email });
        if (wooProductIds != null && !wooProductIds.isEmpty()) {
            List<Integer> ids = new List<Integer>();
            for (String s : wooProductIds) ids.add(Integer.valueOf(s));
            body.put('product_ids', ids);
        }
        try {
            HttpRequest httpReq = new HttpRequest();
            httpReq.setEndpoint('callout:WooCommerce/wp-json/wc/v3/coupons');
            httpReq.setMethod('POST');
            httpReq.setHeader('Content-Type', 'application/json');
            httpReq.setBody(JSON.serialize(body));
            httpReq.setTimeout(60000);
            HttpResponse resp = new Http().send(httpReq);
            if (resp.getStatusCode() >= 200 && resp.getStatusCode() < 300) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
                Object idVal = parsed.get('id');
                return idVal == null ? null : String.valueOf(idVal);
            }
            System.debug('Woo coupon push failed: ' + resp.getStatusCode() + ' ' + resp.getBody());
        } catch (Exception e) {
            System.debug('Woo coupon push exception: ' + e.getMessage());
        }
        return null;
    }

    private static void sendEmail(Order ord, String subject, String htmlBody) {
        if (String.isBlank(ord.Account.PersonEmail)) return;
        if (ord.Account.Email_Consent__c != true) return; // defense in depth
        try {
            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(new List<String>{ ord.Account.PersonEmail });
            msg.setSubject(subject);
            msg.setHtmlBody(htmlBody);
            msg.setSaveAsActivity(false);
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ msg });
        } catch (Exception e) {
            System.debug('Email send failed: ' + e.getMessage());
        }
    }
}
