# Kwitko Coffee — Agentforce + Data Cloud + WooCommerce

A Salesforce DX project that turns a WooCommerce storefront into an Agentforce-powered commerce experience:
multiple Agentforce agents (a customer-facing web Service Agent + headless employee agents), a Data Cloud unified
customer profile with Calculated Insights, and Messaging-for-Web (MIAW) embedded chat, all wired to WooCommerce
order/cart data.

This README is the **deploy-to-any-org** guide. It documents both a Salesforce DX (`sf` CLI) path and a Salesforce
MCP path, the ordering constraints, and the manual/API post-deploy steps that are **not** metadata-deployable.

> **Source API version:** 66.0 (`sfdx-project.json`). The Data Cloud Connect REST examples below use `v62.0`,
> which is a valid current Data Cloud API version; bump if your org requires a newer one.

---

## Architecture summary

**Agentforce agents** (`force-app/main/default/aiAuthoringBundles/**`, Agent Script authoring bundles):

| Agent (developer name) | Type | Role |
|---|---|---|
| `Kwitko_Concierge_Web` | Service Agent (customer-facing) | Web chat concierge served through MIAW; order status, recommendations, cart restore, case handoff. Needs a runtime BotUser. |
| `Product_Advisor` | Employee agent (headless) | Personalized product recommendations. |
| `Inside_Sales` | Employee agent (headless) | Lead/cart-recovery outreach (consent-gated). |
| `Post_Purchase_Growth` | Employee agent (headless) | Post-purchase tips + offers, winback on return. |
| `Kwitko_Concierge` | Employee agent (headless) | Internal concierge / orchestration. |

Employee agents are invoked **headlessly** via `AgentInvoker` (the in-org `generateAiAgentResponse` action) from
Flows/jobs/Apex — agents are conversational, not event-driven.

**Apex** (`force-app/main/default/classes`, 80+ classes): integration + agent action services — `AgentInvoker`,
`AgentContextService`/`EmployeeAgentContextService` (one privacy-gated context envelope for all agents),
`WooOrderService`, `CartRestoreService`, `RecommendationStrategyService`, `FulfillmentTruthService`,
`DataCloudAugmentationService`, plus tests.

**Data model** (`force-app/main/default/objects`): standard objects (Account as **Person Account**, Order, Case,
ReturnOrder, Shipment, Product2, Lead, MessagingSession) + custom (`Cart__c`, `Cart_Item__c`, `Coupon__c`,
`Customer_Journey__c`, `Agent_Interaction__c`, `Order_Analytics__c`, `Woo_Settings__c`) + `Discount_Rule__mdt`
custom metadata.

**Data Cloud**: `dataSourceObjects` (DLO defs), `mktDataTranObjects` + `dataStreamDefinitions` (retrieved CRM
stream metadata), `objectSourceTargetMaps` (DLO→DMO field + relationship maps), and `mktCalcInsightObjectDefs`
(Calculated Insights: customer profile/affinity/return-risk/service-risk/return-churn/shipment-health/order-patterns/
web-engagement). First-time target orgs can still reject stream metadata until the Salesforce CRM source connector
exists; use the UI fallback in post-deploy, then re-run the deploy.

**Messaging for Web / routing:** `messagingChannels` (`Kwitko_Web_Chat`, `Kwitko_Web_Chat_V2`),
`EmbeddedServiceConfig`, a public `sites` entry, `queues` + `queueRoutingConfigs` (Omni-Channel), the
`Kwitko_Web_Chat_Routing` flow, `namedCredentials` (WooCommerce), `cspTrustedSites` + `corsWhitelistOrigins`.

**Permission sets:** `Kwitko_Integration` (FLS/object access for the Woo↔SF integration + agent actions),
`Kwitko_Messaging_Ops` (manage stuck messaging sessions), `Engagement_Tracking` (`Web_Event__c` capture/stitch
access), and `Predictive_Scoring` (churn/LTV fields + `Churn_Training__c` access).

---

## Prerequisites (enable in the target org BEFORE deploying)

These are org features the deploy depends on — none can be toggled by metadata:

- **Person Accounts ENABLED** (irreversible; Setup → Account Settings). The Account model + agent logic assume it.
- **Agentforce / Einstein Generative AI** enabled.
- **Data Cloud provisioned** (for DLO/DMO/Calculated-Insight metadata to import).
- **Messaging for Web (Enhanced Messaging)** enabled (for `MessagingChannel`/`EmbeddedServiceConfig`).
- **Omni-Channel** enabled (for `Queue`/`QueueRoutingConfig` + the routing flow).
- Salesforce CLI (`sf`) installed and authenticated; API version 66.0 compatible.
- Adequate **data storage** — Developer Edition / small orgs are tight; see gotchas.

---

## Repository layout

```
force-app/main/default/   # all metadata (source of truth)
manifest/package.xml      # deployable metadata manifest (wildcards; excludes non-deployable DC + agent bundles)
scripts/
  deploy/deploy-to-new-org.sh   # ordered deploy + permset assign + post-deploy checklist
  ci/                           # CI deploy/smoke scripts (GitHub Actions)
  apex/  soql/                  # one-off Apex / SOQL helpers
tools/agent-mcp/          # MCP server exposing ask_kwitko_agent (see docs/mcp-agent-consumer.md)
docs/                     # design docs, audit, CI runbook, MCP design
```

---

## Deploy to a fresh org — Salesforce DX (`sf` CLI)

### Quick path (recommended)

```bash
# 1. Authenticate to the target org
sf org login web --alias myNewOrg --set-default

# 2. Run the ordered deploy + permission-set assignment + post-deploy checklist
scripts/deploy/deploy-to-new-org.sh myNewOrg
# (scratch/dev orgs without full Apex coverage: scripts/deploy/deploy-to-new-org.sh myNewOrg NoTestRun)
```

The script deploys in dependency order, only includes directories that exist/are non-empty (idempotent, re-runnable),
assigns `Kwitko_Integration`, `Kwitko_Messaging_Ops`, `Engagement_Tracking`, and `Predictive_Scoring`, and prints
the manual/API post-deploy checklist.

### Manual ordered path (what the script does)

> Deploys are **async** — for `--metadata` style calls confirm the final `Succeeded` with
> `sf project deploy report --use-most-recent`. The `--source-dir` calls below wait inline.

```bash
ORG=myNewOrg

# 1) Data model first — record types/fields must exist before profiles/permsets reference them
sf project deploy start --source-dir force-app/main/default/objects \
  --source-dir force-app/main/default/layouts \
  --source-dir force-app/main/default/customMetadata --target-org $ORG

# 2) Apex (with tests) — services the agents + integration depend on
sf project deploy start --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/triggers --test-level RunLocalTests --target-org $ORG

# 3) Integration plumbing
sf project deploy start --source-dir force-app/main/default/namedCredentials \
  --source-dir force-app/main/default/cspTrustedSites \
  --source-dir force-app/main/default/corsWhitelistOrigins --target-org $ORG

# 4) Omni-Channel routing primitives (before messaging/flows that use them)
sf project deploy start --source-dir force-app/main/default/queues \
  --source-dir force-app/main/default/queueRoutingConfigs --target-org $ORG

# 5) Messaging for Web channel + embedded config + site
sf project deploy start --source-dir force-app/main/default/messagingChannels \
  --source-dir force-app/main/default/EmbeddedServiceConfig \
  --source-dir force-app/main/default/sites --target-org $ORG

# 6) Flows (routing + automation) — after objects/queues/Apex exist
sf project deploy start --source-dir force-app/main/default/flows \
  --source-dir force-app/main/default/flowDefinitions --target-org $ORG

# 7) Data Cloud, in dependency order: DLO -> streams -> DLO/DMO maps -> Calculated Insights
sf project deploy start --source-dir force-app/main/default/dataSourceObjects --target-org $ORG
sf project deploy start --source-dir force-app/main/default/mktDataTranObjects \
  --source-dir force-app/main/default/dataStreamDefinitions --target-org $ORG
sf project deploy start --source-dir force-app/main/default/objectSourceTargetMaps --target-org $ORG
sf project deploy start --source-dir force-app/main/default/mktCalcInsightObjectDefs --target-org $ORG

# 8) Security (after all referenced objects/fields exist)
sf project deploy start --source-dir force-app/main/default/permissionsets \
  --source-dir force-app/main/default/profiles --target-org $ORG

# 9) UI + settings
sf project deploy start --source-dir force-app/main/default/applications \
  --source-dir force-app/main/default/flexipages --source-dir force-app/main/default/tabs \
  --source-dir force-app/main/default/lwc --source-dir force-app/main/default/aura \
  --source-dir force-app/main/default/staticresources \
  --source-dir force-app/main/default/contentassets \
  --source-dir force-app/main/default/settings --target-org $ORG

# Assign permission sets to the running user
sf org assign permset --name Kwitko_Integration --target-org $ORG
sf org assign permset --name Kwitko_Messaging_Ops --target-org $ORG
sf org assign permset --name Engagement_Tracking --target-org $ORG
sf org assign permset --name Predictive_Scoring --target-org $ORG
```

### Manifest-based alternative

To deploy via the manifest in one call (after preconditions are met):

```bash
sf project deploy start --manifest manifest/package.xml --target-org $ORG --test-level RunLocalTests
```

`manifest/package.xml` uses wildcards and includes the retrieved Data Cloud stream metadata
(`DataStreamDefinition` / `MktDataTranObject`) where present. It still excludes the Agentforce authoring bundles /
planners / plugins / bots (see `.forceignore`). The ordered script is preferred for a fresh org because it isolates
failures per group and treats CRM stream metadata as an org-sensitive step with a UI fallback.

---

## Deploy / verify via the Salesforce MCP

If you use the connected `salesforce` MCP instead of (or alongside) the CLI:

- **`deploy_metadata`** — deploy a source dir or the manifest. Run it once per ordered group above (objects → apex →
  integration → omni → messaging → flows → data cloud → security → ui), or once with `manifest/package.xml`.
- **`run_soql_query`** — verification, e.g.
  - `SELECT QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName LIKE '%__cio'` (Calculated Insights visible)
  - `SELECT DeveloperName, BotSource, BotUserId FROM BotDefinition` (agent runtime users)
  - `SELECT COUNT() FROM UnifiedssotIndividual__dlm` (unified profiles populated — should be > 0)
- **`assign_permission_set`** — assign `Kwitko_Integration`, `Kwitko_Messaging_Ops`, `Engagement_Tracking`, and
  `Predictive_Scoring`.
- **`run_apex_test`** — run the Apex test suite.
- The Data Cloud Identity-Resolution / Calculated-Insight **run** steps are not MCP deploy operations. CRM stream
  metadata is in source, but if a target org rejects first-run stream deploys, create the stream once in the Data
  Cloud UI and re-run the metadata deploy.

---

## Post-deploy steps (NOT metadata-deployable)

### A) Agentforce agents
The agent bundles are `.forceignore`'d (the CLI registry can't infer them reliably here) and are **excluded from the
manifest**. Author/publish + activate each via `sf agent` (Agent Script) or Agent Builder:
```bash
sf agent validate authoring-bundle --api-name Kwitko_Concierge_Web --target-org $ORG
sf agent publish  authoring-bundle --api-name Kwitko_Concierge_Web --target-org $ORG
```
- **Agent type is immutable after first publish** — the web one must stay a Service Agent; the others employee agents.
- Assign runtime users: the **web Service Agent** needs a BotUser; employee agents run as their `default_agent_user`.
  A null `BotDefinition.BotUserId` on an *employee* agent is a reporting artifact, not a failure.
- Verify headless invocation (no deploy of agents needed for this):
  ```bash
  sf apex run --target-org $ORG \
    --apex 'System.debug(AgentInvoker.callAgent("Product_Advisor","hello").agentResponse);'
  ```

### B) Data Cloud — CRM data streams (metadata first, UI fallback)
This repo carries retrieved CRM stream metadata for `Web_Event__c_Home`, `Churn_Training__c_Home`, and the legacy
commerce streams. Deploy `mktDataTranObjects` + `dataStreamDefinitions` after `dataSourceObjects`. If a fresh target
org rejects a stream with **"no MktDataTranObject named <X>_Home found"**, create that stream once in the UI:
**Data Cloud → Data Streams → New → Salesforce CRM →** pick the source object (`Web_Event__c`,
`Churn_Training__c`, Account, Order_Analytics__c, Shipment, ReturnOrder, FulfillmentOrder as applicable) → map to
the matching `*_Home` DLO → **Save & Run**, then re-run the metadata deploy.

### C) Data Cloud — Identity Resolution + Calculated Insights (Connect REST API)
**GOTCHA (root cause from this build):** Identity Resolution silently produces **0 unified profiles** if the
identity keys source from an **empty** field. The `objectSourceTargetMaps` here already map
`Account_Home Id__c → ssot__Individual__dlm.ssot__Id__c` and
`Account_Home Id__c → ssot__ContactPointEmail__dlm.ssot__PartyId__c` (a POPULATED field) — do **not** re-point them
at `PersonIndividualId__c` (empty).

After the data stream runs and the DLO→DMO reprocess populates keys, run via the Connect API (reuses the CLI session):
```bash
# Identity Resolution — note the path is /actions/run-now and the body is {}
sf api request rest "/services/data/v62.0/ssot/identity-resolutions/<RulesetApiName>/actions/run-now" \
  --method POST --body '{}' --target-org $ORG

# Run each Calculated Insight (path is /actions/run)
for ci in Customer_Agent_Profile Customer_Category_Affinity Customer_Return_Risk \
          Customer_Service_Risk Return_Churn_By_Account Shipment_Delivery_Health \
          Order_Patterns_by_Demographics; do
  sf api request rest "/services/data/v62.0/ssot/calculated-insights/${ci}__cio/actions/run" \
    --method POST --body '{}' --target-org $ORG
done

# Verify unified profiles + ad-hoc SQL
sf api request rest "/services/data/v62.0/ssot/query-sql" --method POST \
  --body '{"sql":"SELECT COUNT(*) FROM UnifiedssotIndividual__dlm"}' --target-org $ORG
```

### D) Person Account default record type (UI-only)
The `PersonAccount` record type is a system RT the Metadata API does not expose, so native lead→Person-Account
conversion needs: **Setup → Profiles → System Administrator → Object Settings → Account → Record Types → set
"Person Account" as default.**

### E) Messaging for Web — user verification / `authMode` (Salesforce-side)
For authenticated (non-Guest) chat via `setIdentityToken`, the deployment's `authMode` must accept verified identity
tokens. There is no Metadata/Tooling field for this — open a **Salesforce support case** to enable user verification
on the Enhanced Messaging deployment, then register your JWK/JWKS under Enhanced Chat User Verification. (Until then,
`setIdentityToken` is silently ignored and sessions are Guest.)

### F) Email deliverability (DNS, external)
Outbound agent email from a `@gmail.com` (or any unowned-domain) Org-Wide Email Address **fails Gmail DMARC** even
though Apex reports success. Add a sending subdomain with SPF + Salesforce DKIM + DMARC and verify an OWEA on it.

### G) Storage
Developer Edition / small orgs are storage-constrained. **Do not run `sf agent test` on a storage-tight org** — its
AI Evaluation result records are a large, hard-to-delete storage hog (Testing Center UI only). A MIAW
`POST /conversation` → **412** usually means storage is full, not misconfiguration. Check:
`sf api request rest "/services/data/v62.0/limits" --target-org $ORG | jq '.DataStorageMB'`.

The web engagement endpoint also fails when data storage is full (`STORAGE_LIMIT_EXCEEDED` from
`EngagementRest`). After generating transient prediction rows or endpoint probes, run:
```bash
sf apex run --file tools/cleanup_transient_storage.apex --target-org $ORG
```

---

## Verify the deploy

```bash
bash scripts/ci/salesforce-post-deploy-smoke.sh $ORG
```
Checks the web messaging channel/config, fails on stuck open `MessagingSession`s, checks the web Service Agent's
runtime BotUser, and checks Data Cloud Calculated-Insight visibility + Account augmented fields.

---

## Consume the agents from an MCP client

`tools/agent-mcp/` is a small MCP server exposing `ask_kwitko_agent(agentApiName, message, sessionId?)`. It calls an
Apex REST wrapper around `AgentInvoker`. Design + registration: [`docs/mcp-agent-consumer.md`](docs/mcp-agent-consumer.md).

---

## CI/CD

GitHub Actions handle PR validation + staging/production deploys; see [`docs/CI_CD_RUNBOOK.md`](docs/CI_CD_RUNBOOK.md).
Secrets (SFDX auth URLs, JWT keys, WooCommerce keys) are never committed — see `.gitignore`.

## Further docs

- `docs/SALESFORCE-BUILD-GUIDE.md` — full build narrative.
- `docs/CHAT-AGENT-ORCHESTRATION-DESIGN.md` — multi-agent orchestration design.
- `docs/AGENTFORCE_WOO_DATACLOUD_AUDIT_2026-06-07.md` — system audit.
- `docs/mcp-agent-consumer.md` — MCP agent-consumer design.
