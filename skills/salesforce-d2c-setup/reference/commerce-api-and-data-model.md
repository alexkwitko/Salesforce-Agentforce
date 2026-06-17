# Commerce API + Data Model Reference (B2B & D2C)

Authoritative extract from the **B2B & D2C Commerce Developer Guide** (`developer.salesforce.com/docs/commerce/salesforce-commerce/guide/b2b-b2c-comm-dev-guide.html`). Load this when you need exact endpoint paths, object/field names, Apex interface signatures, or the LWC adapter list. The playbook (`SKILL.md`) covers the *setup workflow*; this file is the *reference catalog*.

> **Product boundary:** This guide = **B2B/D2C Commerce on the Salesforce core platform** (Experience Cloud LWR/Aura + the Commerce data model). It is NOT "B2C Commerce Cloud" (SFRA / PWA Kit / Demandware lineage) — that's a separate product with a different model. Everything here is the core-platform Commerce.

---

## 1. The two calculation frameworks (architectural fork — pick ONE)

A store's cart/checkout calculations run on **one** of two mutually-exclusive frameworks. **They cannot be mixed** — the new Cart Calculate API is explicitly incompatible with the legacy integrations.

| | **Legacy "Checkout Integrations"** (Aura-era, still supported) | **Cart Extensions / Cart Calculate** (current GA, recommended) |
|---|---|---|
| Apex base | implement `sfdc_checkout.*` interfaces | extend `CartExtension.*` abstract classes |
| Registration | `RegisteredExternalService` + `StoreIntegratedService` | register the class against a named **extension point** (e.g. `Commerce_Domain_Tax_CartCalculator`) |
| Orchestration | each calc is a standalone async job | one `CartExtension.CartCalculate` orchestrator calls each calculator in order |
| Granularity | Price, Tax, Inventory, Shipment (4 types) | Pricing, Promotions, Inventory, Shipping, Tax + endpoint extensions |
| When to use | quick mock/demo, or an existing store already on it | new builds, anything needing the Cart Calculate API, finer control |

Payment is **outside** both — it always uses the `commercepayments` framework regardless of which calc framework the store uses.

### Legacy `sfdc_checkout` interfaces
All four share one method signature (synchronous-capable; `AsyncCartProcessor` for fully async):
```apex
global with sharing class MyTax implements sfdc_checkout.CartTaxCalculations {
    global sfdc_checkout.IntegrationStatus startCartProcessAsync(
        sfdc_checkout.IntegrationInfo jobInfo, Id cartId) {
        sfdc_checkout.IntegrationStatus s = new sfdc_checkout.IntegrationStatus();
        // ...write CartTax / CartItemPriceAdjustment / etc...
        s.status = sfdc_checkout.IntegrationStatus.Status.SUCCESS;   // or .FAILED
        return s;                                                    // NO .message field exists
    }
}
```
| ServiceProviderType | Legacy interface | Sample class (quickstart repo) |
|---|---|---|
| Price | `sfdc_checkout.CartPriceCalculations` | `B2BPricingSample` |
| Tax | `sfdc_checkout.CartTaxCalculations` | `B2BTaxSample` |
| Inventory | `sfdc_checkout.CartInventoryValidations` | `B2BCheckInventorySample` |
| Shipment | `sfdc_checkout.CartShippingCharges` | `B2BShippingSample` |

`StoreIntegratedService.ServiceProviderType` enum (all values): **Flow, Price, Promotions, Inventory, Shipment, Tax, Payment, Extension**. Steps must be **idempotent** — checkout re-runs them.

### Cart Extension framework (`CartExtension` namespace)
Orchestrator — override `calculate()`, call the per-domain helpers:
```apex
public virtual void calculate(CartExtension.CartCalculateOrchestratorRequest request)
// non-overridable helpers: callPricingCalculator / callPromotionsCalculator /
// callInventoryCalculator / callShippingCalculator / callTaxCalculator /
// selectCheapestDeliveryMethod
```
Per-domain calculators extend the abstract base and override `calculate(CartExtension.CartCalculateCalculatorRequest request)`.

| Domain | Base class | Extension point | Status |
|---|---|---|---|
| Cart Calculate (orchestrator) | `CartExtension.CartCalculate` | `Commerce_Domain_Cart_Calculate` | GA |
| Pricing calculator | `CartExtension.PricingCartCalculator` | `Commerce_Domain_Pricing_CartCalculator` | GA |
| Pricing service | `commercestorepricing.PricingService` | `Commerce_Domain_Pricing_Service` | GA |
| Promotions calculator | `CartExtension.PromotionsCartCalculator` | `Commerce_Domain_Promotions_CartCalculator` | GA |
| Inventory calculator | `CartExtension.InventoryCartCalculator` | `Commerce_Domain_Inventory_CartCalculator` | Pilot |
| Inventory service | `commerce_inventory.CommerceInventoryService` | `Commerce_Domain_Inventory_Service` | GA |
| Shipping calculator | `CartExtension.ShippingCartCalculator` | `Commerce_Domain_Shipping_CartCalculator` | GA |
| Split shipment | `CartExtension.SplitShipmentService` (override `arrangeItems()`) | `Commerce_Domain_Shipping_SplitShipment` | — |
| Tax calculator | `CartExtension.TaxCartCalculator` | `Commerce_Domain_Tax_CartCalculator` | GA |
| Tax service | `commercestoretax.TaxService` | `Commerce_Domain_Tax_Service` | GA |
| Checkout create order | `CartExtension.CheckoutCreateOrder` | `Commerce_Domain_Checkout_CreateOrder` | — |

Default calculator order: **pricing → promotions → inventory → shipping → tax**. `BuyerActions` booleans (`isCartItemChanged()`, `isCheckoutStarted()`, `isCouponChanged()`, `isDeliveryGroupChanged()`, `isDeliveryMethodSelected()`) let you skip calculators that aren't affected. Triggers: AddItemToCart, EditCartItem, StartCheckout, PatchCheckout, DeleteCartItem, AddCoupon, DeleteCoupon.

**Endpoint Extensions** (separate family — modify Connect API request/response payloads): extend `connectapi.BaseEndpointExtension`, register against `Commerce_Endpoint_*` points (`_Catalog_Products`, `_Cart_Item`, `_Search_Products`, `_Account_Addresses`, etc.).

**Registering a Cart Extension (the `@salesforce/commerce` CLI plugin — cleanest path):**
```bash
sf plugins | grep commerce                 # @salesforce/commerce ships register/map/unmap
sf commerce extension points -o <org>      # list valid EPN (extension-point) values, e.g. Commerce_Domain_Tax_CartCalculator
sf commerce extension register --registered-extension-name <name> --apex-class <ApexClass> -o <org>
sf commerce extension map --registered-extension-name <name> --store-name "<Store>" --extension-point-name <EPN> -o <org>
sf commerce extension unmap ...            # reverse a mapping
```
Behind the scenes this writes a `RegisteredExternalService` (provider type = the extension point) + a store mapping. **Migration cutover from legacy → extension** = register + map the new calculator, then **delete the legacy `StoreIntegratedService`** for that domain (they're mutually exclusive — leaving both risks double-calc/errors). ⚠️ **Cutting over a working store's calc is hard-to-reverse and cannot be verified headlessly** — the calc only runs in a live shopper checkout. Stage the class first (deploy it; a deploy never touches the running store), then flip + verify with a real storefront cart, keeping the legacy registration handy to re-add if it breaks.

Apex signatures verified against API v62/66: `cartItem.getQuantity()` returns **`Decimal`** (not Double — `Decimal.valueOf()` on it won't compile); item amount getters (`getTotalPriceAfterAllAdjustments()`, `getTotalListPrice()`) return **`Double`**; `new CartExtension.CartTax(TaxTypeEnum, Decimal amount, String name)`, then `.setTaxRate(String.valueOf(rate))`; clear prior taxes with `while (taxes.size()>0) taxes.remove(taxes.get(0));` for idempotent re-runs.

Reference repos: `forcedotcom/commerce-extensibility` (extensions — the tax sample lives at `commerce/domain/tax/cart/calculator/classes/TaxCartCalculatorSample.cls`), `forcedotcom/b2b-commerce-on-lightning-quickstart` (legacy + payments), `forcedotcom/Core-Payments-Reference-Gateway-Integration-Adapters` (full `processRequest` adapters).

---

## 2. Connect Commerce REST API — endpoint catalog

Storefront ops: `/services/data/vXX.0/commerce/webstores/{webstoreId}/...` (buyer-scoped, runs in shopper session). Admin/import: `/commerce/management/webstores/{webstoreId}/...`. Promotion eval is **unscoped**: `/commerce/promotions/...` (store + buyer group in the body). The literal `active` works in place of an Id in `{cartStateOrId}` / `{activeOrCheckoutId}`.

### Carts & cart items
| Method | Path | Does |
|---|---|---|
| POST/GET/PUT/DELETE | `/carts` , `/carts/{cartStateOrId}` | create / get / get-or-create-active / delete |
| GET | `/carts/compact-summary` | compact totals |
| GET/POST | `/carts/{id}/cart-items` | list / add item |
| POST | `/carts/{id}/cart-items/batch` | add up to 100 |
| PATCH/DELETE | `/carts/{id}/cart-items/{itemId}` | update / remove |
| GET | `/carts/{id}/cart-items/{itemId}/children` | child line items |
| POST | `/carts/{id}/actions/clone` , `/make-primary` , `/preserve` | clone / promote secondary / preserve guest cart on login |
| POST | `/carts/{id}/actions/add-cart-to-wishlist` | copy to wishlist |
| GET/POST/PATCH/DELETE | `/carts/{id}/delivery-groups[/{dgId}]` | delivery groups CRUD |
| POST | `/carts/{id}/delivery-groups/actions/arrange-items` , `/itemDistributions` | split items across groups |
| POST | `/carts/{id}/actions/evaluate-taxes` , `/evaluate-shipping` , `/calculate` | recalc |
| GET/POST/DELETE | `/carts/{id}/cart-coupons[/{couponId}]` | coupons on cart |
| GET | `/carts/{id}/promotions` ; POST `/carts/{id}/cart-items/promotions` | promos on cart / items |
| PUT/DELETE | `/carts/{id}/inventory-reservations` | reserve / release stock |
| POST | `/carts/{id}/quotes` | create quote from cart |

### Checkout
| Method | Path | Does |
|---|---|---|
| POST/PUT | `/checkouts` | start checkout (PUT recommended) |
| GET/PATCH/DELETE | `/checkouts/{activeOrCheckoutId}` | get / set address+method / delete |
| POST | `/checkouts/{id}/payments` | submit payment |
| POST | `/payments/token` | tokenize payment |
| POST | `/checkouts/{id}/orders` | **place order (cart → Order)** |
| POST | `/checkouts/{id}/orders/actions` | enhanced place-order |
| POST/DELETE | `/checkouts/{id}/coupons[/{couponId}]` | coupon at checkout |

### Products / categories / search
| Method | Path | Does |
|---|---|---|
| GET | `/products` , `/products/{id}` , `/products/{id}/children` | list / detail / variations |
| GET | `/product-categories/{id}` , `/product-categories/children` | category detail / children |
| GET | `/product-category-path/product-categories/{id}` | breadcrumb path |
| GET | `/search/products` (preferred) ; POST `/search/product-search` (superseded) | search |
| GET | `/search/suggestions` , `/search/sort-rules` | suggestions / sort rules |
| POST/PUT | `/commerce/management/webstores/{id}/composite-products[/{productId}]` | admin: product + category + media in one call |
| POST | `/commerce/management/webstores/{id}/composite-variations` | variation products w/ media + pricing |

### Pricing & promotions
| Method | Path | Does |
|---|---|---|
| GET | `/pricing/products/{id}` ; GET/POST `/pricing/products` | buyer price(s) |
| POST | `/commerce/promotions/actions/evaluate` | **Evaluate Cart** — eligible promos + adjustments (computes, does NOT persist) |
| POST | `/commerce/promotions/actions/evaluate-products` | promos applying to a product set (PDP/PLP) |
| POST | `/commerce/promotions/actions/increase-use/coupon-codes` , `/decrease-use/coupon-codes` | track / revert redemptions |

### Order summaries (post-purchase)
| Method | Path | Does |
|---|---|---|
| GET | `/order-summaries` , `/order-summaries/{id}` | list / get (registered buyers) |
| GET | `/order-summaries/{id}/items` , `/delivery-groups` , `/shipments` | lines / groups / shipments |
| POST | `/order-summaries/actions/lookup` | guest-or-registered lookup (email+phone) |
| POST | `/order-summaries/{id}/actions/add-order-to-cart` | **reorder** — add past order to cart |

Other families on the storefront API parent: Address Management, My Profile, Tax, Wishlists, Search Settings, Import.

### Management endpoints (admin / setup)
| Method | Path | Does |
|---|---|---|
| POST | `/commerce/management/webstores/{id}/search/indexes` (body `{}`) | rebuild search index; GET to poll `indexStatus` |

---

## 3. Cart / checkout object model

| Object | Role | Key fields / relationships |
|---|---|---|
| **WebCart** ("Cart") | root cart; holds product/shipping/tax totals | parent of CartItem, CartDeliveryGroup, CartTax, CartValidationOutput; → WebStore. Can be primary or read-only clone |
| **CartItem** | line item | → `Product2Id`; in a `CartDeliveryGroup`; `Quantity`, `ListPrice`, `SalesPrice`, `TotalPrice`, `AdjustmentAmount`, `Type`; children = CartTax, CartItemPriceAdjustment |
| **CartDeliveryGroup** | items grouped by ship-to / method | `DeliverTo*` address fields, `DesiredDeliveryDate`, `IsGift`, totals; has many `CartDeliveryGroupMethod`. ⚠️ `DeliveryMethodId` **deprecated v64, removed v66** — use CartDeliveryGroupMethod |
| **CartDeliveryGroupMethod** | candidate/selected shipping method (carrier+rate) | child of CartDeliveryGroup |
| **CartTax** | tax line on a CartItem | `Amount`, `TaxRate`, `TaxType` (Estimated/Actual) |
| **CartItemPriceAdjustment** | promo discount at line level | child of CartItem (this is how promo discounts surface) |
| **WebCartAdjustmentGroup** / **WebCartAdjustmentBasis** | cart-level promo adjustments | children of WebCart |
| **CartValidationOutput** | validation errors/info | `RelatedEntityId` → cart entity; `Type` (Inventory/Pricing/Promotions/Entitlement/Taxes/Shipping/Systemic), `Level` (Error/Info), `Message`. UI shows only Level=Error + Type∈{Inventory,Pricing,Promotions,Entitlement} |
| **CartCheckoutSession** | checkout-process state | bridges cart → order |

---

## 4. Order processing — Cart → Order → OrderSummary

Place-order (`POST /checkouts/{id}/orders`) converts **WebCart → Order** (with **OrderItem** + **OrderDeliveryGroup**). **Salesforce Order Management** then creates the **OrderSummary** (auto-generating **OrderItemSummary** + **OrderDeliveryGroupSummary**). The storefront order-history / reorder / returns APIs read **OrderSummary**, not Order — so **no OrderSummary = no post-purchase storefront experience.**

| Object | Role |
|---|---|
| **Order** | placed order (pre-summary, mutable original) |
| **OrderItem** / **OrderDeliveryGroup** | order lines / delivery grouping |
| **OrderSummary** | buyer-facing aggregate of the order + change objects |
| **OrderItemSummary** / **OrderDeliveryGroupSummary** | per-line / per-group summary |
| **OrderItemAdjustmentLineSummary** | promo/price adjustments at summary level |
| **Shipment** (+ items) | fulfillment records (`/shipments`) |
| **InventoryReservation** / **InventoryItemReservation** | stock allocated through checkout |
| **ProcessException** | OM fulfillment exception handling |

Cart→Order mapping: WebCart→Order, CartItem→OrderItem, CartDeliveryGroup→OrderDeliveryGroup, CartItemPriceAdjustment→OrderItemAdjustmentLineSummary.

---

## 5. Pricing & promotions data model

### Pricing
| Object | Role |
|---|---|
| **Pricebook2** | container of prices |
| **PricebookEntry** | Pricebook2↔Product2 = **list price** |
| **WebStorePricebook** | Pricebook2↔WebStore (which prices a store sees) |
| **BuyerGroupPricebook** | Pricebook2↔BuyerGroup (segment pricing) |
| **PricebookEntryAdjustment** | adjust one entry's price |
| **PriceAdjustmentSchedule** / **PriceAdjustmentTier** | time/volume tiered pricing → **sales price** |
| **ProductSellingModel** | one-time / term / usage |

### Promotions
| Object | Role |
|---|---|
| **Promotion** | the discount definition (product / shipping / order promo) |
| **PromotionTarget** | items the discount applies to (the "get Y") |
| **PromotionQualifier** | conditions to earn it (the "buy X") |
| **PromotionTier** | spend/qty thresholds |
| **PromotionLineItemRule** | line-item rule specifics |
| **Coupon** | code attached to a promo → **manual**; no coupon → **automatic** |
| **CouponCodeRedemption** | redemption tracking / caps |
| **PromotionSegment** | audience grouping |
| **PromotionSegmentSalesStore** | scope promo to a store |
| **PromotionSegmentBuyerGroup** | scope promo to a buyer group |
| **PromotionMarketSegment** | market-level scope |

Define = create `Promotion` → attach `PromotionQualifier`(s) + `PromotionTarget`(s) (+ `PromotionTier`s) → optional `Coupon` (makes it manual) → activate for an audience via `PromotionSegmentSalesStore` / `PromotionSegmentBuyerGroup`. The **promotions calculator** runs **Evaluate Cart** on every cart change + checkout; it **computes** adjustments but a separate pipeline step **persists** them as CartItemPriceAdjustment / WebCartAdjustmentGroup.

---

## 6. Custom LWC on the LWR storefront

Custom components read the store via `commerce/*` modules — **wire adapters** (reactive `@wire`, auto-refresh on store change) + **imperative functions** (async). Components render repeatedly as data fills — guard for undefined data and re-render.

| Module | Wire adapters | Imperative |
|---|---|---|
| `commerce/cartApi` | `CartAdapter` (count), `CartItemsAdapter`, `CartSummaryAdapter`, `CartCouponsAdapter`, `CartPromotionsAdapter`, `CartStatusAdapter` | `addItemToCart`, `addItemsToCart`, `updateItemInCart`, `deleteItemFromCart`, `deleteCurrentCart`, `applyCouponToCart`, `deleteCouponFromCart`, `refreshCartSummary` |
| `commerce/productApi` | `ProductAdapter`, `ProductPricingAdapter`, `ProductCategory*Adapter`, `ProductCollectionAdapter`, `ProductChildrenAdapter`, `ProductSearchAdapter`, `ProductTaxAdapter` | `getProductCollection`, `getProductPricingCollection`, `getProductRecommendations`, `searchProducts` |
| `commerce/contextApi` | `AppContextAdapter`, `SessionContextAdapter` | `getAppContext`, `getSessionContext` (webstoreId, effective account, currency/locale, guest-vs-auth) |
| `commerce/effectiveAccountApi` | — | `effectiveAccount.update(accountId, name)` (B2B) |
| `commerce/checkoutApi` | `CheckoutInformationAdapter`, `CheckoutAddressAdapter`, `CheckoutGuestEmailAdapter` | `loadCheckout`, `placeOrder`, `authorizePayment`, `postAuthorizePayment`, `updateShippingAddress`, `updateDeliveryMethod`, `checkoutStatusIsReady` |
| `commerce/orderApi` | `OrderAdapter`, `OrdersAdapter`, `OrderItemsAdapter`, `OrderSummaryLookupAdapter` | `startReOrder(options)`, `authorizeOrderSummaryAccess(options)` |
| `commerce/wishlistApi` | `WishlistAdapter`, `WishlistsAdapter` | `createWishlist`, `addItemToWishlist`, `addWishlistToCart` |
| `commerce/promotionApi` | — | `getPromotionPricingCollection` |
| `commerce/recommendationsApi` | `ProductRecommendationsAdapter` (Einstein) | — |
| `commerce/activitiesApi` | — | `trackAddProductToCart`, `trackViewProduct`, `trackClickReco`, `trackViewReco` (Einstein) |
| `commerce/myAccountApi` | — | `updateMyAccountProfile`, `resetPassword` |
| `commerce/actionApi` | — | `createCartItemAddAction`, `createCouponApplyAction`, `createProductSubscriptionUpdateAction` (Data Provider components) |

Cross-namespace: `lightning/uiapi` (LDS), `experience/navigationMenuApi`, `experience/cmsDeliveryApi`.

**Deploy + expose:** SFDX (`sf project deploy start`); `.js-meta.xml` needs `<isExposed>true</isExposed>` + `<targets>` of `lightningCommunity__Page` / `_Page_Layout` / `_Theme_Layout`; add `lightningCommunity__Default` + `<targetConfigs>` to expose editable props in Experience Builder. **LWR templates disable Lightning Locker + Lightning Web Security** — opt into relaxed CSP via `lightningCommunity__RelaxedCSP` under `<capabilities>`. Reference repo: `forcedotcom/commerce-on-lightning-components` (Public Commerce LWR Library — clone-and-customize the OOTB PDP/cart/search components). LWR supports SSR.

**Checkout component customization (LWR):** layout → section → child component tree in Experience Builder. Custom child components implement the **`useCheckoutComponent` mixin** (hooks into form validation + external API sync). Hard rule: cart/checkout-mutating requests must run **sequentially** — concurrent WebCart writes throw **Version Mismatch / Checkout Conflict**. Default section order Shipping Address → Shipping Method → Payment is enforced.

---

## 7. B2B vs D2C — what actually differs

| Dimension | **B2B** | **D2C / B2C** |
|---|---|---|
| Buyer model | Business Account + Contact (+ BuyerAccount; multiple buyers/roles, parent-child accounts) | **Person Account** (one individual = one record), mandatory |
| Access gate | **Entitlement-gated** — nothing visible without an EntitlementPolicy on the buyer group | Open catalog by default (still uses a default buyer group internally) |
| Pricing | negotiated/account price books via BuyerGroup entitlement; tiered common | one standard/list price book; uniform public pricing |
| Guest checkout | optional; **if enabled, B2B guest uses a Person Account too** | native guest browse + checkout |
| Self-registration | creates buyer users on business accounts | creates Person Account shoppers |
| Template / runtime | LWR (or legacy Aura) B2B template | LWR D2C template — **same platform, objects, Storefront APIs** |

The real technical fork is **Person Account vs Business Account + entitlement gating**, not a different runtime. A store created from the LWR template can be either; the org may expose only a "Commerce Store (LWR)" template (often labeled **B2B** even when used for D2C) — the D2C-ness is buyer access + guest, not a separate template.

---

## 8. Payment — `commercepayments` framework

Server-side adapter:
```apex
global class MyAdapter implements commercepayments.PaymentGatewayAdapter {
    global commercepayments.GatewayResponse processRequest(commercepayments.PaymentGatewayContext ctx) {
        switch on ctx.getPaymentRequestType() { /* Tokenize / Authorize / Capture / Refund ... */ }
    }
}
```
Request types (`commercepayments.*`): `PaymentMethodTokenizationRequest`, `AuthorizationRequest`, `CaptureRequest`, `ReferencedRefundRequest`, `SaleRequest`, `AuthorizationReversalRequest`, `PostAuthorizationRequest` (client-side validation). Minimum paved path = **Tokenize + Authorize** (+ Capture + Refund downstream). Responses subclass `commercepayments.GatewayResponse`. Use `CommercePayments.PaymentsHttp` for callouts (auto-attaches the NamedCredential).

Wiring objects:
- **`PaymentGatewayProvider`** — `ApexAdapterId` (→ your adapter class), `IdempotencySupported`, `DeveloperName`. ⚠️ **not Apex-DML-insertable** — create with `sf data create record`.
- **`PaymentGateway`** — `PaymentGatewayProviderId`, `MerchantCredentialId` (→ NamedCredential), `Status`.
- **`PaymentGatewayLog`** — every gateway call, for debugging in the Commerce app.

Connect to store: Commerce app → Store → **Settings | Checkout → Payments** → Salesforce Payments (paved path; adds Apple Pay digital wallet) or Alternate Provider (your adapter). Client-side: shopper posts a tokenized txn directly to the gateway (PCI shifts to provider) → UI calls Checkout Payment API with `requestType=PostAuth` → adapter validates the `PostAuthorizationRequest`. Server-side **pre-authorizes** before order placement; client-side **post-authorizes**. Components do not collect/store card data. 3DS/SCA: not in this guide — confirm against your gateway/Salesforce Payments docs. Apple Pay is the only digital wallet explicitly documented.

---

## 9. Headless verification recipes (Connect API via `sf api request rest`)

`sf api request rest` uses the stored session (token is redacted by `sf org display` but the session works). Storefront cart/checkout endpoints need a **shopper session** (guest/community user), so admin REST returns "Invalid effective accountId" — those must be proven from the live storefront or a guest-session script. But these read endpoints work as admin:

```bash
WS=<webStoreId>; V=v62.0
# product detail incl. images
sf api request rest "/services/data/$V/commerce/webstores/$WS/products/<productId>" -o <org>
# search (what the LIST page reads)
sf api request rest "/services/data/$V/commerce/webstores/$WS/search/products?searchTerm=espresso" -o <org>
# buyer price
sf api request rest "/services/data/$V/commerce/webstores/$WS/pricing/products/<productId>" -o <org>
# rebuild + poll search index
sf api request rest "/services/data/$V/commerce/management/webstores/$WS/search/indexes" --method POST --body "{}" -o <org>
sf api request rest "/services/data/$V/commerce/management/webstores/$WS/search/indexes" -o <org>   # poll indexStatus
# evaluate promotions for a cart (store + buyer group in body)
sf api request rest "/services/data/$V/commerce/promotions/actions/evaluate" --method POST --body @eval.json -o <org>
```
