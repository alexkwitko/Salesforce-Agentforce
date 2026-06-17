/** FailedPaymentService (handle_failed_payment) — checks Woo payment status and gives the shopper a secure
 *  pay-now link to retry, plus opens a billing case. Identity-gated, journey-logged. */
public without sharing class FailedPaymentService {
    private static final String STORE='https://deepskyblue-deer-920559.hostingersite.com';
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Order Identifier (optional)') public String orderIdentifier;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the payment conversation so the Case carries the chat trail.') public String chatSummary;
    }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String payUrl; @InvocableVariable public String caseNumber; @InvocableVariable public String message; }
    @InvocableMethod(label='Handle Failed Payment' description='Checks payment status and returns a secure pay-now link to retry a failed/pending payment, and opens a billing case. Verified shopper only.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.success=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; return res; }
        Order o=KwitkoServiceUtil.findOrder(acc.Id, r.orderIdentifier);
        if(o==null){ res.message='No matching order found.'; return res; }
        Order full=[SELECT Id, OrderNumber, Payment_Status__c, Woo_Order_Id__c FROM Order WHERE Id=:o.Id LIMIT 1];
        String displayNo=KwitkoServiceUtil.displayOrderNumber(full);
        String pay=full.Payment_Status__c;
        if(pay=='Paid'){
            String resolution='Payment already paid on order '+displayNo+'. Shopper was told no payment retry is needed.';
            res.caseNumber=caseNumber(CaseTranscriptUtil.insertSolvedCase(acc.Id, acc.PersonContactId, r.email, full.Id,
                full.Woo_Order_Id__c, 'Billing', 'Chat service: Payment question answered', resolution, r.chatSummary));
            res.success=true; res.message='Good news — order '+displayNo+' is already paid. Nothing to do.'
                +(String.isBlank(res.caseNumber)?'':' Case '+res.caseNumber+' records this answer.');
            log(r.email,'handle_failed_payment','Payment already paid on '+displayNo, full.Id, r.chatSummary);
            return res;
        }
        res.payUrl=STORE+'/checkout/order-pay/'+full.Woo_Order_Id__c+'/?pay_for_order=true';
        Case c=new Case(AccountId=acc.Id, ContactId=acc.PersonContactId, Order__c=o.Id, Woo_Order_Id__c=full.Woo_Order_Id__c, Origin='Chat',
            Status='New', Priority='High', Category__c='Billing', Subject='Failed/pending payment — order '+displayNo,
            Summary__c='Payment status '+pay+' on order '+displayNo+'. Shopper given a pay-now link.', Description=CaseTranscriptUtil.append('Payment '+pay+'. Pay link issued.', r.chatSummary));
        insert c; res.caseNumber=[SELECT CaseNumber FROM Case WHERE Id=:c.Id].CaseNumber;
        CaseTranscriptUtil.insertTask(c.Id, acc.PersonContactId, r.chatSummary);
        log(r.email,'handle_failed_payment','Payment '+pay+' on '+displayNo+'; pay link issued; case '+res.caseNumber, o.Id, r.chatSummary);
        res.success=true;
        res.message='Your payment for order '+displayNo+' is '+pay+'. You can securely complete it here: '+res.payUrl+' (case '+res.caseNumber+' is tracking it).';
        return res;
    }
    private static String caseNumber(Id caseId){
        if(caseId==null) return null;
        List<Case> cases=[SELECT CaseNumber FROM Case WHERE Id=:caseId LIMIT 1];
        return cases.isEmpty()?null:cases[0].CaseNumber;
    }
    private static void log(String email,String action,String result,Id orderId,String chatSummary){
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=email; lr.agent='Service'; lr.action=action; lr.stage='Service'; lr.result=result;
            lr.orderId=orderId==null?null:String.valueOf(orderId); lr.chatSummary=chatSummary;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){}
    }
}
