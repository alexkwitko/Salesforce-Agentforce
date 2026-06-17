#!/bin/bash
# Kwitko Data Cloud prediction + activation pipeline — reproducible live verification.
# Run anytime: ./tools/verify_pipeline.sh [org-alias]
# Proves: SDK-ingested Data Cloud web events exist and unify; the engagement CI exists;
# prediction artifacts are reported without overstating whether a current Model Builder
# definition is API-visible; scoring jobs are scheduled.
#
# The old custom Apex EngagementRest endpoint is no longer the default certification path.
# Set RUN_LEGACY_ENGAGEMENT=1 to run the legacy endpoint smoke that mutates one
# VERIFY-SCRIPT Web_Event__c row and then deletes it.
set -u
ORG="${1:-AgentforceDev}"
EP="https://MYDOMAIN.develop.my.salesforce-sites.com/woo/services/apexrest/engagement"
ORIGIN="https://deepskyblue-deer-920559.hostingersite.com"
RUN_LEGACY_ENGAGEMENT="${RUN_LEGACY_ENGAGEMENT:-0}"
PASS=0; FAIL=0
check() { if [ "$2" = "1" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 ($3)"; FAIL=$((FAIL+1)); fi; }

echo "== 1. Legacy Apex engagement endpoint =="
if [ "$RUN_LEGACY_ENGAGEMENT" = "1" ]; then
  RESP=$(curl -s -X POST "$EP" -H "Content-Type: application/json" -H "Origin: $ORIGIN" \
    -d '{"deviceId":"VERIFY-SCRIPT","sessionId":"verify","events":[{"type":"pageView","pageUrl":"/verify"}]}')
  echo "  response: $RESP"
  check "legacy endpoint inserts events" "$(echo "$RESP" | grep -cE '\\\\?"?ok\\\\?"?:\\\\?"?true|inserted\\\\?"?:[1-9]')" "$RESP"
  check "legacy endpoint not blocked by storage" "$(echo "$RESP" | grep -c 'STORAGE_LIMIT_EXCEEDED' | awk '{print ($1==0)?1:0}')" "$RESP"

  echo "== 2. Legacy CRM Web_Event__c fallback =="
  N=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM Web_Event__c" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
  S=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM Web_Event__c WHERE Account__c != null" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
  echo "  web events: $N total, $S stitched to a person"
  check "legacy web events exist" "$([ "$N" -gt 0 ] && echo 1 || echo 0)" "none"
  sf data delete record --sobject Web_Event__c --where "Device_Id__c='VERIFY-SCRIPT'" -o "$ORG" --json >/dev/null 2>&1
else
  echo "  SKIP  RUN_LEGACY_ENGAGEMENT is not 1; SDK-first ingestion is verified by tools/verify_sdk_datacloud_pipeline.sh."
fi

echo "== 2. Data Cloud: SDK DMO ingestion + unified profile linkage =="
D=$(sf api request rest "/services/data/v62.0/ssot/query-sql" --method POST \
  --body '{"sql":"SELECT COUNT(*) FROM Web_Event_c_Home__dlm"}' --target-org "$ORG" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['data'][0][0] if 'data' in d else -1)")
echo "  Web_Event DMO rows: $D"
check "SDK Web_Event DMO populated" "$([ "$D" -gt 0 ] && echo 1 || echo 0)" "$D"
U=$(sf api request rest "/services/data/v62.0/ssot/query-sql" --method POST \
  --body '{"sql":"SELECT COUNT(*) FROM UnifiedLinkssotIndividualCoff__dlm UL JOIN Web_Event_c_Home__dlm W ON UL.SourceRecordId__c = W.Account_c__c"}' --target-org "$ORG" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['data'][0][0] if 'data' in d else -1)")
echo "  web events linked to UNIFIED individuals: $U"
check "SDK engagement joins unified profile" "$([ "$U" -gt 0 ] && echo 1 || echo 0)" "$U"

echo "== 3. Engagement Calculated Insight =="
CI=$(sf data query -o "$ORG" -q "SELECT Name FROM MktCalculatedInsight WHERE Name LIKE 'Web Engagement%'" --json 2>/dev/null | python3 -c "import sys,json;r=json.load(sys.stdin)['result']['records'];print(len(r))")
check "Web Engagement Profile CI exists" "$([ "$CI" -gt 0 ] && echo 1 || echo 0)" "missing"

echo "== 4. Predictive: operational scores + Data Cloud prediction artifacts =="
A=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM Account WHERE Churn_Score__c != null" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
M=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM Account WHERE Data_Cloud_Churn_Risk__c LIKE '%AI model%'" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
P=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM MLPredictionDefinition" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])" 2>/dev/null || echo 0)
MM=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM MktMLModel" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])" 2>/dev/null || echo 0)
MLM=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM MLModel" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])" 2>/dev/null || echo 0)
MJ=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM MktMLPredictionJob" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])" 2>/dev/null || echo 0)
MJS=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM MktMLPredictionJob WHERE LastRunStatus='SUCCESS'" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])" 2>/dev/null || echo 0)
MJL=$(sf data query -o "$ORG" -q "SELECT LastRunDate FROM MktMLPredictionJob ORDER BY LastRunDate DESC LIMIT 1" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);r=d.get('result',{}).get('records',[]);print(r[0].get('LastRunDate') if r else '')" 2>/dev/null || echo "")
PD=$(sf api request rest "/services/data/v62.0/ssot/query-sql" --method POST \
  --body '{"sql":"SELECT COUNT(*) FROM Churn_Predictions__dlm"}' --target-org "$ORG" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['data'][0][0] if 'data' in d else 0)" 2>/dev/null || echo 0)
MODEL_OBJECT_ROWS=$((P + MM + MLM))
echo "  accounts with operational churn score: $A | MLPredictionDefinition rows: $P | MktMLModel rows: $MM | MLModel rows: $MLM | MktMLPredictionJob rows: $MJ | successful jobs: $MJS | last run: ${MJL:-none} | prediction rows: $PD | accounts with model-looking score: $M"
check "operational scoring populated on active Accounts" "$([ "$A" -gt 0 ] && echo 1 || echo 0)" "$A"
check "current AI model definition/model is API-visible" "$([ "$MODEL_OBJECT_ROWS" -gt 0 ] && echo 1 || echo 0)" "MLPredictionDefinition=$P MktMLModel=$MM MLModel=$MLM (all 0 means the real Model Builder definition is not currently certified headlessly)"
check "Data Cloud prediction job exists" "$([ "$MJ" -gt 0 ] && echo 1 || echo 0)" "$MJ"
check "Data Cloud prediction job last run succeeded" "$([ "$MJS" -gt 0 ] && echo 1 || echo 0)" "$MJS"
check "historical prediction output rows exist" "$([ "$PD" -gt 0 ] && echo 1 || echo 0)" "$PD"
check "model-looking scores written back on active Accounts" "$([ "$M" -gt 0 ] && echo 1 || echo 0)" "$M (run tools/sync_model_scores.apex after predict job)"
J=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM CronTrigger WHERE CronJobDetail.Name IN ('Kwitko Churn Scoring Daily','Kwitko At-Risk Campaign Daily') AND State='WAITING'" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
check "daily scoring + campaign jobs scheduled" "$([ "$J" = "2" ] && echo 1 || echo 0)" "$J of 2"

echo "== 5. Marketing activation =="
CM=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM CampaignMember WHERE Campaign.Name='DC - High-Value At-Risk Win-Back' AND Status='Emailed'" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
echo "  win-back members emailed: $CM"
check "win-back emails sent + tracked" "$([ "$CM" -gt 0 ] && echo 1 || echo 0)" "$CM"

echo; echo "RESULT: $PASS passed, $FAIL failed"
exit $([ "$FAIL" = "0" ] && echo 0 || echo 1)
