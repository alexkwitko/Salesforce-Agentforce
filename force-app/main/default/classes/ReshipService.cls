/** ReshipService (reship) — creates a zero-charge replacement order (same items) for a lost/damaged delivery
 *  and opens a case. Identity-gated, journey-logged. */
public without sharing class ReshipService {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Order Identifier (optional)') public String orderIdentifier;
        @InvocableVariable(label='Reason') public String reason;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper explicitly confirms the free replacement/reship.') public Boolean confirmed;
    }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String replacementOrderNumber; @InvocableVariable public String caseNumber; @InvocableVariable public String message; }
    @InvocableMethod(label='Reship Order' description='Creates a free replacement order (same items) for a lost or damaged delivery and opens a case. Verified shopper only.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.success=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; return res; }
        Order o=KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if(o==null){ res.message='No matching order found.'; return res; }
        if(r.confirmed!=true){ res.message='Please confirm you want a free replacement/reship for order '+o.OrderNumber+' before I create it.'; return res; }
        String reason=String.isBlank(r.reason)?'Lost/damaged delivery':r.reason.trim();
        Order src=[SELECT Id, OrderNumber, AccountId, Pricebook2Id, ShippingStreet, ShippingCity, ShippingStateCode, ShippingPostalCode, ShippingCountryCode FROM Order WHERE Id=:o.Id LIMIT 1];
        Order rep=new Order(AccountId=src.AccountId, EffectiveDate=Date.today(), Status='Draft', Pricebook2Id=src.Pricebook2Id, Source__c='Manual',
            Fulfillment_Status__c='Processing', ShippingStreet=src.ShippingStreet, ShippingCity=src.ShippingCity, ShippingStateCode=src.ShippingStateCode,
            ShippingPostalCode=src.ShippingPostalCode, ShippingCountryCode=src.ShippingCountryCode,
            Status_Note__c='Free replacement (reship) for order '+src.OrderNumber+' by Chat Agent. Reason: '+reason);
        insert rep;
        List<OrderItem> cloneItems=new List<OrderItem>();
        for(OrderItem oi:[SELECT PricebookEntryId, Product2Id, Quantity FROM OrderItem WHERE OrderId=:src.Id]){
            cloneItems.add(new OrderItem(OrderId=rep.Id, PricebookEntryId=oi.PricebookEntryId, Product2Id=oi.Product2Id, Quantity=oi.Quantity, UnitPrice=0));
        }
        if(!cloneItems.isEmpty()) insert cloneItems;
        update new Order(Id=rep.Id, Status='Activated');
        res.replacementOrderNumber=[SELECT OrderNumber FROM Order WHERE Id=:rep.Id].OrderNumber;
        Case c=new Case(AccountId=acc.Id, ContactId=acc.PersonContactId, Order__c=src.Id, Origin='Chat', Status='New', Priority='High', Category__c='Shipping',
            Subject='Reship — order '+src.OrderNumber, Summary__c='Free replacement '+res.replacementOrderNumber+' created for '+src.OrderNumber+'. Reason: '+reason, Description=reason);
        insert c; res.caseNumber=[SELECT CaseNumber FROM Case WHERE Id=:c.Id].CaseNumber;
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=r.email; lr.agent='Service'; lr.action='reship'; lr.stage='Service'; lr.orderId=String.valueOf(src.Id);
            lr.result='Reship '+res.replacementOrderNumber+' for '+src.OrderNumber+'; case '+res.caseNumber; JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){}
        res.success=true; res.message='I created a free replacement (order '+res.replacementOrderNumber+') for '+src.OrderNumber+' and our team is on it (case '+res.caseNumber+').';
        return res;
    }
}
