/**
 * FieldVisitAI — AI assistant for the field technician.
 * Generates, from a Work Order's real context, either a concise PRE-VISIT BRIEF
 * or DRAFT SERVICE-REPORT NOTES. Exposed @AuraEnabled (for a mobile LWC quick action)
 * and @InvocableMethod (for Flow). Uses the org's generative AI via ConnectApi.EinsteinLLM
 * — online only (AI needs connectivity; the mobile app is offline-first for records, not AI).
 */
public with sharing class FieldVisitAI {

    @AuraEnabled
    public static String summarizeVisit(Id workOrderId, String mode) {
        return run(workOrderId, mode);
    }

    public class Req {
        @InvocableVariable(required=true label='Work Order Id') public Id workOrderId;
        @InvocableVariable(label='Mode: brief | notes') public String mode;
    }
    public class Res { @InvocableVariable public String summary; }

    @InvocableMethod(label='AI: Field Visit Summary'
        description='Generates a pre-visit brief or draft service-report notes for a work order.')
    public static List<Res> generate(List<Req> reqs) {
        List<Res> out = new List<Res>();
        for (Req r : reqs) { Res x = new Res(); x.summary = run(r.workOrderId, r.mode); out.add(x); }
        return out;
    }

    static String run(Id woId, String mode) {
        mode = (mode == 'notes') ? 'notes' : 'brief';
        WorkOrder wo = [
            SELECT WorkOrderNumber, Subject, Status, Description, Account.Name, ServiceTerritory.Name,
                   Payment_Status__c, Amount_Collected__c,
                   (SELECT Asset.Name, Asset.SerialNumber FROM WorkOrderLineItems LIMIT 5)
            FROM WorkOrder WHERE Id = :woId];
        String asset = '';
        for (WorkOrderLineItem li : wo.WorkOrderLineItems) {
            if (li.Asset != null) asset += li.Asset.Name + ' (SN ' + li.Asset.SerialNumber + ') ';
        }
        String ctx = 'Work Order ' + wo.WorkOrderNumber
            + ' | Account: ' + (wo.Account != null ? wo.Account.Name : 'n/a')
            + ' | Territory: ' + (wo.ServiceTerritory != null ? wo.ServiceTerritory.Name : 'n/a')
            + ' | Subject: ' + wo.Subject + ' | Status: ' + wo.Status
            + ' | Asset: ' + (String.isBlank(asset) ? 'n/a' : asset)
            + ' | Payment: ' + (wo.Payment_Status__c == null ? 'Unpaid' : wo.Payment_Status__c);

        String instruction = (mode == 'notes')
            ? 'You are a field service assistant. Draft concise, professional service-report notes (4-6 short bullet points) the technician can finalize after this visit, based only on the work order context. Do not invent specifics that are not implied by the context.'
            : 'You are a field service assistant. Write a short pre-visit brief (3-4 sentences) for the technician: who the customer is, the asset, what to expect on arrival, and one practical prep tip. Be concise.';
        String prompt = instruction + '\n\nWork order context:\n' + ctx;

        if (Test.isRunningTest()) return 'TEST_SUMMARY';

        ConnectApi.EinsteinLlmGenerationsInput inp = new ConnectApi.EinsteinLlmGenerationsInput();
        inp.promptTextorId = prompt;
        inp.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        inp.additionalConfig.applicationName = 'PromptBuilderPreview';
        ConnectApi.EinsteinLLMGenerationsOutput outp = ConnectApi.EinsteinLLM.generateMessages(inp);
        return outp.generations.isEmpty() ? '(no response)' : outp.generations[0].text;
    }
}
