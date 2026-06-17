Lead lead = [
    SELECT Id, Email, Status, Email_Consent__c
    FROM Lead
    WHERE Email = 'alexkwitko@gmail.com'
    ORDER BY LastModifiedDate DESC
    LIMIT 1
];

LeadNurtureService.Result result = LeadNurtureService.run(lead.Id);
System.debug('CODEX_LIVE_CART_RECOVERY_RESULT=' + JSON.serialize(result));

Cart__c cart = [
    SELECT Id, Name, Status__c, Shopper_Email__c, Email_Consent__c, Recovery_Sent_At__c,
           Lead__c, Lead__r.Email, Item_Count__c, Cart_Value__c
    FROM Cart__c
    WHERE Name = 'CART-0019'
    LIMIT 1
];
System.debug('CODEX_LIVE_CART_RECOVERY_CART=' + JSON.serialize(cart));

if (String.isNotBlank(result.couponCode)) {
    List<Coupon__c> coupons = [
        SELECT Id, Code__c, Status__c, Discount_Percent__c, Woo_Coupon_Id__c, CreatedDate
        FROM Coupon__c
        WHERE Code__c = :result.couponCode
        ORDER BY CreatedDate DESC
        LIMIT 5
    ];
    System.debug('CODEX_LIVE_CART_RECOVERY_COUPONS=' + JSON.serialize(coupons));
}
