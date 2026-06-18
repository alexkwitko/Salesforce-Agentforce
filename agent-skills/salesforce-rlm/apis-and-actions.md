# RLM Headless API Surface (for Agentforce agents & integrations)

The whole point of the **headless** RLM (Subscription Management) is that quote-to-cash is driven by **Connect REST APIs** — which is exactly what an Agentforce action (a thin Apex `@InvocableMethod` wrapper) or a Flow calls. Verify exact paths/bodies for your API version against the doc before coding; many are **asynchronous**.

## Connect REST — Transaction Management Business APIs
Base: `/services/data/vXX.0/...` (use `sf api request rest`, which reuses the CLI session).

| Action | Method | Resource |
|---|---|---|
| **Place Quote** | POST | `/commerce/quotes/actions/place` |
| **Place Order** | POST | `/commerce/sales-transactions/actions/place` |
| **Place Sales Transaction** | POST | `/commerce/sales-transactions/actions/place` — create order/quote with integrated pricing, config, validation, est. tax; supports line insert/update/delete |
| **Place Supplemental Transaction** | POST | `/commerce/sales-transactions/actions/placeSupplemental` — amendment/supplemental against existing |
| **Configurator – Configure** | POST | `/commerce/configurator/configurations` |
| **Billing Business APIs** | POST | generate invoices / credit memos / recover billing schedules (`ConnectApi.Billing`) |

Input shapes: **Place Quote Input**, **Place Order Input**, **Sales Transaction Input** (graph of header + line items + selling model + pricing preference).

### Async pattern (don't assume sync)
Many Place * calls are **asynchronous**: submit → response carries a **`requestId`** (or job id) → **poll** the status resource → **fetch** the resulting Quote/Order id. An agent action must:
1. POST the transaction, capture `requestId`.
2. Poll status (bounded ret/timeout) until `Completed`/`Failed`.
3. On success, return the created `Quote`/`Order` id (+ totals) to the agent; on failure, surface the validation messages.
A `pricingPreference` (e.g. `System` / `SystemSpecifiedPricing` / `Skip`) on the input controls whether the call invokes the pricing engine — relevant when the **Salesforce Pricing engine is unavailable** (use list-price/`PricebookEntry`-based pricing).

```bash
# Example: Place Quote (shape illustrative — confirm fields for your API version)
sf api request rest "/services/data/v62.0/commerce/quotes/actions/place" --method POST -o $ORG --body '{
  "pricingPreference": "System",
  "graph": { "graphId": "1",
    "records": [
      { "referenceId": "refQuote", "record": { "attributes": {"type":"Quote"}, "Pricebook2Id": "<pbId>", "AccountId": "<acctId>" } },
      { "referenceId": "refLine",  "record": { "attributes": {"type":"QuoteLineItem"}, "Product2Id": "<prodId>", "ProductSellingModelId": "<psmId>", "Quantity": 10 } }
    ] } }'
```

## Invocable (Flow / Agent) actions Salesforce ships
These are directly usable as **Agentforce agent actions** (via Flow) — no custom Apex needed for the happy path:
- **Place Sales Transaction** — `ind.qocal_invoke_place_sales_transaction_in_a_flow` (create order/quote in a Flow).
- **Submit Sales Transaction** — initiates fulfillment of a quote / order / order summary.
- **Create Order From Quote** — Order from a Quote record.
- **Initiate Renewal** (a.k.a. **Renew Assets**) — initiates/executes asset renewal.
- **Amend / Renew / Cancel assets** — delivered as a configurable **screen flow** (*Set Up Flow for Managing Assets*), backed by `AssetAction`/`AssetStatePeriod`.

## Apex
- **`PlaceQuoteRLMApexProcessor`** — extension point to customize the Place Quote pipeline.
- **Transaction Management Apex Reference** (`qoc_apex_reference`) and **Billing Apex Reference** (`ConnectApi.Billing` static methods).
- For an agent: wrap a Connect API in a thin `@InvocableMethod` returning a flat result the agent can narrate. Keep callouts-before-DML, fail-closed on the external/engine dependency, and return the created record id + a human summary.

## Agentforce-native building blocks
- **Agentforce Revenue Management** ships standard quoting actions (Summer '25): a **"Quote Management"** topic + OOTB flows incl. **Add Quote Line Item** and **Apply Discount to Quote Line Item** (help: `ai.agent_ref_rev_cloud_add_quotelineitems_to_quote`). Admin config = clone the flows → register as actions → add to a topic → assign perm set.
- **Collections with Agentforce** (Summer '26): scores invoices by payment likelihood, recommends dunning.
- Where no native action exists, the path is a **custom `@InvocableMethod` wrapper** around the Connect API (above), surfaced as an agent action. See `salesforce-agentforce` skill for authoring/registering actions and multi-turn certification.

## Reading the install base (what the agent needs to "know what you own")
```sql
-- Active assets (subscriptions) for an account, with current state period
SELECT Id, Name, Product2.Name, Quantity, Status, LifecycleStartDate, LifecycleEndDate,
       (SELECT Id, StartDate, EndDate, Quantity, Amount, MRR FROM AssetStatePeriods ORDER BY StartDate DESC)
FROM Asset WHERE AccountId = :acctId AND Status = 'Active'
-- Lifecycle history
SELECT Id, Category, ActionDate, Asset.Name FROM AssetAction WHERE Asset.AccountId = :acctId ORDER BY ActionDate DESC
```

## Sources
- Transaction Management Business APIs: `.../revenue_lifecycle_management_dev_guide/qoc_business_apis.htm`
- Place Quote / Place Order / Place Sales Transaction / Place Supplemental / Configurator Configure: `.../connect_resources_place_quote.htm`, `..._place_order.htm`, `..._place_sales_transaction.htm`, `..._place_supplemental_transaction.htm`, `..._product_configurator_configure.htm`
- Invocable actions: `.../actions_obj_submit_sales_transaction.htm`, `..._create_order_from_quote.htm`, `..._renew_assets.htm`; `ind.qocal_invoke_place_sales_transaction_in_a_flow`
- Apex: `.../apex_class_placequote_PlaceQuoteRLMApexProcessor.htm`, `.../qoc_apex_reference.htm`
- Agent quoting actions: https://help.salesforce.com/s/articleView?id=ai.agent_ref_rev_cloud_add_quotelineitems_to_quote.htm
