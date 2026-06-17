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

        // Don't CREATE an SF Order for a WooCommerce non-order status (checkout-draft, auto-draft,
        // trash, pending, failed) — these are abandoned/incomplete checkouts, NOT placed orders.
        // They will sync once the checkout completes and the order reaches a real status (a fresh
        // webhook fires then). This stops phantom "orders" like the checkout-draft 00000732.
        String createStatus = o.get('status') == null ? '' : String.valueOf(o.get('status')).toLowerCase();
        if (KwitkoServiceUtil.NON_ORDER_WOO_STATUSES.contains(createStatus)) return null;

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
        // Capture the WooCommerce GRAND total (incl. shipping/tax) — what the customer sees on the
        // storefront. Standard Order.TotalAmount is only the product subtotal (no shipping).
        try { if (o.get('total') != null) ord.Woo_Order_Total__c = Decimal.valueOf(String.valueOf(o.get('total'))); } catch (Exception e) {}
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
                OrderItem item = new OrderItem(OrderId = ord.Id, PricebookEntryId = pbe.get(pid).Id,
                    Product2Id = pbe.get(pid).Product2Id, Quantity = qty, UnitPrice = unit);
                if (li.get('id') != null) item.Woo_Line_Item_Id__c = String.valueOf(li.get('id'));
                items.add(item);
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
        DataCloudAugmentationService.refreshAccountFromDataCloudAsync(acc.Id);

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
        try { if (o.get('total') != null) upd.Woo_Order_Total__c = Decimal.valueOf(String.valueOf(o.get('total'))); } catch (Exception e) {}
        upd.Payment_Status__c = mapPayment(wooStatus, o.get('date_paid'));
        Datetime dp = parseDt(o.get('date_paid'));
        if (dp != null) upd.Date_Paid__c = dp;
        Map<String, String> trk = extractTracking(o);
        if (trk.get('number') != null) { upd.Tracking_Number__c = trk.get('number'); upd.Carrier__c = trk.get('carrier'); upd.Tracking_Url__c = trk.get('url'); }
        reconcileLineItemIds(existing.Id, o);
        Boolean preserveLocalReturn = preserveLocalReturnState(existing, wooStatus);
        if (String.isNotBlank(newFul) && newFul != existing.Fulfillment_Status__c && !preserveLocalReturn) {
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

    private static Boolean preserveLocalReturnState(Order existing, String wooStatus) {
        if (existing == null || existing.Id == null) return false;
        if (wooStatus == 'cancelled' || wooStatus == 'refunded') return false;
        if (existing.Fulfillment_Status__c != 'Return Pending' && existing.Fulfillment_Status__c != 'Returned') return false;
        return [SELECT count() FROM ReturnOrder WHERE Order__c = :existing.Id AND Status != 'Closed'] > 0;
    }

    private static void reconcileLineItemIds(Id orderId, Map<String, Object> o) {
        if (orderId == null || o == null || !(o.get('line_items') instanceof List<Object>)) return;
        List<WooLine> wooLines = new List<WooLine>();
        Set<String> wooProductIds = new Set<String>();
        for (Object rawLine : (List<Object>) o.get('line_items')) {
            if (!(rawLine instanceof Map<String, Object>)) continue;
            Map<String, Object> li = (Map<String, Object>) rawLine;
            WooLine wl = new WooLine();
            wl.id = strv(li.get('id'));
            wl.productId = strv(li.get('product_id'));
            wl.quantity = decv(li.get('quantity'));
            wl.unitPrice = decv(li.get('price'));
            if (String.isBlank(wl.id) || String.isBlank(wl.productId)) continue;
            wooLines.add(wl);
            wooProductIds.add(wl.productId);
        }
        if (wooLines.isEmpty()) return;

        Map<String, List<OrderItem>> byWooProduct = new Map<String, List<OrderItem>>();
        for (OrderItem item : [
            SELECT Id, Product2.Woo_Product_Id__c, Quantity, UnitPrice, Woo_Line_Item_Id__c
            FROM OrderItem
            WHERE OrderId = :orderId
              AND Product2.Woo_Product_Id__c IN :wooProductIds
        ]) {
            String pid = item.Product2.Woo_Product_Id__c;
            if (!byWooProduct.containsKey(pid)) byWooProduct.put(pid, new List<OrderItem>());
            byWooProduct.get(pid).add(item);
        }

        List<OrderItem> updates = new List<OrderItem>();
        Set<Id> usedOrderItemIds = new Set<Id>();
        for (WooLine wl : wooLines) {
            OrderItem match = chooseLineItemMatch(byWooProduct.get(wl.productId), wl, usedOrderItemIds);
            if (match == null || match.Woo_Line_Item_Id__c == wl.id) continue;
            match.Woo_Line_Item_Id__c = wl.id;
            updates.add(match);
            usedOrderItemIds.add(match.Id);
        }
        if (!updates.isEmpty()) update updates;
    }

    private static OrderItem chooseLineItemMatch(List<OrderItem> candidates, WooLine wl, Set<Id> usedIds) {
        if (candidates == null || candidates.isEmpty()) return null;
        List<OrderItem> usable = new List<OrderItem>();
        List<OrderItem> exact = new List<OrderItem>();
        for (OrderItem item : candidates) {
            if (usedIds.contains(item.Id)) continue;
            if (String.isNotBlank(item.Woo_Line_Item_Id__c) && item.Woo_Line_Item_Id__c != wl.id) continue;
            usable.add(item);
            Boolean qtyMatches = wl.quantity == null || item.Quantity == wl.quantity;
            Boolean unitMatches = wl.unitPrice == null || item.UnitPrice == wl.unitPrice;
            if (qtyMatches && unitMatches) exact.add(item);
        }
        if (exact.size() == 1) return exact[0];
        if (usable.size() == 1) return usable[0];
        return null;
    }

    /** WooCommerce status → Order.Fulfillment_Status__c (restricted picklist). Null = leave as-is. */
    @TestVisible
    private static String mapFulfillment(String s) {
        if (String.isBlank(s)) return null;
        if (s == 'processing') return 'Processing';
        if (s == 'completed') return 'Shipped';
        if (s == 'delivered') return 'Delivered';
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

    private class WooLine {
        String id;
        String productId;
        Decimal quantity;
        Decimal unitPrice;
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
    private static Decimal decv(Object o) {
        if (o == null) return null;
        try { return Decimal.valueOf(String.valueOf(o)); }
        catch (Exception e) { return null; }
    }
}
