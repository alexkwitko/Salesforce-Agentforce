/** TrackingService (get_tracking) — READ: returns the shopper's order tracking (carrier/number/url),
 *  synced from WooCommerce/AST. Identity-gated. */
public without sharing class TrackingService {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Order Identifier (optional)') public String orderIdentifier;
    }
    public class Result {
        @InvocableVariable public Boolean found;
        @InvocableVariable public String trackingNumber;
        @InvocableVariable public String carrier;
        @InvocableVariable public String trackingUrl;
        @InvocableVariable public String message;
    }
    @InvocableMethod(label='Get Tracking' description='Returns carrier, tracking number, and tracking link for the shopper own order. Read-only, verified shopper only.')
    public static List<Result> get(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.found=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; return res; }
        Order o=KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if(o==null){ res.message='No matching order found.'; return res; }
        FulfillmentTruthService.Snapshot truth=FulfillmentTruthService.forOrder(o);
        res.trackingNumber=truth.trackingNumber; res.carrier=truth.carrier; res.trackingUrl=truth.trackingUrl;
        if(String.isBlank(truth.trackingNumber)){
            res.message='Order '+truth.orderNumber+' is '+(truth.effectiveStatus==null?'being prepared':truth.effectiveStatus)+'. No tracking number is available yet.';
        } else {
            res.found=true;
            res.message='Order '+truth.orderNumber+' ('+truth.effectiveStatus+'): '+(String.isBlank(truth.carrier)?'':truth.carrier+' ')+'tracking '+truth.trackingNumber
                +(String.isBlank(truth.trackingUrl)?'':' — '+truth.trackingUrl);
            if(truth.effectiveStatus=='Shipped' && truth.hasDeliveryProof!=true) res.message+=' It is not marked delivered yet.';
        }
        return res;
    }
}
