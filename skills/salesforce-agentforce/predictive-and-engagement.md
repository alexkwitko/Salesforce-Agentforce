# Data Cloud predictive (Einstein Studio) + web engagement — hard-won playbook

Everything below is from building a real churn-prediction + anonymous-web-engagement pipeline on a
Developer Edition org (5 MB storage). Read it before you promise a customer "AI prediction" or
"Web SDK tracking" — several steps are UI-gated, storage-fragile, or have non-obvious gotchas.

## 1. Web engagement capture — two routes, pick by what the org exposes

**Route A — Data Cloud Web SDK (the "official" beacon).** Requires a **Web connector** data stream
(Setup → Data Cloud → connectors → Web). On some orgs the connector isn't provisioned —
the data-stream "New" list shows only *Web Service Consumer* / *WebSockets*, not a browser beacon.
If there's no Web connector, the SDK path is unavailable; don't pretend otherwise. (Confirmed available
+ working end-to-end on a Developer Edition org — events land at 204, rows materialize.)

> **Route A — the COMPLETE pipeline. Skip ANY step and the captured browsing never reaches the
> unified profile — it sits in an orphan DLO and the whole exercise is in vain.** The CDN snippet
> firing 204s is NOT "done"; it only fills a DLO. The five mandatory steps:
>
> 1. **Connect a Website connector** (Setup → Data Cloud → Configuration → Connectors → New → Website,
>    or App "Web & Mobile App"). This yields the **CDN beacon `<script>`** (e.g.
>    `cdn.c360a.salesforce.com/beacon/c360a/<connectorId>/scripts/c360a.min.js`) — the snippet's `src`.
> 2. **Create + upload the schema file** (the Event Type JSON — catalog/cart/identity/contactPointEmail/
>    partyIdentification event shapes) on the connector, and **select which events to ingest.** Without
>    the schema the connector has no DLO fields to land into.
> 3. **Install the SDK snippet** on the site: `SalesforceInteractions.init()` → `initSitemap()` with a
>    product-detail pageType (`ViewCatalogObjectDetail`), add-to-cart listener (`AddToCart`), and an
>    email/identity hook firing `identity` + `contactPointEmail` (+ `partyIdentification`) events. The
>    anonymous `deviceId` is auto-managed by the SDK and stamped on every event.
> 4. **DLO→DMO mapping** — the step everyone forgets. The connector lands a *Behavioral Events* DLO
>    (engagement category) with **Fields mapped 0/0**. A DLO alone gets NO Identity Resolution, NO
>    Calculated Insights, NO streaming, NO Data-Cloud-Triggered Flows — those ALL run on DMOs. Map it
>    into an engagement DMO (federate into your existing web-event DMO, or "New Custom Object"). Required
>    field maps: `eventId → <DMO PK>`, the **event-time field** (`dateTime → Occurred_At` — engagement
>    DLO maps FAIL without it: *"Unable to find Event Field for Engagement DLO"*), and **`deviceId → the
>    DMO's Individual-FK field`** (see step 5). Connect-API create body in the data-cloud doc / memory
>    `datacloud-dlo-dmo-mapping-post-schema`. Types must match (a Number price won't map to a Currency
>    field). **Gotcha: on some orgs the mapping is create-only via API** — `PATCH`/`PUT` return
>    METHOD_NOT_ALLOWED and `DELETE` returns `FUNCTIONALITY_NOT_ENABLED`, so you CANNOT add a forgotten
>    field map later via API; get the field set right on first POST or finish it in the mapping UI.
> 5. **Make the engagement rows attach to a person, and run Identity Resolution.** The SDK's `identity`
>    stream maps **`deviceId → ssot__Individual.ssot__Id`** — i.e. the anonymous visitor already IS an
>    Individual keyed by deviceId. For the *behavioral* rows to join that Individual, the engagement
>    DMO's **foreign-key-to-Individual field must carry the deviceId** (e.g. map `deviceId → Account_c`
>    where the DMO→Individual relationship is `Account_c → ssot__Id`). Anonymous (device-only) rows then
>    attach to the device-Individual; when the same device later logs in, the SDK fires `contactPointEmail`
>    (PartyId = deviceId) + `identity(isAnonymous=0)`, and the **IR email match rule unifies** the
>    device-Individual with the known person — so pre-login browsing retroactively rolls up. The email
>    match rule does the stitch; deviceId is the *link*, not necessarily a separate IR match key.
>
> **Verify (don't trust the Data Explorer grid — it's flaky):** `query-sql` the DMO
> (`SELECT DataSource__c, COUNT(*) ... GROUP BY DataSource__c`) to confirm behavioral rows materialized,
> confirm the FK field is populated, then run/confirm IR. Only then is browsing on the unified profile.

**Route B — custom Apex REST (what actually shipped).** A guest `@RestResource` endpoint on a
Salesforce **Site** (`/services/apexrest/engagement`) that the storefront JS POSTs to (CORS-allowlisted
origin). A self-managed `deviceId` cookie = the anonymous id; an `identify{email}` payload stitches
the device to a Person Account. This works on ANY org (no Web connector needed) and is fully DX —
the object (`Web_Event__c`), the REST class, the stitch service, and a `CorsWhitelistOrigin` are all
metadata. Trade-off: you own identity-resolution in Apex instead of getting it from Data Cloud IR.
- **Identity stitch must be self-healing.** Two concurrent `identify` POSTs each create a Person
  Account → duplicates. Make the stitch pick the OLDEST account for the email as canonical, collect
  every device id ever seen for that email + the incoming one, and relink ALL their events +
  events on the dup accounts to the canonical, then leave the dup empty. Idempotent.
- **Trust boundary:** only a **server-rendered** logged-in email is trustworthy. A client-supplied
  `identify{email}` (checkout field, JS hook) is spoofable — treat it as a soft signal, hard-stitch
  only on server-verified identity (logged-in WP user, or JWT-verified chat).
- **The cross-snippet identify hook:** the tracker defines `window.appIdentify(email,first,last)`.
  The chat/login controller calls it on sign-in. Make this controller-INDEPENDENT (a small watcher
  that polls the `/me` endpoint and fires once per email) so it works even if the heavy chat
  controller snippet is disabled. WPCode-Lite's editor "Update" frequently fails to persist a
  programmatic `CodeMirror.setValue` — **always reload the snippet and grep for your change**; the
  reliable save is a real coordinate-click on Update, or create a fresh snippet via "Add Snippet".

## 2. DLO→DMO mapping modal is NOT hung — it takes 60–120 s

The data-stream → Data Mapping → **Start → Select Objects** modal shows a spinner for **one to two
minutes** before the object list renders. Earlier builds "gave up" thinking it hung. Wait it out.
One-click custom DMO: Custom Data Model → **New Custom Object** auto-creates a DMO with every DLO
field + correct types and auto-maps them. Then add the relationship to Individual:
Data Model → the DMO → **Relationships → Edit → New Relationship** → Account field → N:1 → Individual.

## 3. MktCalcInsightObjectDef deploys "Succeeded" but silently does NOT provision

A `MktCalcInsightObjectDef` metadata deploy returns **Succeeded** yet creates **no**
`MktCalculatedInsight` record and no `*__cio` table on some orgs (older repo CIs were absent too).
**Build the CI in the UI** (Calculated Insights → New → Calculated Insight → Use SQL Authoring),
schedule it, Enable. Keep the metadata file in the repo as documentation. Note: a failed metadata
attempt can orphan the API name → "API name already exists" → use a `_v2` suffix in the UI.
CI SQL can read a `__dll` (DLO) directly OR a `__dlm` (DMO) — the UI builder targets the DMO.

## 4. Einstein Studio Model Builder — the UI flow (7 steps, fully click-driven)

Data Cloud app → **AI Models → Add Predictive Model → Create a model**:
1. **Type:** Binary (likelihood 0-100), Multiclass, or Regression. Churn = Binary.
2. **Select Data:** a **DMO** (not a DLO). So you need training rows in CRM → stream → DLO → **DMO**.
3. **Select Training Data:** All Records / filtered.
4. **Set Goal:** pick the label field; choose the value to predict (TRUE) + minimize/maximize.
5. **Prepare Variables:** Autopilot on = it picks features; toggle Autopilot **off** to exclude
   leaky identifiers (Account id, Name, the autonumber). Identifiers at 0.0% importance but a
   near-perfect AUC (.97+) = leakage warning — retrain without them.
6. **Select Algorithm:** Automatic (GLM/XGBoost) is fine.
7. **Save & Train:** "can take up to 24h" but on small data it's **~5 min**. Then **Activate** the
   model version (Activate button on the model detail).

**Training data must be point-in-time, no leakage:** one row per (customer, ref-date); features from
orders BEFORE the ref date; label = churned if NO order within N days AFTER. Generate via Apex into a
custom object (`Churn_Training__c`), let it stream to its DLO/DMO, then train.

## 5. Predict jobs — where the model actually scores rows

Model detail → **Integrations tab → Predict Jobs → New Predict Job** (4 steps): pick input DMO
(auto-maps feature columns by name), **enable "Include binary class probabilities"** (else you only
get the class label, not the 0-1 score), name the output object, choose **Streaming** or **Batch**.
- **Streaming jobs do NOT score data that arrived BEFORE the job was activated.** Symptom: job Active,
  output DMO = 0 rows forever. Fixes: (a) the row-action menu has a **Run** action that forces a
  one-time scoring of current input — this is the reliable trigger; (b) or touch/regenerate the input
  rows so the stream emits change events; (c) or use a **Batch** job (scores the whole input on demand).
- **Output DMO schema** (binary, probabilities on): `PredictedChurned_c1__c` = class label ('TRUE'),
  `PredictedChurned_c1Value__c` = P(that class); `_c2__c`/`_c2Value__c` = the other class.
  `PrimaryObjectPk__c` = the **source training row's record id** (NOT the Account id).
  Churn prob = `CASE WHEN c1='TRUE' THEN c1Value ELSE c2Value END`.

## 6. Writing scores back to Account — the join + the ConnectApi gotcha

`PrimaryObjectPk__c` is the `Churn_Training__c` record id, so join predictions → training-DMO (or the
CRM object) → Account. **`ConnectApi.CdpQuery.queryAnsiSqlV2` returns 0 rows for cross-DMO JOINs even
when the SAME SQL via `/services/data/vXX/ssot/query-sql` returns rows** (Apex Connect path lags/limits
joins). Workarounds that actually worked:
- Pull the join via REST `query-sql` (shell `sf api request rest`) and write back with `sf data`/Apex.
- Or — if you kept the CRM `Churn_Training__c` rows — map predictionPK→Account by **SOQL on the CRM
  object** (reliable), no Data Cloud join. Even DELETED training rows are queryable for 15 days with
  `ALL ROWS`, so you can recover the PK→Account map after cleanup.
- `query-sql` itself is **eventually consistent / flaky**: the same SELECT can return rows then 0
  seconds later; `COUNT(*)` can be stale vs the column SELECT. **Retry with backoff.**

## 7. ⚠️ The 5 MB storage trap (Developer Edition) — the #1 thing that breaks this

Developer Edition data storage is **5 MB** (the `limits` API occasionally misreports it as ~11 GB —
do not trust a single reading; the enforcement is 5 MB). 161 scoring rows ≈ 0.3 MB; 414 training
rows ≈ 0.8 MB. With business data (OrderItem is usually the hog) already near 5 MB, **you cannot hold
the model dataset AND run live engagement tracking at the same time.** Consequences and rules:
- When storage is full, the live engagement endpoint returns **HTTP 200 with an `APEX_ERROR` body**
  (`STORAGE_LIMIT_EXCEEDED`) — a browser `fetch` won't throw; events silently stop landing. **Always
  curl-probe the endpoint after any bulk insert** and check for `"ok":true`, not just a 200.
- Training/scoring rows are **transient**: generate → wait for DLO/DMO sync → train/predict → write
  scores back → DELETE. Keep them only as long as you need the PK→Account map.
- **`Database.emptyRecycleBin` caps at 200 records per call** — batch it in slices of 200, or your
  purge silently fails and the deleted rows keep consuming storage (15-day retention).
- **Storage recalculation lags minutes to hours.** After deleting + purging, the `limits` API AND the
  insert enforcement may still report full for a while. Don't trust an immediate re-read; poll.
- Deleting the CRM source rows triggers a **full-refresh of the DLO/DMO to empty**, orphaning any
  predictions keyed to those rows. If you need the predictions usable, keep the source rows or capture
  the PK→Account map (ALL ROWS) before purging.

## 8. Two-tier scoring is the honest design

Keep BOTH: a daily **operational** Apex scorer (`Churn_Score__c`, always fresh, purchase + engagement
heuristics) AND the **strategic** Einstein model score (`Data_Cloud_Churn_Risk__c`, e.g. `"0.72 (AI
model v2)"`). Downstream actions (the win-back campaign) should **prefer the model score when present,
fall back to the heuristic** — parse the leading decimal out of the string field. Engagement features
(events/dwell/recency) belong in BOTH the heuristic and the model's training rows; on a brand-new
tracker they carry ~0 historical signal (honest: they're real model INPUTS whose predictive value
grows as engagement history accumulates — not a fabricated signal).

## 9. Deploy-path completeness for a fresh org

`DataStreamDefinition` + `MktDataTranObject` ARE retrievable/deployable, but a brand-new org rejects
them with `no MktDataTranObject named <X>_Home found` until the source object has been streamed once.
So: include them in the manifest, run that deploy step **non-fatally**, and document the UI fallback
(create the stream once in Data Streams → New → Salesforce CRM, then re-run — the metadata upserts).
Always assign the FLS permsets for the new custom objects/fields after deploy (`Engagement_Tracking`,
`Predictive_Scoring`) or SOQL reports "No such column".

## Point-in-time training, score writeback & activation (reusable templates)

**Training-row generator — no-leakage construction (any binary-outcome model).** Pick N **reference dates**; for each entity at each ref date, aggregate features from events strictly **before** the ref date (`if (eventDate >= ref) continue;` — explicit leakage guard) and set the **label** from whether the outcome occurred in a window **after** (`ref.addDays(N)`). One row per (entity, ref-date). Include real "new-signal" features even if they currently carry ~0 history — their value grows over time. (Generalize the domain nouns; the windowed point-in-time shape is universal.)

**Score writeback — recover the entity id via the training-row PK.** The prediction output DMO keys on `PrimaryObjectPk__c = <training-row id>`, NOT the entity id. Writeback = JOIN predictions → training-DMO to recover the entity id, then `CASE WHEN classLabel='TRUE' THEN p ELSE 1-p END` for P(positive). Store as a **model-version-tagged string** (`"0.NN (model v2)"`). If training rows were deleted for storage, recover the id map with `SELECT Id, <Entity>__c FROM <Training>__c ALL ROWS` (works for ~15 days post-delete).

**Two-tier scoring → CRM Campaign activation (segment→activation WITHOUT Marketing Cloud).** Reusable: an `effectiveScore()` that **prefers the model score and falls back to a heuristic**, gate on consent + value threshold, add `CampaignMember`s to a classic **Campaign** (idempotent via an `existing` member-id `Set`), and create a human follow-up `Task` only for the top tier.
- **⚠️ Score-in-a-string-field SOQL gotcha:** a score stored as text is **not SOQL-comparable** — prefilter permissively in SOQL, then apply the real numeric threshold **in the Apex loop** (parse the string). (This is also why a Data Cloud / model score written to a CRM text field can't be used directly in a record-triggered Flow entry condition — branch in Apex/Flow formula instead.)
