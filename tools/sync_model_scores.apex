// Pull "Predicted Churned" (Einstein Studio v2) streaming-prediction scores from the
// Churn_Predictions__dlm output DMO and write them onto Account.Data_Cloud_Churn_Risk__c.
// Joins predictions back to the input feature rows to recover the Account id.
// Run after the predict job fires (tools/verify_pipeline.sh checks this).
ConnectApi.CdpQueryInput inp = new ConnectApi.CdpQueryInput();
inp.sql = 'SELECT t.Account_c__c, p.Churned_Probability__c '
        + 'FROM Churn_Predictions__dlm p '
        + 'JOIN Churn_Training_c_Home__dlm t ON t.Id__c = p.Id__c';
List<Account> ups = new List<Account>();
try {
    ConnectApi.CdpQueryOutputV2 res = ConnectApi.CdpQuery.queryAnsiSqlV2(inp);
    for (ConnectApi.CdpQueryV2Row row : res.data) {
        List<Object> cells = row.rowData;
        if (cells == null || cells.size() < 2 || cells[0] == null || cells[1] == null) continue;
        String acctId = String.valueOf(cells[0]);
        Decimal prob;
        try { prob = Decimal.valueOf(String.valueOf(cells[1])); } catch (Exception e) { continue; }
        if (acctId.length() >= 15) {
            ups.add(new Account(Id = (Id) acctId,
                Data_Cloud_Churn_Risk__c = prob.setScale(2) + ' (AI model v2)'));
        }
    }
    update ups;
    System.debug('MODEL_SCORES_SYNCED=' + ups.size());
} catch (Exception e) {
    // Column names on the prediction DMO can differ ("Churned_Prediction__c", "score__c", ...)
    // — if the join errors, run DESCRIBE via /ssot/metadata and adjust the SELECT.
    System.debug('MODEL_SYNC_ERROR=' + e.getMessage());
}
