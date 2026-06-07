/**
 * Maps a deserialized WooCommerce order (Map) into Salesforce:
 * upsert Person Account by email, create Order + OrderItems
 * (resolved via Product2.Woo_Product_Id__c -> PricebookEntry). Idempotent on Woo_Order_Id__c.
 */
public without sharing class WooOrderService {

    public static Id ingestOrder(Map<String, Object> o) {
        String wooOrderId = String.valueOf(o.get('id'));
        if (String.isBlank(wooOrderId) || wooOrderId == 'null') return null;

        // TWO-WAY SYNC: if the order already exists, RECONCILE its status/payment/tracking from
        // WooCommerce instead of skipping — this is how Woo-side cancellations/refunds/fulfillment
        // flow back into Salesforce (fixes SF-only-cancellation drift like order 00000727).
        List<Order> existingOrders = [SELECT Id, Fulfillment_Status__c, Status FROM Order WHERE Woo_Order_Id__c = :wooOrderId LIMIT 1];
        if (!existingOrders.isEmpty()) { reconcileFromWoo(existingOrders[0], o); return existingOrders[0].Id; }

        Map<String, Object> billing = (Map<String, Object>) o.get('billing');
        String email = billing != null ? (String) billing.get('email') : null;
        if (String.isBlank(email)) return null;
        String firstName = billing != null && billing.get('first_name') != null
            ? (String) billing.get('first_name') : 'Customer';
        String lastName = billing != null && billing.get('last_name') != null
            ? (String) billing.get('last_name') : 'Web';
        if (String.isBlank(lastName)) lastName = 'Web';
        String phone = billing != null ? (String) billing.get('phone') : null;

        Object cidObj = o.get('customer_id');
        String wooCustId = (cidObj != null && String.valueOf(cidObj) != '0') ? String.valueOf(cidObj) : null;

        // --- Upsert Person Account by email ---
        Id paRt = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true LIMIT 1].Id;
        List<Account> existing = [SELECT Id FROM Account WHERE PersonEmail = :email LIMIT 1];
        Account acc = existing.isEmpty()
            ? new Account(RecordTypeId = paRt, FirstName = firstName, LastName = lastName, PersonEmail = email)
            : existing[0];
        if (String.isNotBlank(phone)) acc.Phone = phone;
        if (wooCustId != null) acc.Woo_Customer_Id__c = wooCustId;

        // --- Email marketing consent captured at WooCommerce checkout ---
        // (additional checkout field "kwitko/marketing_consent" -> order meta "_wc_other/kwitko/marketing_consent")
        Boolean consent = parseConsent(o);
        if (consent) {
            // customer opted in on this order -> grant/refresh consent + stamp the date
            acc.Email_Consent__c = true;
            acc.Email_Consent_Date__c = System.now();
        } else if (existing.isEmpty()) {
            // brand-new customer who did NOT opt in -> explicit false (never auto-revoke an existing opt-in)
            acc.Email_Consent__c = false;
        }
        // They placed an order -> they are a CUSTOMER (buyer), not a prospect.
        acc.Customer_Status__c = 'Customer';
        upsert acc;

        // The standard price book isn't returned by SOQL in test context, so use the test helper there.
        Id stdPb = Test.isRunningTest()
            ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

        // coupon code (first applied) + total discount on the order
        String coupon = '';
        Decimal couponDiscount = 0;
        List<Object> couponLines = (List<Object>) o.get('coupon_lines');
        if (couponLines != null && !couponLines.isEmpty()) {
            Object c = ((Map<String, Object>) couponLines[0]).get('code');
            if (c != null) coupon = (String) c;
        }
        if (o.get('discount_total') != null) {
            try { couponDiscount = Decimal.valueOf(String.valueOf(o.get('discount_total'))); } catch (Exception e) {}
        }

        // --- Create Order ---
        Order ord = new Order(
            AccountId = acc.Id, EffectiveDate = Date.today(), Status = 'Draft',
            Pricebook2Id = stdPb, Woo_Order_Id__c = wooOrderId, Source__c = 'Ecommerce',
            Coupon_Code__c = coupon);
        Map<String, Object> ship = (Map<String, Object>) o.get('shipping');
        if (ship != null) {
            ord.ShippingStreet = (String) ship.get('address_1');
            ord.ShippingCity = (String) ship.get('city');
            ord.ShippingPostalCode = (String) ship.get('postcode');
            // Org has State & Country picklists -> set the ISO Code fields (Woo sends codes like US/WA)
            String cc = (String) ship.get('country');
            String sc = (String) ship.get('state');
            if (String.isNotBlank(cc)) ord.ShippingCountryCode = cc;
            if (String.isNotBlank(sc)) ord.ShippingStateCode = sc;
        }
        // Map WooCommerce status → fulfillment/payment/tracking on create (Woo is source of truth).
        String wooStatus = o.get('status') == null ? '' : String.valueOf(o.get('status')).toLowerCase();
        ord.Woo_Status__c = wooStatus;
        Map<String, String> trk = extractTracking(o);
        String mappedFul = mapFulfillment(wooStatus);
        if (String.isNotBlank(mappedFul)) ord.Fulfillment_Status__c = mappedFul;
        ord.Payment_Status__c = mapPayment(wooStatus, o.get('date_paid'));
        ord.Date_Paid__c = parseDt(o.get('date_paid'));
        if (trk.get('number') != null) { ord.Tracking_Number__c = trk.get('number'); ord.Carrier__c = trk.get('carrier'); ord.Tracking_Url__c = trk.get('url'); }
        ord.Last_Woo_Sync__c = System.now();
        insert ord;

        // --- Order line items ---
        List<Object> lines = (List<Object>) o.get('line_items');
        Set<String> wooPids = new Set<String>();
        if (lines != null) {
            for (Object lo : lines) {
                Object pid = ((Map<String, Object>) lo).get('product_id');
                if (pid != null) wooPids.add(String.valueOf(pid));
            }
        }
        Map<String, PricebookEntry> pbe = new Map<String, PricebookEntry>();
        for (PricebookEntry e : [
                SELECT Id, Product2Id, Product2.Woo_Product_Id__c FROM PricebookEntry
                WHERE Pricebook2Id = :stdPb AND Product2.Woo_Product_Id__c IN :wooPids]) {
            pbe.put(e.Product2.Woo_Product_Id__c, e);
        }
        List<OrderItem> items = new List<OrderItem>();
        if (lines != null) {
            for (Object lo : lines) {
                Map<String, Object> li = (Map<String, Object>) lo;
                String pid = String.valueOf(li.get('product_id'));
                if (!pbe.containsKey(pid)) continue;
                Decimal qty = li.get('quantity') != null ? Decimal.valueOf(String.valueOf(li.get('quantity'))) : 1;
                Decimal unit = li.get('price') != null ? Decimal.valueOf(String.valueOf(li.get('price'))) : 0;
                items.add(new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.get(pid).Id,
                    Product2Id = pbe.get(pid).Product2Id, Quantity = qty, UnitPrice = unit));
            }
        }
        if (!items.isEmpty()) insert items;

        // Journey memory: record purchased products so the orchestrator can exclude them
        // from future recommendations and avoid duplicate post-purchase offers.
        List<Id> purchasedPids = new List<Id>();
        for (OrderItem oi : items) if (oi.Product2Id != null) purchasedPids.add(oi.Product2Id);
        JourneyService.recordPurchase(email, acc.Id, purchasedPids, ord.Id);

        // Coupon redemption tracking: if this order used a coupon we issued, mark it redeemed
        // on the customer's journey with the actual discount value (closes the efficiency loop).
        Boolean weIssuedCoupon = false;
        if (String.isNotBlank(coupon)) {
            for (Customer_Journey__c j : [SELECT Id, Coupon_Code__c FROM Customer_Journey__c
                                          WHERE Email__c = :email AND Coupon_Code__c = :coupon LIMIT 1]) {
                j.Coupon_Redeemed__c = true;
                j.Coupon_Redeemed_Date__c = System.now();
                j.Coupon_Redeemed_Order_Id__c = wooOrderId;
                j.Coupon_Discount_Amount__c = couponDiscount;
                update j;
                weIssuedCoupon = true;
            }
        }

        // Cart lifecycle: a coupon WE issued was redeemed -> the abandoned cart was RECOVERED via an
        // incentive (a stronger, attributable signal than a plain conversion). Mark the cart + its Lead
        // Recovered; the AbandonedCartSweep only ever marks Converted, so this fills the missing state.
        if (weIssuedCoupon) {
            List<Cart__c> recoveredCarts = new List<Cart__c>();
            Set<Id> recoveredLeadIds = new Set<Id>();
            for (Cart__c c : [SELECT Id, Lead__c FROM Cart__c
                              WHERE Shopper_Email__c = :email AND Status__c IN ('Active', 'Abandoned')]) {
                recoveredCarts.add(new Cart__c(Id = c.Id, Status__c = 'Recovered'));
                if (c.Lead__c != null) recoveredLeadIds.add(c.Lead__c);
            }
            if (!recoveredCarts.isEmpty()) update recoveredCarts;
            List<Lead> leadUpdates = new List<Lead>();
            for (Id lid : recoveredLeadIds) leadUpdates.add(new Lead(Id = lid, Cart_Status__c = 'Recovered'));
            if (!leadUpdates.isEmpty()) update leadUpdates;
        }

        // Close the full cycle: any open Lead for this email (cart OR chat) becomes Converted-by-purchase.
        LeadLifecycleService.closeForPurchase(email, acc.Id, ord.Id);

        // Refresh agent-facing augmentation immediately after the purchase so agents do not rely on stale segments.
        DataCloudAugmentationService.refreshAccount(acc.Id);

        ord.Status = 'Activated';
        update ord;
        FulfillmentTruthService.syncFromWoo(ord, wooStatus, trk);
        return ord.Id;
    }

    /** Reads the WooCommerce checkout marketing-consent additional field from order meta_data. */
    private static Boolean parseConsent(Map<String, Object> o) {
        Object md = o.get('meta_data');
        if (!(md instanceof List<Object>)) return false;
        for (Object mo : (List<Object>) md) {
            Map<String, Object> m = (Map<String, Object>) mo;
            String k = m.get('key') == null ? '' : String.valueOf(m.get('key')).toLowerCase();
            if (k.contains('marketing_consent')) {
                String v = m.get('value') == null ? '' : String.valueOf(m.get('value')).toLowerCase();
                return (v == '1' || v == 'yes' || v == 'true');
            }
        }
        return false;
    }

    /** Reconcile an existing SF Order from a WooCommerce payload (Woo→SF status/payment/tracking). */
    @TestVisible
    private static void reconcileFromWoo(Order existing, Map<String, Object> o) {
        String wooStatus = o.get('status') == null ? '' : String.valueOf(o.get('status')).toLowerCase();
        String newFul = mapFulfillment(wooStatus);
        Order upd = new Order(Id = existing.Id);
        upd.Woo_Status__c = wooStatus;
        upd.Last_Woo_Sync__c = System.now();
        upd.Payment_Status__c = mapPayment(wooStatus, o.get('date_paid'));
        Datetime dp = parseDt(o.get('date_paid'));
        if (dp != null) upd.Date_Paid__c = dp;
        Map<String, String> trk = extractTracking(o);
        if (trk.get('number') != null) { upd.Tracking_Number__c = trk.get('number'); upd.Carrier__c = trk.get('carrier'); upd.Tracking_Url__c = trk.get('url'); }
        if (String.isNotBlank(newFul) && newFul != existing.Fulfillment_Status__c) {
            upd.Fulfillment_Status__c = newFul;
            upd.Last_Status_Change__c = System.now();
            if (wooStatus == 'cancelled') {
                upd.Cancellation_Source__c = 'WooCommerce';
                upd.Cancelled_Date__c = System.now();
                upd.Cancelled_By__c = 'WooCommerce (reconciled)';
                upd.Status_Note__c = 'Reconciled from WooCommerce: cancelled in WooCommerce on ' + System.now().format() + '.';
            } else if (wooStatus == 'refunded') {
                upd.Status_Note__c = 'Reconciled from WooCommerce: refunded on ' + System.now().format() + '.';
            } else {
                upd.Status_Note__c = 'Reconciled from WooCommerce: status "' + wooStatus + '" on ' + System.now().format() + '.';
            }
        }
        update upd;
        FulfillmentTruthService.syncFromWoo(existing, wooStatus, trk);
    }

    /** WooCommerce status → Order.Fulfillment_Status__c (restricted picklist). Null = leave as-is. */
    @TestVisible
    private static String mapFulfillment(String s) {
        if (String.isBlank(s)) return null;
        if (s == 'processing') return 'Processing';
        if (s == 'completed') return 'Shipped';
        if (s == 'cancelled') return 'Cancelled';
        if (s == 'refunded') return 'Refunded';
        if (s == 'pending' || s == 'on-hold' || s == 'failed') return 'Not Shipped';
        return null;
    }

    /** WooCommerce status (+date_paid) → Order.Payment_Status__c. */
    @TestVisible
    private static String mapPayment(String s, Object datePaid) {
        if (s == 'refunded') return 'Refunded';
        if (s == 'failed') return 'Failed';
        if (s == 'pending' || s == 'on-hold') return 'Pending';
        if (s == 'processing' || s == 'completed' || datePaid != null) return 'Paid';
        return null;
    }

    private static Datetime parseDt(Object v) {
        if (v == null) return null;
        try { return Datetime.valueOfGmt(String.valueOf(v).replace('T', ' ').replace('Z', '').substringBefore('.')); }
        catch (Exception e) { return null; }
    }

    /** Pull AST shipment tracking from order meta_data (number/carrier/url), best-effort. */
    @TestVisible
    private static Map<String, String> extractTracking(Map<String, Object> o) {
        Map<String, String> out = new Map<String, String>{ 'number' => null, 'carrier' => null, 'url' => null };
        Object md = o.get('meta_data');
        if (!(md instanceof List<Object>)) return out;
        for (Object mo : (List<Object>) md) {
            Map<String, Object> m = (Map<String, Object>) mo;
            String k = m.get('key') == null ? '' : String.valueOf(m.get('key')).toLowerCase();
            if (k.contains('shipment_tracking') || k.contains('tracking_items') || k.contains('tracking_number')) {
                Object v = m.get('value');
                if (v instanceof List<Object> && !((List<Object>) v).isEmpty() && ((List<Object>) v)[0] instanceof Map<String, Object>) {
                    Map<String, Object> t = (Map<String, Object>) ((List<Object>) v)[0];
                    out.put('number', strv(t.get('tracking_number')));
                    out.put('carrier', strv(t.get('tracking_provider')));
                    out.put('url', strv(t.get('custom_tracking_link')));
                } else if (v != null) {
                    out.put('number', String.valueOf(v));
                }
            }
        }
        return out;
    }
    private static String strv(Object o) { return o == null ? null : String.valueOf(o); }
}
