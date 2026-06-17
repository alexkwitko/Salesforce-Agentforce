Order orderRecord = [
    SELECT Id, OrderNumber, Woo_Order_Id__c, Account.PersonEmail
    FROM Order
    WHERE Woo_Order_Id__c LIKE 'CODEXPOST%'
    ORDER BY CreatedDate DESC
    LIMIT 1
];

PostPurchaseService.Result result = PostPurchaseService.buildOffer(orderRecord.Id);
System.debug('CODEX_POST_PURCHASE_RESULT=' + JSON.serialize(result));

List<Coupon__c> coupons = [
    SELECT Id, Code__c, Status__c, Discount_Percent__c, Woo_Coupon_Id__c,
           Order__c, Order__r.OrderNumber, Account__r.PersonEmail, CreatedDate
    FROM Coupon__c
    WHERE Order__c = :orderRecord.Id
    ORDER BY CreatedDate DESC
    LIMIT 5
];
System.debug('CODEX_POST_PURCHASE_COUPONS=' + JSON.serialize(coupons));

List<Agent_Interaction__c> interactions = [
    SELECT Id, Agent__c, Action__c, Result__c, Order__c, Product_Ids__c, CreatedDate
    FROM Agent_Interaction__c
    WHERE Order__c = :orderRecord.Id
    ORDER BY CreatedDate DESC
    LIMIT 5
];
System.debug('CODEX_POST_PURCHASE_INTERACTIONS=' + JSON.serialize(interactions));
