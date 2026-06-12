# Einstein churn predictions — runbook

The org has **5 MB data storage**. Feature rows for scoring (~0.33 MB for 161 customers)
only fit *transiently* — leaving them in place breaks the live web tracker with silent
`STORAGE_LIMIT_EXCEEDED` (POST returns 200 with an APEX_ERROR body). So scoring is a
deliberate, short-lived operation:

## What is permanently in place
- Model **"Predicted Churned" v2 — ACTIVE** (Model Builder; binary classification;
  AUC .978; trained on 414 point-in-time snapshots; identifiers excluded).
- Predict job **"Churn_Prediction_Job" — ACTIVE, Streaming**, input `Churn_Training_c_Home__dlm`,
  output `Churn_Predictions__dlm` (with class probabilities). It scores automatically
  whenever new rows reach the input DMO.
- Daily operational scorer (`Kwitko Churn Scoring Daily`, 03:00) keeps
  `Account.Churn_Score__c` fresh regardless (purchase + web-engagement heuristics).

## To produce fresh model scores (15-30 min, mostly waiting)
1. `sf apex run --file tools/generate_scoring_rows.apex -o AgentforceDev`
   (one row per buyer, features as of today; ~161 rows)
2. Wait for the `Churn_Training__c_Home` stream's incremental sync (~5-15 min):
   `SELECT COUNT(*) FROM Churn_Training_c_Home__dlm` via /ssot/query-sql → 161.
3. The streaming predict job fires on the new data → rows appear in `Churn_Predictions__dlm`.
4. `sf apex run --file tools/sync_model_scores.apex -o AgentforceDev`
   → writes "0.NN (AI model v2)" to `Account.Data_Cloud_Churn_Risk__c`.
   (If the JOIN errors, check the output DMO's column names first.)
5. **Cleanup immediately**: `delete [SELECT Id FROM Churn_Training__c];` +
   `Database.emptyRecycleBin(...)` — then probe the tracker:
   `./tools/verify_pipeline.sh` (check #1 must PASS).

## Known timing quirk
A streaming job activated AFTER data arrived does not score retroactively — touch the
rows (`update`) or regenerate them so the stream emits a change event.
