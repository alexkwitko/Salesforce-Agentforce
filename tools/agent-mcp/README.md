# kwitko-agent-mcp

A small **MCP server** that exposes the org's Agentforce agents as one tool:

```
ask_kwitko_agent(agentApiName, message, sessionId?) -> agent reply + sessionId
```

It calls the in-org Apex REST endpoint `POST /services/apexrest/agent`, which wraps
`AgentInvoker.callAgent` (the platform `generateAiAgentResponse` action). Full design:
[`../../docs/mcp-agent-consumer.md`](../../docs/mcp-agent-consumer.md).

## Prereqs

1. Deploy `AgentInvoker.cls` (already in the repo) and `AgentRestResource.cls` (snippet in the design doc).
2. Grant your integration user access to the `AgentRestResource` Apex class.
3. Node >= 18.

## Install & run

```bash
npm install            # installs @modelcontextprotocol/sdk
AUTH_MODE=cli SF_TARGET_ORG=AgentforceDev node src/index.js
```

## Auth modes

| Mode    | Env vars                                                              | Notes |
|---------|----------------------------------------------------------------------|-------|
| `cli`   | `SF_TARGET_ORG` (an `sf` org alias/username)                          | Default. Reuses the Salesforce CLI session via `sf api request rest`. No secrets. |
| `oauth` | `SF_CLIENT_ID`, `SF_CLIENT_SECRET`, `SF_LOGIN_URL`, `SF_APEX_BASE?`   | Client Credentials flow; Bearer POST to the Apex REST endpoint. |

## Register (Claude Code / Claude Desktop `mcpServers`)

```json
{
  "mcpServers": {
    "kwitko-agents": {
      "command": "node",
      "args": ["/ABSOLUTE/PATH/agentforce-dev/tools/agent-mcp/src/index.js"],
      "env": { "AUTH_MODE": "cli", "SF_TARGET_ORG": "AgentforceDev" }
    }
  }
}
```

Then: *"Use ask_kwitko_agent with agentApiName Product_Advisor and message 'recommend a medium roast'."*
