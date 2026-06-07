## What changed

## Why

## Salesforce validation

- [ ] Static checks passed.
- [ ] Salesforce validation/deploy dry run passed.
- [ ] Apex tests passed.
- [ ] Agentforce smoke checked agent runtime users, topics/actions, and web chat config.
- [ ] Data Cloud smoke checked streams, identity resolution, calculated insights, and augmented fields.

## Risk controls

- [ ] No secrets, keys, auth URLs, or local org cache files committed.
- [ ] Anonymous users cannot access PII/order/account data.
- [ ] Logged-in recognition tested without asking for email.
- [ ] Order status uses Order + FulfillmentOrder + Shipment truth.
- [ ] Coupon behavior verified in WooCommerce cart.
