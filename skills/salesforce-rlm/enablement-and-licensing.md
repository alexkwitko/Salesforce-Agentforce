# RLM Enablement & Licensing

> Naming: in-product/Setup the feature is **Revenue Lifecycle Management** (newest help docs: **Agentforce Revenue Management**); the brand is **Revenue Cloud**. Object/API names below are verbatim from the Revenue Cloud Developer Guide + Data Model Gallery. Exact PSL **API** strings vary by org/release — confirm in-org with the queries below before encoding them anywhere.

## STEP 1 — Setup enablement (some is genuinely UI-only)
RLM enablement is **distributed**, not one switch:
1. **Revenue Settings** (Setup → quick-find *Revenue Settings*): verify **Enable Revenue Cloud Features** is on, and turn on **Create Application Usage Type for Revenue Cloud** (application tagging is required). *(Setup-UI / Salesforce-provisioned.)*
2. **Context Service** (a.k.a. Expression Set Runtime / ESR): RLM pricing, billing-schedule generation, and the configurator run on Context Service. *(Setup step.)*
3. Per-module enablement: **Transaction Management (Quote and Order Capture)**, **Salesforce Pricing**, **Product Catalog Management**, **Billing**, **Dynamic Revenue Orchestrator** each have their own enablement step.
4. **Standard Quote object** — separately gated by `QuoteSettings.enableQuote`. **DX-deployable** (see SKILL.md fast-path). Often `INVALID_TYPE` until you deploy it.

`RevenueManagementSettings` exists as a settings metadata type, but initial feature **provisioning** is Setup + Salesforce-gated — it is *not* fully captured in source metadata. Budget a manual enablement pass per target org.

## Permission Set Licenses (PSLs)
Assign the PSL **before** the matching permission set. Module → PSL (display labels; confirm API names in-org):

| Module | PSL (label) |
|---|---|
| Subscription Management / overall RLM | **Subscription Management** (`Rev*` API name, e.g. `RevSubscriptionManagementPsl`) |
| Salesforce Pricing | **Salesforce Pricing** (Design Time + Run Time) — `CorePricingDesignTime`, `CorePricingRunTime` |
| Product Catalog Management | **Product Catalog Management** |
| Transaction Management | **Transaction Management** (Quote and Order Capture) |
| Product Configurator | **Product Configurator** |
| Rate / Usage Management | **Rate Management** |
| Billing | Billing PSL |

**PSL state semantics (critical):**
- `TotalLicenses > 0, Status = Active` → entitled; you can assign seats.
- `TotalLicenses = 0, Status = Disabled` → **NOT entitled.** No admin action (Setup toggle, metadata, CLI) can promote it — it's Salesforce-provisioned via the contract. Paid org → AE adds the SKU. Free Developer Edition → not available; spin up a Revenue-Cloud-enabled signup/trial org instead.

```bash
# What PSLs exist & their provisioning state
sf data query -o $ORG -q "SELECT MasterLabel, DeveloperName, TotalLicenses, UsedLicenses, Status FROM PermissionSetLicense ORDER BY MasterLabel"
# Assign a PSL to a user (DX)
sf data create record -o $ORG -s PermissionSetLicenseAssign -v "AssigneeId=<userId> PermissionSetLicenseId=<pslId>"
```

## Permission sets (assign after the PSL)
Two flavors (detect which the org has — it changes everything):

**A) Headless Subscription Management** (API-first, no UI):
`SubscriptionManagementSalesRep`, `SubscriptionManagementSalesOperationsRep`, `SubscriptionManagementProductAndPricingAdmin`, `SubscriptionManagementBillingAdmin`, `SubscriptionManagementBillingOperations`, `SubscriptionManagementBuyerIntegrationUser`, `SubscriptionManagementCollections`, `SubscriptionManagementPaymentAdministrator`, `SubscriptionManagementPaymentOperations`, `SubscriptionManagementCreditMemoAdjustmentsOperations`, `SubscriptionManagementTaxAdmin`.

**B) Revenue Cloud Advanced** (builder UIs):
`Quote and Order Capture Admin/Designer/User`, `Product Catalog Management Admin/Designer/Viewer`, `Pricing Admin/Designer` (Salesforce Pricing: `CorePricingAdmin`, `CorePricingManager`, `CorePricingDesignTimeUser`, `CorePricingRunTimeUser`), Billing permission sets, `Dynamic Revenue Orchestrator` (incl. *Fulfillment User*), `Rate Management`.

```bash
# Detect flavor + assign
sf data query -o $ORG -q "SELECT Name,Label FROM PermissionSet WHERE Name LIKE 'SubscriptionManagement%' OR Name LIKE '%Quote and Order Capture%' OR Name LIKE 'CorePricing%'"
sf org assign permset --name SubscriptionManagementSalesRep -o $ORG
```

## Recommended setup sequence
1. **Enable** — Revenue Settings (+ Application Usage Type), Context Service; assign PSLs + admin permission sets; deploy `QuoteSettings` if you need standard Quotes.
2. **Product Catalog** — attributes first (`AttributeDefinition`/`AttributePicklist`/`AttributeCategory`) → `ProductClassification` → `Product2` → `ProductSellingModel` → bundles (`ProductRelatedComponent`/`ProductComponentGroup`) → categories (`ProductCategory`/`ProductCategoryProduct`) → qualification/disqualification rules.
3. **Pricing** — `Pricebook2`/`PricebookEntry` → `PriceAdjustmentSchedule`/`PriceAdjustmentTier`, attribute-based adjustments → pricing procedures (`ExpressionSet`).
4. **Configurator** — constraint/qualification rules (Context Service).
5. **Transaction Management** — quoting (`Quote` + `QuoteAction`) → ordering (Create Order From Quote).
6. **Asset Lifecycle** — asset creation from order; `AssetStatePeriod`/`AssetAction`/`AssetActionSource`; configure the amend/renew/cancel **screen flow** (*Set Up Flow for Managing Assets* — UI).
7. **Contracts** — CLM + DocGen.
8. **Billing** — legal entity / accounting periods → billing policies/treatments → `BillingSchedule` → `Invoice`/`InvoiceLine`.
9. **(Optional) DRO** — order decomposition + fulfillment plans/steps.

Salesforce notes the order "can vary"; enablement errors are usually a missing prerequisite permission set.

## DX vs UI
- **Metadata-deployable**: settings (`QuoteSettings`, `RevenueManagementSettings`), the per-module metadata families (**Product Catalog Management Metadata**, **Salesforce Pricing Metadata**, **Product Configurator Metadata**, **Transaction Management Metadata**, **Billing Metadata**, **Usage Management Metadata**), `ExpressionSet`/`ExpressionSetDefinition` (order-sensitive). The **Revenue Cloud Deployment** guide gives per-module object deploy sequences + lookup dependencies — respect them or deploys fail on missing parents.
- **Data (records, via `sf data`/Bulk)**: `Product2`, `PricebookEntry`, `ProductSellingModel`, `ProductRelatedComponent`, `AttributeDefinition`, `PriceAdjustmentSchedule`, `Asset`, etc.
- **UI-only**: Enable Revenue Cloud Features (provisioning), Create Application Usage Type, Context Service enablement, the amend/renew/cancel screen-flow assignment.
