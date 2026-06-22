# Troubleshooting & gotchas

When something fails mysteriously on a Developer Edition / storage-tight org, suspect **storage** before config.

## 1. Storage exhaustion masquerades as everything

A Developer Edition org has a **5 MB Data Storage cap**. When it's full, Salesforce **cannot create ANY records** — which cascades into seemingly-unrelated failures:
- MIAW `POST /iamessage/v1/conversation` → **412 "Conversation Precondition failed"** (the `MessagingSession` record can't be created). The access token issues fine; the org rejects the conversation.
- Embedded Chat **site provisioning GACK / internal server error** (e.g. `907028510`) on publish / "Switch to V2" → "site properties didn't update" (Site/Network records can't be created).
- v2 chat: **0 MessagingSession / 0 ConversationEntry**, send disabled even in Salesforce's own "Test Enhanced Web Chat" page.
- Apex backfills → **`STORAGE_LIMIT_EXCEEDED`**.

**Diagnose:**
```bash
sf api request rest "/services/data/v62.0/limits" --target-org MyOrg | jq '.DataStorageMB'
# also Setup → Storage Usage (UI) for per-object breakdown
```
> The limits API number lags (async recalc) — after freeing space, trust a SUCCESSFUL test insert as proof rather than waiting for the number to update.

**The "orgMigrationBehavior=true" red herring:** a half-completed messaging-platform migration *looks* like the cause (every token carries `orgMigrationBehavior: true`), but on a DE org the actual root cause of all of the above was storage being full. Fix storage before opening a Support case about migration.

### Freeing storage — what to delete and the order
- **AI Evaluation test-run records (`AiEvaluation` + `AiEvalTestCaseCritRslt`/`AiEvalTestCaseResult`/`AiEvalCopilotTestCaseRslt`) are the biggest, sneakiest hog** (multiple MB from `sf agent test`, and they **grow with every run**). **There is NO programmatic purge — confirmed exhaustively:** not via Apex (`AiEvaluation` is "Invalid type", not even in `Schema.getGlobalDescribe()`), not via REST/Tooling/Bulk ("sObject type not supported"), not via Mass Delete Records / Data Loader (objects unsupported); and **deleting the `AiEvaluationDefinition` does NOT cascade** the result records. ⇒ purge = **Agentforce Studio → Testing Center UI** (delete eval runs — *only if your runs surface there; CLI/metadata-created suites often show "no test suites"*) **or a Salesforce Support case**. **So PREVENTION is the real fix:** don't run `sf agent test`/`run-eval` on a storage-tight org, keep it out of CI there, and certify with the **zero-eval-record `AgentInvoker` bait-prompt harness** instead (see `multi-turn-agent-testing.md`). When full, the symptoms are **agent publish 500 ("Internal Error") + MIAW `POST /conversation` 412 + `STORAGE_LIMIT_EXCEEDED` on any insert** — all one root cause. Full scorer/observability detail in `scorers-intent-and-observability.md`.
- Large analytics/seed objects you can confirm are not referenced (e.g. a denormalized `Order_Analytics__c`) are safe to delete via Apex if nothing reads them.
- **Deleted records keep consuming storage until the Recycle Bin is emptied:**
  ```apex
  Database.emptyRecycleBin([SELECT Id FROM Order_Analytics__c LIMIT 10000]);
  ```
  Forgetting this is why "I deleted a bunch of records but storage didn't drop."

## 2. New custom fields invisible after deploy
SOQL "No such column" on a field you just deployed = missing FLS. Deploy AND assign a permission set granting FLS. (Repeated here because it bites constantly.)

## 3. Deploys are async
The first component table is not the verdict. `sf project deploy report --use-most-recent` until "Succeeded".

## 4. Person Account record-type requirements (native lead conversion)

Native `Database.convertLead` into a Person Account fails with **`UNAVAILABLE_RECORDTYPE_EXCEPTION: Unable to find default record type`** unless the running user's profile has a **Person-Account default record type**.

- That default can only be set via `recordTypeVisibilities` referencing **`Account.PersonAccount`** — but the **PersonAccount record type is a system RT the Metadata API does NOT expose.** Retrieving `RecordType:Account.PersonAccount` returns only `Business_Account`; deploying a profile that references `Account.PersonAccount` fails ("no RecordType named Account.PersonAccount found"); a profile RT-default deploy for it **silently no-ops.**
- ⇒ Set the Person-Account default **in the UI**: Setup → Profiles → <Profile> → Object Settings → Account → Record Types → set Person Account as default.
- **`Lead.Company` must be blank** for a Person-Account conversion, else Salesforce does a B2B (business account + contact) conversion.
- For PA conversion pass `setAccountId(existingPA)` with **no** contactId, and `setDoNotCreateOpportunity(true)`.
```apex
Lead l = [SELECT Id, Company FROM Lead WHERE Id = :leadId];
l.Company = null; update l;
Database.LeadConvert lc = new Database.LeadConvert();
lc.setLeadId(leadId);
lc.setAccountId(existingPersonAccountId);     // no contactId for a PA
lc.setDoNotCreateOpportunity(true);
lc.setConvertedStatus('Closed - Converted');
Database.LeadConvertResult r = Database.convertLead(lc);
```
- **Cascading record-type needs:** conversion triggers that create custom-object records *with* record types add their OWN default-RT requirements on the running user's profile — grant those too.
- Assigning the PersonAccount record type to a **Site guest user** (for webhook ingestion) is also UI-only.

## 5. Site-guest-context automation runs locked-down
An external/webhook POST (e.g. from a commerce platform) hits a public Salesforce Site, so anything it triggers runs as the **Site guest user**. Guest-context Flows fail ("List has no rows for assignment to SObject") because the guest can't see the records, and can't safely do credential callouts / record creates. **Fix pattern:**
- Put trusted back-end logic in a `without sharing` Apex service.
- Run it from a **scheduled sweep** (Schedulable → Queueable with `Database.AllowsCallouts`) executed by a privileged user, querying recent records — not from a guest-context Flow.
- For the webhook itself, grant the guest profile only **Apex class access** (+ PersonAccount RT). Apex DML runs system-mode for CRUD/FLS, so guest does NOT need object CRUD.
- Apex scheduler does **not** allow comma-lists in the cron minute field — schedule N separate CronTriggers (e.g. `0 0 * * * ?`, `0 15 * * * ?`, ...) for every-15-min cadence.

## 6. Email fails Gmail DMARC even when Apex says success
`Messaging.sendEmail` returns `isSuccess=true` (and counts against the daily external-email limit, ~15/day on DE) but the mail **never arrives** when the From is a `@gmail.com` (or any domain you don't control) Org-Wide Email Address — Gmail's inbound DMARC/SPF/DKIM rejects mail "from gmail.com" relayed by Salesforce. Self-send (From == To) is also deduped, and plus-addressing doesn't help.
- **Real fix:** add an Org-Wide Email Address on a domain you control, publish SPF + Salesforce DKIM (Setup → Email → DKIM Keys) in that domain's DNS, point the email service at it.
- **Quick mitigation:** Setup → Deliverability → "Use a substitute email address for unverified domains" = ON, and send WITHOUT `setOrgWideEmailAddressId` so the unverified From is substituted.
- **Demo:** send to a DIFFERENT real mailbox (not the org's own gmail) to prove delivery.
This is an email-authentication problem, not a code defect.

## 7. External-system one-way sync gotchas (pattern, generalizable)
- External-system cancellations don't sync back unless you build a status-webhook → update path; idempotent ingestion skips updates by design.
- Internal SF record numbers (e.g. `OrderNumber 00000727`) ≠ external numbers (e.g. `#193`) — link via a stored external-id field (`External_Order_Id__c`).
- A standard Order may not allow `Status='Canceled'` directly — use a custom `Fulfillment_Status__c` as the source of truth and instruct the agent accordingly (and to say "predates traceability" rather than invent who/when cancelled).
- The Standard Pricebook is NOT returned by SOQL in tests — use `Test.isRunningTest() ? Test.getStandardPricebookId() : [SELECT Id FROM Pricebook2 WHERE IsStandard=true]`.
- Pure-Flow HTTP callout gotchas: an async path on a record-triggered flow only activates with the "Is Changed" operator (requires trigger "A record is updated", not "created or updated"); bind an External Service path param `{id}` via the resource PICKER, not literal `{!...}` text (typed literal → `rest_no_route` 404); active flows save as a new version then activate.

## Quick triage flow
1. Chat/records failing to create, 412s, GACKs on publish → **check storage** (`limits` → DataStorageMB; Storage Usage). Free `AiEval*` (Testing Center UI) + empty Recycle Bin.
2. SOQL "No such column" → **FLS / permission set**.
3. Deploy "looks done" but behavior unchanged → **`sf project deploy report`** for true status; check Flow `activeVersionNumber`.
4. Chat opens but agent never speaks → **routing** (Omni-flow + Route Work + fallback queue routing config), not direct channel routing.
5. Signed-in shopper seen as Guest → JWT **timing** (apply inside `onEmbeddedMessagingReady`) AND deployment **`authMode`** (must not be `UnAuth`).
6. Email "sent" but not received → **DMARC / sending domain**.
7. Lead won't convert → **Person-Account default record type** (UI) + blank `Lead.Company`.

## 8. Agent/integration gotchas (cross-cutting)
- **Callout fails at runtime but the Named Credential deployed fine** → the running user's permission set is missing the **External Credential principal** grant (`<externalCredentialPrincipalAccesses>` for `<ExtCred>-<Principal>`). Outbound analog of the FLS gotcha.
- **Agent's reply drops/redacts an external URL** → that domain needs a **`CspTrustedSite`** (`context=All`, `isApplicableToConnectSrc=true`). Agentforce redacts links to non-trusted domains.
- **Webhook signature never matches** → you HMAC'd a re-serialized map, not the **raw request body** (`request.requestBody` Blob); and/or the header lookup is case-sensitive (match header names with `equalsIgnoreCase`).
- **"You have uncommitted work pending" in an agent action** → it did DML before an HTTP callout. **Callouts must precede DML**; or move the callout to a Queueable.
- **A score/numeric stored in a TEXT field can't be used in SOQL or a Flow entry condition** (model scores written as `"0.83 (model v2)"`) → prefilter permissively, parse + threshold in Apex/Flow formula.
- **New agent action never fires after publish** → `genAiPlannerBundles/**` or `genAiPlugins/**` is force-ignored (action schemas live there), or you published but didn't **activate** the new version.
- **Per-identity singleton write throws `DUPLICATE_VALUE` mid-conversation** → race on a unique non-Id key; normalize the key, try case variants on read, catch-then-re-SELECT (see `agent-orchestration-and-memory.md`).
