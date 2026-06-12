// Native lead conversion into an EXISTING Person Account.
// For Person-Account conversion the Lead.Company must be blank, otherwise
// Salesforce performs a B2B conversion (business account + business contact).
Lead l = [SELECT Id, Company FROM Lead WHERE Id='00Qfj00000VCWYYEA5'];
l.Company = null;
try { update l; System.debug('COMPANY blanked'); }
catch (Exception e) { System.debug('COMPANY blank FAILED: ' + e.getMessage()); }

Database.LeadConvert lc = new Database.LeadConvert();
lc.setLeadId('00Qfj00000VCWYYEA5');
lc.setAccountId('001fj00001HIm5aAAD');           // existing Person Account (no contactId for PA)
lc.setDoNotCreateOpportunity(true);
lc.setConvertedStatus('Closed - Converted');
try {
    Database.LeadConvertResult r = Database.convertLead(lc);
    System.debug('CONVERT success=' + r.isSuccess() + ' account=' + r.getAccountId() + ' contact=' + r.getContactId());
} catch (Exception e) {
    System.debug('CONVERT FAILED: ' + e.getMessage());
}
Lead chk = [SELECT Id, IsConverted, ConvertedAccountId, ConvertedContactId FROM Lead WHERE Id='00Qfj00000VCWYYEA5'];
System.debug('RESULT IsConverted=' + chk.IsConverted + ' ConvertedAccountId=' + chk.ConvertedAccountId + ' ConvertedContactId=' + chk.ConvertedContactId);
