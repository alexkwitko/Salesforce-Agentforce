# Kwitko Coffee — a full multi-cloud Agentforce reference org

An end-to-end Salesforce build that wires **one coffee business** across **D2C/B2B Commerce, Service Cloud, Field Service, Revenue Lifecycle Management (RLM), Data Cloud (+ the web browsing SDK), Salesforce Payments, and Agentforce** — with **12 AI agents** and a layer of deterministic + generative AI on top. Two brands (Kwitko Coffee on WooCommerce + Bean & Brew on a native LWR storefront) run as **one unified customer profile**.

It's also a **reference + playbook**: it ships the reusable **Claude Code skills** used to build it, a one-command deploy, and a headless **MCP** path to drive the agents.

> **Scale:** 172 Apex classes · 12 Agentforce agents · 9 Flows · 8 LWC · 24 custom objects · 14 permission sets · Data Cloud (Identity Resolution + 8 Calculated Insights + Web SDK) · source API 66.0.
> **Built DX-first.** Most of it deploys from metadata; the genuinely-UI/Salesforce-gated steps are listed explicitly in [Post-deploy](#post-deploy-steps-not-metadata-deployable).

---

## What each cloud / capability includes

### 🛒 Commerce — D2C + B2B (WooCommerce **and** native LWR storefront)
- **WooCommerce integration** (bi-directional): order pull/push, product sync, customers, coupons, webhooks, return receipts — `WooOrderService`, `WooOrderPull`, `WooOrderActionService`, `WooProductSync`, `WooCustomerService`, `WooCouponService`, `WooWebhookResource`, `WooCartResource`, `WooReturnReceiptResource`. HMAC-verified inbound webhooks; Named-Credential outbound.
- **Cart & recovery:** `Cart__c`/`Cart_Item__c`, `CartRestoreService`, `CartLinkService`, `CartQueueService`, abandoned-cart capture → lead (`AbandonedCartService`, `Abandoned_Cart_to_Lead` flow), `ReplenishmentService` (consumable re-order).
- **Bean & Brew native storefront** (LWR, second brand): custom homepage components `bbHero`, `bbBrandStory`, `bbFeaturedCollection`, `bbValueProps`, `bbNewsletter`, `bbThemeLayout`; **CartExtension** calculators `BeanBrewTaxCartCalculator` (tax) + `BeanBrewPromotionsCalculator` (spend-based promo); buyer provisioning (`Bean_Brew_Commerce_Buyer` permset).
- **Promotions / coupons / pricing:** `CouponService`, `CouponAnalyticsService`, `Discount_Rule__mdt`.

### 🎧 Service Cloud
- **Case lifecycle:** record types + support processes, queues, escalation, `CaseService`, `CaseResolutionService`, `caseServicePanel` LWC, transcript persistence (`CaseTranscriptUtil`, `CaseMessagingSessionLinker`).
- **Order-service fix tools (real actions, not just answers):** `ReturnService`, `CancellationService`, `ExchangeService`, `ReshipService`, `AddressUpdateService`, `OrderModifyService`, `FailedPaymentService`, `StoreCreditService`, `PasswordResetService`, `OrderStatusService`, `TrackingService`.
- **Entitlements / SLA:** `Kwitko_Entitlement_Access`, milestones; **Knowledge** grounding for the agent; **Omni-Channel** routing for web chat (`Kwitko_Web_Chat_Routing` flow + queues).
- **Consent + identity gate:** `ConsentService`, `IdentityService`, OTP verification (`VerificationService`, `RequestVerificationCodeAction`, `VerifyCodeAction`), `LoginLinkService`, `Chat_Verification__c`.

### 🔧 Field Service (FSL)
- **Work orders → appointments**, **Maintenance Plans** (preventive, asset-based), **scheduling** (Dispatcher Console / Classic), service territories/resources.
- **On-site invocables:** `FieldServiceTechActions` (incl. **collect payment**), `FieldQuoteAction` (field quotes), `FieldServiceAutopilot`, `FieldVisitToolkit`, service reports + digital signature.
- **Field Service AI:** `FieldVisitAI` — a grounded **pre-visit brief + draft service-report notes** via `ConnectApi.EinsteinLLM`, surfaced in the **`fsVisitAssistant`** mobile LWC (record action).
- **Maintenance self-service:** `Fs*` action classes power the Maintenance Concierge agents (coverage, book/reschedule/cancel visits).

### 💳 Payments
- **Salesforce Payments** for D2C checkout (Bean & Brew), **field payments** (`FieldServiceTechActions.collectPayment` → Payment record + `WO Payment_Status`, mock gateway), and **pay-now retry links** for failed commerce payments (`FailedPaymentService`). `Field_Service_Payments` permset.

### 🔁 Revenue Lifecycle Management (RLM / Revenue Cloud)
Built + proven on a **headless Subscription Management** org (no RCA builder/Place-Quote engine — the agents are the front door):
- **Subscription lifecycle on `Asset`:** provision / amend (seats) / renew / cancel — `SubscriptionConciergeService` + `Sub*` actions.
- **AI quoting on the standard `Quote` object** (no engine needed): `DraftQuoteAction` + `QuoteDraftService`.
- **RLM ↔ Field Service coupling:** `AssetSubscriptionLifecycle` trigger keeps `MaintenancePlan` + `ServiceContract` in lockstep on renew/cancel (`AssetLifecycleCouplingService`).
- **Real-time subscription insights:** `SubscriptionInsightsService` recomputes `Account.Insights_Subscription_*` **synchronously on every Asset change** (trigger-driven, not a nightly batch).
- See `skills/salesforce-rlm/use-cases-and-agent-patterns.md` → *"engine-gated org playbook."*

### 🧠 Data Cloud (unified profile + predictive)
- **Unified customer profile** via **Identity Resolution** (both brands → one Individual), DLOs/DMOs (`dataSourceObjects`, `objectSourceTargetMaps`), and **8 Calculated Insights** (customer profile / category affinity / return risk / service risk / return-churn / shipment health / order patterns / web engagement).
- **Augmentation back to CRM:** `DataCloudAugmentationService` writes unified-profile signals (segment, LTV, churn, NBA) onto the `Account` so agents read them live.
- **Predictive pipeline:** an **Einstein Studio churn model** + `ChurnScoreService` (writes `Account.Churn_*`), `CustomerInsightsService` (RFM/value/taste), `AtRiskCampaignBuilder` (churn → campaign activation).

### 🌐 Data Cloud SDK — web browsing capture
- **Web SDK / engagement capture** of anonymous browsing → `Web_Event__c` → the Web_Event DMO; custom ingest endpoint `EngagementRest` (`@RestResource`); **device→person identity stitch** (`IdentityStitchService`, `WebIdentityService`) so anonymous activity resolves to the unified profile after sign-in. `Engagement_Tracking` permset.

### 🏷️ Multi-brand
One org, two brands as **one profile** — brand is a dimension, not an identity: `MessagingSessionBrandStamp` (chat → brand) + `OrderBrandStamp` (order → brand) so recommendations/segments are brand-aware.

---

## The 12 Agentforce agents

**Service Agents** (customer-facing, MIAW web chat — need a runtime BotUser):

| Agent | What it does |
|---|---|
| `Kwitko_Concierge_Web` / `Kwitko_Concierge_Web_Live` | The storefront concierge: shopping + personalized recommendations **and** full order service (status, tracking, returns, refunds, cancellations, cases) **and** field-service maintenance — all in one chat, identity-gated. |
| `Maintenance_Concierge_Web` | Customer self-service for Field Service maintenance (coverage, book/reschedule/cancel visits) over WorkOrder/ServiceAppointment/ServiceContract. |

**Employee agents** (internal / headless — invoked via `AgentInvoker` / MCP):

| Agent | What it does |
|---|---|
| `Kwitko_Concierge` | Concierge orchestrator (internal): greet, capture lead+consent, recognize returning customers, build buyer-aware recommendations. |
| `Product_Advisor` | The **recommendation brain** — profiles the buyer, picks products + quantities, resolves discounts deterministically (the engine other agents call). |
| `Inside_Sales` | Re-engages abandoned-cart leads with a personalized one-time recovery discount (consent-gated). |
| `Post_Purchase_Growth` | Analyzes a completed order, recommends an in-stock product, issues a one-time coupon, emails the customer; winback on return. |
| `Lead_Copilot` | Reviews a Nurture lead's unified-profile metrics (LTV, purchases, recency, cart) and recommends + applies the next-best conversion step. |
| `Subscription_Concierge` | NL front door to RLM subscriptions: view / provision / amend / renew / cancel on the `Asset` object. |
| `Renewal_Retention` | Works the subscription install base: renewals due + **Data Cloud churn risk** → next-best action (at-risk save / renew+upsell), renews, logs plays. |
| `Quote_Copilot` | Drafts standard Salesforce Quotes (Quote + QuoteLineItem) from natural language, at catalog price with an optional discount. |
| `Maintenance_Concierge` | Internal/headless field-service maintenance self-service (the employee-agent twin of the web one). |

Agent actions are thin Apex `@InvocableMethod` wrappers; every agent shares **one privacy-gated context envelope** (`AgentContextService` / `EmployeeAgentContextService`) and an **anti-hallucination** instruction grammar (never claim an outcome unless the action returned success this turn).

## The AI (beyond the conversational agents)

| AI | What it does | How |
|---|---|---|
| **Churn model** | Predicts account churn risk → `Account.Churn_Score__c`/`Churn_Risk_Tier__c`; drives renewal/retention plays + at-risk campaigns. | Einstein Studio model + `ChurnScoreService` + `AtRiskCampaignBuilder` |
| **Recommendation engine** | Deterministic product/quantity/discount strategy the agents call (so the LLM never invents prices). | `RecommendationStrategyService`, `ProductSuggestionService` |
| **Field Visit AI** | Grounded pre-visit brief + draft service-report notes for technicians. | `FieldVisitAI` via `ConnectApi.EinsteinLLM` + `fsVisitAssistant` LWC |
| **Profile insights** | Per-account RFM / value / taste / subscription value + next renewal, written to `Account.Insights_*` (real-time for subscriptions). | `CustomerInsightsService`, `SubscriptionInsightsService`, `DataCloudAugmentationService` |

---

## Quick start — deploy to a fresh dev/scratch org (one command)

```bash
# 1) Authenticate to the target org (or create a scratch org with config/project-scratch-def.json)
sf org login web --alias myOrg --set-default

# 2) Ordered deploy + permission-set assignment + a printed post-deploy checklist
scripts/deploy/deploy-to-new-org.sh myOrg
#   scratch/dev orgs without full Apex coverage:  scripts/deploy/deploy-to-new-org.sh myOrg NoTestRun
```

The script is **idempotent** (re-runnable), deploys in dependency order (objects → Apex → integration → Omni-Channel → messaging → flows → Data Cloud → security → UI), assigns the core permission sets, and prints the manual steps that can't be deployed.

> **Org prerequisites** (toggle BEFORE deploying — none are metadata): Person Accounts ENABLED, Agentforce/Einstein on, Data Cloud provisioned, Messaging for Web (Enhanced Messaging) on, Omni-Channel on, `sf` CLI authenticated. See the full list the script prints.

---

## Use it — drive the agents headlessly (Apex / MCP / Flow)

Employee agents are **conversational, not event-driven** — fire them headlessly from Apex, a Flow, a scheduled job, or an MCP client.

**From Apex / CLI** (the in-org `generateAiAgentResponse`, no OAuth):
```bash
sf apex run --target-org myOrg \
  --apex 'System.debug(AgentInvoker.callAgent("Subscription_Concierge","I am dana.demo@example.com — what am I subscribed to?").agentResponse);'
```

**Multi-turn** — pass back the returned `sessionId`:
```apex
AgentInvoker.Response r1 = AgentInvoker.callAgent('Quote_Copilot','Quote Acme Roasters 20 of the Coffee Club at 10% off');
AgentInvoker.Response r2 = AgentInvoker.callAgent('Quote_Copilot','make it 30', r1.sessionId);
```

**Via MCP (headless):** `tools/agent-mcp/` is a small MCP server exposing `ask_kwitko_agent(agentApiName, message, sessionId?)` over an Apex REST wrapper around `AgentInvoker` — drive any employee agent from any MCP client. Design + registration: [`docs/mcp-agent-consumer.md`](docs/mcp-agent-consumer.md).

**Customer-facing (Service Agents):** reached through the deployed **Messaging-for-Web** channel (not `generateAiAgentResponse`). A storage-free SCRT/SSE smoke test lives in `scripts/ci/web-chat-conversation-smoke.sh`.

> Note: `generateAiAgentResponse` works for **employee** agents; Service Agents are exercised through the messaging channel.

---

## Prerequisites (enable in the target org BEFORE deploying)

These are org features the deploy depends on — none can be toggled by metadata:

- **Person Accounts ENABLED** (irreversible; Setup → Account Settings). The Account model + agent logic assume it.
- **Agentforce / Einstein Generative AI** enabled.
- **Data Cloud provisioned** (for DLO/DMO/Calculated-Insight metadata to import).
- **Messaging for Web (Enhanced Messaging)** enabled (for `MessagingChannel`/`EmbeddedServiceConfig`).
- **Omni-Channel** enabled (for `Queue`/`QueueRoutingConfig` + the routing flow).
- (Optional, per cloud) **Field Service** managed package, **Revenue Cloud / Subscription Management**, **Salesforce Payments** — enable the ones whose features you want.
- Salesforce CLI (`sf`) installed and authenticated; API version 66.0 compatible. Adequate **data storage** (DE orgs are tight — see gotchas).

---

## Repository layout

```
force-app/main/default/   # all metadata (source of truth)
manifest/package.xml      # deployable manifest (wildcards; excludes non-deployable DC + agent bundles)
config/                   # project-scratch-def.json (scratch org shape)
scripts/
  deploy/deploy-to-new-org.sh   # ordered, idempotent deploy + permset assign + post-deploy checklist
  ci/                           # CI deploy/smoke/secret-scan scripts (GitHub Actions)
  apex/  soql/                  # one-off Apex / SOQL helpers
tools/agent-mcp/          # MCP server exposing ask_kwitko_agent (see docs/mcp-agent-consumer.md)
docs/                     # build guides, orchestration design, CI runbook, MCP design, use-cases & QA
skills/                   # reusable Claude Code skills (salesforce-rlm/agentforce/service/field-service/d2c-setup)
```

---

## Deploy via the Salesforce MCP

If you use the connected `salesforce` MCP instead of (or alongside) the CLI:

- **`deploy_metadata`** — deploy a source dir or the manifest. Run once per ordered group (objects → apex → integration → omni → messaging → flows → data cloud → security → ui), or once with `manifest/package.xml`.
- **`run_soql_query`** — verification, e.g. `SELECT DeveloperName, BotUserId FROM BotDefinition`, `SELECT COUNT() FROM UnifiedssotIndividual__dlm` (unified profiles > 0).
- **`assign_permission_set`** — assign the core permsets (below).
- **`run_apex_test`** — run the Apex test suite.

Core permission sets: `Kwitko_Integration`, `Kwitko_Messaging_Ops`, `Engagement_Tracking`, `Predictive_Scoring` (+ per-cloud: `Field_Service_Payments`, `Subscription_Insights_FLS`, `Bean_Brew_Commerce_Buyer`, `Kwitko_Entitlement_Access`, `Brand_Catalog_Access`, …).

---

## Post-deploy steps (NOT metadata-deployable)

### A) Agentforce agents
Bundles are `.forceignore`'d / excluded from the manifest. Publish + activate each via `sf agent` (Agent Script) or Agent Builder:
```bash
sf agent validate authoring-bundle --api-name Subscription_Concierge --target-org myOrg
sf agent publish  authoring-bundle --api-name Subscription_Concierge --target-org myOrg
sf agent activate --api-name Subscription_Concierge --version 1 --target-org myOrg   # publish does NOT auto-activate
```
- **Agent type is immutable after first publish** — Service Agents stay Service Agents; employee agents stay employee.
- Service Agents need a runtime **BotUser**; employee agents run as their `default_agent_user`.
- ⚠️ Service Agent bundles carry a `default_agent_user` that is org-specific — set it to your org's Einstein Service Agent `*.ext` user before publishing.
- Verify an employee agent headlessly: `sf apex run --apex 'System.debug(AgentInvoker.callAgent("Product_Advisor","hello").agentResponse);'`

### B) Data Cloud — CRM data streams (metadata first, UI fallback)
Deploy `mktDataTranObjects` + `dataStreamDefinitions` after `dataSourceObjects`. If a fresh org rejects a stream with **"no MktDataTranObject named &lt;X&gt;_Home found"**, create it once: **Data Cloud → Data Streams → New → Salesforce CRM →** pick the source object → map to the matching `*_Home` DLO → **Save & Run**, then re-run the deploy.

### C) Data Cloud — Identity Resolution + Calculated Insights (Connect REST API)
**GOTCHA:** Identity Resolution silently yields **0 unified profiles** if the identity key sources from an **empty** field. The `objectSourceTargetMaps` here map a **populated** field — don't re-point them at an empty one. After the stream runs:
```bash
sf api request rest "/services/data/v62.0/ssot/identity-resolutions/<Ruleset>/actions/run-now" --method POST --body '{}' --target-org myOrg
for ci in Customer_Agent_Profile Customer_Category_Affinity Customer_Return_Risk Customer_Service_Risk \
          Return_Churn_By_Account Shipment_Delivery_Health Order_Patterns_by_Demographics; do
  sf api request rest "/services/data/v62.0/ssot/calculated-insights/${ci}__cio/actions/run" --method POST --body '{}' --target-org myOrg
done
```

### D) Person Account default record type (UI-only)
**Setup → Profiles → System Administrator → Object Settings → Account → Record Types → set "Person Account" as default** (the system RT isn't in metadata).

### E) Messaging for Web — user verification (Salesforce-side)
Authenticated chat via `setIdentityToken` needs the deployment's user-verification enabled (no metadata field) — open a Salesforce support case, then register your JWK/JWKS under Enhanced Chat User Verification. Until then, `setIdentityToken` is ignored and sessions are Guest.

### F) Email deliverability (DNS) · G) Storage
Outbound agent email from an unowned-domain OWEA fails Gmail DMARC — add a sending subdomain with SPF/DKIM/DMARC. DE/small orgs are storage-tight: **don't run `sf agent test` on a storage-tight org** (AI-Evaluation records are a hard-to-delete hog); a MIAW `POST /conversation` → 412 usually means storage is full.

---

## Verify the deploy
```bash
bash scripts/ci/salesforce-post-deploy-smoke.sh myOrg
```
Checks the web messaging channel/config, stuck `MessagingSession`s, the Service Agent's BotUser, and Data Cloud Calculated-Insight visibility + Account augmented fields.

---

## Reusable Claude Code skills (`/skills`)

Product-agnostic, DX-first playbooks used to build this — drop into `~/.claude/skills/`:

| Skill | Covers |
|---|---|
| `salesforce-rlm` | Revenue Cloud / RLM — catalog, pricing, Asset lifecycle, RLM↔Field-Service, the headless-vs-RCA fork, the **engine-gated org playbook**. |
| `salesforce-agentforce` | Agentforce agents (Agent Script), Data Cloud, MIAW chat, page-layouts/Dynamic-Forms, multi-turn agent testing. |
| `salesforce-service` | Service Cloud — cases, Knowledge, Omni-Channel, order-service flows. |
| `salesforce-field-service` | Field Service — enablement, managed package, work orders/appointments, scheduling, Maintenance Plans, payments, mobile. |
| `salesforce-d2c-setup` | D2C/B2B Commerce — storefront, catalog, checkout, payments/tax, promotions, OrderSummary. |

## Further docs
- `docs/SALESFORCE-BUILD-GUIDE.md` — full build narrative · `docs/BUILD_TUTORIAL.md` — step-by-step tutorial
- `docs/CHAT-AGENT-ORCHESTRATION-DESIGN.md` — multi-agent orchestration design
- `docs/USE-CASES-AND-QA.md` — use cases + Q&A · `docs/AGENT_CERTIFICATION_SUMMARY.md` — agent test/cert summary
- `docs/mcp-agent-consumer.md` — MCP agent-consumer design · `docs/CI_CD_RUNBOOK.md` — CI/CD

## CI/CD
GitHub Actions handle PR validation + staging/production deploys (`docs/CI_CD_RUNBOOK.md`). Secrets (SFDX auth URLs, JWT keys, WooCommerce keys) are never committed — see `.gitignore` + `scripts/ci/secret-scan.sh`.

## License
MIT — see [LICENSE](LICENSE). Reference build; not affiliated with or endorsed by Salesforce.
