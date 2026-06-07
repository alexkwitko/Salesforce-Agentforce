# Agentforce, WooCommerce, Salesforce, and Data Cloud Audit

Date: 2026-06-07
Org used: `AgentforceDev`
Wrong org explicitly avoided: `kwitkodev`

## Executive Summary

This solution is not production-ready yet.

The Apex/service layer has improved and now passes a full local Salesforce regression, but the end-to-end system still has major runtime and setup blockers:

- Live web chat does not recognize logged-in Woo users because the live page is not passing `Kwitko_Logged_In_Email__c` or `Kwitko_Logged_In_First_Name__c` into `MessagingSession`.
- Four of five active published agents cannot start a published preview session because their `BotDefinition.BotUserId` is null.
- Agent Testing Center is not green across all suites. Web concierge and sign-in simulations pass, but Inside Sales and Post-Purchase Growth still return generic runtime errors, and several service/privacy tests need business-rule alignment.
- Data Cloud is not a certified source of unified agent context. Identity Resolution is published but has `UnifiedCount = 0`; only one of the authored business calculated insights is active live.
- Lead purchase close is custom-stamped, but native Salesforce Lead conversion still fails with `UNAVAILABLE_RECORDTYPE_EXCEPTION`.
- Return and historical fulfillment data are incomplete. The newest shipped test order is now correct, but historical orders are not fully backfilled to FulfillmentOrder/Shipment.

## What Is Fixed And Verified

### Apex Regression

Fresh full regression in `AgentforceDev`:

- Test run: `707fj00000c8Vtn`
- Start time: `2026-06-07T05:15:35Z`
- Result: `120/120` passed
- Failures: `0`
- Org-wide coverage: `83%`
- Test-run coverage: `87%`

### Woo Order And Fulfillment Truth

Woo order truth:

| Woo order | Woo status | Salesforce order | Salesforce fulfillment | FulfillmentOrder | Shipment |
|---|---:|---|---|---|---|
| `269` | `completed` | `00000731` | `Shipped` | `FO-0088`, Assigned | `SP-0001`, Shipped, UPS `2123121323`, `Delivered_At__c = null` |
| `212` | `processing` | `00000726` | `Processing` | `FO-0089`, Assigned | none |
| `222` | `cancelled` | `00000727` | `Cancelled` | none | none |

Important result: Woo `completed` plus tracking is now treated as `Shipped`, not `Delivered`, unless a Shipment delivery event or `Delivered_At__c` proves delivery.

Verified live action behavior:

- Verified shopper request for Woo `269` returns `found=true`, `fulfillment=Shipped`, `source=Shipment`, `canReturn=false`, and says it is not marked delivered yet.
- Guest/typed-email request for the same order returns `found=false` and a sign-in message, with no private order data.

Relevant code:

- `force-app/main/default/classes/FulfillmentTruthService.cls`
- `force-app/main/default/classes/OrderStatusService.cls`

### Local Web Chat Package

The local controller sends both hidden pre-chat fields and agent variables:

- `Kwitko_Logged_In_Email__c`
- `loggedInEmail`
- `Kwitko_Logged_In_First_Name__c`
- `loggedInFirstName`
- `Kwitko_Cart_Token__c`

I also fixed the local WordPress PHP package so `wp_kwitko_inchat_auth.php` now loads `kwitko_chat_controller.js` from `wp-content/uploads/kwitko/`. This removes the fragile dependency on a separate stale WPCode JavaScript snippet.

Changed files:

- `tools/inchat-auth/wp_kwitko_inchat_auth.php`
- `tools/inchat-auth/README.md`

Local validation:

- `node -c tools/inchat-auth/kwitko_chat_controller.js` passed.
- PHP lint could not be run locally because `php` is not installed in this workspace.

## Production Blockers

### 1. Live Woo/Web Chat Identity Is Broken

Live page check:

- URL checked: `https://deepskyblue-deer-920559.hostingersite.com/`
- `KWITKO_AUTH`: present
- identity refresh code: present
- sign-in text: present
- `Kwitko_Cart_Token__c`: present
- `Kwitko_Logged_In_Email__c`: missing
- `Kwitko_Logged_In_First_Name__c`: missing
- current controller name: missing

Salesforce live evidence:

- Latest 10 `MessagingSession` records all have:
  - `Kwitko_Logged_In_Email__c = null`
  - `Kwitko_Logged_In_First_Name__c = null`
  - `Kwitko_Cart_Token__c = null`

Impact:

- The web agent cannot know the shopper is logged in.
- It correctly falls back to asking for email/sign-in.
- The instruction "if loggedInEmail is non-empty, do not ask for email" cannot work because `loggedInEmail` never arrives.

Fix required in Woo/WordPress admin:

1. Upload current `tools/inchat-auth/kwitko_chat_controller.js` to `wp-content/uploads/kwitko/kwitko_chat_controller.js`.
2. Upload current `tools/inchat-auth/kwitko_chat_controller.css` to `wp-content/uploads/kwitko/kwitko_chat_controller.css`.
3. Replace the active WPCode PHP snippet with current `tools/inchat-auth/wp_kwitko_inchat_auth.php`.
4. Disable any old separate WPCode JavaScript snippet for the controller.
5. Confirm Salesforce Embedded Service hidden pre-chat includes:
   - `MessagingSession.Kwitko_Logged_In_Email__c`
   - `MessagingSession.Kwitko_Logged_In_First_Name__c`
   - `MessagingSession.Kwitko_Cart_Token__c`
6. Publish the Embedded Service deployment.
7. Start a new logged-in browser chat and verify the new `MessagingSession` has email and first name populated before judging agent behavior.

### 2. Four Published Agents Cannot Start

Published preview start results:

| Agent | Published preview |
|---|---|
| `Kwitko_Concierge_Web` | starts |
| `Kwitko_Concierge` | fails: `Invalid user ID provided on start session` |
| `Product_Advisor` | fails: `Invalid user ID provided on start session` |
| `Inside_Sales` | fails: `Invalid user ID provided on start session` |
| `Post_Purchase_Growth` | fails: `Invalid user ID provided on start session` |

Live `BotDefinition` evidence:

| Agent | Agent type | BotUserId |
|---|---|---|
| `Kwitko_Concierge_Web` | Einstein Service Agent / ExternalCopilot | populated |
| `Kwitko_Concierge` | Agentforce Employee Agent / InternalCopilot | null |
| `Product_Advisor` | Agentforce Employee Agent / InternalCopilot | null |
| `Inside_Sales` | Agentforce Employee Agent / InternalCopilot | null |
| `Post_Purchase_Growth` | Agentforce Employee Agent / InternalCopilot | null |

`BotDefinition.BotUserId` is visible but not createable/updateable through the normal API in this org. This needs Salesforce Setup/runtime-user binding and republish, not another Apex patch.

Fix required:

1. In Agentforce Setup, assign an active runtime user to each employee agent.
2. Make sure the runtime user has required permission sets:
   - Agentforce employee agent permission set
   - `Kwitko_Integration`
   - object/FLS access for Lead, Account, Order, OrderItem, FulfillmentOrder, Shipment, ReturnOrder, Case, Cart, Customer Journey, Agent Interaction
   - Apex action class access
   - Named credential/external credential access where relevant
3. Republish all four employee agents.
4. Re-run published preview start for all five agents.

### 3. Agent Testing Center Is Not Fully Green

Fresh rerun output directory:

`test-results/audit-2026-06-07-agent-tests-rerun`

Completed suite summary:

| Suite | Result | Interpretation |
|---|---:|---|
| `Kwitko_Concierge_Web_Test` | `3/3` | pass |
| `Kwitko_Concierge_Web_SignIn` | `2/2` | pass in simulated Testing Center |
| `Kwitko_Concierge_Test` | `0/1` | only topic assertion mismatch: actual `agent_router`, expected `concierge`; actions/output passed |
| `Product_Advisor_Test` | `0/2` | only topic assertion mismatch: actual `agent_router`, expected `recommend`; actions/output passed |
| `Inside_Sales_Test` | `0/2` | real runtime/action failure; actions empty; generic unexpected error |
| `Post_Purchase_Growth_Test` | `0/2` | real runtime/action failure; actions empty; generic unexpected error |
| `Kwitko_Concierge_Web_Service` | `0/3` | tests expect typed email to unlock service actions; current privacy rule requires verified sign-in |
| `Kwitko_Concierge_Web_ServiceRedteam` | `1/4` | mix of privacy-spec mismatch and topic classification mismatch |
| `Kwitko_Concierge_Web_Confused` | not clean | started job `4KBfj0000002zk9GAA`, then polling failed with `read EINVAL` |
| `Kwitko_Concierge_Web_Security` | not clean | start failed with `read EINVAL` |
| `Kwitko_Concierge_Web_Adversarial` | not clean | start failed with platform error |

Required work:

- Fix runtime-user setup first. It likely explains Inside Sales and Post-Purchase Growth runtime failures.
- Update topic assertions to match current router behavior or change the authoring structure so final topic labels match expected labels.
- Decide the service business rule:
  - Strict privacy: typed email never unlocks order/case/cancel actions. Then update service tests to expect sign-in.
  - Softer service intake: typed email can open a generic unlinked case but cannot reveal/link private order data until verified. Then update agent instructions and `open_case` action rules.
- Re-run all 11 until every suite either passes or has an intentionally documented expected failure.

### 4. Data Cloud Is Not Production-Certified

Live Data Stream status:

- Active and successful: Account, Lead, Order, OrderItem, Product2, ReturnOrder, Case, Order Analytics.
- Missing from live stream query: `Shipment_Home`, `FulfillmentOrder_Home`.

Identity Resolution:

- Name: `inCoffee Unified Profile`
- Status: `PUBLISHED`
- LastRunStatus: `SUCCESS`
- `SourceCount = 16`
- `MatchedCount = 0`
- `UnifiedCount = 0`

Calculated Insights:

- Authored locally:
  - `Customer Agent Profile`
  - `Customer Category Affinity`
  - `Customer Return Risk`
  - `Customer Service Risk`
  - `Order Patterns by Demographics`
  - `Return Churn by Account`
  - `Shipment Delivery Health`
- Live active among those: only `Order Patterns by Demographics`.

CRM entity visibility:

- Query for `__cio`, `__dlm`, and `__dmo` entities returned zero rows through CRM SOQL.

Current Account augmentation:

- The account has Data Cloud-style fields populated, but `Data_Cloud_Insight_Source__c = CRM fallback`.
- `Data_Cloud_Unified_Individual_Id__c = null`.

Conclusion:

The fields are useful for agent grounding after verified identity, but this is not a certified Data Cloud unified profile plus calculated insight implementation yet.

Fix required:

1. Activate/confirm Data Streams for:
   - Account
   - Contact/ContactPointEmail/Individual
   - Lead
   - Cart
   - Order
   - OrderItem
   - Product2
   - FulfillmentOrder
   - Shipment
   - ReturnOrder
   - Case
   - Agent interaction/session telemetry
2. Complete DLO to DMO mappings:
   - Account to Individual and ContactPointEmail
   - Order/OrderItem/Product to Sales Order/Product DMOs or custom commerce DMOs
   - FulfillmentOrder to fulfillment DMO
   - Shipment to shipment/delivery DMO
   - ReturnOrder to return/refund DMO
   - Case to service interaction DMO
   - Consent fields to consent/contact point consent model
3. Fix Identity Resolution so unified profiles actually produce unified rows.
4. Activate and run all seven business CIs.
5. Verify Account augmentation changes from `CRM fallback` to `Data Cloud CI + CRM fallback` for a known test account.
6. Expose only verified-safe augmented fields to agents.

### 5. Lead Conversion After Purchase Is Not Native

Live lead evidence:

- Lead status: `Closed - Converted`
- `Purchase_Closed__c = true`
- `Converted_Account__c` populated
- `Converted_Order__c` populated
- Native `IsConverted = false`
- Native `ConvertedAccountId = null`
- Native `ConvertedContactId = null`

Native conversion retry result:

- `Database.convertLead` with existing Person Account and no Opportunity still failed:
  - `UNAVAILABLE_RECORDTYPE_EXCEPTION: Unable to find default record type`

Fix required:

1. In Setup, grant the conversion-running profile/user access to the Account record type needed for conversion.
2. Set a valid default Account record type for the conversion user/profile.
3. Re-run native lead conversion using existing Person Account and no Opportunity.
4. Add a CI/test check that a post-purchase lead is both custom-closed and `IsConverted = true`.

### 6. Return Lifecycle Is Incomplete

Live return evidence:

- `RO-0002`
- Status: `Draft`
- Account populated
- `OrderId = null`

Impact:

- Agent cannot reliably connect return status to order lifecycle.
- Winback and service risk can be wrong because return context is not anchored to an order.

Fix required:

1. Update return creation/backfill to always link `ReturnOrder.OrderId` and custom `Order__c` where possible.
2. Block return creation unless the order is actually delivered.
3. Add tests:
   - shipped but not delivered: return denied
   - delivered: return created and linked
   - existing unlinked return: backfilled or flagged

### 7. Historical Fulfillment Backfill Is Missing

Live object counts:

| Object | Count |
|---|---:|
| Account | 173 |
| Contact | 180 |
| Lead | 34 |
| Order | 388 |
| OrderItem | 1182 |
| FulfillmentOrder | 10 |
| Shipment | 1 |
| ReturnOrder | 1 |
| Case | 34 |
| Customer_Journey__c | 15 |
| Agent_Interaction__c | 40 |
| Cart__c | 3 |
| Order_Analytics__c | 373 |

Only recent/tested orders have proper FulfillmentOrder/Shipment records. This needs a backfill plan before agents are allowed to answer broadly about historical shipping.

Fix required:

1. Pull Woo orders in batches.
2. For each order:
   - sync Account/Contact
   - sync Order/OrderItem
   - create/update FulfillmentOrder for processing/completed statuses
   - create/update Shipment only when tracking metadata exists
   - set Delivered only from carrier/delivery proof, not Woo completed
3. Reconcile counts:
   - processing/completed shipped orders should have FulfillmentOrder
   - tracked orders should have Shipment
   - cancelled/refunded orders should not create active fulfillment/shipment records

### 8. CI/CD Does Not Catch The Real Failures

Current workflow:

- Prettier and JS lint
- Deploy validate with RunLocalTests
- Basic Data Cloud health query
- Basic Agentforce config query

Missing gates:

- Agent Testing Center all 11 suites
- Published preview start for all five agents
- Web chat live hidden-field smoke
- MessagingSession hidden-field verification after logged-in chat
- Woo order lifecycle fixture sync for processing, shipped, cancelled, delivered, returned
- Data Cloud mapping completeness check
- Identity Resolution `UnifiedCount > 0`
- All required business CIs active and successful
- Native lead conversion smoke
- ReturnOrder linked-to-order smoke

## Business Object And Integration Map

### WooCommerce To Salesforce

| Woo event/state | Salesforce target | Required rule |
|---|---|---|
| customer/account update | Person Account, Contact, consent fields | honor explicit opt-out |
| cart active/abandoned | `Cart__c`, Lead, Customer Journey | do not market without consent |
| checkout/purchase | Account, Order, OrderItem, Lead lifecycle | purchase closes lead and should natively convert when setup is fixed |
| Woo `processing` | Order + FulfillmentOrder | customer-facing status Processing |
| Woo `completed` without delivery proof | Order + FulfillmentOrder + maybe Shipment | customer-facing status Shipped, not Delivered |
| tracking added | Shipment linked to Order and FulfillmentOrder | expose tracking only to verified identity |
| carrier delivered event | Shipment `Delivered_At__c`/Delivered | only then allow return |
| Woo `cancelled` | Order cancellation fields | no active fulfillment, no shipment |
| refund/return | ReturnOrder + Case + Order | must link to order |

### Salesforce To Agentforce

| Agent | Intended role | Current state |
|---|---|---|
| `Kwitko_Concierge_Web` | public web chat/service/commerce | published preview starts; simulated tests pass for web/sign-in; live identity broken upstream |
| `Kwitko_Concierge` | employee/general concierge | source starts; published preview fails runtime user |
| `Product_Advisor` | deterministic recommendation brain | source starts; published preview fails runtime user; tests fail only topic expectation |
| `Inside_Sales` | abandoned cart lead recovery | source starts; published preview fails runtime user; tests fail runtime/actions |
| `Post_Purchase_Growth` | buy-again/post-purchase offers | source starts; published preview fails runtime user; tests fail runtime/actions |

### Salesforce To Data Cloud

| Area | Current state | Required state |
|---|---|---|
| DLO streams | many active, but Shipment/Fulfillment not confirmed live | all commerce/service streams active |
| DMO mappings | local maps only cover Account identity and Order Analytics | complete commerce, service, fulfillment, return, consent mapping |
| Identity Resolution | published, success, but `UnifiedCount = 0` | unified profiles > 0 and test profile unified |
| Calculated Insights | only one business CI active live | all seven active and successful |
| Augmented Account fields | populated from CRM fallback | populated from Data Cloud CI where available, fallback only as backup |
| Agent access | verified-only guard exists in Apex | agents must consume only through verified context envelope |

## Production Fix Plan

### Phase 1: Stop The Live Web Identity Failure

1. Update Woo/WordPress admin with the fixed in-chat auth package.
2. Confirm live page contains:
   - `kwitko_chat_controller.js`
   - `Kwitko_Logged_In_Email__c`
   - `Kwitko_Logged_In_First_Name__c`
3. Start a new logged-in Woo session and a new web chat.
4. Verify the new `MessagingSession` hidden fields are populated.
5. Ask "What do I like?" and confirm the agent greets by name or uses verified identity without asking for email.
6. Ask the same question as a guest and confirm no private account/order/profile data leaks.

### Phase 2: Fix Agent Runtime Users And Republish

1. Assign runtime user for all four employee agents.
2. Assign required permissions and Apex access.
3. Republish all five agents.
4. Run published preview start for all five.
5. Do not proceed until all five published previews start successfully.

### Phase 3: Fix Agent Tests And Business Rules

1. Re-run all 11 Agent Testing Center suites.
2. Fix real runtime/action failures:
   - `Inside_Sales_Test`
   - `Post_Purchase_Growth_Test`
3. Resolve topic assertion expectations:
   - update test expected topics to `agent_router`, or change authoring so terminal topic labels match expected values.
4. Decide service privacy rule for typed email:
   - strict sign-in required for all private service actions, or
   - generic case intake allowed without private order details.
5. Update tests to enforce the chosen policy.

### Phase 4: Fix Data Cloud

1. Add/activate missing Data Streams for FulfillmentOrder and Shipment.
2. Complete DLO/DMO mappings for fulfillment, shipment, returns, cases, orders, products, consent.
3. Fix Identity Resolution match rules so unified profile count is nonzero.
4. Activate all business CIs.
5. Refresh Account augmented fields from CIs.
6. Confirm `Data_Cloud_Insight_Source__c = Data Cloud CI + CRM fallback` for test profiles.
7. Add CI gate for IR and CI health.

### Phase 5: Fulfillment And Return Backfill

1. Backfill FulfillmentOrders and Shipments from Woo for historical orders.
2. Backfill ReturnOrder links.
3. Run lifecycle fixture tests:
   - processing
   - shipped with tracking
   - delivered with proof
   - cancelled
   - returned/refunded
4. Confirm no shipped-only order is reported as delivered.

### Phase 6: Lead Native Conversion

1. Fix Account record type access/default for the conversion-running user/profile.
2. Re-run conversion for the purchase-closed lead.
3. Confirm `IsConverted = true`.
4. Add a native conversion smoke test to CI or a scheduled admin validation.

### Phase 7: CI Hardening

Add required gates before production:

1. `sf apex run test --test-level RunLocalTests`
2. `sf agent test run` for all 11 Agent Testing Center definitions.
3. Published `sf agent preview start` for all five agents.
4. Live web hidden-field smoke.
5. Woo fixture sync smoke for all order states.
6. Data Cloud stream, IR, and CI health checks.
7. Lead conversion smoke.
8. Return/order linkage smoke.

## Acceptance Criteria

The solution is production-ready only when all are true:

- All five published agents start successfully.
- All 11 Agent Testing Center suites pass or have documented intentional expectations aligned with business policy.
- A logged-in Woo user starts chat and new `MessagingSession` contains logged-in email and first name.
- A guest typed email cannot reveal order, coupon, saved cart, address, Data Cloud profile, or order history.
- Woo `completed` plus tracking says Shipped, not Delivered.
- Delivered is used only when delivery proof exists.
- Processing, shipped, delivered, cancelled, returned, refunded all have tested agent behavior.
- FulfillmentOrder and Shipment are linked to Order.
- ReturnOrder is linked to Order.
- Native Lead conversion works after purchase.
- Data Cloud IR produces unified profiles.
- All required CIs are active and available to Account augmentation.
- Account augmentation source shows Data Cloud CI where applicable.
- CI catches Apex, agent, web identity, Woo lifecycle, Data Cloud, and lead conversion failures.

