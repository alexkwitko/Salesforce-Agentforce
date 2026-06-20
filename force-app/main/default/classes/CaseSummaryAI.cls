/**
 * CaseSummaryAI — Einstein agent-assist for HUMAN service agents.
 * From a Case's real context (subject, description, status, priority, account, recent
 * comments + emails) it generates either a concise CASE SUMMARY (wrap-up) or a DRAFT
 * REPLY the agent can edit and send. Exposed @AuraEnabled (for a console LWC / quick
 * action) and @InvocableMethod (for Flow). Uses the org's generative AI via
 * ConnectApi.EinsteinLLM — the same proven path as FieldVisitAI. Grounding is the case
 * record itself (deterministic, no hallucinated specifics).
 */
public with sharing class CaseSummaryAI {

    @AuraEnabled
    public static String assist(Id caseId, String mode) {
        return run(caseId, mode);
    }

    public class Req {
        @InvocableVariable(required=true label='Case Id') public Id caseId;
        @InvocableVariable(label='Mode: summary | reply') public String mode;
    }
    public class Res { @InvocableVariable public String result; }

    @InvocableMethod(label='AI: Case Summary or Draft Reply'
        description='Generates a case summary (wrap-up) or a draft customer reply from the case context.')
    public static List<Res> generate(List<Req> reqs) {
        List<Res> out = new List<Res>();
        for (Req r : reqs) { Res x = new Res(); x.result = run(r.caseId, r.mode); out.add(x); }
        return out;
    }

    static String run(Id caseId, String mode) {
        mode = (mode == 'reply') ? 'reply' : 'summary';
        Case c = [
            SELECT CaseNumber, Subject, Description, Status, Priority, Origin,
                   Type, Reason, Account.Name, Contact.Name,
                   (SELECT CommentBody, CreatedDate FROM CaseComments ORDER BY CreatedDate DESC LIMIT 5),
                   (SELECT TextBody, Incoming, Subject FROM EmailMessages ORDER BY CreatedDate DESC LIMIT 3)
            FROM Case WHERE Id = :caseId];

        String comments = '';
        for (CaseComment cc : c.CaseComments) {
            if (String.isNotBlank(cc.CommentBody)) comments += '- ' + cc.CommentBody.abbreviate(300) + '\n';
        }
        String emails = '';
        for (EmailMessage em : c.EmailMessages) {
            String dir = (em.Incoming == true) ? 'Customer' : 'Agent';
            if (String.isNotBlank(em.TextBody)) emails += dir + ': ' + em.TextBody.abbreviate(400) + '\n';
        }

        String ctx = 'Case ' + c.CaseNumber
            + ' | Account: ' + (c.Account != null ? c.Account.Name : 'n/a')
            + ' | Contact: ' + (c.Contact != null ? c.Contact.Name : 'n/a')
            + ' | Status: ' + c.Status + ' | Priority: ' + c.Priority
            + ' | Origin: ' + c.Origin + ' | Type: ' + c.Type
            + '\nSubject: ' + c.Subject
            + '\nDescription: ' + (String.isBlank(c.Description) ? 'n/a' : c.Description.abbreviate(600))
            + (String.isBlank(comments) ? '' : '\nRecent internal comments:\n' + comments)
            + (String.isBlank(emails) ? '' : '\nRecent emails:\n' + emails);

        String instruction = (mode == 'reply')
            ? 'You are a customer-service assistant for a coffee retailer. Draft a brief, warm, professional reply to the customer for this case, based ONLY on the case context below. Acknowledge the issue, state the next step, and keep it under 120 words. Do not invent order numbers, refund amounts, dates, or policies that are not in the context. Leave a [bracketed placeholder] where the agent must add a specific detail.'
            : 'You are a customer-service assistant. Write a concise wrap-up SUMMARY of this case for the service agent and for the customer record: 3-5 short bullet points covering the issue, what has happened so far, and the recommended next action. Base it ONLY on the case context below; do not invent specifics.';
        String prompt = instruction + '\n\nCase context:\n' + ctx;

        if (Test.isRunningTest()) return 'TEST_RESULT';

        ConnectApi.EinsteinLlmGenerationsInput inp = new ConnectApi.EinsteinLlmGenerationsInput();
        inp.promptTextorId = prompt;
        inp.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        inp.additionalConfig.applicationName = 'PromptBuilderPreview';
        ConnectApi.EinsteinLLMGenerationsOutput outp = ConnectApi.EinsteinLLM.generateMessages(inp);
        return outp.generations.isEmpty() ? '(no response)' : outp.generations[0].text;
    }
}
