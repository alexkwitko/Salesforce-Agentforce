# Einstein churn predictions — runbook

The org has **5 MB data storage**. Feature rows for scoring (~0.33 MB for 161 customers)
only fit *transiently* — leaving them in place breaks the live web tracker with silent
`STORAGE_LIMIT_EXCEEDED` (the REST POST returns an APEX_ERROR; browser `fetch` will not
throw unless the response is inspected). So scoring is a deliberate, short-lived operation:

## Do not claim AI prediction until these prove true
Live verification on 2026-06-12 showed the predictive pipeline is **not producing model
output yet**:

- `MLPredictionDefinition`: 0 rows.
- `Churn_Predictions__dlm`: 0 rows.
- `Account.Data_Cloud_Churn_Risk__c LIKE '%AI model%'`: 0 rows.

What is actually in place:

- `Churn_Training__c` source object + `Churn_Training_c_Home` Data Cloud stream metadata.
- `tools/generate_scoring_rows.apex` to create transient scoring rows.
- `tools/sync_model_scores.apex` to write model output back once an output DMO exists.
- Daily operational scorer (`Kwitko Churn Scoring Daily`, 03:00) keeps
  `Account.Churn_Score__c` fresh regardless (purchase + web-engagement heuristics).

The real Einstein Studio Model Builder model/job is a UI-gated step. Build or repair it in
Einstein Studio first, then use this runbook to generate fresh rows and sync output scores.

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
