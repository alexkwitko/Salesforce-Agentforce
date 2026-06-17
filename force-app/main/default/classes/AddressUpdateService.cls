/** AddressUpdateService (update_shipping_address) — FIX: updates the shipping address on a not-yet-shipped
 *  order in Salesforce AND pushes it to WooCommerce. Identity-gated, journey-logged. */
public without sharing class AddressUpdateService {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Order Identifier (optional)') public String orderIdentifier;
        @InvocableVariable(label='Street') public String street;
        @InvocableVariable(label='City') public String city;
        @InvocableVariable(label='State Code') public String stateCode;
        @InvocableVariable(label='Postal Code') public String postalCode;
        @InvocableVariable(label='Country Code') public String countryCode;
        @InvocableVariable(label='Confirmed by Shopper' description='Must be true only after the shopper explicitly confirms the replacement shipping address.') public Boolean confirmed;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the address update conversation so the solved service Case has context.') public String chatSummary;
    }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String caseNumber; @InvocableVariable public String message; }
    @InvocableMethod(label='Update Shipping Address' description='Updates the shipping address on a not-yet-shipped order in Salesforce and WooCommerce. Verified shopper only.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.success=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; return res; }
        Order o=KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if(o==null){ res.message='No matching order found.'; return res; }
        String displayNo=KwitkoServiceUtil.displayOrderNumber(o);
        String ful=KwitkoServiceUtil.fulfillment(o);
        if(!(new Set<String>{'Not Shipped','Processing'}.contains(ful))){
            res.message='Order '+displayNo+' is already '+ful+', so the shipping address can no longer be changed. I can open a case for our team.'; return res;
        }
        if(r.confirmed!=true){ res.message='Please confirm the full replacement shipping address before I update order '+displayNo+'.'; return res; }
        // callout to Woo first, then DML
        Boolean wooOk=WooOrderActionService.updateShippingAddress(o.Woo_Order_Id__c, r.street, r.city, r.stateCode, r.postalCode, r.countryCode);
        update new Order(Id=o.Id, ShippingStreet=r.street, ShippingCity=r.city, ShippingStateCode=r.stateCode, ShippingPostalCode=r.postalCode, ShippingCountryCode=r.countryCode,
            Status_Note__c='Shipping address updated by Chat Agent on '+System.now().format()+(wooOk?'; synced to WooCommerce.':'; WooCommerce sync pending.'), Last_Status_Change__c=System.now());
        String auditResult = 'Updated shipping address on order '+displayNo+(wooOk?' (synced to Woo)':' (Woo sync pending)');
        res.caseNumber=createCase(acc,o,displayNo,auditResult,wooOk,r.chatSummary);
        log(r.email,'update_shipping_address',auditResult, o.Id, r.chatSummary);
        res.success=true;
        res.message='Updated the shipping address on order '+displayNo+(wooOk?' and synced it to our store.':'. The store sync is processing.')
            +(String.isBlank(res.caseNumber)?'':' Case '+res.caseNumber+' is tracking it.');
        return res;
    }
    private static String createCase(Account acc, Order orderRecord, String displayNo, String auditResult, Boolean wooOk, String chatSummary){
        try{
            Case c=new Case(AccountId=acc.Id, ContactId=acc.PersonContactId, Order__c=orderRecord.Id, Woo_Order_Id__c=orderRecord.Woo_Order_Id__c,
                Origin='Chat', Status=wooOk?'Closed':'New', Priority=wooOk?'Low':'Medium', Category__c='Shipping',
                Subject='Chat service: Shipping address updated',
                Summary__c=auditResult,
                Description=CaseTranscriptUtil.append(auditResult, chatSummary));
            if(wooOk){
                c.Resolution__c=auditResult;
                c.Resolved_By__c='Chat Agent ('+UserInfo.getName()+')';
            }
            insert c;
            CaseTranscriptUtil.insertTask(c.Id, acc.PersonContactId, chatSummary);
            return [SELECT CaseNumber FROM Case WHERE Id=:c.Id LIMIT 1].CaseNumber;
        }catch(Exception e){
            System.debug('address update case failed: '+e.getMessage());
            return null;
        }
    }
    private static void log(String email,String action,String result,Id orderId,String chatSummary){
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=email; lr.agent='Service'; lr.action=action; lr.stage='Service'; lr.result=result;
            lr.orderId=orderId==null?null:String.valueOf(orderId); lr.chatSummary=chatSummary;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){}
    }
}
