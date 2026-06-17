# Page layouts, fields, related lists & Dynamic Forms — making things actually visible (DX)

Deploying a custom field does NOT make it appear on a record page. Four independent things must all be true, and they fail silently and separately. This is the checklist + the exact metadata, all DX-deployable.

## The 4 gates a field must pass to be visible

1. **It exists** (field deployed).
2. **FLS** — the running user's profile/permission set grants read (and edit). New metadata-deployed fields are invisible on every profile until granted. SOQL says "No such column"; the field won't render anywhere.
3. **It's placed** — on the **page layout** *(classic layouts)* OR on the **Lightning record page / FlexiPage** *(Dynamic Forms)*. **These are mutually exclusive — see the Dynamic Forms section. This is the #1 gotcha.**
4. **The record page renders it** — the right layout is assigned to the record type/profile, or the FlexiPage is the assigned org/app default.

If a field "isn't showing" and FLS is fine, it's almost always gate 3: **the page uses Dynamic Forms, so your page-layout edit is ignored.**

## Gate 2 — FLS via a permission set (DX)

Don't hand-edit profiles. Generate one permission set granting FLS to all the new fields and assign it:

```xml
<!-- Field_Visibility.permissionset-meta.xml -->
<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
  <label>Field Visibility</label>
  <hasActivationRequired>false</hasActivationRequired>
  <fieldPermissions>
    <field>Account.Churn_Score__c</field>
    <readable>true</readable>
    <editable>true</editable>   <!-- MUST be false for formula/rollup/autonumber -->
  </fieldPermissions>
  ...
</PermissionSet>
```
```bash
sf project deploy start -d .../Field_Visibility.permissionset-meta.xml -o ORG
sf org assign permset --name Field_Visibility -o ORG
```
Rules learned the hard way:
- **`editable` must be `false`** for non-updateable fields (formula, rollup-summary, auto-number) or deploy errors.
- **Skip required + master-detail fields** — they're always visible and can't take a FieldPermissions row ("cannot deploy to a required field: Lead.Status"). Filter to `__c` custom fields only; a standard-field customization file (e.g. `Lead/fields/Status.field-meta.xml`) is NOT a custom field — its name doesn't end in `__c`.

## Gate 3a — classic page layout (non-Dynamic-Forms objects)

Layouts live in `force-app/main/default/layouts/<Object>-<Layout Name>.layout-meta.xml`. **Retrieve the real layout first** (don't author blind — you'll clobber related lists/buttons):
```bash
sf project retrieve start --metadata "Layout:Account-Account Layout" -o ORG
```
Add a section with your fields (read-only for formula/rollup/autonumber):
```xml
<layoutSections>
  <customLabel>true</customLabel><detailHeading>true</detailHeading><editHeading>true</editHeading>
  <label>Custom Fields</label>
  <layoutColumns>
    <layoutItems><behavior>Edit</behavior><field>Churn_Score__c</field></layoutItems>
    <layoutItems><behavior>Readonly</behavior><field>Value_At_Risk__c</field></layoutItems>
  </layoutColumns>
  <layoutColumns>...</layoutColumns>
  <style>TwoColumnsTopToBottom</style>
</layoutSections>
```
- `behavior`: `Edit` | `Readonly` | `Required`. A standard required field on the layout **must** be `Required` (e.g. `Shipment.ShipToName` → deploy error "must be Required" otherwise).
- Person Accounts use a **separate** layout: `PersonAccount-Person Account Layout`. Add fields there too — the business-account layouts don't drive Person Accounts.
- Objects with 4 layouts (Account/Lead/Case: default + Marketing/Sales/Support) — add to all so it shows regardless of which profile/record-type assignment is in effect.

## Gate 3b — Dynamic Forms (CHECK THIS FIRST)

**Always determine the page type before editing layouts.** If the record page uses Dynamic Forms, the page layout is ignored for fields and your layout edit does nothing.

Detect it — retrieve the Lightning record page and inspect:
```bash
sf org list metadata --metadata-type FlexiPage -o ORG    # find <Object>_Record_Page
sf project retrieve start --metadata "FlexiPage:Account_Record_Page" -o ORG
```
```bash
grep -c 'flexipage:fieldSection' .../Account_Record_Page.flexipage-meta.xml   # >0  → Dynamic Forms (fields on the FlexiPage)
grep -c 'force:recordDetail'     .../Account_Record_Page.flexipage-meta.xml   # >0  → classic (renders the page layout)
```
- `flexipage:fieldSection` + `fieldInstance` present → **Dynamic Forms**: add fields to the FlexiPage (below).
- `force:recordDetail` present (no fieldSections) → classic: the page layout drives it (gate 3a).

### Adding fields to a Dynamic Forms FlexiPage

Fields live inside **Facet** regions referenced by `flexipage:fieldSection` components (`columns` property = `Facet-<uuid>`). Append `fieldInstance`s into an existing custom-field facet (lowest risk), matching the org's EXACT format:
```xml
<itemInstances>
  <fieldInstance>
    <fieldInstanceProperties><name>uiBehavior</name><value>none</value></fieldInstanceProperties>
    <fieldItem>Record.Churn_Score__c</fieldItem>
    <identifier>RecordChurn_Score_cField</identifier>
  </fieldInstance>
</itemInstances>
```
**The two rules that cause the cryptic `"The Record.X field isn't allowed in the <Facet> region"` error** (which does NOT mean the field is disallowed):
1. **Identifier format is mandatory:** `Record` + fieldApiName with `__c`→`_c` + `Field` → `Account.Churn_Score__c` ⇒ `RecordChurn_Score_cField`. A malformed identifier (e.g. `my_Churn_Score__c`) yields that exact misleading error.
2. **`<uiBehavior>` must be present:** `none` (editable), `readonly` (formula/rollup/autonumber), or `required`.
Also: a field already placed anywhere on the page can't be added again (genuine duplicate → same error). De-dupe against existing `<fieldItem>Record.X</fieldItem>`.

**The structure: a field SECTION is a 2-column wrapper, and fields live in its inner COLUMN facets — not the section facet.** A `flexipage:fieldSection` componentInstance's `columns` property points to an outer **section facet**; that section facet contains `flexipage:column` components whose `body` property each points to an **inner column facet** (`Facet-...`); the `fieldInstance`s live in those inner column facets. So an *empty* named section (e.g. "Additional Information") shows `0 fields` on its section facet but already has two pre-registered empty column facets ready to receive fields. **Append your `fieldInstance`s into the inner column facets** (split across the two for balance) — that deploys cleanly. Appending to the section/outer facet instead fails with `"field isn't allowed in the region"`. Map it with: section's `columns` → outer facet → its `flexipage:column` `body` values → inner column facets.

**Do NOT try to create a brand-new section via raw metadata.** A new section in principle needs a new `flexiPageRegions` Facet + a `flexipage:fieldSection` componentInstance referencing it (`columns` = new facet name) in the Details-tab column. **But in practice this is rejected** — even a verbatim clone of a working section, with correct identifiers, no duplicates, well-formed XML, and the facet positioned among the others, fails `--dry-run` with the SAME misleading `"The Record.X field isn't allowed in the <Facet> region"`. The new facet GUID isn't "registered" the way App Builder registers it. Confirmed by exhaustive bisection (1 field, 1 section, repositioned facet, real GUID — all rejected; appending the identical field to an *existing* facet succeeds). **So: to add fields, append to an existing section's facet. To get a NEW labeled section, use Lightning App Builder (UI) — it's the one genuinely UI-only step here — or repurpose/rename an existing custom section's `label`.** Watch for the duplicate trap: the org's deployed page already holds the fields you added before, so on each retrieve you must STRIP a field from its current facet before placing it elsewhere, or you get the same "isn't allowed" error from the genuine duplicate.

> A custom `Account_Record_Page` serves **both** business and person accounts — one edit covers both.

## Related lists (child objects on the parent record)

Related lists render on a Lightning page's **Related** tab via the `force:relatedListContainer`, which reads the **page layout's `<relatedLists>`** — so even on a Dynamic Forms page, related lists come from the *layout*, not the FlexiPage. Add them to the parent layout.

1. **Find the exact related-list name** from the parent's childRelationships (don't guess):
```bash
sf api request rest "/services/data/v62.0/sobjects/Account/describe" -o ORG \
 | python3 -c "import sys,json;[print(c['childSObject']+'.'+c['field']) for c in json.load(sys.stdin)['childRelationships'] if c.get('field','').endswith('__c')]"
```
The related-list name = **`ChildObject.LookupField`** (e.g. `Cart__c.Customer__c`, `Shipment.Order__c`).

2. **Add to the layout** (de-dupe against existing):
```xml
<relatedLists>
  <fields>NAME</fields>
  <fields>Status__c</fields>
  <fields>Cart_Value__c</fields>
  <relatedList>Cart__c.Customer__c</relatedList>
</relatedLists>
```
`<fields>` come **before** `<relatedList>`.

### Related-list columns — the token rules (this trips everyone)
- **Custom object children:** `NAME` for the record name + custom field **API names** (`Status__c`, `Cart_Value__c`). Reliable.
- **Standard fields on standard children** use **legacy tokens**, not API names: `CASES.CASE_NUMBER`, `CASES.SUBJECT`, `CASES.STATUS`, `CASES.PRIORITY`, `CONTACT.EMAIL`, `OPPORTUNITY.STAGE_NAME`. Learn them by grepping an existing related list in a retrieved standard layout.
- **`NAME` is NOT valid for some standard children.** `Lead`, `Shipment`, `ReturnOrder` reject `NAME` / `LEAD.NAME` / `ShipmentNumber` in a *custom* related list. For these, **lead with their custom `__c` fields** (always valid) and skip the name token — Lightning still renders a link to the record.
- **Always `--dry-run` first** to surface bad tokens before committing — the error names the exact field + related list:
```bash
sf project deploy start -d "<layout files>" -o ORG --dry-run --wait 15 --json
```

## List views (DX) — the token rules (mirror the related-list ones)
List views live at `objects/<Object>/listViews/<Name>.listView-meta.xml`. `<columns>` and `<filters><field>` use the **same legacy `OBJECT.FIELD` tokens** as related-list columns, NOT API names — and getting them wrong fails `--dry-run` with `Could not resolve list view column: <token>`.
- **Standard fields on a standard object** → `OBJECT.FIELD` legacy token: `ASSET.STATUS`, `ASSET.QUANTITY`, `ASSET.USAGE_END_DATE`, `ASSET.NAME`, `CASES.CASE_NUMBER`, `CASES.STATUS`. The object prefix is the legacy plural-ish token (`CASES`, `ASSET`) — `Asset.Status` (object API name) and bare `NAME`/`STATUS` both FAIL on Asset.
- **Lookups** → `ACCOUNT.NAME`, `OWNER_NAME`, `CORE.USERS.ALIAS`.
- **Custom fields** → the full `Object.Field__c` (e.g. `Account.Churn_Risk_Tier__c`) — these resolve fine with the object prefix.
- **Date filters** take literals: `value` = `NEXT_N_DAYS:60` / `LAST_N_DAYS:30`, operation `lessOrEqual`/`equals`.
- **`filterScope`**: `Everything` (all records). A list view with NO `<columns>` deploys (uses defaults) — but a bad `<filters><field>` token still fails as a "column".
- **Learn the exact tokens** by retrieving a rich existing list view on a standard object (e.g. `ListView:Case.AllOpenCases`) and copying its `<columns>`/`<filters>` verbatim — don't guess.
- **Not every child is addable as a related list:** `RelatedMaintenancePlanList` (and the `MaintenancePlan.AccountId` form) are both rejected on the Account layout — some standard children simply have no Account related-list token. `RelatedAssetList` + `RelatedServiceContractList` work.

## Organizing a layout well (sections)

- Group related fields into labeled `<layoutSections>` with `<style>TwoColumnsTopToBottom</style>` (balanced two-column) rather than one giant section. Common groupings: *Identity/Integration*, *Status/Fulfillment*, *Financials*, *AI & Insights*, *System*.
- Put **read-only signals** (scores, Data-Cloud-cached fields, formulas) in their own "Insights" section, all `Readonly`.
- Lead with the record's key/identifier fields; push audit/system fields (`Last_*__c`, `*_Sync__c`) to the bottom.
- On Dynamic Forms pages, the same grouping is achieved with multiple `flexipage:fieldSection`s, each pointing to its own facet; you can also use **field visibility rules** on a section (component `visibilityRule`) — e.g. show the "Win-back" section only when `Churn_Risk_Tier__c = 'A'`.

## Tabs for a standard object (no CustomTab)

You can't create a `CustomTab` for a standard object. Make its standard tab visible via a permission set and it appears in the App Launcher:
```xml
<tabSettings><tab>standard-Shipment</tab><visibility>Visible</visibility></tabSettings>
```
(`Visible` deploys as `DefaultOn`.) To pin it into an app's nav bar, edit that `CustomApplication`'s `<tabs>` list (`standard-Shipment`).

## The reliable workflow (every time)

1. Deploy field → **deploy + assign an FLS permission set**.
2. **Check the page type** (FlexiPage Dynamic Forms vs classic) — don't assume.
3. Place the field: layout section *or* FlexiPage facet (correct identifier + uiBehavior).
4. Add related lists to the **layout** (names from childRelationships; columns per the token rules).
5. **`--dry-run` validate**, then deploy. Confirm async deploys with `sf project deploy report`.
6. Hard-refresh the record page.
