# RLM Use Cases & Agentforce Agent Patterns

## The engine-vs-AI split (internalize this first)
The RLM transaction engine — pricing, proration, renewals, amendments, billing schedules, the asset state-period timeline — is **deterministic and NOT AI**. Agentforce adds three things on top: (1) a **natural-language front door** ("add 5 seats", "what do I owe?", "renew me for another year"), (2) **reasoning/recommendation** (which upsell, which retention offer, dunning risk), and (3) **outreach orchestration** (proactive renewal/upsell emails). Design agents to *narrate and invoke* the engine, never to *compute* revenue themselves.

## Top use cases, ranked by prevalence
1. **CPQ for complex configurable bundles** — successor to End-of-Sale CPQ; the use case the largest install base is migrating into. `Product2`+bundles+Configurator→`Quote`.
2. **Subscription / recurring-revenue management** — the canonical RLM buyer (SaaS). `ProductSellingModel`(term/evergreen)→Order→**Asset/AssetStatePeriod**→Contract→Billing.
3. **Renewals & amendments** (upgrade/downgrade/co-term/cancel) — the strongest **RLM-specific** mechanic and the prime re-pricing moment. Asset-driven; every change is a Quote→Order.
4. **Billing, invoicing & collections** — completes quote-to-cash; subscription businesses leak ~3–9% of revenue here. (Native dispute mgmt Spring '26; Collections-with-Agentforce Summer '26.)
5. **Usage / consumption billing** — `UsageResource`+`RateCard`; monetize metered/pay-per-use. GA Spring '25.
6. **Contract Lifecycle Management** — clause library, obligations, e-sign; the differentiator legacy CPQ lacked.
7. **Order management & fulfillment (DRO)** — decompose complex orders into fulfillment plans.
8. **Self-service / digital commerce quoting (headless)** — Place Quote APIs power portals/PLG; **no customer UI ships natively** → Experience Cloud + LWC, or an **Agentforce front door**.
9. **Revenue recognition / compliance** — ASC 606 / IFRS 15 via Billing.
10. **Cross-sell / upsell on the install base** — whitespace vs current `Asset`s; renewals double as the upsell moment.

## By industry (which engine)
- **SaaS / tech, manufacturing, medtech** → **core RLM/RCA** (± a non-CPQ industry overlay like Manufacturing Cloud Sales Agreements). RLM's flagship fit.
- **Telecom, media, energy & utilities** → **Industries CPQ + EPC** on OmniStudio (catalog/standards complexity RLM's PCM can't yet match; TM Forum SID/Open APIs in telco). NOT core RLM.
- **Financial services / insurance** → split: policy **rating = OmniStudio** (not CPQ); the institution's own fee/subscription monetization = core RLM.

## Where AI adds value — agent patterns (trigger → reads → acts)
| Agent capability | Trigger | Reads | Acts | Maturity |
|---|---|---|---|---|
| **Assisted quoting** | rep/customer NL: "quote 25 licenses, 10% off" | catalog, selling models, pricing, Account, existing Assets | Place Quote → add lines (`Add Quote Line Item`) → `Apply Discount` (guard-railed) | native (Summer '25) |
| **Quote → Order** | quote accepted | Quote + lines | `Create Order From Quote` → activate | native |
| **Automated renewals** | subscription nears expiry / "renew" | `Asset`, `AssetStatePeriod`, `Contract` | `Initiate Renewal` → new state period; + proactive outreach | engine native; outreach = custom |
| **Self-service subscription changes** | "add 5 seats" / "downgrade" / "cancel" | `Asset`, selling model, pricing | Place Supplemental Transaction (amend +qty / cancel −qty) | engine native; agent front door = custom |
| **Upsell/cross-sell on install base** | existing-customer touch / scheduled | current `Asset`s vs catalog whitespace | recommend + draft outreach / open opp | custom (+ Data Cloud for intelligence) |
| **Billing / invoice questions** | "what do I owe / why this charge?" | `Invoice`, `BillingSchedule`, `CreditMemo` | preview invoice, suspend/resume, adjust | growing native |
| **Collections / dunning** | aging invoices | `Invoice`, payment history | score risk, recommend dunning plan | native (Summer '26) |
| **Churn-risk retention** | Data Cloud churn score rises | unified profile, purchase/support history | retention offer + case + AM alert | custom (Data Cloud) |

## Recommended highest-value FIRST build
**The Subscription Asset Lifecycle — provision → amend → renew → cancel — fronted by an Agentforce agent.**

Why this one:
1. It's the **RLM-specific differentiator** (amend/renew/cancel against a live `Asset` with state-period time-slicing and negative-quantity cancellation) — the "wow" spreadsheets and legacy CPQ can't show.
2. It's the **#2 + #3 most-common** use cases (subscription + renewals/amendments) — what real SaaS buyers adopt.
3. **No advanced Pricing engine required** — pure lifecycle mechanics + list price from `PricebookEntry`. Discounts can be manual overrides. (Critical when the Salesforce Pricing PSL is Disabled.)
4. **Demoable end-to-end with no external systems** (no payment gateway / ERP / Data Cloud needed for the core flow).
5. Pairs perfectly with the **AI front door**: one agent drives "set me up with N seats", "add seats", "renew", "cancel" — showing engine + NL interface in one build.

**Build sequence:** a few `Product2`s with subscription `ProductSellingModel`s + list prices → provision an `Asset` (+ first `AssetStatePeriod`) → demo **amend** (new period, +qty), **renew** (new period, extended term), **cancel** (period ends, −qty) → wrap each as an `@InvocableMethod` agent action → author the agent (Quote/Subscription topic) → multi-turn certify.

**Defer to phase 2** (need advanced Pricing / Billing SKU / Data Cloud): tiered/attribute discounting & rate cards, usage rating, invoice generation & collections, CLM, churn-retention.

## Two facts to state carefully
- Legacy **CPQ "EOL 2029–2030" is unofficial** — only the **~March 2025 End-of-Sale** is confirmed by Salesforce.
- The widely-quoted **"75% quoting-time reduction"** is Salesforce's own internal-team figure, not an independent customer benchmark.

## Building the RLM AI layer when the transaction engine is GATED (headless org) — proven patterns
In a **headless Subscription Management** org (or any org where Place Quote / Salesforce Pricing isn't provisioned), there are **no RCA builder / transaction-line-editor / configurator / pricing screens** and the Place Quote API returns `FUNCTIONALITY_NOT_ENABLED [PlaceQuoteApplication]`. **The agents + standard objects ARE the product surface.** Build the AI layer on standard objects + CRM:

1. **AI quoting on the STANDARD `Quote` object** (the "Agentforce quoting" experience without the engine): one `@InvocableMethod` (`DraftQuoteAction`) creates `Quote` + `QuoteLineItem` from NL. Gotchas: **`Quote` requires `OpportunityId`** → find-or-create an open Opportunity; `QuoteLineItem` requires `QuoteId`+`PricebookEntryId`+`Product2Id`+`Quantity` (+`UnitPrice`; `Discount` is a **percent** on the line); set `Quote.Pricebook2Id` = the `IsStandard=true` pricebook; read `QuoteNumber`/`GrandTotal` after insert. Resolve the product by `ProductCode` OR fuzzy `Name LIKE`. ⚠️ **`like` is a reserved Apex word** — name the bind var `pattern`.
2. **Asset-direct subscription lifecycle** (`AssetStatePeriod`/`AssetAction` are engine-only — **0 createable fields** — so when gated, model recurring state on the basic CRM `Asset`: `Quantity`/`Price`/`Status`[Installed→Obsolete]/`UsageEndDate`). Five thin `@InvocableMethod` actions (one class each — only ONE invocable per class): get / provision / amend(qty) / renew(extend UsageEndDate) / cancel(Status=Obsolete).
3. **Native lifecycle Quick Action** (clickable UI without RCA): a screen `Flow` (radio choice → routes to SubRenew/SubAmend/SubCancel apex actions) + a `QuickAction` (type Flow) on the Asset page. **Flow-XML gotchas:** top-level elements must be in **schema order** and same-type elements **contiguous** (all `<screens>` together) or `Element X is duplicated`; an apex `actionCalls` returning `List<>` needs `<storeOutputAutomatically>true</storeOutputAutomatically>` to reference `{!Action.field}`; in the layout, `<platformActionList>` must sit **before `<relatedLists>`**, and a quick-action ref needs the **object prefix** (`Asset.Manage_Subscription`).
4. **REAL-TIME insights, NOT a cron** — agents must read live data. Recompute on the **Asset trigger** (`after insert,update,delete,undelete` → `recomputeForAccounts(acctIds)`, synchronous). Keep a nightly `Schedulable` only as a reconcile safety-net. (A daily batch = stale agent reads.)
5. **Unified-profile awareness via CRM write-back** (Data Cloud CI/DMO creation is UI-gated/Gacks): aggregate in Apex → write to `Account.Insights_*__c` fields. ⚠️ **Key finding:** in a Salesforce-CRM-connector Data Cloud org, the Account **DMO data stream may not carry custom insight fields at all** (churn included) — the agents read insights from the **CRM `Account` fields directly** (often labeled `dataCloud*`), not the DMO. So **CRM write-back IS the agent connection**; the literal DMO field-mapping is only for Data-Cloud-native **segmentation** and is **genuinely UI-only** (`DataStreamDefinition` metadata is a pointer — `dataConnector`/`mktDataLakeObject`/`mktDataTranObject`, **no editable field list**; don't risk a Connect-API PATCH on the live profile-feeding stream). Editing the CRM stream's source-field selection needs Data Cloud admin (`CDPAdmin`) + the UI.
6. **MRR caveat:** a directly-created `Asset` doesn't record the selling-model **term**, so term-normalized MRR isn't computable — use un-normalized recurring value (`Qty × Price`) unless the term is stored (the Place Quote engine sets it).

## Sources
- Trailhead (best primary): *Revenue Lifecycle Management Foundations*; *Asset Lifecycle Management with Revenue Cloud* (amend/renew/cancel); *Agentforce Revenue Management Quick Look*; *Quick Start: Build an Agent to Create Quotes Fast*.
- Salesforce: revenue-lifecycle-management product pages; `ind.qocal_manage_assets_in_revenue_lifecycle_management`; Summer '26 Agentforce Revenue Management release notes.
- Ecosystem: salesforceben.com (Revenue Cloud guide; "future of CPQ"), stratuscarta.com RLM series, cloudmasonry.com RLM use cases.
