# Agentforce and Data 360 Consumption Cost Calculator

Research date: June 12, 2026.

Files:

- `docs/agentforce-data360-cost-calculator.html`
- `docs/AGENTFORCE_DATA360_COST_CALCULATOR.md`

## What the Calculator Covers

The calculator now starts with an executive planning flow instead of a full billing-table workflow. It estimates Salesforce consumption cost across the most common Agentforce and Data 360 purchasing patterns:

- Agentforce Flex Credits per action
- Agentforce Conversations at a flat customer-facing conversation price
- Agentforce user and edition fixed costs
- Data 360 Flex Credits with the current tiered rate card
- Data 360 Profiles and Enterprise Profiles
- Legacy Data Services Credits for older Data Cloud contracts

It is a planning estimator, not a Salesforce quote. Use your order form, Salesforce account team, and Digital Wallet for actual billing. The right way to use it is:

1. Pick the project shape.
2. Enter only the big business drivers you know.
3. Use the low, expected, and high range for the business case.
4. Run a small pilot.
5. Replace assumptions with Digital Wallet usage after 30 days.

## Current Salesforce Billing Logic Used

### Agentforce Flex Credits

Salesforce prices current Flex Credits publicly at `$500 per 100,000 Flex Credits`. The April 21, 2026 Flex Credits Rate Card lists these Agentforce multipliers:

- Standard Action: `20` credits in production, `16` in sandbox
- Custom Action: `20` credits in production, `16` in sandbox
- Standard Voice Action: `30` credits in production, `24` in sandbox
- Custom Voice Action: `30` credits in production, `24` in sandbox
- Starter Prompts: `2`
- Basic Prompts: `2`
- Standard Prompts: `4`
- Advanced Prompts: `16`

Formula:

```text
Monthly Agentforce Flex Credits =
monthly work items
* (
  standard actions per item * action multiplier
  + voice actions per item * voice multiplier
  + starter prompts per item * 2
  + basic prompts per item * 2
  + standard prompts per item * 4
  + advanced prompts per item * 16
)
```

### Agentforce Conversations

Salesforce lists Agentforce Conversations at `$2 USD per conversation`. The pricing page says Flex Credits and Conversation pricing are not supported in the same org, so the calculator lets you choose one model while showing the other as a comparison.

Formula:

```text
Annual Conversation Cost =
monthly conversations * 12 * conversation price
```

### Data 360 Flex Credits

Salesforce now refers to Data Cloud as Data 360 in current pricing pages. Public current list pricing is `$500 per 100,000 Flex Credits`, and Salesforce says Flex Credits can be used across Data 360 and Agentforce.

The current Data 360 rate card has production volume tiers per usage type. The tiers reset monthly and are applied independently by usage type:

- Base tier: up to `300,000` credits
- Tier 2: `300,000` to `1,500,000` credits
- Tier 3: `1,500,000` to `12,500,000` credits
- Tier 4: after `12,500,000` credits

Sandbox and other pre-production environments use the sandbox multiplier and do not use tiered multipliers.

Formula:

```text
Units = monthly quantity / rate card unit
Credits = units * multiplier
```

For tiered production usage, the calculator fills each tier by credit capacity before moving to the next tier.

### Data 360 Profile Pricing

Salesforce lists:

- Profiles: `$240 per 1,000 profiles/year`, with `1 Flex Credit per profile`
- Enterprise Profiles: `$420 per 1,000 profiles/year`, with `2 Flex Credits per profile`

Salesforce describes profile pricing as un-metering the usage types used to form unified profiles. Flex Credits still apply to non-profile use cases such as querying data or unstructured data processing for AI agents. The calculator therefore includes checkboxes to decide whether Prep, Unification, and Segmentation rows should be treated as bundled for the scenario.

### Legacy Data Services Credits

Salesforce says existing Data Services Credit customers are not forced to migrate. The calculator includes a legacy mode using the 2025 Salesforce Customer Data Cloud rate sheets for Data Services Credits. Legacy pricing varies by contract, so the calculator exposes a separate price per 100,000 Data Services Credits field.

## Factors Salesforce Usually Considers

Agentforce:

- Number of conversations, cases, calls, tasks, or other work items
- Number of actions per work item
- Whether actions are standard, custom, or voice actions
- Prompt tier and prompt count
- Whether the use case is customer-facing, employee-facing, or covered by a user/edition SKU
- Included credits, no-rollover terms, and contracted Flex Credit rate

Data 360:

- Usage type, for example prep, unification, segmentation, activation, query, streaming, real-time, unstructured, or intelligent processing
- Rows, MB, events, API calls, actions, or compute units processed
- Refresh frequency
- Batch versus streaming architecture
- Whether profile pricing bundles profile-building usage
- Storage, premium add-ons, Digital Wallet alerts, and other fixed SKUs

## Source Links

- Salesforce Agentforce Pricing: https://www.salesforce.com/agentforce/pricing/
- Salesforce Flex Credits Rate Card, updated April 21, 2026: https://www.salesforce.com/en-us/wp-content/uploads/sites/4/assets/pdf/agentforce/Flex-Credits-Rate-Card-04.21.2026.pdf
- Salesforce Data 360 Pricing: https://www.salesforce.com/data/pricing/
- Salesforce Data 360 Pricing Calculator: https://www.salesforce.com/data/pricing/calculator/
- Salesforce Customer Data Cloud legacy Data Services rate card, last updated July 2025: https://www.salesforce.com/en-us/wp-content/uploads/sites/4/documents/platform/data-cloud-platform-services-rate-sheet.pdf
- Salesforce Customer Data Cloud legacy Data Services and Segmentation/Activation rate card, last updated August 2025: https://www.salesforce.com/en-us/wp-content/uploads/sites/4/documents/platform/data-cloud-platform-services-rate-sheet-dc-9-04.pdf
- Trailhead Data 360 Credit Consumption: https://trailhead.salesforce.com/content/learn/modules/data-cloud-credit-consumption-quick-look/get-started-with-data-cloud-credit-consumption

## Layout and Usability Notes

The HTML file was redesigned to avoid the original spreadsheet-like first screen. The default view now asks for only the major drivers:

- Monthly conversations or work items
- Agent actions per work item
- Percentage of work needing Data 360 context
- Customer profile count
- Source count
- Refresh frequency
- Real-time events
- Unstructured content volume
- Known contract numbers

Detailed Salesforce rates are still available, but they are collapsed in an advanced assumptions section.

## Font and Compatibility Notes

The HTML file is standalone and uses no external CSS, JavaScript, font, or icon dependency. The font stack starts with `Salesforce Sans` if it is available locally, then falls back to `Inter`, system UI fonts, `Segoe UI`, `Arial`, and generic sans-serif.

The calculator should work by opening the HTML file directly in a modern browser. It also supports printing to PDF from the browser.
