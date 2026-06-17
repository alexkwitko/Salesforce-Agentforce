# RLM Data Model Reference (by module)

Verbatim API object names from the Revenue Cloud Developer Guide + Data Model Gallery. **There is no `Subscription` object** — recurring entitlement = `Asset` + `AssetStatePeriod` + `AssetAction` + subscription `ProductSellingModel`.

## Product Catalog Management (PCM)
`Product2`, `ProductCatalog`, `ProductCategory`, `ProductCategoryProduct`, `ProductClassification`, `ProductClassificationAttr`, `ProductRelatedComponent` (bundle children), `ProductRelatedComponentOverride`, `ProductComponentGroup`, `ProductComponentGroupOverride`, `ProductRelationshipType`, **`ProductSellingModel`** (one-time / term-defined / evergreen / usage), `ProductSellingModelOption`, `ProductSpecificationType`, `ProductSpecificationRecType`, `ProductRampSegment`, `ProductQualification`/`ProductDisqualification`, `ProductCategoryQualification`/`ProductCategoryDisqualification`, `AttributeDefinition`, `AttributeCategory`, `AttributeCategoryAttribute`, `AttributePicklist`, `AttributePicklistValue`, `ProductAttributeDefinition`, `ProductAttribute`, `ProductAttributeSet`. (`Product2.UsageModelType` flags a usage product.)

Bundles: a parent `Product2` + child `ProductRelatedComponent` rows (up to ~5 levels), grouped by `ProductComponentGroup`.

## Salesforce Pricing
`Pricebook2`, `PricebookEntry` (`UnitPrice` = list price), `PricebookEntryDerivedPricing`, `PriceAdjustmentSchedule`, `PriceAdjustmentTier`, `AttributeBasedAdjustment`/`AttributeBasedAdjRule`/`AttributeAdjustmentCondition`, `BundleBasedAdjustment`, `Costbook`/`CostbookEntry`, **`ExpressionSet`** (pricing procedures, on Context Service — *not* a "PricingProcedure" object), `PriceRevisionPolicy`, `IndexRate`. **Pricing procedures are the gated piece**: if Salesforce Pricing isn't provisioned, `ExpressionSet` is `INVALID_TYPE`. Headless Subscription Management prices off `PricebookEntry` + `PriceAdjustmentSchedule` directly.

## Transaction Management — Quote
`Quote`, `QuoteLineItem`, `QuoteLineDetail` (line breakdown), **`QuoteAction`** (the sales-transaction type: New / Renewal / Amendment / Cancellation; v59+), `QuoteLineRelationship`, `QuoteLineGroup`, `QuoteLineAttribute`, `QuoteLinePriceAdjustment`, `QuoteLineRateAdjustment`, `QuoteLineRateCardEntry`, `QuoteItemTaxItem`, `QuoteDocument` (v61+). (Standard Quote gated by `QuoteSettings.enableQuote`.)

## Transaction Management — Order
`Order`, `OrderItem`, **`OrderAction`**, `OrderItemRelationship` (v58+), `OrderItemDetail`, `OrderItemGroup`, `OrderItemType`, `OrderItemAttribute`, `OrderItemAdjustmentLineItem`, `OrderItemRateAdjustment`, `OrderItemRateCardEntry`, `OrderItemTaxLineItem`, `OrderDeliveryGroup`/`OrderDeliveryMethod`. Abstraction: `SalesTransactionType`.

## Asset Lifecycle Management ⭐ (the RLM differentiator)
- **`Asset`** — what the customer owns (the "subscription"). `Asset.LifecycleStartDate`/`LifecycleEndDate`, `Quantity`, `MRR`/`TotalLifecycleAmount`, `Status`.
- **`AssetStatePeriod`** — a **time slice** where quantity/amount/MRR is constant. Each amend/renew creates a **new** period; the timeline of an asset = a chain of state periods.
- **`AssetAction`** (v50+) — a change event on a lifecycle-managed asset. Categories: **New, Amend (upsell/downsell), Renew, Cancel**.
- **`AssetActionSource`** — what *caused* the change (links to the `OrderItem` / Work Order Line Item / external transaction id that drove it).
- Also: `AssetStatePeriodAttribute`, `AssetRelationship`, `AssetRateAdjustment`, `AssetRateCardEntry`, `FulfillmentAsset`.

**Lifecycle mechanics (memorize):**
| Action | Effect |
|---|---|
| **Amend** (add seats / upgrade) | new `AssetStatePeriod` with changed qty/amount; `AssetAction` category Amend; quote line **positive/negative delta** quantity |
| **Renew** | new `AssetStatePeriod` extending the term; `AssetAction` Renew |
| **Cancel** | **ends** the current period (no new period); quote/order line uses **negative quantity**; `AssetAction` Cancel |

## Contract / CLM
`Contract`, `SalesContractLine`, `ContractType`/`ContractTypeConfig`, `Obligation`, document/CLM stack (`DocumentClause`, `DocumentClauseSet`, `DocumentTemplate`, `DocumentEnvelope`, `ContractDocumentVersion`, `ContractDocumentReview`), state machine (`ObjectStateDefinition`/`ObjectStateTransition`/`ObjectStateValue`).

## Billing & Invoicing
`BillingSchedule` (v55+), `BillingScheduleGroup`, `BsgRelationship`, `BillingPeriodItem`, `BillingPolicy`, `BillingTreatment`/`BillingTreatmentItem`, `Invoice`, `InvoiceLine` (v62+), `InvoiceLineRelationship`, `InvoiceLineTax`, `CreditMemo`, `BillingAccount`/`AccountBillingAccount`, `PaymentSchedule`, `PaymentTerm`, `ProrationPolicy`, `TaxTreatment`, `LegalEntity`, `LegalEntityAccountingPeriod`, `InvoiceBatchRun`. Gated by the Billing module — `INVALID_TYPE` if off.

## Usage / Rating
`Product2.UsageModelType`, `UsageResource`, `RateCard`/`RateCardEntry` (per-unit / per-package), `PriceBookRateCard`, usage policies, `TransactionJournal`. (Usage is NOT a `ProductSellingModel` type.) GA Spring '25.

## Dynamic Revenue Orchestrator (DRO)
`FulfillmentOrder`/`FulfillmentOrderLineItem`, `FulfillmentAsset`, `FulfillmentPlan`, `FulfillmentStep`/`FulfillmentStepDependency`/`FulfillmentStepOrchestration`, `FulfillmentTransaction`/`FulfillmentTransactionItem`, design-time `RuleSet`/`IntegrationDefinition`/`OmniProcess`, `RevenueTransactionErrorLog`.

## Sources
- Data Model Gallery — Revenue Management: https://developer.salesforce.com/docs/platform/data-models/guide/revenue-cloud-category.html (+ per-module pages: product-catalog-mgmt, salesforce-pricing, transaction-management-quote/order/asset, salesforce-contracts, billing-invoice, usage-management, dro-fulfillment)
- AssetStatePeriod / AssetAction object refs under `.../revenue_lifecycle_management_dev_guide/sforce_api_objects_*.htm`
- ProductSellingModel: https://developer.salesforce.com/docs/atlas.en-us.object_reference.meta/object_reference/sforce_api_objects_productsellingmodel.htm
