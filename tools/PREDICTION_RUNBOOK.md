# Einstein churn predictions — runbook

The org has **5 MB data storage**. Feature rows for scoring (~0.33 MB for 161 customers)
only fit *transiently* — leaving them in place breaks the live web tracker with silent
`STORAGE_LIMIT_EXCEEDED` (the REST POST returns an APEX_ERROR; browser `fetch` will not
throw unless the response is inspected). So scoring is a deliberate, short-lived operation:

## Status: the pipeline DOES produce model output (proven 2026-06-12 PM)
End-to-end verified this session:
- Model **"Predicted Churned" v2** ACTIVE; predict job **"Churn_Prediction_Job"** (Integrations
  tab) → its row-action **Run** produced **161 rows in `Churn_Predictions__dlm`**.
- Output schema: `PredictedChurned_c1__c`='TRUE' / `PredictedChurned_c1Value__c`=P(churn);
  `PrimaryObjectPk__c` = the `Churn_Training__c` record id (NOT the Account id).
- `tools/sync_model_scores.apex` joins predictions→Account and wrote **161 Accounts** with
  `Data_Cloud_Churn_Risk__c` = e.g. `"0.96 (AI model v2)"` — and they diverge from the
  heuristic (model 0.96 vs heuristic 0.49), i.e. genuinely different real predictions.
- `AtRiskCampaignBuilder` now selects on this model score when present (E1).

The daily operational scorer (`Kwitko Churn Scoring Daily`, 03:00) keeps `Account.Churn_Score__c`
fresh regardless (purchase + web-engagement heuristics) — the two-tier design.

## Write-back gotchas you WILL hit again
- `ConnectApi.CdpQuery.queryAnsiSqlV2` returns **0 rows for cross-DMO JOINs** even when the same
  SQL via `/services/data/vXX/ssot/query-sql` returns rows. So `sync_model_scores.apex` runs the
  join via the REST path (shell), OR maps PK→Account by **SOQL on the CRM `Churn_Training__c`**
  (the reliable path — see below).
- `query-sql` is eventually-consistent/flaky: the same SELECT returns rows then 0; `COUNT(*)` can
  be stale vs a column SELECT. **Retry with backoff** (8× / 8-10 s).
- **Deleting the CRM `Churn_Training__c` rows full-refreshes the DLO/DMO to empty and orphans the
  predictions** (they key to the deleted record ids). Recover the map with
  `SELECT Id, Account__c FROM Churn_Training__c ... ALL ROWS` (deleted rows queryable 15 days),
  then join to the still-present `Churn_Predictions__dlm`. That's how the 161 scores were written
  back AFTER the rows were purged.
- `Database.emptyRecycleBin` caps at **200 records/call** — batch in slices of 200 or the purge
  silently fails and deleted rows keep eating the 5 MB.

## Streaming predict jobs do NOT score pre-existing data
A streaming job activated AFTER the input rows arrived sits at 0 output forever. Use the predict
job row-action **Run** (forces a one-time scoring of the current input DMO) — that is what made
the 161 predictions land. Or switch the job to **Batch**.

## To produce fresh model scores (15-30 min, mostly waiting)
1. `sf apex run --file tools/generate_scoring_rows.apex -o AgentforceDev`
   (one row per buyer, features as of today; ~161 rows)
2. Wait for the `Churn_Training__c_Home` stream's incremental sync (~5-15 min):
   `SELECT COUNT(*) FROM Churn_Training_c_Home__dlm` via /ssot/query-sql → 161.
3. In Einstein Studio, verify the prediction definition and job are active. The job should
   score the new rows → rows appear in `Churn_Predictions__dlm`.
4. `sf apex run --file tools/sync_model_scores.apex -o AgentforceDev`
   → writes "0.NN (AI model v2)" to `Account.Data_Cloud_Churn_Risk__c`.
   (If the JOIN errors, check the output DMO's column names first.)
5. **Cleanup immediately**: `delete [SELECT Id FROM Churn_Training__c];` +
   `Database.emptyRecycleBin(...)` — then probe the tracker:
   `./tools/verify_pipeline.sh` (check #1 must PASS).

## Known timing quirk
A streaming job activated AFTER data arrived does not score retroactively — touch the
rows (`update`) or regenerate them so the stream emits a change event.

## Storage cleanup
Use `sf apex run --file tools/cleanup_transient_storage.apex -o AgentforceDev` after
streaming/prediction checks. It removes transient scoring/probe rows and hard-purges
already-deleted recycle-bin records so the live web tracker can keep inserting events.
