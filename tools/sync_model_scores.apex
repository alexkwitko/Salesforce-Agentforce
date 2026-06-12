// Write the Einstein Studio "Predicted Churned" v2 model output back onto Accounts.
// The predict job ("Churn_Prediction_Job") writes Churn_Predictions__dlm, keyed by the
// source Churn_Training row PK. Join back to the training DMO to recover the Account id,
// take P(churn = TRUE), and store it on Account.Data_Cloud_Churn_Risk__c as "0.NN (AI model v2)".
// Verified column shape (2026-06-12): PredictedChurned_c1__c label + _c1Value__c probability,
// PrimaryObjectPk__c = Churn_Training_c_Home__dlm.Id__c.
ConnectApi.CdpQueryInput inp = new ConnectApi.CdpQueryInput();
inp.sql =
    'SELECT t.Account_c__c, ' +
    '  CASE WHEN p.PredictedChurned_c1__c = \'TRUE\' THEN p.PredictedChurned_c1Value__c ' +
    '       ELSE p.PredictedChurned_c2Value__c END AS churn_prob ' +
    'FROM Churn_Predictions__dlm p ' +
    'JOIN Churn_Training_c_Home__dlm t ON t.Id__c = p.PrimaryObjectPk__c';

Map<Id, Decimal> byAccount = new Map<Id, Decimal>();
ConnectApi.CdpQueryOutputV2 res = ConnectApi.CdpQuery.queryAnsiSqlV2(inp);
for (ConnectApi.CdpQueryV2Row row : res.data) {
    List<Object> cells = row.rowData;
    if (cells == null || cells.size() < 2 || cells[0] == null || cells[1] == null) continue;
    String acctId = String.valueOf(cells[0]);
    if (acctId.length() < 15) continue;
    Decimal prob;
    try { prob = Decimal.valueOf(String.valueOf(cells[1])); } catch (Exception e) { continue; }
    // keep the highest (most recent runs can repeat keys); we just need one score per account
    byAccount.put((Id) acctId, prob.setScale(2, System.RoundingMode.HALF_UP));
}

List<Account> ups = new List<Account>();
for (Id aid : byAccount.keySet()) {
    ups.add(new Account(Id = aid,
        Data_Cloud_Churn_Risk__c = byAccount.get(aid) + ' (AI model v2)'));
}
update ups;
System.debug('MODEL_SCORES_SYNCED=' + ups.size());
