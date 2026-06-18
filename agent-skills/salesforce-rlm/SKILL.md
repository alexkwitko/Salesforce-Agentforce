---
name: salesforce-rlm
description: Use when building, deploying, or troubleshooting ANY Salesforce Revenue Cloud / Revenue Lifecycle Management (RLM) solution — also branded Subscription Management, Revenue Cloud Advanced (RCA), and Agentforce Revenue Management (ARM). Covers the whole quote-to-cash lifecycle on the CORE platform (not the legacy CPQ/Billing managed packages): Product Catalog Management (Product2, ProductSellingModel, bundles, attributes), Salesforce Pricing (pricing procedures = ExpressionSet), Product Configurator, Transaction Management (Quote/Order capture + the Place Quote / Place Order / Place Sales Transaction Connect APIs), Asset Lifecycle Management (Asset + AssetStatePeriod + AssetAction — the amend/renew/cancel differentiator), Contracts/CLM, Billing & Invoicing, Usage/Rating, and Dynamic Revenue Orchestrator (DRO). Also covers how RLM goes hand-in-hand with **Field Service Maintenance Plans** and the shared **Asset** install base (Asset created/time-sliced by RLM, consumed by Field Service; selling maintenance AS a subscription via the ServiceContract/Entitlement bridge; the quote→cash→service→renew flow). Includes enablement + permission-set licensing, the Subscription-Management-vs-RCA fork, DX/CLI-vs-UI line, the headless API surface for Agentforce agents (quoting / renewals / upsell / self-service subscription changes / billing-question agents), and hard-won gotchas (incl. the PlaceQuoteApplication gate that can be un-provisionable in a Developer org). DX-first (sf CLI / metadata) with exact object/API names. Product-agnostic; reusable for any RLM build.
---

# Salesforce Revenue Lifecycle Management (RLM) — Implementation & Agent Playbook

Practical, **DX-first** playbook for standing up Salesforce's native quote-to-cash suite end to end, and for putting an **Agentforce AI agent** in front of it. The mechanics are general; substitute your own products/selling models. Follow the DX-first order; only fall to the UI when there is genuinely no API/metadata/CLI path.

## The #0 rule: official-first, never Frankenstein
RLM is a huge, *native* product family. Before hand-rolling a custom object + Apex to model a quote, a subscription, a renewal, or an invoice — **there is already a standard object and a supported API for it.** A custom "Subscription__c" + Apex renewal engine is a Frankenstein: it demos fine, then drifts from the platform, duplicates the Asset lifecycle, and becomes permanent tech debt. Use the standard objects and the Connect APIs. The only legitimate custom Apex is a **thin `@InvocableMethod` wrapper** that calls an RLM Connect API so an Agentforce action / Flow can invoke it.

## The naming reality (read this FIRST — it controls everything)
The product has been renamed ~5 times. These are **the same core-platform product line** at different dates:

> SteelBrick CPQ (2015) → Salesforce CPQ (2016) → Salesforce Billing (2016) → **Revenue Cloud** (2020) → **Subscription Management** (2022–23, the *headless* precursor) → **Revenue Lifecycle Management / RLM** (Spring '24) → **Revenue Cloud Advanced (RCA) + Revenue Cloud Billing** (Dreamforce '24) → **Agentforce Revenue Management (ARM)** (Dreamforce '25).

Two things that are **NOT** this product line and must not be confused with it:
- **Legacy Salesforce CPQ + Salesforce Billing** = the old *managed packages* (SteelBrick heritage, `SBQQ__`/`blng__` namespaces). **End-of-Sale ~March 2025** (no new sales; existing customers keep support). Migration CPQ→RLM is a **re-implementation, not a data migration**. A `Salesforce CPQ License` PSL in an org is the *legacy* package, separate from RLM.
- **Industries CPQ + Enterprise Product Catalog (EPC)** on OmniStudio (Vlocity heritage) — the catalog/CPQ used inside Communications, Media, Energy & Utilities clouds. Telco/media/utility orgs ride EPC, **not** core RLM. SaaS/manufacturing/medtech ride core RLM. Financial-services insurance rating is OmniStudio, not RLM. (See `use-cases-and-agent-patterns.md`.)

When you research docs: index all of "Revenue Cloud", "Revenue Lifecycle Management", "Subscription Management", "Revenue Cloud Advanced", "Agentforce Revenue Management" — they point at overlapping doc sets.

## The two flavors you'll actually meet in an org
The single most important thing to determine before designing: **which RLM flavor is provisioned.**

| | **Subscription Management** (headless) | **Revenue Cloud Advanced (RCA)** |
|---|---|---|
| Era | 2022–23 precursor, still live in many orgs | Current GA |
| Permission sets | `SubscriptionManagementSalesRep`, `SubscriptionManagementProductAndPricingAdmin`, `SubscriptionManagementBillingAdmin`, … | `Quote and Order Capture Admin/Designer/User`, `Product Catalog Management Admin/Designer/Viewer`, `Pricing Admin/Designer` |
| UI | **None** — API-first / headless by design | Builder UIs (catalog, pricing, configurator, transaction line editor) |
| Pricing | PricebookEntry + Price Adjustment Schedules; Place Quote `pricingPreference` | Salesforce Pricing engine = **pricing procedures (`ExpressionSet`)**, required even for list price |
| Consumption | Place Quote / Place Order Connect APIs | Same APIs + the builder UIs |

**Detect it:** `SELECT Name FROM PermissionSet WHERE Name LIKE 'SubscriptionManagement%'` vs `... LIKE '%Quote and Order Capture%'`. A `SubscriptionManagement*` permission-set set = the **headless** flavor — which is *ideal* for an Agentforce agent, because the agent IS the front door to an API-first product.

## What's in this skill
- **`enablement-and-licensing.md`** — ⭐ STEP 1. Revenue Settings enablement, the per-module Permission Set Licenses (PSLs) + permission sets, Context Service, the Subscription-Mgmt-vs-RCA fork detection, and exactly what is DX-deployable vs Setup-UI-only.
- **`data-model-reference.md`** — ⭐ the full object model by module (Catalog / Pricing / Quote / Order / **Asset Lifecycle** / Contract / Billing / Usage / DRO), with verbatim API object names and the key relationships (AssetStatePeriod time-slicing, AssetAction categories, negative-quantity cancellation).
- **`apis-and-actions.md`** — ⭐ the headless API surface: Place Quote / Place Order / Place Sales Transaction / Place Supplemental Transaction / Configurator Connect REST endpoints, the async submit→poll→fetch pattern, the invocable Flow actions (Place Sales Transaction, Submit Sales Transaction, Create Order From Quote, Initiate Renewal/Renew Assets), the `PlaceQuoteRLMApexProcessor` extension point, and how to wrap them as Agentforce actions.
- **`use-cases-and-agent-patterns.md`** — ⭐ the ranked business use cases, the engine-vs-AI split, the per-agent design patterns, the recommended first build, AND the **engine-gated (headless org) playbook** (battle-tested): AI quoting on the **standard `Quote`** object when Place Quote is gated, Asset-direct lifecycle, a native lifecycle **Quick Action** (screen-flow XML gotchas), **real-time insights via the Asset trigger (not a cron)**, and **unified-profile awareness via Apex→`Account.Insights_*` write-back** — incl. the finding that the Account **DMO doesn't carry CRM insight fields** (agents read CRM Account directly; the DMO mapping is UI-only and only for segmentation).
- **`rlm-fieldservice-asset-integration.md`** — ⭐ how RLM, **Field Service Maintenance Plans**, and the **`Asset`** install base go hand-in-hand: Asset as the shared backbone (RLM creates/time-slices it, FSL consumes it), Maintenance Plans → recurring Work Orders, selling maintenance AS a subscription via the `ServiceContract`/`Entitlement` bridge, the end-to-end quote→cash→service→renew flow table, and the **custom** renewal-coupling you must build. Pairs with the `salesforce-field-service` skill.

This skill is the RLM domain layer. For **how to author/deploy/test the Agentforce agent itself** (Agent Script bundles, custom Apex actions, headless invocation, multi-turn certification), pair it with the **`salesforce-agentforce`** skill.

## The #1 rule: DX/CLI/API first, UI last
1. **`sf` CLI** — `sf project deploy/retrieve`, `sf data`, `sf apex run`, `sf agent`.
2. **Connect/REST via CLI** — `sf api request rest "/services/data/vXX.0/commerce/..."` (reuses the stored session even when the token is redacted).
3. **Metadata XML deploy** — settings (`QuoteSettings`, `RevenueManagementSettings`), pricing/configurator `ExpressionSet`, page layouts.
4. **Data loads** — catalog rows (`Product2`, `PricebookEntry`, `ProductSellingModel`, `ProductRelatedComponent`, `AttributeDefinition`) move as **records** (`sf data` / Bulk), not metadata source.
5. **UI** — last resort: the master *Enable Revenue Cloud Features* provisioning, *Create Application Usage Type*, *Context Service* enablement, and the amend/renew/cancel **screen-flow** assignment are genuinely Setup-driven.

## Fast-path: detect what's live in an org
```bash
ORG=<alias>
# Which flavor + which modules are provisioned?
sf data query --target-org $ORG -q "SELECT Name FROM PermissionSet WHERE Name LIKE 'SubscriptionManagement%' OR Name LIKE '%Quote and Order Capture%' OR Name LIKE 'CorePricing%'"
# PSL provisioning (TotalLicenses=0 + Status=Disabled = NOT entitled, admin canNOT enable — Salesforce-controlled)
sf data query --target-org $ORG -q "SELECT MasterLabel,TotalLicenses,Status FROM PermissionSetLicense WHERE DeveloperName LIKE 'Rev%' OR DeveloperName LIKE 'CorePricing%'"
# Probe object accessibility (INVALID_TYPE = feature not enabled or object absent)
for OBJ in ProductSellingModel Quote Order Asset AssetStatePeriod AssetAction ExpressionSet BillingSchedule Invoice; do
  echo -n "$OBJ: "; sf data query --target-org $ORG -q "SELECT COUNT() FROM $OBJ" --json 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print('OK '+str(d['result']['totalSize']) if d.get('status')==0 else 'OFF')"
done
```

## Fast-path: enable the standard Quote object (DX)
The standard Quote object is **off by default** in many orgs (`INVALID_TYPE` on `SELECT … FROM Quote`). It's a one-line metadata deploy:
```xml
<!-- force-app/main/default/settings/Quote.settings-meta.xml -->
<QuoteSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <enableQuote>true</enableQuote>
</QuoteSettings>
```
```bash
sf project deploy start --metadata Settings:Quote --target-org $ORG
```

## ⚠️ Top gotchas (hard-won)
1. **Pricing-engine dependency (RCA).** In Revenue Cloud Advanced, *even list price* is resolved by a **pricing procedure (`ExpressionSet`)** run by the Salesforce Pricing engine. The Place Quote/Place Sales Transaction pipeline **requires a default pricing procedure to be set**. If the `Salesforce Pricing Run Time`/`Design Time` PSL is **Disabled with 0 seats**, `ExpressionSet` is `INVALID_TYPE`, advanced pricing is unavailable, and you cannot self-enable it (it's Salesforce-provisioned, not an admin toggle). **Headless Subscription Management** orgs price off `PricebookEntry` + Price Adjustment Schedules and a Place Quote `pricingPreference` instead — verify the actual pricing path with a live Place Quote call before promising discount math.
2. **There is no `Subscription` object.** Recurring entitlement = `Asset` + `AssetStatePeriod` (time-sliced quantity/MRR) + `AssetAction` + `ProductSellingModel` (subscription/term/evergreen). Don't invent one.
3. **Amend / Renew / Cancel are deterministic engine mechanics, NOT AI.** Amend & Renew create a **new** `AssetStatePeriod`; **Cancel** ends the period via a **negative-quantity** quote/order line and does NOT create a new period. The AI's job is the natural-language front door + outreach orchestration on top.
4. **Many RLM Connect APIs are ASYNC** — submit returns a `requestId`; you poll a status resource, then fetch the result. Build agent actions to handle the poll, not assume a synchronous body.
5. **Deploy order matters.** Attributes/classifications → products → bundles → pricing. `ExpressionSet` (pricing/configurator) is order-sensitive; out-of-order deploys fail on missing parents. Catalog rows are *data*, not metadata.
6. **PSL Disabled+0 ≠ enableable.** A `PermissionSetLicense` with `TotalLicenses=0, Status=Disabled` is an entitlement Salesforce never provisioned; no Setup toggle, metadata, or CLI promotes it. Paid orgs add the SKU via their AE; free Developer orgs simply lack it.
7. **Enablement isn't fully in source metadata.** Plan a manual Setup enablement pass (Enable Revenue Cloud Features, Application Usage Type, Context Service) per target org before deploying config.
8. **The headless Place Quote/Order API has a separate `PlaceQuoteApplication` gate that may be un-provisionable in a Developer Edition org (verified).** Real case: deployed `SubscriptionManagementSettings.enableSubscriptionManagement=true` (surfaced the `Quote` object + selling models), assigned the `RevSubscriptionManagementPsl` PSL + `SubscriptionManagement*` permission sets, and confirmed in **Setup → Subscription Management → General Settings** that **"Access Subscription Management Features" = Active** — yet `POST /commerce/quotes/actions/place` still returns `FUNCTIONALITY_NOT_ENABLED: [PlaceQuoteApplication]`. There is **no further self-service toggle** (Quick Find "Revenue" returns nothing; only "Subscription Management" exists), and `ExpressionSet` (Salesforce Pricing) is also un-provisionable (PSL Disabled+0). Conclusion: the headless transaction engine needs **Salesforce-side provisioning** in a DE org. **Workaround that ships today:** model the subscription on the standard **`Asset`** object directly (createable: `Quantity`/`Price`/`Status`/`InstallDate`/`UsageEndDate`) — note `AssetStatePeriod`/`AssetAction` are **engine-only (0 createable fields)**, so you keep current state on the `Asset` itself. Agent actions wrap `Asset` DML now; when the engine is provisioned, swap the DML for a Place Quote callout with **identical action signatures** (agent unchanged), gaining engine-managed state-period time-slicing.

See the supporting files for the detailed object model, API bodies, and agent design patterns.
