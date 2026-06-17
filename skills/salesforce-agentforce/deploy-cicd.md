# DX Workflow, Deploy & CI/CD

## Project layout

A standard `sfdx-project.json` with one default package dir (`force-app`):
```json
{
  "packageDirectories": [{ "path": "force-app", "default": true }],
  "name": "agentforce-dev",
  "sourceApiVersion": "66.0"
}
```
Source lives under `force-app/main/default/<metadataType>/`. Agentforce + Data Cloud add these folders alongside the usual `classes/`, `objects/`, `flows/`, `permissionsets/`:
- `aiAuthoringBundles/` — Agent Script `.agent` bundles (one folder per agent).
- `objectSourceTargetMaps/` — Data Cloud DLO→DMO field maps (`ObjectSourceTargetMap`).
- `mktCalcInsightObjectDefs/` — Data Cloud Calculated Insights (`MktCalcInsightObjectDef`, SQL in `<expression>`).
- `dataSourceObjects/` — Data Cloud source-object defs (where supported).
- `messagingChannels/` + `EmbeddedServiceConfig/` + `sites/` — MIAW.
- `flowDefinitions/` — to control which Flow version is active (`activeVersionNumber`).
- `queues/` + `queueRoutingConfigs/` — Omni-Channel routing.

Keep secrets out of git (e.g. `.wc-credentials.sh`); store API keys in External Credentials / Named Credentials, never in source.

## Auth & the redacted-token gotcha

In a sandboxed agent environment `sf org display` **REDACTS** the access token. Do not scrape it. Everything you need reuses the CLI's stored session:
```bash
sf data query  --target-org MyOrg --query "SELECT Id FROM Account LIMIT 1"
sf apex run    --target-org MyOrg --file scripts/apex/thing.apex
sf api request rest "/services/data/v62.0/limits" --target-org MyOrg
sf org open    --target-org MyOrg --path "/lightning/setup/..." --url-only   # get a login URL without opening a browser
```
`sf api request rest` is the workhorse for Connect/Data-Cloud endpoints that have no first-class CLI command.

## Deploy & retrieve

Deploys are **asynchronous**. The first component table is not the verdict — wait for final "Succeeded":
```bash
sf project deploy start --metadata ApexClass:MyService Flow:My_Flow --target-org MyOrg
sf project deploy report --use-most-recent          # poll to final status
# or deploy a whole source dir
sf project deploy start --source-dir force-app/main/default/classes --target-org MyOrg
# validate-only (no save) with tests
sf project deploy validate --source-dir force-app --test-level RunLocalTests --target-org MyOrg
```
Retrieve to pull org state into source:
```bash
sf project retrieve start --metadata "ObjectSourceTargetMap" --target-org MyOrg
sf project retrieve start --metadata "Profile:Admin" --target-org MyOrg
```

### Gotcha: new fields are invisible until a permset grants FLS
Metadata-deployed custom fields return SOQL "No such column" until a **permission set** grants FLS. Always deploy AND assign a permission set after adding fields:
```bash
sf project deploy start --metadata PermissionSet:My_Integration --target-org MyOrg
sf org assign permset --name My_Integration --target-org MyOrg
```

### The profile + record-type deploy trick
A `profile` with `recordTypeVisibilities` that references a record type will fail to deploy unless that record type resolves. For **custom** record types: author the `RecordType` in the object's metadata and deploy the object + profile **together** so the `recordTypeVisibilities` reference resolves in the same deploy.

**Exception — the PersonAccount system record type is NOT exposed by the Metadata API.** Retrieving `RecordType:Account.PersonAccount` returns only `Business_Account`; deploying a profile that references `Account.PersonAccount` fails ("no RecordType named Account.PersonAccount found"), and a profile RT-default deploy for it silently no-ops. Setting the Person-Account *default* record type on a profile is therefore **UI-only** (Setup → Profiles → … → Object Settings → Account → Record Types). See `troubleshooting.md`.

## Run Apex from a file
```bash
sf apex run --file scripts/apex/backfill.apex --target-org MyOrg
```
Anonymous Apex is the right tool for one-off data fixes, backfills, and diagnostics (e.g. `Database.emptyRecycleBin`, lead conversion, querying Data Cloud via `ConnectApi.Cdp*`). Wrap risky calls in try/catch + `System.debug` so failures are visible in the run log.

## Query data
```bash
sf data query --target-org MyOrg --query "SELECT Id, Status FROM MessagingSession ORDER BY CreatedDate DESC LIMIT 5"
sf data query --target-org MyOrg --query "..." --json | jq '.result.records'
sf data query --target-org MyOrg --query "..." --result-format human
```
Useful introspection queries:
- Calculated Insights present: `SELECT QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName LIKE '%__cio'`
- Augmented fields: `SELECT QualifiedApiName, DataType FROM FieldDefinition WHERE EntityDefinition.QualifiedApiName='Account' AND QualifiedApiName LIKE 'Data_Cloud_%'`
- Agent runtime users: `SELECT DeveloperName, BotSource, BotUserId FROM BotDefinition WHERE DeveloperName IN (...)`

## CI/CD: deploy core + post-deploy smoke

**Deploy core** — iterate over only the source dirs that actually exist and contain files, then `sf project deploy start`/`validate` with `--test-level RunLocalTests`, `--junit`, `--coverage-formatters json-summary`, `--results-dir`. Supports `dry-run` / `deploy` / `validate-json` modes. (Reference: `scripts/ci/salesforce-deploy-core.sh`.)

**Post-deploy smoke** (`scripts/ci/salesforce-post-deploy-smoke.sh` + `web-chat-conversation-smoke.sh`) verifies the live system end-to-end:
1. **Channel is WebV2** — fetch the served Embedded Messaging config and assert `esClientVersion == "WebV2"`:
   ```bash
   curl -fsSL "${SCRT}/embeddedservice/v1/embedded-service-config?orgId=${ORG}&esConfigName=${DEPLOYMENT}&language=en_US" \
     | jq -e '.embeddedServiceConfig.embeddedServiceMessagingChannel.esClientVersion == "WebV2"'
   ```
2. **Live conversation create** — get an unauth access token then `POST /iamessage/v1/conversation`; treat non-200/201 as failure (a 412 here usually means storage is full — see `troubleshooting.md`).
3. **No stuck sessions** — fail if any `MessagingSession WHERE EndTime = null` exist.
4. **Service-agent BotUserId present** — only the **Service Agent** (`*_Concierge_Web`) needs a non-null `BotDefinition.BotUserId`; scope the check to it and SKIP employee Agent-Script rows (their null `BotUserId` is a reporting artifact, not a failure).
5. **Data Cloud CI + augmented fields exist** — assert the `%__cio` Calculated Insights and `Data_Cloud_*` Account fields are present.

> Do NOT put `sf agent test` in CI against a storage-tight Developer Edition org — the AI Evaluation result records are a large, hard-to-delete storage hog (see `troubleshooting.md`).
