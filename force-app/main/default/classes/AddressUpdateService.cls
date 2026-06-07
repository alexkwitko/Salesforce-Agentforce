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
    }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String message; }
    @InvocableMethod(label='Update Shipping Address' description='Updates the shipping address on a not-yet-shipped order in Salesforce and WooCommerce. Verified shopper only.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.success=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; return res; }
        Order o=KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if(o==null){ res.message='No matching order found.'; return res; }
        String ful=KwitkoServiceUtil.fulfillment(o);
        if(!(new Set<String>{'Not Shipped','Processing'}.contains(ful))){
            res.message='Order '+o.OrderNumber+' is already '+ful+', so the shipping address can no longer be changed. I can open a case for our team.'; return res;
        }
        if(r.confirmed!=true){ res.message='Please confirm the full replacement shipping address before I update order '+o.OrderNumber+'.'; return res; }
        // callout to Woo first, then DML
        Boolean wooOk=WooOrderActionService.updateShippingAddress(o.Woo_Order_Id__c, r.street, r.city, r.stateCode, r.postalCode, r.countryCode);
        update new Order(Id=o.Id, ShippingStreet=r.street, ShippingCity=r.city, ShippingStateCode=r.stateCode, ShippingPostalCode=r.postalCode, ShippingCountryCode=r.countryCode,
            Status_Note__c='Shipping address updated by Chat Agent on '+System.now().format()+(wooOk?'; synced to WooCommerce.':'; WooCommerce sync pending.'), Last_Status_Change__c=System.now());
        log(r.email,'update_shipping_address','Updated shipping address on order '+o.OrderNumber+(wooOk?' (synced to Woo)':' (Woo sync pending)'));
        res.success=true;
        res.message='Updated the shipping address on order '+o.OrderNumber+(wooOk?' and synced it to our store.':'. The store sync is processing.');
        return res;
    }
    private static void log(String email,String action,String result){
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=email; lr.agent='Service'; lr.action=action; lr.stage='Service'; lr.result=result;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){}
    }
}
