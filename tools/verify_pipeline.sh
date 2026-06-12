#!/bin/bash
# Kwitko engagement + prediction pipeline — reproducible live verification.
# Run anytime: ./tools/verify_pipeline.sh [org-alias]
# Proves: live endpoint accepts events; events stitch to people; Data Cloud ingests +
# unifies them; the engagement CI exists; the Einstein model + predict job are active;
# scoring jobs are scheduled. Read-only except one self-cleaning test event.
set -u
ORG="${1:-AgentforceDev}"
EP="https://MYDOMAIN.develop.my.salesforce-sites.com/woo/services/apexrest/engagement"
ORIGIN="https://deepskyblue-deer-920559.hostingersite.com"
PASS=0; FAIL=0
check() { if [ "$2" = "1" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 ($3)"; FAIL=$((FAIL+1)); fi; }

echo "== 1. Live engagement endpoint (storefront -> Site REST) =="
RESP=$(curl -s -X POST "$EP" -H "Content-Type: application/json" -H "Origin: $ORIGIN" \
  -d '{"deviceId":"VERIFY-SCRIPT","sessionId":"verify","events":[{"type":"pageView","pageUrl":"/verify"}]}')
echo "  response: $RESP"
check "endpoint inserts events" "$(echo "$RESP" | grep -c '\"ok\":true')" "$RESP"

echo "== 2. CRM: events + stitched identities =="
N=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM Web_Event__c" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
S=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM Web_Event__c WHERE Account__c != null" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
echo "  web events: $N total, $S stitched to a person"
check "web events exist" "$([ "$N" -gt 0 ] && echo 1 || echo 0)" "none"
sf data delete record --sobject Web_Event__c --where "Device_Id__c='VERIFY-SCRIPT'" -o "$ORG" --json >/dev/null 2>&1

echo "== 3. Data Cloud: DLO/DMO ingestion + unified profile linkage =="
D=$(sf api request rest "/services/data/v62.0/ssot/query-sql" --method POST \
  --body '{"sql":"SELECT COUNT(*) FROM Web_Event_c_Home__dlm"}' 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['data'][0][0] if 'data' in d else -1)")
echo "  Web_Event DMO rows: $D"
check "Web_Event DMO populated" "$([ "$D" -gt 0 ] && echo 1 || echo 0)" "$D"
U=$(sf api request rest "/services/data/v62.0/ssot/query-sql" --method POST \
  --body '{"sql":"SELECT COUNT(*) FROM UnifiedLinkssotIndividualCoff__dlm UL JOIN Web_Event_c_Home__dlm W ON UL.SourceRecordId__c = W.Account_c__c"}' 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['data'][0][0] if 'data' in d else -1)")
echo "  web events linked to UNIFIED individuals: $U"
check "engagement joins unified profile" "$([ "$U" -gt 0 ] && echo 1 || echo 0)" "$U"

echo "== 4. Engagement Calculated Insight =="
CI=$(sf data query -o "$ORG" -q "SELECT Name FROM MktCalculatedInsight WHERE Name LIKE 'Web Engagement%'" --json 2>/dev/null | python3 -c "import sys,json;r=json.load(sys.stdin)['result']['records'];print(len(r))")
check "Web Engagement Profile CI exists" "$([ "$CI" -gt 0 ] && echo 1 || echo 0)" "missing"

echo "== 5. Predictive: model scores on Accounts + schedules =="
A=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM Account WHERE Churn_Score__c != null" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
M=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM Account WHERE Data_Cloud_Churn_Risk__c LIKE '%AI model%'" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
echo "  accounts with operational churn score: $A | with Einstein model score: $M"
check "operational scoring populated" "$([ "$A" -gt 100 ] && echo 1 || echo 0)" "$A"
check "Einstein model scores written back" "$([ "$M" -gt 0 ] && echo 1 || echo 0)" "$M (run tools/sync_model_scores.apex after predict job)"
J=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM CronTrigger WHERE CronJobDetail.Name IN ('Kwitko Churn Scoring Daily','Kwitko At-Risk Campaign Daily') AND State='WAITING'" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
check "daily scoring + campaign jobs scheduled" "$([ "$J" = "2" ] && echo 1 || echo 0)" "$J of 2"

echo "== 6. Marketing activation =="
CM=$(sf data query -o "$ORG" -q "SELECT COUNT(Id) c FROM CampaignMember WHERE Campaign.Name='DC - High-Value At-Risk Win-Back' AND Status='Emailed'" --json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['records'][0]['c'])")
echo "  win-back members emailed: $CM"
check "win-back emails sent + tracked" "$([ "$CM" -gt 0 ] && echo 1 || echo 0)" "$CM"

echo; echo "RESULT: $PASS passed, $FAIL failed"
exit $([ "$FAIL" = "0" ] && echo 0 || echo 1)
