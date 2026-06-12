#!/usr/bin/env bash
#
# deploy-to-new-org.sh — deploy the Kwitko Coffee Agentforce + WooCommerce + Data Cloud
# package to a FRESH Salesforce org, in dependency order, then assign permission sets and
# print the manual/API post-deploy checklist.
#
# This script is IDEMPOTENT: every `sf project deploy start` is safe to re-run (the Metadata
# API upserts), permission-set assignment tolerates "already assigned", and nothing here
# deletes data. Re-run it as many times as you like.
#
# IMPORTANT — this script does NOT enable platform features that are org-toggles or UI/API-only
# (Person Accounts, Data Cloud provisioning, Agentforce, Messaging for Web, Identity Resolution
# run, Calculated Insight runs, Agentforce agent activation). Those are listed as preconditions
# and as the printed post-deploy checklist. See README.md for the full narrative.
#
# Usage:
#   scripts/deploy/deploy-to-new-org.sh <org-alias> [test-level]
#
#   <org-alias>   Required. The `sf` alias of the target org (e.g. you ran:
#                   sf org login web --alias myNewOrg --set-default)
#   [test-level]  Optional. Apex test level for the Apex deploy step.
#                 Default: RunLocalTests. Use NoTestRun only for non-prod scratch orgs.
#
# Examples:
#   scripts/deploy/deploy-to-new-org.sh myNewOrg
#   scripts/deploy/deploy-to-new-org.sh myScratch NoTestRun
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Args + setup
# ---------------------------------------------------------------------------
ORG_ALIAS="${1:?Usage: deploy-to-new-org.sh <org-alias> [test-level]}"
TEST_LEVEL="${2:-RunLocalTests}"
WAIT_MINUTES="${WAIT_MINUTES:-60}"

# Resolve repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." >/dev/null 2>&1 && pwd)"
cd "$REPO_ROOT"

# Permission sets to assign to the running user after deploy.
PERMISSION_SETS=(
  "Kwitko_Integration"
  "Kwitko_Messaging_Ops"
  "Engagement_Tracking"   # FLS for Web_Event__c (engagement capture + identity stitch)
  "Predictive_Scoring"    # FLS for churn/LTV fields + Churn_Training__c (predictive pipeline)
)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }

# A wrapper that deploys a set of source dirs but only includes dirs that exist and are non-empty,
# so the same script works against partial checkouts and stays idempotent.
deploy_dirs() {
  local label="$1"; shift
  local args=()
  local dir
  for dir in "$@"; do
    if [[ -d "$dir" ]] && find "$dir" -type f -print -quit | grep -q .; then
      args+=(--source-dir "$dir")
    fi
  done
  if [[ "${#args[@]}" -eq 0 ]]; then
    warn "Skipping '$label' — no source found."
    return 0
  fi
  log "Deploying: $label"
  sf project deploy start \
    "${args[@]}" \
    --target-org "$ORG_ALIAS" \
    --test-level "$TEST_LEVEL" \
    --wait "$WAIT_MINUTES" \
    --concise
}

# ---------------------------------------------------------------------------
# Preconditions (informational — we verify the org is reachable, the rest is on the operator)
# ---------------------------------------------------------------------------
log "Target org: $ORG_ALIAS  |  test level: $TEST_LEVEL"
sf org display --target-org "$ORG_ALIAS" >/dev/null || {
  warn "Cannot reach org '$ORG_ALIAS'. Run: sf org login web --alias $ORG_ALIAS"
  exit 1
}

cat <<'PRECHECK'

------------------------------------------------------------------------------
PRECONDITIONS (must already be true in the target org — this script cannot toggle them):
  [ ] Person Accounts are ENABLED (irreversible org setting; Setup > Account Settings).
  [ ] Agentforce / Einstein Generative AI is enabled.
  [ ] Data Cloud is provisioned (for the DataSourceObject / ObjectSourceTargetMap /
      Calculated Insight metadata to import).
  [ ] Messaging for Web (Enhanced Messaging) is enabled (for MessagingChannel /
      EmbeddedServiceConfig).
  [ ] Omni-Channel is enabled (for Queue / QueueRoutingConfig + routing flow).
If any are missing, the corresponding deploy step below will fail — enable, then re-run.
------------------------------------------------------------------------------
PRECHECK

# ---------------------------------------------------------------------------
# Ordered deploys.
#
# The Metadata API resolves most intra-deploy references, but a few ordering constraints are real:
#  1. Object model (record types/fields) must exist before Profiles/PermissionSets reference them.
#  2. Data Cloud DLO definitions (DataSourceObject) must exist before the ObjectSourceTargetMap
#     that maps DLO->DMO fields, which must exist before Calculated Insights that read the DMOs.
#  3. Messaging channel + routing queues must exist before the EmbeddedServiceConfig that points
#     at them, and before the routing Flow.
# We deploy in groups to make a failure point obvious and to keep each step re-runnable.
# ---------------------------------------------------------------------------

# 1) Data model first (objects, fields, record types, layouts, custom metadata records).
#    NOTE: the Account "Business_Account" record type deploys fine; the system "PersonAccount"
#    record type is NOT in source (Metadata API does not expose it) — see README gotchas.
deploy_dirs "1. Data model (objects/fields/recordTypes/layouts/customMetadata)" \
  "force-app/main/default/objects" \
  "force-app/main/default/layouts" \
  "force-app/main/default/customMetadata"

# 2) Apex (with tests). Services the agents + integration depend on.
deploy_dirs "2. Apex classes & triggers (test level: $TEST_LEVEL)" \
  "force-app/main/default/classes" \
  "force-app/main/default/triggers"

# 3) Integration plumbing (Named Credential, CSP/CORS for the storefront + Woo).
deploy_dirs "3. Integration (namedCredentials, cspTrustedSites, corsWhitelistOrigins)" \
  "force-app/main/default/namedCredentials" \
  "force-app/main/default/cspTrustedSites" \
  "force-app/main/default/corsWhitelistOrigins"

# 4) Omni-Channel routing primitives (queues + routing config) before messaging/flows that use them.
deploy_dirs "4. Omni-Channel (queues, queueRoutingConfigs)" \
  "force-app/main/default/queues" \
  "force-app/main/default/queueRoutingConfigs"

# 5) Messaging for Web channel + embedded config + the public site.
deploy_dirs "5. Messaging for Web (messagingChannels, EmbeddedServiceConfig, sites)" \
  "force-app/main/default/messagingChannels" \
  "force-app/main/default/EmbeddedServiceConfig" \
  "force-app/main/default/sites"

# 6) Automation flows (routing + record-triggered) — after objects, queues, and Apex exist.
deploy_dirs "6. Flows (routing + automation)" \
  "force-app/main/default/flows" \
  "force-app/main/default/flowDefinitions"

# 7) Data Cloud metadata, in dependency order:
#    DLO defs -> CRM stream metadata -> DLO->DMO maps -> Calculated Insights.
#    Stream metadata is org-sensitive, so its deploy is non-fatal with a UI fallback.
deploy_dirs "7a. Data Cloud DLO definitions (dataSourceObjects)" \
  "force-app/main/default/dataSourceObjects"

# 7b. CRM DATA STREAMS (MktDataTranObject + DataStreamDefinition) — NON-FATAL.
#     On a fresh org these create/upsert the streams that POPULATE the *_Home DLOs. If the
#     source object has never been streamed, the Metadata API rejects with
#     "no MktDataTranObject named <X>_Home found" — that is expected on first run: create the
#     stream once in the UI (Data Streams > New > Salesforce CRM) and re-run this script; the
#     metadata then upserts cleanly. We do NOT abort the whole deploy on this step.
deploy_streams_nonfatal() {
  local args=() dir
  for dir in "force-app/main/default/mktDataTranObjects" \
             "force-app/main/default/dataStreamDefinitions"; do
    if [[ -d "$dir" ]] && find "$dir" -type f -print -quit | grep -q .; then
      args+=(--source-dir "$dir")
    fi
  done
  [[ "${#args[@]}" -eq 0 ]] && { warn "Skipping '7d. Data Cloud streams' — no source found."; return 0; }
  log "Deploying: 7d. Data Cloud CRM streams (dataStreamDefinitions, mktDataTranObjects) [non-fatal]"
  if sf project deploy start "${args[@]}" --target-org "$ORG_ALIAS" \
        --test-level NoTestRun --wait "$WAIT_MINUTES" --concise; then
    echo "    streams deployed."
  else
    warn "Stream metadata deploy failed (expected on a fresh org with no prior stream for the"
    warn "source object). Create each stream once in the Data Cloud UI (see post-deploy section B),"
    warn "then re-run this script — the stream metadata will upsert cleanly. Continuing."
  fi
}
deploy_streams_nonfatal

deploy_dirs "7c. Data Cloud DLO->DMO maps (objectSourceTargetMaps)" \
  "force-app/main/default/objectSourceTargetMaps"
deploy_dirs "7d. Data Cloud Calculated Insights (mktCalcInsightObjectDefs)" \
  "force-app/main/default/mktCalcInsightObjectDefs"

# 8) Security/access (permission sets + profile). After all referenced objects/fields exist.
deploy_dirs "8. Security (permissionsets, profiles)" \
  "force-app/main/default/permissionsets" \
  "force-app/main/default/profiles"

# 9) UI + remaining settings.
deploy_dirs "9. UI & settings (apps, flexipages, tabs, lwc, aura, staticresources, contentassets, settings)" \
  "force-app/main/default/applications" \
  "force-app/main/default/flexipages" \
  "force-app/main/default/tabs" \
  "force-app/main/default/lwc" \
  "force-app/main/default/aura" \
  "force-app/main/default/staticresources" \
  "force-app/main/default/contentassets" \
  "force-app/main/default/settings"

# ---------------------------------------------------------------------------
# Assign permission sets to the running user (idempotent).
# ---------------------------------------------------------------------------
log "Assigning permission sets to the running user"
for ps in "${PERMISSION_SETS[@]}"; do
  if sf org assign permset --name "$ps" --target-org "$ORG_ALIAS" 2>/tmp/ps_err.txt; then
    echo "    assigned: $ps"
  else
    if grep -qiE 'already|DUPLICATE' /tmp/ps_err.txt; then
      echo "    already assigned: $ps"
    else
      warn "Could not assign $ps:"; cat /tmp/ps_err.txt >&2
    fi
  fi
done
rm -f /tmp/ps_err.txt

# ---------------------------------------------------------------------------
# Manual / API post-deploy checklist (NOT metadata-deployable).
# ---------------------------------------------------------------------------
cat <<'POST'

==============================================================================
 METADATA DEPLOY COMPLETE. The following steps are NOT metadata-deployable and
 must be done manually (UI) or via the Connect/Data Cloud REST API.
==============================================================================

A) AGENTFORCE AGENTS (authoring bundles are excluded from the manifest)
   The agents (Kwitko_Concierge_Web service agent + employee agents Inside_Sales,
   Post_Purchase_Growth, Product_Advisor, Kwitko_Concierge) live under
   force-app/main/default/aiAuthoringBundles/** and are .forceignore'd.
   - Author/publish each via:  sf agent ...  (Agent Script authoring) or the Agent Builder UI.
   - Activate each agent and assign a runtime user:
       * The web Service Agent (Kwitko_Concierge_Web) needs a BotUser (Agentforce Service Agent user).
       * Employee agents run as their default_agent_user (dedicated integration users).
   - Verify headless invocation without deploying agents:
       sf apex run --target-org "<alias>" \
         --apex 'System.debug(AgentInvoker.callAgent("Product_Advisor","hello").agentResponse);'

B) DATA CLOUD — CRM DATA STREAMS (metadata first, UI fallback)
   This repo includes retrieved stream metadata for Web_Event__c_Home and
   Churn_Training__c_Home, plus the legacy commerce streams. The script attempts to
   deploy MktDataTranObject/DataStreamDefinition metadata. If a target org rejects a
   stream with "no MktDataTranObject named <X>_Home found", create that stream once:
     Data Cloud UI > Data Streams > New > Salesforce CRM > pick the source object
       (Web_Event__c, Churn_Training__c, Account, Order_Analytics__c, Shipment,
        ReturnOrder, FulfillmentOrder as applicable) >
       map to the matching *_Home DLO > Save & Run, then re-run this script.

C) DATA CLOUD — IDENTITY RESOLUTION + CALCULATED INSIGHTS (API post-steps)
   GOTCHA (root cause from this build): the unified Individual key MUST source from a POPULATED
   field. Map Account_Home Id__c -> ssot__Individual__dlm.ssot__Id__c and
   Account_Home Id__c -> ssot__ContactPointEmail__dlm.ssot__PartyId__c (the objectSourceTargetMaps
   in this repo already do this). Do NOT source from PersonIndividualId__c — it is empty, which
   yields 0 unified profiles.
   Then run, via the Data Cloud REST API (uses the org you are logged into):
     # Run Identity Resolution now (accepted once keys are populated):
     sf api request rest "/services/data/v62.0/ssot/identity-resolutions/<RulesetApiName>/actions/run-now" --method POST --body '{}' --target-org "<alias>"
     # Run each Calculated Insight:
     sf api request rest "/services/data/v62.0/ssot/calculated-insights/Customer_Agent_Profile__cio/actions/run" --method POST --target-org "<alias>"
     # (repeat for Customer_Category_Affinity, Customer_Return_Risk, Customer_Service_Risk,
     #  Return_Churn_By_Account, Shipment_Delivery_Health, Order_Patterns_by_Demographics,
     #  Web_Engagement_Profile_v2)
   Verify unified profiles populated:
     sf data query --target-org "<alias>" --query "SELECT COUNT() FROM UnifiedssotIndividual__dlm"

D) PERSON ACCOUNT DEFAULT RECORD TYPE (UI-only)
   The PersonAccount record type is a system RT the Metadata API does not expose. To allow native
   lead conversion into Person Accounts:
     Setup > Profiles > System Administrator > Object Settings > Account > Record Types >
       set "Person Account" as default.

E) MESSAGING FOR WEB — USER VERIFICATION / authMode (Salesforce-side toggle)
   If you need authenticated (non-Guest) chat with setIdentityToken, the deployment's authMode
   must accept verified identity tokens. There is no Metadata/Tooling field for this — open a
   Salesforce support case to enable user verification on the Enhanced Messaging deployment, then
   register your JWK/JWKS under Enhanced Chat User Verification.

F) EMAIL DELIVERABILITY (DNS, external)
   Agent emails fail Gmail DMARC when sent from a @gmail.com Org-Wide Email Address. Add a real
   sending subdomain with SPF/DKIM/DMARC and verify an OWEA on it before relying on agent email.

G) STORAGE
   Developer Edition / small orgs are storage-constrained. `sf agent test` and large data loads
   can hit limits. Load only the data you need.

Run the smoke checks once the above are done:
   bash scripts/ci/salesforce-post-deploy-smoke.sh "<alias>"
==============================================================================
POST

log "Done. Review the post-deploy checklist above."
