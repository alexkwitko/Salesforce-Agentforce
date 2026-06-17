/** TrackingService (get_tracking) — READ: returns the shopper's order tracking (carrier/number/url),
 *  synced from WooCommerce/AST. Identity-gated. */
public without sharing class TrackingService {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Order Identifier (optional)') public String orderIdentifier;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the conversation so the solved service Case has context.')
        public String chatSummary;
    }
    public class Result {
        @InvocableVariable public Boolean found;
        @InvocableVariable public String trackingNumber;
        @InvocableVariable public String carrier;
        @InvocableVariable public String trackingUrl;
        @InvocableVariable public String caseNumber;
        @InvocableVariable public String message;
    }
    @InvocableMethod(label='Get Tracking' description='Returns carrier, tracking number, and tracking link for the shopper own order. Read-only, verified shopper only.')
    public static List<Result> get(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.found=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; res.caseNumber=caseNumber(CaseTranscriptUtil.insertSolvedCase(null,null,r.email,null,null,'Shipping','Chat service: Tracking answered',res.message,r.chatSummary)); logSolvedService(r,null,res.message); return res; }
        Order o=KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if(o==null){ res.message='No matching order found.'; res.caseNumber=caseNumber(CaseTranscriptUtil.insertSolvedCase(acc.Id,acc.PersonContactId,r.email,null,null,'Shipping','Chat service: Tracking answered',res.message,r.chatSummary)); logSolvedService(r,null,res.message); return res; }
        FulfillmentTruthService.Snapshot truth=FulfillmentTruthService.forOrder(o);
        String displayNo=String.isBlank(truth.orderNumber)?KwitkoServiceUtil.displayOrderNumber(o):truth.orderNumber;
        res.trackingNumber=truth.trackingNumber; res.carrier=truth.carrier; res.trackingUrl=truth.trackingUrl;
        if(String.isBlank(truth.trackingNumber)){
            res.message='Order '+displayNo+' is '+(truth.effectiveStatus==null?'being prepared':truth.effectiveStatus)+'. No tracking number is available yet.';
        } else {
            res.found=true;
            res.message='Order '+displayNo+' ('+truth.effectiveStatus+'): '+(String.isBlank(truth.carrier)?'':truth.carrier+' ')+'tracking '+truth.trackingNumber
                +(String.isBlank(truth.trackingUrl)?'':' — '+truth.trackingUrl);
            if(truth.effectiveStatus=='Shipped' && truth.hasDeliveryProof!=true) res.message+=' It is not marked delivered yet.';
        }
        res.caseNumber=caseNumber(CaseTranscriptUtil.insertSolvedCase(acc.Id,acc.PersonContactId,r.email,o.Id,o.Woo_Order_Id__c,'Shipping','Chat service: Tracking answered',res.message,r.chatSummary));
        logSolvedService(r,o.Id,res.message);
        return res;
    }
    private static String caseNumber(Id caseId){
        if(caseId==null) return null;
        List<Case> cs=[SELECT CaseNumber FROM Case WHERE Id=:caseId LIMIT 1];
        return cs.isEmpty()?null:cs[0].CaseNumber;
    }
    private static void logSolvedService(Request r, Id orderId, String result){
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=r.email; lr.agent='Service'; lr.action='get_tracking'; lr.stage='Resolved';
            lr.orderId=orderId==null?null:String.valueOf(orderId); lr.result=result; lr.chatSummary=r.chatSummary;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){ System.debug('journey log failed: '+e.getMessage()); }
    }
}
