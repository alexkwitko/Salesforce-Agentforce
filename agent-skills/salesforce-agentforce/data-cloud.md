# Data Cloud — API-first (not screen-only)

Most Data Cloud modeling that people assume is UI-only is actually DX-deployable or Connect-API-driven. Know what IS and ISN'T.

## Object vocabulary
- **DLO** — Data Lake Object, suffix `__dll` (e.g. `Account_Home__dll`). Raw ingested data from a data stream.
- **DMO** — Data Model Object, suffix `__dlm` (e.g. `ssot__Individual__dlm`, `ssot__ContactPointEmail__dlm`). The modeled/standard layer.
- **CI** — Calculated Insight, the CI *object* suffix is `__cio` (e.g. `Order_Patterns_by_Demographics__cio`).
- **Unified DMO** — output of Identity Resolution, e.g. `UnifiedssotIndividual...__dlm`.

## Metadata types that ARE DX-deployable
- `MktDataLakeObject` (DLO) / `MktDataModelObject` (DMO) — model definitions where exposed.
- **`ObjectSourceTargetMap`** — DLO→DMO field + relationship maps (`objectSourceTargetMaps/`). Fully retrieve/edit/deploy-able.
- `DataSrcDataModelFieldMap` — field-level source→model mapping.
- **`MktCalcInsightObjectDef`** — a Calculated Insight; the SQL lives in `<expression>` (`mktCalcInsightObjectDefs/`).
- `DataCalcInsightTemplate`, `DataStreamDefinition` (for already-provisioned streams).

## What is UI-ONLY (no metadata path)
- **Creating a NEW Salesforce-CRM data stream.** Deploying a `DataStreamDefinition` for a not-yet-existing source object fails with `no MktDataTranObject named <X>_Home found`. The Data Source Object + its DLO are provisioned by the Data Cloud connector UI (it reads the source object's schema at setup). Create the stream via: App Launcher → Data Cloud → Data Streams → New → Salesforce CRM → View Objects → pick objects → category + event-time field → Deploy.
- **Adding a new custom field to an existing stream's DLL** — re-map in the data stream (UI).
- **The Identity Resolution ruleset's nested `matchRules` schema** is undocumented and errors are opaque (`UNKNOWN_EXCEPTION`) — create the ruleset in the UI (~5 clicks), then drive *runs* via the API.

## DLO→DMO mapping — Connect REST API FIRST (not metadata for connector DLOs)

**⭐ Use the Data 360 Connect REST API to create DLO→DMO mappings directly — it's the cleanest no-UI path, and for connector-generated DLOs (Web/Mobile App, etc.) the metadata `ObjectSourceTargetMap` deploy often throws an opaque server Gack** (`An unexpected error occurred… ErrorId: …`), especially when the target is **`ssot__Individual__dlm`**. (Observed: `ContactPointEmail` map deploys via metadata, the sibling `Identity → Individual` map Gacks every time, even stripped to one field. Don't burn time retrying the metadata path — switch to the REST API.)

```bash
# Discover the connector's DLO names + field developer names
sf api request rest "/services/data/v62.0/ssot/metadata?entityType=DataLakeObject" --target-org ORG   # names + fields[].name + primaryKeys
# (or the v66 list endpoint: /services/data/v66.0/ssot/data-lake-objects )

# CREATE the mapping (one POST per DLO→DMO pair)
sf api request rest "/services/data/v66.0/ssot/data-model-object-mappings?dataspace=default" \
  --method POST --target-org ORG --body '{
    "sourceEntityDeveloperName": "Kwitko_Storefront_identity_98754656__dll",
    "targetEntityDeveloperName": "ssot__Individual__dlm",
    "fieldMapping": [
      { "sourceFieldDeveloperName": "deviceId__c",  "targetFieldDeveloperName": "ssot__Id__c" },
      { "sourceFieldDeveloperName": "firstName__c", "targetFieldDeveloperName": "ssot__FirstName__c" },
      { "sourceFieldDeveloperName": "lastName__c",  "targetFieldDeveloperName": "ssot__LastName__c" }
    ]
  }'

# VERIFY
sf api request rest "/services/data/v66.0/ssot/data-model-object-mappings?dataspace=default" --method GET --target-org ORG
```
Notes:
- **`?dataspace=default`** (or your data space) is required.
- Field/object args are **developer names** (`*__dll`, `*__dlm`, `*__c`) — discover the real DLO field names from the org (connector DLOs carry many `cdp_sys_*` + plumbing fields; map only identity keys + attributes).
- **Web-connector identity model:** map `deviceId__c → ssot__Id__c` on Individual; on ContactPointEmail map `email__c → ssot__EmailAddress__c`, `deviceId__c → ssot__PartyId__c` (and `→ ssot__Id__c`). Then Identity Resolution merges by **Email Address** across web + CRM sources.
- `ObjectSourceTargetMap` metadata is still the right tool for **CRM** DLOs and for source-control/repeat deploys; the Connect API is for creating/updating mappings directly, and is the fallback when metadata Gacks.
- Sources: Data 360 Connect API DMO use-case + `/ssot/data-model-object-mappings` spec.

## DLO→DMO mapping (DX metadata or one-click UI)

UI one-click: on the DLO detail page → Data Mapping → Start → Select Objects → Custom Data Model → "New Custom Object" auto-creates a DMO with all DLO fields + types and auto-maps them. Einstein also auto-maps standard DMO fields (Individual, Contact Point Email) when you add them.

Field-name conventions after auto-map: source field API names get a `_c__c` suffix (e.g. `Age_Group_c__c`), the autonumber Name becomes `Name__c`. Use the CI editor's **Insert** button on a field to learn the exact reference string.

`ObjectSourceTargetMap` shape (each `<fieldSourceTargetMaps>` = one field link; the same source field can map to multiple targets, e.g. both `ssot__Id__c` and `ssot__PartyId__c`):
```xml
<ObjectSourceTargetMap xmlns="http://soap.sforce.com/2006/04/metadata">
  <creationType>Standard</creationType>
  <fieldSourceTargetMaps>
    <sourceField>Account_Home__dll.PersonEmail__c</sourceField>
    <targetField>ssot__ContactPointEmail__dlm.ssot__EmailAddress__c</targetField>
    <filterApplied>false</filterApplied>
    <filterOperationType>Equal</filterOperationType>
  </fieldSourceTargetMaps>
  <sourceObjectName>Account_Home__dll</sourceObjectName>
  <targetObjectName>ssot__ContactPointEmail__dlm</targetObjectName>
</ObjectSourceTargetMap>
```
> **Tip:** to make the Individual DMO selectable in the Identity Resolution wizard, the ContactPointEmail map needs a RELATIONSHIP to Individual — add `<sourceField>...Id__c</sourceField> → ssot__ContactPointEmail__dlm.ssot__PartyId__c` and redeploy; the wizard's "required fields mapped" warning then clears.

## ⚠️ The empty-identity-key gotcha (0 unified profiles)

**Symptom:** Identity Resolution reads all source profiles but produces **0 unified** rows. The match rule can never form because the identity keys are empty.

**Root cause:** the Individual PK (`ssot__Individual__dlm.ssot__Id__c`) and the email→individual link (`ssot__ContactPointEmail__dlm.ssot__PartyId__c`) were sourced from an **EMPTY** DLO field (e.g. `Account_Home__dll.PersonIndividualId__c`, which is never populated for Person Accounts) instead of a populated one.

**Fix (metadata, deployable):** re-point both maps to a POPULATED field — `Account_Home__dll.Id__c` holds the real id:
- Individual map: `Id__c → ssot__Individual__dlm.ssot__Id__c`
- ContactPointEmail map: `Id__c → ssot__ContactPointEmail__dlm.ssot__PartyId__c` (and also `→ ssot__Id__c`)

After deploy, the DLO→DMO reprocess populates the keys, and IR `run-now` is accepted (no longer `NoPendingChangesJobRunSkipped`).

**Verify:**
```bash
sf api request rest "/services/data/v62.0/ssot/query-sql" --method POST \
  --body '{"sql":"SELECT COUNT(*) FROM UnifiedssotIndividual...__dlm"}'   # should be > 0, was 0
```

## Connect REST endpoints (drive via `sf api request rest`)

```bash
# List DMOs
sf api request rest "/services/data/v62.0/ssot/metadata?entityType=DataModelObject"

# Identity Resolution: list / get / RUN (note the exact action path + empty body)
sf api request rest "/services/data/v62.0/ssot/identity-resolutions"
sf api request rest "/services/data/v62.0/ssot/identity-resolutions/<id>"
sf api request rest "/services/data/v62.0/ssot/identity-resolutions/<id>/actions/run-now" --method POST --body '{}'
#   ^ path is /actions/run-now with body {} — NOT /actions/run

# Calculated Insight: RUN
sf api request rest "/services/data/v62.0/ssot/calculated-insights/<apiName>/actions/run" --method POST --body '{}'

# Ad-hoc SQL query (DLM / DLL / CIO)
sf api request rest "/services/data/v62.0/ssot/query-sql" --method POST \
  --body '{"sql":"SELECT AccountId__c FROM Customer_Agent_Profile__cio LIMIT 5"}'
```
From Apex, the same query path is `ConnectApi.CdpQueryInput` / `ConnectApi.Cdp...` (a JOIN example is in the Calculated Insight section below).

## Identity Resolution rulesets — create/update/run WITHOUT (or with partial) UI

**IR rulesets ARE officially API-manageable** — do NOT assume match/reconciliation rules are UI-only. Two supported channels:
- **Connect REST API:** `GET`/`POST`/`PATCH` on `/services/data/vXX.0/ssot/identity-resolutions[/<id>]`, and run via `/<id>/actions/run-now` (body `{}`).
- **Apex:** `ConnectApi.CdpIdentityResolution` (create/get/update/delete/run).

**The safe pattern (don't hand-author the nested rule JSON blind — it's touchy and errors are opaque):**
1. Create ONE good ruleset in the UI **once** (or use the org's existing one).
2. `GET` it via Connect REST → save that JSON as your **template** (note: the GET *output* rep differs from the create/update *input* rep, like DLO→DMO maps — round-tripping may need key tweaks).
3. Edit the template (add a `matchRules[].criteria[]` entry) and `PATCH`/recreate in repeatable envs. Then `run-now`.

**Channel split (memorize):**
- **DLO→DMO mapping** (incl. putting a field like `deviceId` onto a DMO so IR can match on it): **Metadata API / DX** via `ObjectSourceTargetMap` (+ `MktDataTranObject` for the DMO itself). This is the DX path.
- **Run IR / get IR:** Connect REST / CLI (`run-now`).
- **Create/update match + reconciliation rules:** Connect REST or Apex `ConnectApi.CdpIdentityResolution`, **starting from an exported working payload.**
- **Data 360 "Direct API" does NOT include IR rulesets** — wrong tool for this; use Connect REST/Apex.

**Match-criteria prerequisite:** a criterion's `entityName`+`fieldName` must reference a field that actually EXISTS on an IR-eligible DMO (Individual, Contact Point Email/Phone/Address, Party Identification, Contact Point App). To match on `deviceId`, first **map deviceId onto one of those DMOs** (e.g. Party Identification / Contact Point App) via `ObjectSourceTargetMap` — otherwise the rule has no field to point at. IR is rules-based matching/reconciliation — **no Agentforce/predictive AI needed** (fuzzy matching uses Salesforce's built-in algorithms).

**Repo-specific gotcha (still applies):** map POPULATED identity keys first — `Account_Home.Id__c → Individual.Id` and `Account_Home.Id__c → ContactPointEmail.PartyId` — *then* run IR. Empty keys or a missing ContactPointEmail→Individual relationship silently yield **0 unified profiles** with almost no error feedback.

Sources: Data 360 custom app dev (`developer.salesforce.com/docs/data/data-cloud-dev/guide/custom-app-dev.html`), IR run-now endpoint (`developer.salesforce.com/docs/marketing/marketing-cloud-growth/guide/mc-manage-identity-resolution-run-now.html`).

### ⭐ Web SDK anonymous→known device stitch — 100% DX, NO connector wizard, NO UI, NO custom Apex

The cross-device "anonymous device → later identifies → all prior anonymous browsing retroactively attributes to the person" behavior does **NOT** require the connector Data-Mapping wizard, a `deviceId` Identity-Resolution match rule, a `ContactPointApp` DMO, or a custom Apex stitch. It's achievable with **two `ObjectSourceTargetMap` metadata maps + a `run-now`**, reusing the standard email match rule. The trick is **keying the SDK source Individual by `deviceId`**:

1. **SDK identity stream → `ssot__Individual__dlm`**, mapping `<sdk_identity_dll>.deviceId__c → ssot__Individual__dlm.ssot__Id__c`. Every device becomes a source Individual keyed by its deviceId (anonymous ones included).
2. **SDK contactPointEmail stream → `ssot__ContactPointEmail__dlm`**, mapping `email__c → ssot__EmailAddress__c`, **`deviceId__c → ssot__Id__c` AND `deviceId__c → ssot__PartyId__c`** (+ the System `DataSource__c`/`DataSourceObject__c` maps). PartyId=deviceId links the contact point back to the device-Individual.
3. **Run IR** (`/identity-resolutions/<id>/actions/run-now`, body `{}`).

How the stitch then happens with the **existing** `Fuzzy Name + Normalized Email` rule (no new rule needed):
- Anonymous browsing → a device-Individual keyed by deviceId, no email yet → stays anonymous.
- On identify, an SDK `contactPointEmail` event lands (email + that deviceId) → the device-Individual now has a ContactPointEmail with the email → the **email match rule unifies the device-Individual with the CRM Account-Individual that shares that email** → every event under that deviceId-Individual rolls up to the customer's unified profile.
- **Cross-device falls out for free:** two devices, same email at login → two deviceId-Individuals, each with the same email contact point → both unify into the one customer. No deviceId match rule required.

Verify (all DX): `SELECT ssot__Id__c FROM ssot__Individual__dlm WHERE ssot__Id__c='<deviceId>'`, the ContactPointEmail PartyId=deviceId row, and after the run the unified link DMO (`UnifiedLinkssot...__dlm`) tying the deviceId source to the unified individual. Watch the **empty-key gotcha**: if `deviceId__c`/`email__c` are blank in the source, you get 0 stitches with no error. A `deviceId` match rule on `ssot__ContactPointApp__dlm.ssot__DeviceId__c` is only needed for stitching two devices that are BOTH still anonymous (rare) — skip it otherwise. This whole flow is DX: maps deploy via `sf project deploy`, IR runs via `run-now`. The lesson: **research the supported primitive (here, deviceId-keyed Individual + the standard email rule) before concluding "UI-only."**

## Calculated Insight SQL — strict rules (hard-won)

A CI can read a `__dll` (DLO) **directly** — no DLO→DMO map required for analytics CIs:
```sql
SELECT AccountId__c, Status__c, count(Id__c) AS ReturnCount__c, max(CreatedDate__c) AS LastReturnDate__c
FROM ReturnOrder_Home__dll GROUP BY AccountId__c, Status__c
```

Rules the engine enforces (each violation has a distinct, confusing error):
- **No table aliases.** `FROM dmo AS x` fails (`DMO <alias> is not listed in factTables`). Qualify every field with the FULL DMO/DLO API name, e.g. `Order_Analytics_c_Home__dlm.Age_Group_c__c`.
- **Output aliases must end in `__c`**, e.g. `... AS AvgOrderValue__c` (else `Invalid Attribute name, must be ended with __c`).
- **Currency-typed source fields must be wrapped in `TRY_CONVERT_CURRENCY`** in any aggregation: `avg(TRY_CONVERT_CURRENCY(dmo.Amount__c, 'USD', 'USD'))`. Signature `(Number, sourceISO, targetISO-literal)`; the 3rd arg MUST be a string literal. Plain `avg(dmo.Amount__c)` fails ("must be wrapped by TRY_CONVERT_CURRENCY()").
- **A target-currency dimension is required in BOTH SELECT and GROUP BY.** Add `'USD' AS CurrencyCode__c` to SELECT and the literal `'USD'` to GROUP BY. Neither a SELECT-only literal nor the source-currency field satisfies it.
- Counting rows over a NON-currency field (`count(dmo.SomeText__c)`) avoids the currency-wrap requirement for the count measure.

Working CI (`MktCalcInsightObjectDef`):
```xml
<MktCalcInsightObjectDef xmlns="http://soap.sforce.com/2006/04/metadata">
  <creationType>Custom</creationType>
  <expression>SELECT Order_Analytics_c_Home__dlm.Age_Group_c__c AS AgeGroup__c,
    'USD' AS CurrencyCode__c,
    count(Order_Analytics_c_Home__dlm.Age_Group_c__c) AS OrderCount__c,
    avg(TRY_CONVERT_CURRENCY(Order_Analytics_c_Home__dlm.Order_Amount_c__c,'USD','USD')) AS AvgOrderValue__c
    FROM Order_Analytics_c_Home__dlm
    GROUP BY Order_Analytics_c_Home__dlm.Age_Group_c__c, 'USD'</expression>
  <masterLabel>Order Patterns by Demographics</masterLabel>
</MktCalcInsightObjectDef>
```
> Avoid currency machinery entirely by making the source CRM field a plain **Number** before ingestion — DMO field types are inherited from the DLO/CRM field and are NOT editable after creation.

## Consuming Data Cloud from an agent (Apex)
The unified profile the agents actually read is a JOIN of ContactPointEmail → Individual on the resolved key, run via `ConnectApi.CdpQueryInput`:
```sql
SELECT cpe.ssot__EmailAddress__c, ind.ssot__Id__c, ind.ssot__FirstName__c
FROM ssot__ContactPointEmail__dlm cpe
JOIN ssot__Individual__dlm ind ON ind.ssot__Id__c = cpe.ssot__PartyId__c
WHERE cpe.ssot__EmailAddress__c = '...'  LIMIT 1
```
Calculated-Insight CIOs (`*__cio`) are also queryable per record (`SELECT ... FROM Customer_Agent_Profile__cio WHERE AccountId__c = '...'`). Always `String.escapeSingleQuotes` interpolated values, wrap in try/catch, and stub query results in tests.

## Predictive (Einstein Studio) + web engagement
For the full playbook — Model Builder UI flow, predict jobs (streaming-vs-batch + the **Run**
action), the prediction output-DMO schema, writing scores back via the PK join (and the
`ConnectApi.CdpQuery` JOIN-returns-0 gotcha), the custom-Apex-REST engagement route vs the Web SDK
connector, `MktCalcInsightObjectDef` deploying "Succeeded" but never provisioning, the DLO→DMO
mapping modal's 60–120 s load, and the **5 MB storage trap** (transient rows, `emptyRecycleBin`
200-cap, recalc lag, silent `STORAGE_LIMIT_EXCEEDED` behind an HTTP 200) — see
**`predictive-and-engagement.md`**.

## Operational notes
- Data streams auto-refresh on schedule — do NOT manually refresh via the screen.
- A manual FULL refresh on big Order/OrderItem streams can fail under contention; incremental keeps them current.
- Recommendations in this build run in CRM (Apex affinity engine), not Data Cloud; the demographic CI is analytics, not the recommender.

## Surfacing Calculated Insights + related objects on the Unified Individual (Profile Explorer)

**A CI appears on the Unified Individual profile ONLY if it is keyed on the Unified Individual Id** — i.e. a dimension that resolves to `UnifiedssotIndividual<space>__dlm.ssot__Id__c` (the unified id), NOT a source `AccountId`/text field. Source-keyed CIs compute fine but **never show in Profile Explorer's Calculated Insights panel** (this is the #1 "no calculated insight to display" cause).

**Proven recipe (headless, Connect API):** create the CI via `POST /ssot/calculated-insights` (this REGISTERS it, unlike the `MktCalcInsightObjectDef` metadata path which silently no-ops on some orgs). Join the source/engagement DMO to the unified id through the **unified link DMO**:
```sql
SELECT UnifiedLinkssotIndividual<space>__dlm.UnifiedRecordId__c AS UnifiedIndividualId__c,
       count(Web_Event_c_Home__dlm.Id__c) AS WebEventCount__c,
       max(Web_Event_c_Home__dlm.Occurred_At_c__c) AS LastWebActivity__c
FROM Web_Event_c_Home__dlm
JOIN UnifiedLinkssotIndividual<space>__dlm
  ON UnifiedLinkssotIndividual<space>__dlm.SourceRecordId__c = Web_Event_c_Home__dlm.Account_c__c
GROUP BY UnifiedLinkssotIndividual<space>__dlm.UnifiedRecordId__c
```
Link DMO columns: `SourceRecordId__c` (source profile id), `UnifiedRecordId__c` (unified id). POST body needs `apiName, displayName, definitionType:CALCULATED_METRIC, publishScheduleInterval:"TwentyFour", publishScheduleStartDateTime, expression`. Then `/<apiName>__cio/actions/run`. PROVEN: `UP_Web_Engagement` → 110 web events on a unified profile aggregated across 2 stitched devices.

**Related LISTS/records on the Unified Individual** (Orders, Cases, browsing): the object must be a **DMO related to the Individual**. A lake-only `__dll` won't surface — it must be promoted to a `__dlm` and related. That promotion is the blocker below.

## Headless vs UI matrix for the Data Cloud data-model build (hard-won)

On paper everything is API-driven (Data 360 Connect REST: DMOs, mappings, relationships, CIs, IR). In practice on a constrained/older org:

**Headless-doable (PROVEN):**
- DLO→DMO field maps **after the DMO exists** (`POST /ssot/data-model-object-mappings`)
- DMO relationships **after the DMO exists**
- Calculated Insights (`POST /ssot/calculated-insights`) incl. Unified-Individual-keyed
- Identity Resolution `run-now` and **match-rule PATCH** (`PATCH /ssot/identity-resolutions/<id>`)
- CRM Account-360 fallback for the same metrics via Apex (`CustomerInsightsService`)

**The actual blocker — creating a NEW DMO:** `POST /ssot/data-model-objects` throws **`UNKNOWN_EXCEPTION`** on some orgs (CLI hits the same backend, so `sf api request` does NOT help). Everything downstream of a missing DMO (Order/Case/Return ecommerce+service related lists & CIs) is therefore gated on this one call.

**Before accepting the UI "New Data Model Object" wizard as the only path, try (no-UI):**
1. **Map to a STANDARD Data 360 DMO** if the right one exists (e.g. `ssot__SalesOrder__dlm`, `ssot__Case__dlm`, `ssot__ContactPointApp__dlm` for deviceId) instead of creating a custom DMO.
2. **Retry DMO create with the minimal possible payload** (single PK field, no category quirks).
3. **Create the DMO in a clean org → retrieve/package (`MktDataTranObject`/metadata) → deploy here.**
4. **Open a Salesforce support case** with the `UNKNOWN_EXCEPTION` request/correlation id.

If all fail, the wizard once per missing DMO unblocks it; **everything after (map → relate → CI → IR) is headless.**

Sources: Data Model Objects API collection (postman salesforce-developers), Data 360 dev guide (`developer.salesforce.com/docs/data/data-cloud-dev/guide/dc-get-started.html`).

## Querying Data Cloud from Apex (agent-read path) + the cache-on-CRM pattern
- Query DMOs from Apex with **`ConnectApi.CdpQuery.queryAnsiSqlV2(ConnectApi.CdpQueryInput)`** → `CdpQueryOutputV2`. Rows come back as nested `Object` lists — normalize via `JSON.deserializeUntyped(JSON.serialize(out.data))` then index cells. Target `*__dlm` with `ssot__` fields; `String.escapeSingleQuotes` all interpolated values.
- **⚠️ `ConnectApi.CdpQuery` is NOT `HttpCalloutMock`-able.** Add a test seam: `@TestVisible static Map<String,List<Object>> testRows` and a `firstRow(sql)` that returns canned rows when the SQL contains a token key in `Test.isRunningTest()`, else runs the real query. (Same idea for any ConnectApi dependency.)
- **Cache-on-CRM:** for agent actions that must be fast and reliable, write Data Cloud insights (segment, churn, next-best-action, LTV) to `Account.Data_Cloud_*__c` fields via an async `Queueable(AllowsCallouts)` refresh, and have agent actions read them with fast SOQL behind the identity gate — don't run a slow/flaky CI query per turn.
- **CRM-fallback-when-empty:** build the live answer from CRM facts first, fill gaps from `Data_Cloud_*__c` only where the CRM value is 0/blank. Never make the live answer depend on Data Cloud being populated — degrade to CRM.
