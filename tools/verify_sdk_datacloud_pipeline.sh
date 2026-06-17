#!/bin/bash
# Kwitko SDK-first Data Cloud verification.
# Proves the production path: Woo SDK -> Data Cloud DLO/DMO -> Identity Resolution
# -> unified-profile CIs -> Account cache read by Agentforce.
set -u

ORG="${1:-AgentforceDev}"
EMAIL="${2:-alexkwitko@gmail.com}"

PASS=0
FAIL=0

check() {
  if [ "$2" = "1" ]; then
    echo "  PASS  $1"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $1 ($3)"
    FAIL=$((FAIL+1))
  fi
}

dc_sql() {
  local sql="$1"
  local body
  body=$(jq -nc --arg sql "$sql" '{sql:$sql}')
  sf api request rest "/services/data/v67.0/ssot/query-sql" \
    --method POST --body "$body" --target-org "$ORG" 2>/dev/null
}

first_cell() {
  python3 -c 'import json,sys
d=json.load(sys.stdin)
try:
 print(d["data"][0][0])
except Exception:
 print("")'
}

echo "== 1. SDK DLO/DMO ingestion =="
DLO_COUNT=$(dc_sql "SELECT COUNT(*) FROM Kwitko_Storefront_Behavioral_Ev_2C84D952__dll" | first_cell)
DMO_COUNT=$(dc_sql "SELECT COUNT(*) FROM Web_Event_c_Home__dlm" | first_cell)
LATEST_DMO=$(dc_sql "SELECT MAX(Occurred_At_c__c) FROM Web_Event_c_Home__dlm" | first_cell)
echo "  behavioral DLO rows: ${DLO_COUNT:-0}"
echo "  web event DMO rows: ${DMO_COUNT:-0}"
echo "  latest web DMO activity: ${LATEST_DMO:-none}"
check "SDK behavioral DLO populated" "$([ "${DLO_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "$DLO_COUNT"
check "SDK web-event DMO populated" "$([ "${DMO_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "$DMO_COUNT"

echo "== 2. Identity Resolution configuration =="
IR=$(sf api request rest "/services/data/v67.0/ssot/identity-resolutions/1irfj000000fyoIAAQ" \
  --method GET --target-org "$ORG" 2>/dev/null)
IR_AUTO=$(printf "%s" "$IR" | jq -r '.doesRunAutomatically // false')
IR_STATUS=$(printf "%s" "$IR" | jq -r '.lastJobStatus // "unknown"')
echo "  auto-run: $IR_AUTO | last status: $IR_STATUS"
check "IR runs automatically" "$([ "$IR_AUTO" = "true" ] && echo 1 || echo 0)" "$IR_AUTO"
check "IR last job succeeded" "$([ "$IR_STATUS" = "SUCCESS" ] && echo 1 || echo 0)" "$IR_STATUS"

echo "== 3. Email identity rows and unified link =="
ACCOUNT_ID=$(sf data query -o "$ORG" -q "SELECT Id FROM Account WHERE PersonEmail = '$EMAIL' LIMIT 1" --json 2>/dev/null \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0]["Id"] if r else "")')
SOURCE_IDS=$(dc_sql "SELECT ssot__PartyId__c FROM ssot__ContactPointEmail__dlm WHERE ssot__EmailAddress__c = '$EMAIL' LIMIT 50" \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(",".join(sorted({str(r[0]) for r in d.get("data",[]) if r and r[0]})))')
IDS_FOR_SQL="$ACCOUNT_ID"
if [ -n "$SOURCE_IDS" ]; then
  IDS_FOR_SQL="$IDS_FOR_SQL,$SOURCE_IDS"
fi
IN_LIST=$(printf "%s" "$IDS_FOR_SQL" | tr ',' '\n' | awk 'NF {printf "%s'\''%s'\''", sep, $0; sep=","}')
LINKS=$(dc_sql "SELECT SourceRecordId__c, UnifiedRecordId__c FROM UnifiedLinkssotIndividualCoff__dlm WHERE SourceRecordId__c IN ($IN_LIST)")
UNIFIED_COUNT=$(printf "%s" "$LINKS" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(len({r[1] for r in d.get("data",[]) if len(r)>1 and r[1]}))')
ACCOUNT_UNIFIED=$(printf "%s" "$LINKS" | ACCOUNT_ID="$ACCOUNT_ID" python3 -c 'import json,sys,os
acct=os.environ.get("ACCOUNT_ID","")
d=json.load(sys.stdin)
for r in d.get("data",[]):
 if r and r[0] == acct:
  print(r[1]); break
else:
 print("")')
echo "  account: ${ACCOUNT_ID:-none}"
echo "  email source ids: ${SOURCE_IDS:-none}"
echo "  account unified id: ${ACCOUNT_UNIFIED:-none}"
check "Account found for email" "$([ -n "$ACCOUNT_ID" ] && echo 1 || echo 0)" "$EMAIL"
check "Email profile rows exist" "$([ -n "$SOURCE_IDS" ] && echo 1 || echo 0)" "$EMAIL"
check "Email sources collapse to one unified profile" "$([ "$UNIFIED_COUNT" = "1" ] && echo 1 || echo 0)" "unified ids=$UNIFIED_COUNT"

echo "== 4. Unified-profile calculated insights =="
UP_VALUE=$(dc_sql "SELECT OrderCount__c, LifetimeValue__c, AvgOrderValue__c, LastOrderDate__c FROM UP_Customer_Value__cio WHERE UnifiedIndividualId__c = '$ACCOUNT_UNIFIED' LIMIT 1")
UP_ORDER_COUNT=$(printf "%s" "$UP_VALUE" | first_cell)
UP_LTV=$(printf "%s" "$UP_VALUE" | python3 -c 'import json,sys
d=json.load(sys.stdin)
try: print(d["data"][0][1])
except Exception: print("")')
UP_AOV=$(printf "%s" "$UP_VALUE" | python3 -c 'import json,sys
d=json.load(sys.stdin)
try: print(d["data"][0][2])
except Exception: print("")')
UP_LAST_ORDER=$(printf "%s" "$UP_VALUE" | python3 -c 'import json,sys
d=json.load(sys.stdin)
try: print(d["data"][0][3])
except Exception: print("")')
UP_WEB=$(dc_sql "SELECT WebEventCount__c, LastWebActivity__c FROM UP_Web_Engagement__cio WHERE UnifiedIndividualId__c = '$ACCOUNT_UNIFIED' LIMIT 1")
UP_WEB_COUNT=$(printf "%s" "$UP_WEB" | first_cell)
UP_WEB_LAST=$(printf "%s" "$UP_WEB" | python3 -c 'import json,sys
d=json.load(sys.stdin)
try: print(d["data"][0][1])
except Exception: print("")')
UP_SDK_WEB=$(dc_sql "SELECT WebEventCount__c, DeviceCount__c, SessionCount__c, TotalDwellSeconds__c, LastWebActivity__c FROM UP_Web_Engagement_Device_Profile__cio WHERE UnifiedIndividualId__c = '$ACCOUNT_UNIFIED' LIMIT 1")
UP_SDK_WEB_COUNT=$(printf "%s" "$UP_SDK_WEB" | first_cell)
UP_SDK_DEVICE=$(printf "%s" "$UP_SDK_WEB" | python3 -c 'import json,sys
d=json.load(sys.stdin)
try: print(d["data"][0][1])
except Exception: print("")')
UP_SDK_SESSION=$(printf "%s" "$UP_SDK_WEB" | python3 -c 'import json,sys
d=json.load(sys.stdin)
try: print(d["data"][0][2])
except Exception: print("")')
UP_SDK_DWELL=$(printf "%s" "$UP_SDK_WEB" | python3 -c 'import json,sys
d=json.load(sys.stdin)
try: print(d["data"][0][3])
except Exception: print("")')
UP_SERVICE=$(dc_sql "SELECT CaseCount__c, LastCaseDate__c FROM UP_Service_Profile__cio WHERE UnifiedIndividualId__c = '$ACCOUNT_UNIFIED' LIMIT 1")
UP_CASE_COUNT=$(printf "%s" "$UP_SERVICE" | first_cell)
UP_LAST_CASE=$(printf "%s" "$UP_SERVICE" | python3 -c 'import json,sys
d=json.load(sys.stdin)
try: print(d["data"][0][1])
except Exception: print("")')
echo "  UP order count: ${UP_ORDER_COUNT:-0}"
echo "  UP lifetime value: ${UP_LTV:-0}"
echo "  UP avg order value: ${UP_AOV:-0}"
echo "  UP last order: ${UP_LAST_ORDER:-none}"
echo "  UP web event count: ${UP_WEB_COUNT:-0}"
echo "  UP last web activity: ${UP_WEB_LAST:-none}"
echo "  UP SDK web events/devices/sessions/dwell: ${UP_SDK_WEB_COUNT:-0}/${UP_SDK_DEVICE:-0}/${UP_SDK_SESSION:-0}/${UP_SDK_DWELL:-0}"
echo "  UP case count: ${UP_CASE_COUNT:-0}"
echo "  UP last case: ${UP_LAST_CASE:-none}"
check "UP customer value CI populated" "$([ "${UP_ORDER_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "$UP_ORDER_COUNT"
check "UP web engagement CI populated" "$([ "${UP_WEB_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "$UP_WEB_COUNT"
check "UP SDK device/session CI populated" "$([ "${UP_SDK_WEB_COUNT:-0}" -gt 0 ] && [ "${UP_SDK_DEVICE:-0}" -gt 0 ] && [ "${UP_SDK_SESSION:-0}" -gt 0 ] && echo 1 || echo 0)" "${UP_SDK_WEB_COUNT:-0}/${UP_SDK_DEVICE:-0}/${UP_SDK_SESSION:-0}"
check "UP service profile CI populated" "$([ "${UP_CASE_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "$UP_CASE_COUNT"

echo "== 5. Account cache used by Agentforce =="
ACCT=$(sf data query -o "$ORG" -q "SELECT Data_Cloud_Unified_Individual_Id__c, Data_Cloud_Profile_Summary__c, Data_Cloud_Insight_Source__c, Data_Cloud_Last_Augmented_At__c, Insights_Order_Count__c, Insights_LTV__c, Insights_Web_Events__c, Insights_Device_Count__c, Insights_Session_Count__c, Insights_Open_Cases__c, Insights_Total_Cases__c, Insights_Returns__c FROM Account WHERE Id = '$ACCOUNT_ID' LIMIT 1" --json 2>/dev/null)
CACHED_UID=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Data_Cloud_Unified_Individual_Id__c") if r else "")')
CACHED_SOURCE=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Data_Cloud_Insight_Source__c") if r else "")')
CACHED_AT=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Data_Cloud_Last_Augmented_At__c") if r else "")')
INSIGHTS_ORDER_COUNT=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Insights_Order_Count__c") if r else "")')
INSIGHTS_LTV=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Insights_LTV__c") if r else "")')
INSIGHTS_WEB=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Insights_Web_Events__c") if r else "")')
INSIGHTS_DEVICE=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Insights_Device_Count__c") if r else "")')
INSIGHTS_SESSION=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Insights_Session_Count__c") if r else "")')
INSIGHTS_CASES=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Insights_Total_Cases__c") if r else "")')
INSIGHTS_RETURNS=$(printf "%s" "$ACCT" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result",{}).get("records",[])
print(r[0].get("Insights_Returns__c") if r else "")')
echo "  cached unified id: ${CACHED_UID:-none}"
echo "  cached source: ${CACHED_SOURCE:-none}"
echo "  cached at: ${CACHED_AT:-none}"
echo "  cached order count/LTV: ${INSIGHTS_ORDER_COUNT:-0}/${INSIGHTS_LTV:-0}"
echo "  cached web events/devices/sessions: ${INSIGHTS_WEB:-0}/${INSIGHTS_DEVICE:-0}/${INSIGHTS_SESSION:-0}"
echo "  cached total cases/returns: ${INSIGHTS_CASES:-0}/${INSIGHTS_RETURNS:-0}"
check "Account cache has unified id" "$([ "$CACHED_UID" = "$ACCOUNT_UNIFIED" ] && echo 1 || echo 0)" "$CACHED_UID vs $ACCOUNT_UNIFIED"
check "Account cache uses unified CI source" "$([ "$CACHED_SOURCE" = "Data Cloud Unified CI + CRM fallback" ] && echo 1 || echo 0)" "$CACHED_SOURCE"
check "Account cache has order insight fields" "$([ "${INSIGHTS_ORDER_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "$INSIGHTS_ORDER_COUNT"
check "Account cache has web insight fields" "$([ "${INSIGHTS_WEB:-0}" -gt 0 ] && [ "${INSIGHTS_DEVICE:-0}" -gt 0 ] && [ "${INSIGHTS_SESSION:-0}" -gt 0 ] && echo 1 || echo 0)" "${INSIGHTS_WEB:-0}/${INSIGHTS_DEVICE:-0}/${INSIGHTS_SESSION:-0}"
check "Account cache has service insight fields" "$([ "${INSIGHTS_CASES:-0}" -gt 0 ] && echo 1 || echo 0)" "$INSIGHTS_CASES"

echo
echo "RESULT: $PASS passed, $FAIL failed"
exit "$FAIL"
