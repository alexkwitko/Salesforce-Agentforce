@isTest
private class EmployeeAgentContextServiceTest {
    @isTest
    static void recordIdWrapperReturnsSharedLeadContext() {
        Lead l = new Lead(LastName='Wrapper', Company='Kwitko', Email='wrapper.lead@example.com',
            LeadSource='WooCommerce Abandoned Cart', Status='Open - Not Contacted', Email_Consent__c=false);
        insert l;
        Customer_Journey__c j = new Customer_Journey__c(Name='wrapper.lead@example.com',
            Email__c='wrapper.lead@example.com', Coupon_Code__c='WRAPPRIVATE',
            Coupon_Redeemed__c=false, Coupon_Discount_Percent__c=10);
        insert j;

        EmployeeAgentContextService.Request req = new EmployeeAgentContextService.Request();
        req.recordId = l.Id;

        Test.startTest();
        EmployeeAgentContextService.Result res =
            EmployeeAgentContextService.getContext(new List<EmployeeAgentContextService.Request>{ req })[0];
        Test.stopTest();

        System.assertEquals(true, res.identityVerified);
        System.assertEquals('trusted_internal_record', res.privacyMode);
        System.assertEquals('wrapper.lead@example.com', res.email);
        System.assertEquals('Inside_Sales', res.handoffTarget);
        System.assertEquals('WRAPPRIVATE', res.activeCouponCode);
        System.assert(res.summary.contains('SHARED AGENT CONTEXT'));
    }
}
