/** CallbackService (schedule_callback) — logs a callback request as a high-priority Task + Case for a human. */
public without sharing class CallbackService {
    public class Request {
        @InvocableVariable(label='Email' required=true) public String email;
        @InvocableVariable(label='Verified Email (pass loggedInEmail)') public String verifiedEmail;
        @InvocableVariable(label='Reason') public String reason;
        @InvocableVariable(label='Preferred Time') public String preferredTime;
        @InvocableVariable(label='Chat Summary' description='Faithful summary/transcript of the callback conversation so the Case carries the chat trail.') public String chatSummary;
    }
    public class Result { @InvocableVariable public Boolean success; @InvocableVariable public String caseNumber; @InvocableVariable public String message; }
    @InvocableMethod(label='Schedule Callback' description='Logs a callback request for a human agent (creates a case + task). Verified shopper only.')
    public static List<Result> run(List<Request> rs){ List<Result> o=new List<Result>(); for(Request r:rs) o.add(go(r)); return o; }
    private static Result go(Request r){
        Result res=new Result(); res.success=false;
        if(!IdentityService.isVerified(r.email,r.verifiedEmail)){ res.message=IdentityService.signInMessage(); return res; }
        Account acc=KwitkoServiceUtil.findAccount(r.email);
        if(acc==null){ res.message='No account found for that email.'; return res; }
        String reason=String.isBlank(r.reason)?'Callback requested via chat':r.reason.trim();
        String pt=String.isBlank(r.preferredTime)?'as soon as possible':r.preferredTime.trim();
        String description='Preferred time: '+pt+'. Reason: '+reason;
        Case c=new Case(AccountId=acc.Id, ContactId=acc.PersonContactId, Origin='Chat', Status='Escalated', Priority='High', Category__c='Escalation',
            Subject='Callback request', Summary__c='Callback requested ('+pt+'): '+reason, Description=CaseTranscriptUtil.append(description, r.chatSummary));
        insert c; res.caseNumber=[SELECT CaseNumber FROM Case WHERE Id=:c.Id].CaseNumber;
        CaseTranscriptUtil.insertTask(c.Id, acc.PersonContactId, r.chatSummary);
        insert new Task(WhatId=c.Id, WhoId=acc.PersonContactId, Subject='Call back '+acc.FirstName+' ('+pt+')', Priority='High', Status='Open', ActivityDate=Date.today(), Description=reason);
        try{ JourneyLogger.LogRequest lr=new JourneyLogger.LogRequest(); lr.email=r.email; lr.agent='Service'; lr.action='schedule_callback'; lr.stage='Service'; lr.result='Callback case '+res.caseNumber+' ('+pt+')'; lr.chatSummary=r.chatSummary;
            JourneyLogger.logInteraction(new List<JourneyLogger.LogRequest>{lr}); }catch(Exception e){}
        res.success=true; res.message='A callback is scheduled ('+pt+') — case '+res.caseNumber+'. Our team will reach out.';
        return res;
    }
}
