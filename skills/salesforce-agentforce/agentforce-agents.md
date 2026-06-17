# Agentforce Agents (Agent Script bundles)

Build agents as **Agent Script authoring bundles** in DX source, NOT in the screen builder. Bundles live at `force-app/main/default/aiAuthoringBundles/<Name>/<Name>.agent` (+ `<Name>.bundle-meta.xml`).

## Lifecycle (`sf agent`)
```bash
sf agent generate agent-spec       --target-org MyOrg ...   # scaffold a spec
sf agent generate authoring-bundle --target-org MyOrg ...   # spec -> .agent bundle
# edit the .agent file by hand
sf agent validate authoring-bundle --api-name My_Agent --target-org MyOrg   # 0 errors before publishing
sf agent publish  authoring-bundle --api-name My_Agent --target-org MyOrg
```
- `sf agent activate` can fail org-wide on a brand-new Agentforce org with "bots are still being provisioned" — transient, retry later.
- `sf agent preview` needs a TTY (Ink TUI). For headless/CI use `sf agent test` or the `AgentInvoker` Apex bridge (below).

## Employee agent vs Service Agent — the immutable choice

**Agent type is IMMUTABLE after first publish.** To change it you must publish a fresh bundle with a NEW `developer_name` (legacy bots are hard to delete: `AiAuthoringBundle` isn't deletable via Metadata API, and the bundle↔bot reference blocks Bot delete; delete via Setup UI Agents list, or leave inactive).

**Employee / internal agent** (`BotDefinition.Type = InternalCopilot`) — for staff-invoked or headless automation:
- `config.agent_type: "AgentforceEmployeeAgent"`.
- MUST NOT have `default_agent_user`, `connection messaging:`, or `@MessagingSession`-linked variables — any of those turn it into a customer **Service Agent** (`ExternalCopilot`).
- A null `BotDefinition.BotUserId` on an employee agent is a **reporting artifact**, not a runtime failure. They run under their `default_agent_user` (a dedicated `*@...ext` user). Verify by actually invoking the agent; don't fail CI on null `BotUserId` for employee rows.

**Service Agent** (`ExternalCopilot`) — for customer-facing MIAW web chat: has `connection messaging:`, `@MessagingSession` variables, and a runtime BotUser (`EinsteinServiceAgent`). This one DOES need a non-null `BotUserId`.

## .agent file anatomy (Agent Script)

Top level: `system` (instructions + welcome/error messages), `config` (developer_name, agent_label, description, agent_type), `variables`, `language`, a `start_agent <router>`, and one or more `subagent <name>` blocks.

```
system:
    instructions: "You are the Inside Sales agent for ... Consent is mandatory before any marketing send. Never reveal PII unless returned by an action for the specific record the user asked about."
    messages:
        welcome: "Hi, I'm the inside-sales assistant. Give me a lead and I'll send a recovery offer."
        error: "Sorry, it looks like something has gone wrong."

config:
    developer_name: "Inside_Sales"
    agent_label: "Inside Sales"
    agent_type: "AgentforceEmployeeAgent"

variables:
    last_recovery_code: mutable string = ""
        description: "Most recent recovery coupon code generated this session."

start_agent agent_router:
    label: "Agent Router"
    reasoning:
        instructions: -> | Route to the subagent matching the user's message.
        actions:
            go_to_cart_recovery: @utils.transition to @subagent.cart_recovery
```

### Custom Apex actions — no GenAiFunction metadata needed
Agent Script runtime auto-discovers `@InvocableMethod` from `target: "apex://ClassName"`. You do NOT author `GenAiFunction`/`GenAiPlugin` metadata for Agent Script actions.

Inside a `subagent`, declare the action under `actions:` (description/label/target/inputs/outputs), then wire it under `reasoning.actions:` with `with <input>=...` and `set @variables.x = @outputs.y`:
```
subagent cart_recovery:
    actions:
        check_consent:
            description: "Check email marketing consent. MUST be called first, before send_recovery."
            target: "apex://ConsentService"
            inputs:
                recordId: object
                    complex_data_type_name: "lightning__recordIdType"
                    developer_name: "recordId"
                    is_required: True
            outputs:
                hasConsent: boolean
                    is_displayable: True
        send_recovery:
            target: "apex://LeadNurtureService"
            inputs:
                leadId: object
                    complex_data_type_name: "lightning__recordIdType"
                    developer_name: "leadId"
                    is_required: True
            outputs:
                couponCode: string
                    is_displayable: True
    reasoning:
        instructions: -> | Execute exactly ONE action per turn; wait for its output before the next.
                          CONSENT IS MANDATORY: run check_consent first; if hasConsent is false, STOP — do NOT run send_recovery.
        actions:
            check_consent: @actions.check_consent
                with recordId=...
            send_recovery: @actions.send_recovery
                with leadId=...
                set @variables.last_recovery_code = @outputs.couponCode
```
- A record-id input uses `complex_data_type_name: "lightning__recordIdType"`.
- `is_displayable: True` lets the agent surface an output to the user; `False` keeps it internal (e.g. a machine-readable handoff packet).
- Enforce guardrails in BOTH the action layer (Apex hard-gates, e.g. consent floor) AND the reasoning instructions ("MUST call check_consent first and STOP if false") for defense in depth.

### Apex action class rules (hard-won)
- **Only ONE `@InvocableMethod` per Apex class.** A class with two invocable methods fails to compile (`Only one method per type can be defined with: InvocableMethod`). If an agent needs N actions, put each in its **own thin wrapper class** (e.g. `FooMarkAction`, `FooStepAction`) that delegates to a shared logic class with plain `static` methods. Bonus: the same `static` methods are then callable from a scheduled sweep/Queueable too (no invocable overhead).
- **Action input/output names must match the `@InvocableVariable` names** on the Request/Result inner classes (the `inputs:`/`outputs:` keys in the `.agent` map 1:1 to them). A record-id input is `complex_data_type_name: "lightning__recordIdType"` and the field is typed `Id`.
- **Return a structured Result, don't make the action `void`.** The agent can only *honestly* confirm an outcome if the action returned a success flag this turn (anti-hallucination). A `void` action gives it nothing to assert. Always return `{ success, message, ...}`.
- Keep the logic class `without sharing` if it runs in headless/guest/sweep contexts; wrappers can be `with sharing`.

## DX authoring bundle vs the Agentforce Builder (Studio) — which to use
There are two authoring surfaces and they are NOT interchangeable for automation:
- **DX `aiAuthoringBundle`** (`.agent` Agent Script in source) — version-controlled, `sf agent validate/publish/activate`, diffable, testable. **Use this for anything you build/maintain programmatically.**
- **Agentforce Builder / Studio "agent projects"** (the in-browser canvas, URL `…/AgentAuthoring/…?projectId=…`) — a separate project format. **You cannot reliably read or edit a Builder draft headlessly**: the canvas exposes no Agent Script text to scrape, and an **uncommitted draft has no `BotDefinition`/`BotVersion`** yet (so there's nothing in metadata to retrieve or fix). Its "Problems" panel (errors like `'x' is not defined in variables`, undefined actions, syntax) must be fixed in the UI — or sidestepped.
- **Reconciliation:** `sf agent publish authoring-bundle --api-name <SameDevName>` publishes INTO the agent of that developer name — so authoring a clean bundle with the **same dev name** as a broken Builder draft **replaces** it with a valid, active version (one agent, one version; verify with `SELECT VersionNumber,Status FROM BotVersion WHERE BotDefinition.DeveloperName='<X>'`). This is the reliable way to "fix" a broken Builder draft: rebuild it as a DX bundle and publish+activate. The stale Builder draft layer is harmless once a clean active version exists; delete it from Studio if desired.
- A Builder draft may have been created as the wrong **agent type** (e.g. Service Agent when you wanted an internal copilot) — and type is immutable after first publish, so rebuilding as a bundle with the correct `agent_type` is the fix, not editing the draft.

## Publish gotchas that silently drop NEW actions (hard-won)
- **Do NOT `.forceignore` `genAiPlugins/**` or `genAiPlannerBundles/**`.** `sf agent publish` regenerates the
  planner+plugins (which hold the topic→action mapping) and deploys them; if they're force-ignored, your
  **instruction edits still go live but NEW actions never register** — the agent keeps refusing/falling back
  because it literally doesn't have the new tool. Symptom: existing actions work, a freshly-added action is
  never called even when asked explicitly. Fix: remove those from `.forceignore`, republish. (Keep only
  `aiEvaluationDefinitions/**` ignored — that's the storage hog.)
- **`sf agent publish` does NOT auto-activate.** It creates a new version; the live channel keeps running the
  previously-active version until you run `sf agent activate --api-name <A> --version <N>` (the bare command is
  an interactive TUI that needs a TTY — pass `--version` explicitly in headless/CI). Instruction-only changes
  often appear live, but treat publish+activate as two steps and always activate the new version.
- After publish+activate, verify a NEW action actually fires (e.g. assert a row/record it creates), not just
  that the agent "responds" — a new action that isn't registered fails silently.

## Knowledge grounding (RAG) in an Agent-Script agent — the DX recipe (hard-won + PROVEN, Summer '26)
Wiring Salesforce Knowledge / a Data Library into an **Agent-Script** agent is NOT a plain action add, and the new Agentforce Builder exposes **no UI to "assign" a Data Library** to an Agent-Script agent. **But you don't need the assignment — bind the RAG config id directly as a literal and publish via DX.** Proven end-to-end on `Kwitko_Concierge_Web`:
1. **Action target schemes** are `apex://`, `flow://`, `prompt://` **and** `standardInvocableAction://<name>` (public docs list only the first three). No `knowledge://`/`retriever://` scheme, no top-level `data:`/`knowledge:` construct.
2. **Add the OOB "General FAQ" subagent** via Builder **Explorer → "+" → Add from Asset Library** (search "knowledge"/"General FAQ"; asset library is subagents-only). It ships the **Answer Questions with Knowledge** action (`source: "EmployeeCopilot__AnswerQuestionsWithKnowledge"`, `target: "standardInvocableAction://streamKnowledgeSearch"`) with strong built-in anti-hallucination reasoning ("Never provide generic information… unless retrieved from searching knowledge articles"; "Include sources…"). ⚠️ EmployeeCopilot flavor even on a customer Service Agent — works fine. **Save** the draft.
3. **The action inputs default to `@knowledge.*`** (`ragFeatureConfigId=@knowledge.rag_feature_config_id`, `citationsUrl=@knowledge.citations_url`, `citationsEnabled=@knowledge.citations_enabled`). `@knowledge` is only populated when a library is *assigned* — so as-is you get `Unknown @knowledge field` errors (×3) → uncommittable. The Builder "Data" node is read-only, "+→Add connections" = channels only, and `sf agent adl` can't assign. **So bypass the whole assignment concept:**
4. **THE FIX — retrieve the bundle, bind literals (NO assignment):**
   - The saved Builder draft **IS retrievable** as `AiAuthoringBundle` metadata: `sf project retrieve start --metadata "AiAuthoringBundle:<Agent>" -o <org> --target-metadata-dir /tmp/x` (then unzip). (Diff vs your repo bundle to confirm no drift before overwriting.)
   - **`ragFeatureConfigId` is DETERMINISTIC: `ARFPC_<libraryId>`** — confirmed in the `@salesforce/agents` SDK (`agentDataLibrary.js`: `ragFeatureConfigId: \`ARFPC_${libraryId}\``); it never creates a separate config object. Get the `libraryId` (`1JD…`) from `sf agent adl get -i <id> --json` (also returns `retrieverId` `1Cx…`, grounding fields, `featureAssignments`).
   - In the `.agent`, change the input default expressions: `"ragFeatureConfigId": string=@knowledge.rag_feature_config_id` → `string="ARFPC_<libraryId>"`; `"citationsUrl": string=@knowledge.citations_url` → `string=""`; `"citationsEnabled": boolean=@knowledge.citations_enabled` → `boolean=False`.
   - In the subagent's `reasoning.actions`, **drop** the `with citationsUrl/ragFeatureConfigId/citationsEnabled=...` lines (keep only `with query=...`) so the literal input defaults apply (else the planner re-supplies empty values and overrides them).
5. **Validate → publish → activate (CLI):** `sf agent validate authoring-bundle --api-name <A>` (expect 0 errors) → `sf agent publish authoring-bundle --api-name <A>` (publishes INTO the same dev-name agent, reconciling/superseding the Builder draft into a committed BotVersion) → `sf agent activate --api-name <A> --version <N>` (publish ≠ activate; the active version keeps serving until you activate).
6. **Verify functionally WITHOUT the storage hog:** invoke headlessly with `AgentInvoker.callAgent(api, msg, null)` (`generateAiAgentResponse` — works for Service Agents too; capture the response via a thrown exception message since `sf apex run` truncates long debug logs). Confirm (a) a policy question returns KB-sourced text + `success=true`, and (b) a guardrail still holds (guest order-status still triggers the OTP/sign-in identity gate, no PII leak). Do NOT use `sf agent test` for a smoke check — it writes the AI-Evaluation storage hog. See `salesforce-service/reference/knowledge.md` §7.

## Headless invocation (run the agent from Apex/Flow/jobs)

Use the in-org platform action `generateAiAgentResponse` — no Connected App / OAuth. The agent runs as the **current user**, so headless callers must run privileged.

```apex
public without sharing class AgentInvoker {
    public static Response callAgent(String agentApiName, String userMessage, String sessionId) {
        Invocable.Action action = Invocable.Action.createCustomAction('generateAiAgentResponse', agentApiName);
        action.setInvocationParameter('userMessage', userMessage);
        if (String.isNotBlank(sessionId)) action.setInvocationParameter('sessionId', sessionId); // continue a session = multi-turn
        Invocable.Action.Result result = action.invoke()[0];
        // result.getOutputParameters() -> 'sessionId' + 'agentResponse'
        // agentResponse is a JSON envelope {"type":"Text","value":"..."} — unwrap to .value
    }
}
```
- Pass back the returned `sessionId` to continue a multi-turn conversation.
- In test context (`Test.isRunningTest()`) `generateAiAgentResponse` isn't supported — return a deterministic stub.
- This is the right pattern for self-service automation: agents are **conversational, not event-driven**, so fire them headlessly from a scheduled job / record-triggered Flow instead of expecting them to self-fire on data changes. (`AgentInvoker` is `@InvocableMethod`, so it's also callable directly from Flow.)

## Agent testing (`sf agent test`)
```bash
sf agent test create --spec specs/My_Agent_Test.yaml --api-name My_Agent_Test --target-org MyOrg
sf agent test run    --api-name My_Agent_Test --wait --target-org MyOrg
```
- Spec YAML: `subjectType: AGENT`, `subjectName` = agent dev name, `testCases` with `utterance` / `expectedActions` / `expectedOutcome`.
- Use a REAL, CURRENT record id in the utterance for a clean outcome pass (it triggers real side effects; reseeding deletes old ids).
- **`expectedTopic` assertions are brittle** for Agent Script — the harness reports the router/subagent name (e.g. `agent_router`), not your topic. Rely on the `expectedActions` assertion + verifiable real side effects (a created Coupon, a sent email) as the functional truth; the outcome assertion is a fuzzy LLM judge.
- **WARNING:** every `sf agent test` run writes AI Evaluation result records that are a large, hard-to-delete storage hog (Testing Center UI only — NOT Apex/Tooling). Do not run agent tests on a storage-tight org. See `troubleshooting.md`.

## AI-written copy without a callout credential
You can call Einstein Models from native Apex (no API key / Named Credential): `aiplatform.ModelsAPI` with a model like `sfdc_ai__DefaultGPT4OmniMini`, request body type `aiplatform.ModelsAPI_GenerationRequest`. The model call is a **callout** — run it BEFORE any DML and skip it in `Test.isRunningTest()`. Always keep a deterministic fallback so the feature works if the model call fails. (Discover unknown Apex API types via a forced compile error, e.g. assign a wrong type and read the error.)

## Agent variables — kinds, data types, when to use, and how they map
Top-level `variables:` are **agent-global**: declared once, available in EVERY subagent for the whole conversation (no re-passing). There are two **kinds**:

| Kind | Syntax | Read/Write | Source | Compiles to | Trust | Use it for |
|---|---|---|---|---|---|---|
| **`linked`** | `name: linked <type>` + `source: @MessagingSession.<Field>__c` (no default) | **Read-only** | Bound to a session/record field, populated by the channel | `contextVariables` | **Trusted** — the user can't set it conversationally | Channel-provided identity/context: signed-in email, first name, a host-page token. The ONLY thing that proves identity. |
| **`mutable`** | `name: mutable <type> = <default>` | Read-write (`set @variables.x = @outputs.y`) | The agent/actions write it | internal `stateVariables` | **Untrusted** for auth | Session scratchpad + cross-subagent handoff: last-result ids, step flags, captured-this-turn values, an OTP proof to pass from the gate subagent to a privileged one. |

**Data types** (what the real agents use): `string`, `boolean`, `number`. (A *record id* is not a top-level variable type — it's an **action input** typed `object` with `complex_data_type_name: "lightning__recordIdType"`; employee agents take the native `Id` as an action input, see below.)

**When to use which — decision rules:**
- Value comes from the **host page / messaging channel** (web chat embedding) and must be trustworthy → **`linked`** with `source: @MessagingSession.<field>` (and wire the hidden-prechat → channel customParameter → routing-flow → session-field chain; see `messaging-web.md`).
- Value is **produced/needed during the conversation** (an action returned it; a flag you set after a step; something you must remember for a later subagent) → **`mutable`** with a sensible default.
- **Never gate a privileged/PII action on a `mutable` value** — only a non-empty `linked` value (or a re-verified opaque OTP proof passed per-call) authorizes. A typed/looked-up value held in a `mutable` var is not proof.

**How values move:**
- Reference any variable in instructions/actions as `{!@variables.name}`.
- Capture an action output into a variable: under `reasoning.actions`, `set @variables.lastCouponCode = @outputs.couponCode`. That written value is then readable by **any other subagent** (this is how OTP proof / last recommendation / last coupon flow across subagents).
- `linked` values arrive pre-populated from the session — you only read them.

**Employee/internal agents (not web chat):** do **NOT** declare `linked @MessagingSession` variables or `connection messaging:` — those make it a customer **Service Agent**, and agent type is immutable after first publish. An internal copilot gets its context from the **record Id passed into its actions** (e.g. a `get_context` action taking the Lead/Order Id), plus `mutable` session vars. Use `linked @MessagingSession` ONLY on the MIAW/web-chat Service Agent.
