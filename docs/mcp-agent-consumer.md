# MCP Agent Consumer — `ask_kwitko_agent`

Design (and a working Node scaffold) for a small **Model Context Protocol (MCP) server** that exposes the
org's Agentforce agents as a tool any MCP client (Claude Desktop, Claude Code, etc.) can call:

```
ask_kwitko_agent(agentApiName, message, sessionId?) -> { agentResponse, sessionId }
```

The scaffold lives at [`tools/agent-mcp/`](../tools/agent-mcp/). It is a stdio MCP server built on
`@modelcontextprotocol/sdk` that calls a thin **Apex REST** wrapper around the existing
[`AgentInvoker`](../force-app/main/default/classes/AgentInvoker.cls) class.

---

## Why an Apex REST wrapper (recommended call path)

`AgentInvoker.callAgent(agentApiName, message, sessionId)` already runs an agent **headlessly** in-org via
the platform action `generateAiAgentResponse` — no Connected App, no separate Agent-API session lifecycle,
no per-agent runtime BotUser plumbing. It returns the unwrapped agent text plus a `sessionId` for multi-turn.

So the cleanest consumer is: **expose `AgentInvoker` as an authenticated Apex REST endpoint, and have the MCP
server POST to it.** This keeps all agent-selection / privacy / unwrap logic server-side in Apex (one source of
truth) and gives the MCP server a tiny, stable contract.

The agent runs as **the calling user**, so call this endpoint as a privileged integration user.

### 1. The Apex REST endpoint (deploy this class)

Add `AgentRestResource.cls` (a few lines; wraps the existing `AgentInvoker`):

```apex
@RestResource(urlMapping='/agent/*')
global without sharing class AgentRestResource {
    global class In  { public String agentApiName; public String message; public String sessionId; }
    global class Out { public Boolean success; public String agentResponse; public String sessionId; public String error; }

    @HttpPost
    global static Out post() {
        Out o = new Out();
        try {
            In req = (In) JSON.deserialize(RestContext.request.requestBody.toString(), In.class);
            if (String.isBlank(req.agentApiName) || String.isBlank(req.message)) {
                o.success = false; o.error = 'agentApiName and message are required'; return o;
            }
            AgentInvoker.Response r = AgentInvoker.callAgent(req.agentApiName, req.message, req.sessionId);
            o.success = r.success; o.agentResponse = r.agentResponse; o.sessionId = r.sessionId; o.error = r.error;
        } catch (Exception e) {
            o.success = false; o.error = e.getTypeName() + ': ' + e.getMessage();
        }
        return o;
    }
}
```

Endpoint: `POST /services/apexrest/agent`
Request:  `{ "agentApiName": "Product_Advisor", "message": "recommend a medium roast", "sessionId": "" }`
Response: `{ "success": true, "agentResponse": "...", "sessionId": "0Xx...." }`

> Grant the integration user access to this Apex class (add it to the `Kwitko_Integration` permission set or a
> dedicated one). Without Apex-class access the REST call returns 403/“not enabled for OAuth”.

### 2. Auth — three options, simplest first

**Option A — reuse the `sf` CLI session (zero secrets; great for local/dev).**
The MCP server shells out to the Salesforce CLI, which already holds an authenticated session for the org alias:
```bash
sf api request rest "/services/apexrest/agent" --method POST \
  --body '{"agentApiName":"Product_Advisor","message":"hi"}' \
  --target-org <alias>
```
No tokens are ever handled by the MCP server — the CLI injects the stored session. This is what the scaffold uses
by default (`AUTH_MODE=cli`). Ideal because in sandboxed environments the raw access token is redacted anyway.

**Option B — OAuth Client Credentials (headless server-to-server; for prod/CI).**
Create a Connected App with the **Client Credentials** flow, assign it a "run-as" integration user, and have the
MCP server exchange `client_id`/`client_secret` for an access token:
```
POST https://<MyDomain>.my.salesforce.com/services/oauth2/token
  grant_type=client_credentials&client_id=...&client_secret=...
-> { access_token, instance_url }
```
Then `POST {instance_url}/services/apexrest/agent` with `Authorization: Bearer <access_token>`.
Set `AUTH_MODE=oauth` and supply `SF_CLIENT_ID` / `SF_CLIENT_SECRET` / `SF_LOGIN_URL` env vars.

**Option C — JWT Bearer flow** (Connected App + private key, no stored secret) — same call shape as B, different
token grant. Use when you cannot store a client secret. (Not implemented in the scaffold; documented for parity.)

---

## Alternative call path — native Agent API (no Apex)

If you would rather not deploy any Apex, the **Agentforce Agent API** can drive an agent directly over REST. It is
more moving parts (you manage the session lifecycle yourself and need a Connected App + a configured agent
"connection"), so the scaffold does NOT use it, but the shape is:

```
# 1) Start a session for an agent
POST {instance_url}/einstein/ai-agent/v1/agents/{agentId}/sessions
  Authorization: Bearer <token>
  { "externalSessionKey": "<uuid>", "instanceConfig": { "endpoint": "{instance_url}" } }
-> { "sessionId": "..." }

# 2) Send a message (synchronous)
POST {instance_url}/einstein/ai-agent/v1/sessions/{sessionId}/messages
  { "message": { "sequenceId": 1, "type": "Text", "text": "recommend a medium roast" } }
-> { "messages": [ { "type": "Inform", "message": "..." } ] }

# 3) End the session
DELETE {instance_url}/einstein/ai-agent/v1/sessions/{sessionId}
```

Trade-off: the Apex-REST path reuses `AgentInvoker`'s privacy/unwrap logic and the in-org `generateAiAgentResponse`
action (no Connected App, no `agentId` lookup, no manual session start/stop). Prefer it unless a no-Apex
constraint forces the native Agent API.

---

## MCP tool contract

```jsonc
// tools/list -> one tool:
{
  "name": "ask_kwitko_agent",
  "description": "Send a message to a Kwitko Agentforce agent and get its reply. Pass sessionId to continue a multi-turn conversation.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "agentApiName": { "type": "string", "description": "Agent developer name, e.g. Product_Advisor, Inside_Sales, Post_Purchase_Growth, Kwitko_Concierge" },
      "message":      { "type": "string", "description": "Natural-language message to the agent" },
      "sessionId":    { "type": "string", "description": "Optional: continue an existing agent session" }
    },
    "required": ["agentApiName", "message"]
  }
}
```

`tools/call` returns the agent text as `content[0].text`, with the `sessionId` echoed in a structured block so the
client can pass it back on the next turn. On `success:false` the tool returns `isError:true` with the Apex error.

---

## Register the MCP server

**Claude Code / `claude_desktop_config.json` (`mcpServers`):**
```json
{
  "mcpServers": {
    "kwitko-agents": {
      "command": "node",
      "args": ["/ABSOLUTE/PATH/agentforce-dev/tools/agent-mcp/src/index.js"],
      "env": {
        "AUTH_MODE": "cli",
        "SF_TARGET_ORG": "AgentforceDev"
      }
    }
  }
}
```
For OAuth mode instead:
```json
"env": {
  "AUTH_MODE": "oauth",
  "SF_LOGIN_URL": "https://login.salesforce.com",
  "SF_CLIENT_ID": "...",
  "SF_CLIENT_SECRET": "...",
  "SF_APEX_BASE": "https://<MyDomain>.my.salesforce.com"
}
```

Then in any MCP client:
> Use `ask_kwitko_agent` with agentApiName `Product_Advisor` and message "recommend a medium roast single-origin".

---

## Files

- [`tools/agent-mcp/package.json`](../tools/agent-mcp/package.json) — deps (`@modelcontextprotocol/sdk`).
- [`tools/agent-mcp/src/index.js`](../tools/agent-mcp/src/index.js) — the stdio MCP server (CLI + OAuth auth modes).
- [`tools/agent-mcp/README.md`](../tools/agent-mcp/README.md) — install/run/register quickstart.
- Deploy `AgentRestResource.cls` (snippet above) to expose `AgentInvoker` over REST for `AUTH_MODE=oauth`.
  (`AUTH_MODE=cli` works against the same endpoint via `sf api request rest`.)
