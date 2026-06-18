# AGENTS.md — working in this repo with an AI coding agent

This is the cross-tool instruction file. **OpenAI Codex, Google Antigravity, Cursor, and other agents read `AGENTS.md` automatically.** Claude Code users get the same guidance from `CLAUDE.md` / the `skills/` directory. Keep this file tool-agnostic.

## What this repo is

A complete, multi-cloud Salesforce **Agentforce** reference org for one (fictional) coffee business — Commerce (D2C + B2B), Service, Field Service, Revenue Lifecycle Management (RLM), Data Cloud, and Payments — with **12 AI agents** on top, deployable to a fresh Developer/scratch org. See `README.md` for the full breakdown.

## The golden rule: DX-first, browser last

When making changes, always prefer in this order:

1. **Salesforce DX / `sf` CLI** — `sf project deploy/retrieve`, `sf data`, `sf apex run`, `sf agent` commands.
2. **Salesforce MCP tools** (if connected) — `deploy_metadata`, `run_soql_query`, `run_apex_test`, `run_agent_test`, etc.
3. **Metadata XML deploy** for anything not in the CLI surface.
4. **Apex / REST / Connect API** via CLI for runtime actions.
5. **Browser / UI automation — last resort only.** It is slow and brittle. Use it only when something genuinely has no API/metadata/CLI path, and say so first.

## Deploy (one command, idempotent)

```bash
sf org login web --alias devorg          # or a scratch org from config/project-scratch-def.json
scripts/deploy/deploy-to-new-org.sh devorg
```

Then complete the non-metadata post-deploy steps documented in `README.md` (data seed, agent activation, channel wiring).

## Drive the agents headlessly (no UI)

Employee agents can be invoked in-org:

```bash
sf apex run --file tools/run-agent.apex   # wraps AgentInvoker.callAgent(apiName, message[, sessionId])
```

or through the MCP server in `tools/agent-mcp/` (exposes `ask_kwitko_agent`). Service agents (MIAW) are tested via SCRT/SSE, not `AgentInvoker`.

## Critical gotchas (read before editing)

- **`sf agent publish` does NOT activate.** A freshly published agent version is Inactive; the old version keeps serving and being tested. Run `sf agent activate --api-name <name> --version <n>` and verify the active version before testing.
- **Agent type is immutable** after the first publish (Employee `AgentforceEmployeeAgent` vs Service `AgentforceServiceAgent`).
- **Headless RLM engine is gated.** On a Developer org the Place Quote / Salesforce Pricing engine can be un-provisionable (`FUNCTIONALITY_NOT_ENABLED [PlaceQuoteApplication]`). This build models the subscription lifecycle directly on the standard `Asset` object as a drop-in. See the `salesforce-rlm` skill.
- **One `@InvocableMethod` per Apex class.** `like` is a reserved word (use `pattern`).
- **Never commit secrets or org identifiers.** Org ID, My Domain, SCRT URLs, and `*.ext` usernames are scrubbed to placeholders (`00DXX0000000000`, `MYDOMAIN`). `tmp/`, `.codex-sf-home/`, `*.pem`, and `**/keys/` are gitignored. Do not reintroduce real values.

## Reusable skills

Tool-agnostic playbooks live in `skills/` (Claude format) and `agent-skills/` (portable copy for Codex / Antigravity / Cursor — same `SKILL.md` format, Claude-specific references scrubbed). Regenerate the portable copy with `scripts/convert-skills.sh`.

| Skill | Covers |
|---|---|
| `salesforce-agentforce` | Building/deploying/testing Agentforce agents (Agent Script, validate/publish/activate, headless invocation) |
| `salesforce-service` | Service Cloud: cases, record types, entitlements/SLA, knowledge, fix-tools |
| `salesforce-field-service` | Field Service: work orders, maintenance plans, scheduling, mobile, field AI/payments |
| `salesforce-d2c-setup` | D2C/B2B Commerce storefront, buyer provisioning, promotions, custom LWR design |
| `salesforce-rlm` | Revenue Lifecycle Management quote-to-cash + the headless-engine workaround + RLM↔Field-Service asset coupling |

## Repo layout

- `force-app/main/default/` — all org metadata (Apex `classes/`, `aiAuthoringBundles/` agents, `flows/`, `lwc/`, `objects/`, `permissionsets/`, …)
- `scripts/` — `deploy/` (ordered deploy) and `ci/` (authenticate, deploy-core, smoke, secret-scan)
- `tools/` — `agent-mcp/` MCP server + headless invocation helpers
- `skills/`, `agent-skills/` — reusable playbooks (Claude + portable)
- `docs/` — build guides, certification matrix, cost calculator, design docs
