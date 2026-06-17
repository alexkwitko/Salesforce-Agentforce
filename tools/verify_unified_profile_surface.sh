#!/bin/bash
# Verifies the Unified Profile data surface without pretending Profile Explorer UI
# display is certified by headless checks.
set -u

ORG="${1:-AgentforceDev}"
EMAIL="${2:-alexkwitko@gmail.com}"

PASS=0
FAIL=0
WARN=0

check() {
  if [ "$2" = "1" ]; then
    echo "  PASS  $1"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $1 ($3)"
    FAIL=$((FAIL+1))
  fi
}

warn() {
  echo "  WARN  $1"
  WARN=$((WARN+1))
}

dc_sql() {
  local sql="$1"
  jq -nc --arg sql "$sql" '{sql:$sql}' \
    | sf api request rest "/services/data/v67.0/ssot/query-sql" \
      --method POST --body - --target-org "$ORG" 2>/dev/null
}

first_cell() {
  jq -r 'try (.data[0][0] // "") catch ""'
}

num_or_zero() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

sf_query() {
  sf data query --target-org "$ORG" --query "$1" --json 2>/dev/null
}

echo "== 1. Resolve Account + Unified Individual =="
ACCOUNT_JSON=$(sf_query "SELECT Id, Name, PersonEmail, Data_Cloud_Unified_Individual_Id__c, Data_Cloud_Insight_Source__c, Data_Cloud_Last_Augmented_At__c, Insights_Order_Count__c, Insights_LTV__c, Insights_Web_Events__c, Insights_Device_Count__c, Insights_Session_Count__c, Insights_Total_Cases__c, Insights_Returns__c FROM Account WHERE PersonEmail = '$EMAIL' LIMIT 1")
ACCOUNT_ID=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Id // ""')
CACHED_UID=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Data_Cloud_Unified_Individual_Id__c // ""')
CACHED_SOURCE=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Data_Cloud_Insight_Source__c // ""')
CACHED_AT=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Data_Cloud_Last_Augmented_At__c // ""')
echo "  account: ${ACCOUNT_ID:-none}"
echo "  cached unified id: ${CACHED_UID:-none}"
echo "  cached source: ${CACHED_SOURCE:-none}"
echo "  cached at: ${CACHED_AT:-none}"
check "Account found by PersonEmail" "$([ -n "$ACCOUNT_ID" ] && echo 1 || echo 0)" "$EMAIL"
check "Account has Unified Individual id cache" "$([ -n "$CACHED_UID" ] && echo 1 || echo 0)" "blank"
check "Account cache source is Data Cloud CI based" "$([ "$CACHED_SOURCE" = "Data Cloud Unified CI + CRM fallback" ] && echo 1 || echo 0)" "$CACHED_SOURCE"

if [ -n "$ACCOUNT_ID" ]; then
  ACCOUNT_LINK=$(dc_sql "SELECT UnifiedRecordId__c FROM UnifiedLinkssotIndividualCoff__dlm WHERE SourceRecordId__c = '$ACCOUNT_ID' LIMIT 1" | first_cell)
else
  ACCOUNT_LINK=""
fi
echo "  unified link for account: ${ACCOUNT_LINK:-none}"
check "UnifiedLink maps the Account to the cached unified id" "$([ -n "$CACHED_UID" ] && [ "$ACCOUNT_LINK" = "$CACHED_UID" ] && echo 1 || echo 0)" "$ACCOUNT_LINK vs $CACHED_UID"

echo "== 2. Calculated Insight definitions and runtime rows =="
CI_JSON=$(sf_query "SELECT Id, Name, CalculatedInsightStatus, LastRunStatus, LastRunDateTime FROM MktCalculatedInsight WHERE Name IN ('UP Customer Value','UP Web Engagement','UP Web Engagement Device Profile','UP Service Profile') ORDER BY Name")

verify_ci() {
  local label="$1"
  local api="$2"
  local file="force-app/main/default/mktCalcInsightObjectDefs/${api}.mktCalcInsightObjectDef-meta.xml"
  local status
  local last_status
  local count
  status=$(printf "%s" "$CI_JSON" | jq -r --arg name "$label" '.result.records[]? | select(.Name==$name) | .CalculatedInsightStatus' | head -n 1)
  last_status=$(printf "%s" "$CI_JSON" | jq -r --arg name "$label" '.result.records[]? | select(.Name==$name) | (.LastRunStatus // "")' | head -n 1)
  count=$(dc_sql "SELECT COUNT(*) FROM ${api}__cio" | first_cell)
  echo "  $label: status=${status:-none} lastRun=${last_status:-none} rows=${count:-0}"
  check "$label exists and is ACTIVE" "$([ "$status" = "ACTIVE" ] && echo 1 || echo 0)" "${status:-missing}"
  check "$label CIO has materialized rows" "$([ "${count:-0}" -gt 0 ] && echo 1 || echo 0)" "${count:-0}"
  check "$api definition is in local source" "$([ -f "$file" ] && echo 1 || echo 0)" "$file missing"
}

verify_ci "UP Customer Value" "UP_Customer_Value"
verify_ci "UP Web Engagement" "UP_Web_Engagement"
verify_ci "UP Web Engagement Device Profile" "UP_Web_Engagement_Device_Profile"
verify_ci "UP Service Profile" "UP_Service_Profile"

if [ -n "$CACHED_UID" ]; then
  UP_VALUE=$(dc_sql "SELECT OrderCount__c, LifetimeValue__c, AvgOrderValue__c, LastOrderDate__c FROM UP_Customer_Value__cio WHERE UnifiedIndividualId__c = '$CACHED_UID' LIMIT 1")
  UP_ORDER_COUNT=$(printf "%s" "$UP_VALUE" | first_cell)
  UP_WEB_COUNT=$(dc_sql "SELECT WebEventCount__c FROM UP_Web_Engagement__cio WHERE UnifiedIndividualId__c = '$CACHED_UID' LIMIT 1" | first_cell)
  UP_DEVICE_COUNT=$(dc_sql "SELECT DeviceCount__c FROM UP_Web_Engagement_Device_Profile__cio WHERE UnifiedIndividualId__c = '$CACHED_UID' LIMIT 1" | first_cell)
  UP_CASE_COUNT=$(dc_sql "SELECT CaseCount__c FROM UP_Service_Profile__cio WHERE UnifiedIndividualId__c = '$CACHED_UID' LIMIT 1" | first_cell)
else
  UP_ORDER_COUNT=0
  UP_WEB_COUNT=0
  UP_DEVICE_COUNT=0
  UP_CASE_COUNT=0
fi
echo "  unified profile metrics: orders=${UP_ORDER_COUNT:-0} webEvents=${UP_WEB_COUNT:-0} devices=${UP_DEVICE_COUNT:-0} cases=${UP_CASE_COUNT:-0}"
check "Unified profile customer-value CI row populated" "$([ "${UP_ORDER_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "${UP_ORDER_COUNT:-0}"
check "Unified profile web-engagement CI row populated" "$([ "${UP_WEB_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "${UP_WEB_COUNT:-0}"
check "Unified profile device/session CI row populated" "$([ "${UP_DEVICE_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "${UP_DEVICE_COUNT:-0}"
check "Unified profile service CI row populated" "$([ "${UP_CASE_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "${UP_CASE_COUNT:-0}"

echo "== 3. Row-level DMO relationship readiness =="
ORDER_DMO_COUNT=$(dc_sql "SELECT COUNT(*) FROM ssot__SalesOrder__dlm JOIN UnifiedLinkssotIndividualCoff__dlm ON UnifiedLinkssotIndividualCoff__dlm.SourceRecordId__c = ssot__SalesOrder__dlm.ssot__SoldToCustomerId__c WHERE UnifiedLinkssotIndividualCoff__dlm.UnifiedRecordId__c = '$CACHED_UID'" | first_cell)
CASE_DMO_TOTAL=$(dc_sql "SELECT COUNT(*) FROM ssot__Case__dlm" | first_cell)
CASE_DMO_INDIVIDUAL_COUNT=$(dc_sql "SELECT COUNT(*) FROM ssot__Case__dlm JOIN UnifiedLinkssotIndividualCoff__dlm ON UnifiedLinkssotIndividualCoff__dlm.SourceRecordId__c = ssot__Case__dlm.ssot__IndividualId__c WHERE UnifiedLinkssotIndividualCoff__dlm.UnifiedRecordId__c = '$CACHED_UID'" | first_cell)
CASE_DMO_ACCOUNT_COUNT=$(dc_sql "SELECT COUNT(*) FROM ssot__Case__dlm JOIN UnifiedLinkssotIndividualCoff__dlm ON UnifiedLinkssotIndividualCoff__dlm.SourceRecordId__c = ssot__Case__dlm.ssot__AccountId__c WHERE UnifiedLinkssotIndividualCoff__dlm.UnifiedRecordId__c = '$CACHED_UID'" | first_cell)
CASE_DMO_INDIVIDUAL_COUNT=$(num_or_zero "$CASE_DMO_INDIVIDUAL_COUNT")
CASE_DMO_ACCOUNT_COUNT=$(num_or_zero "$CASE_DMO_ACCOUNT_COUNT")
CASE_DMO_COUNT=$((CASE_DMO_INDIVIDUAL_COUNT + CASE_DMO_ACCOUNT_COUNT))
WEB_DMO_COUNT=$(dc_sql "SELECT COUNT(*) FROM Web_Event_c_Home__dlm JOIN UnifiedLinkssotIndividualCoff__dlm ON UnifiedLinkssotIndividualCoff__dlm.SourceRecordId__c = Web_Event_c_Home__dlm.Account_c__c WHERE UnifiedLinkssotIndividualCoff__dlm.UnifiedRecordId__c = '$CACHED_UID'" | first_cell)
echo "  row-level joins to unified profile: salesOrders=${ORDER_DMO_COUNT:-0} cases=${CASE_DMO_COUNT:-0} webEvents=${WEB_DMO_COUNT:-0}"
echo "  case join detail: total=${CASE_DMO_TOTAL:-0} viaIndividual=${CASE_DMO_INDIVIDUAL_COUNT:-0} viaAccount=${CASE_DMO_ACCOUNT_COUNT:-0}"
check "SalesOrder rows join to the Unified Profile" "$([ "${ORDER_DMO_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "${ORDER_DMO_COUNT:-0}"
check "Case rows join to the Unified Profile by IndividualId or AccountId" "$([ "${CASE_DMO_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "individual=${CASE_DMO_INDIVIDUAL_COUNT:-0} account=${CASE_DMO_ACCOUNT_COUNT:-0}"
check "Web event rows join to the Unified Profile" "$([ "${WEB_DMO_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "${WEB_DMO_COUNT:-0}"

MDTO_JSON=$(sf org list metadata --target-org "$ORG" --metadata-type MktDataTranObject --json 2>/dev/null)
for dto in Order_Home Case_Home ReturnOrder_Home Web_Event_c_Home; do
  present=$(printf "%s" "$MDTO_JSON" | jq -r --arg dto "$dto" '([.result[]? | select(.fullName==$dto)] | length)')
check "MktDataTranObject metadata exists for $dto" "$([ "${present:-0}" -gt 0 ] && echo 1 || echo 0)" "missing"
done
check "Standard ssot__SalesOrder DMO is queryable" "$([ "${ORDER_DMO_COUNT:-0}" -gt 0 ] && echo 1 || echo 0)" "join returned ${ORDER_DMO_COUNT:-0}"
check "Standard ssot__Case DMO is queryable" "$([ "${CASE_DMO_TOTAL:-0}" -gt 0 ] && echo 1 || echo 0)" "total returned ${CASE_DMO_TOTAL:-0}"

echo "== 4. CRM Account 360 fallback surface =="
INSIGHTS_ORDER_COUNT=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Insights_Order_Count__c // 0')
INSIGHTS_LTV=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Insights_LTV__c // 0')
INSIGHTS_WEB=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Insights_Web_Events__c // 0')
INSIGHTS_DEVICE=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Insights_Device_Count__c // 0')
INSIGHTS_SESSION=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Insights_Session_Count__c // 0')
INSIGHTS_CASES=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Insights_Total_Cases__c // 0')
INSIGHTS_RETURNS=$(printf "%s" "$ACCOUNT_JSON" | jq -r '.result.records[0].Insights_Returns__c // 0')
echo "  account insight fields: orders=$INSIGHTS_ORDER_COUNT ltv=$INSIGHTS_LTV web=$INSIGHTS_WEB devices=$INSIGHTS_DEVICE sessions=$INSIGHTS_SESSION cases=$INSIGHTS_CASES returns=$INSIGHTS_RETURNS"
check "Account order/LTV insight fields populated" "$([ "${INSIGHTS_ORDER_COUNT:-0}" -gt 0 ] && [ "${INSIGHTS_LTV:-0}" != "0" ] && echo 1 || echo 0)" "$INSIGHTS_ORDER_COUNT/$INSIGHTS_LTV"
check "Account SDK web/device/session insight fields populated" "$([ "${INSIGHTS_WEB:-0}" -gt 0 ] && [ "${INSIGHTS_DEVICE:-0}" -gt 0 ] && [ "${INSIGHTS_SESSION:-0}" -gt 0 ] && echo 1 || echo 0)" "$INSIGHTS_WEB/$INSIGHTS_DEVICE/$INSIGHTS_SESSION"
check "Account service insight fields populated" "$([ "${INSIGHTS_CASES:-0}" -gt 0 ] && echo 1 || echo 0)" "$INSIGHTS_CASES"

ACCOUNT_PAGE="force-app/main/default/flexipages/Account_Record_Page.flexipage-meta.xml"
ACCOUNT_LAYOUT="force-app/main/default/layouts/Account-Account Layout.layout-meta.xml"
for field in Insights_Order_Count__c Insights_LTV__c Insights_Web_Events__c Insights_Device_Count__c Insights_Session_Count__c Insights_Total_Cases__c Insights_Returns__c Data_Cloud_Unified_Individual_Id__c Data_Cloud_Insight_Source__c; do
  check "Account UI source contains $field" "$(rg -q "Record\\.$field|>$field<|$field" "$ACCOUNT_PAGE" "$ACCOUNT_LAYOUT" && echo 1 || echo 0)" "$ACCOUNT_PAGE or $ACCOUNT_LAYOUT"
done

echo "== 5. Visual enrichment configuration boundary =="
CRM_RELATED_JSON=$(sf_query "SELECT DurableId, ParentEntityDefinitionId, EntityDefinitionId, Label, RelatedListId, RelatedListName FROM RelatedListDefinition WHERE ParentEntityDefinitionId IN ('Account','Contact') AND (Label LIKE '%Data Cloud%' OR Label LIKE '%Unified%' OR Label LIKE '%Customer Value%' OR Label LIKE '%Web Engagement%' OR Label LIKE '%Service Profile%' OR Label LIKE '%SalesOrder%' OR Label LIKE '%Sales Order%' OR Label LIKE '%Insight%') ORDER BY ParentEntityDefinitionId, Label LIMIT 100")
CRM_RELATED_COUNT=$(printf "%s" "$CRM_RELATED_JSON" | jq -r '.result.totalSize // 0')
ACCOUNT_RELATED_COMPONENT_COUNT=$(python3 - <<'PY'
from pathlib import Path
path = Path("force-app/main/default/flexipages/Account_Record_Page.flexipage-meta.xml")
text = path.read_text() if path.exists() else ""
needles = [
    "force:relatedListContainer",
    "force:relatedListQuickLinksContainer",
    "force:relatedListSingleContainer",
    "force:dynamicRelatedListSingle",
]
print(sum(text.count(n) for n in needles))
PY
)
echo "  Data Cloud-like Account/Contact related-list definitions: ${CRM_RELATED_COUNT:-0}"
echo "  Account flexipage related-list components: ${ACCOUNT_RELATED_COMPONENT_COUNT:-0}"
check "CRM Account copied-field enrichment is present" "$([ -n "$CACHED_UID" ] && [ "${INSIGHTS_ORDER_COUNT:-0}" -gt 0 ] && [ "${INSIGHTS_WEB:-0}" -gt 0 ] && echo 1 || echo 0)" "missing Account Data Cloud/Insights cache"
if [ "${CRM_RELATED_COUNT:-0}" -eq 0 ]; then
  warn "No Data Cloud-like Account/Contact related-list enrichment is visible through RelatedListDefinition. Salesforce setup docs create Data Cloud Related Lists from Object Manager, and the current CLI registry cannot retrieve a DataCloudRelatedList metadata type."
else
  check "Data Cloud-like Account/Contact related-list definitions detected" "1" "$CRM_RELATED_COUNT"
fi
if [ "${ACCOUNT_RELATED_COMPONENT_COUNT:-0}" -eq 0 ]; then
  warn "Account_Record_Page has copied Data Cloud insight fields but no related-list component in retrievable Flexipage metadata; CRM related-list display depends on page layout/app builder configuration."
else
  check "Account flexipage has related-list components" "1" "$ACCOUNT_RELATED_COMPONENT_COUNT"
fi
warn "Profile Explorer calculated-insight panel and row-level related-list display are UI/enrichment surfaces; this verifier proves data, CI, source metadata, joins, and CRM Account copied-field surface, but not the visual Data Cloud Profile Explorer configuration."

echo
echo "RESULT: $PASS passed, $FAIL failed, $WARN warning(s)"
exit "$FAIL"
