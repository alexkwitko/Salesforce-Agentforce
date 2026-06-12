#!/usr/bin/env node
/**
 * Kwitko Agent MCP server.
 *
 * Exposes one tool, `ask_kwitko_agent(agentApiName, message, sessionId?)`, that runs an Agentforce
 * agent in the org and returns its reply. It calls the in-org Apex REST endpoint
 *   POST /services/apexrest/agent
 * which wraps AgentInvoker.callAgent (the platform `generateAiAgentResponse` action). See
 * docs/mcp-agent-consumer.md for the design and the AgentRestResource.cls snippet to deploy.
 *
 * Two auth modes (set AUTH_MODE):
 *   cli   (default)  -> shells out to `sf api request rest ...`, reusing the CLI's stored session.
 *                       No secrets handled here. Requires SF_TARGET_ORG (an `sf` org alias/username).
 *   oauth            -> Client Credentials flow against SF_LOGIN_URL using SF_CLIENT_ID/SF_CLIENT_SECRET,
 *                       then POSTs to SF_APEX_BASE + /services/apexrest/agent with a Bearer token.
 */
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema
} from '@modelcontextprotocol/sdk/types.js';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const AUTH_MODE = process.env.AUTH_MODE || 'cli';
const APEX_PATH = '/services/apexrest/agent';

// ---------------------------------------------------------------------------
// Call paths
// ---------------------------------------------------------------------------

/** CLI mode: `sf api request rest` injects the stored session — no token handling here. */
async function callViaCli(payload) {
  const targetOrg = process.env.SF_TARGET_ORG;
  if (!targetOrg) throw new Error('SF_TARGET_ORG is required when AUTH_MODE=cli');
  const args = [
    'api',
    'request',
    'rest',
    APEX_PATH,
    '--method',
    'POST',
    '--body',
    JSON.stringify(payload),
    '--target-org',
    targetOrg
  ];
  const { stdout } = await execFileAsync('sf', args, { maxBuffer: 10 * 1024 * 1024 });
  return JSON.parse(stdout);
}

let cachedToken = null; // { access_token, instance_url, expiresAt }

async function getOAuthToken() {
  const now = Date.now();
  if (cachedToken && cachedToken.expiresAt > now + 30_000) return cachedToken;

  const loginUrl = process.env.SF_LOGIN_URL || 'https://login.salesforce.com';
  const clientId = process.env.SF_CLIENT_ID;
  const clientSecret = process.env.SF_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    throw new Error('SF_CLIENT_ID and SF_CLIENT_SECRET are required when AUTH_MODE=oauth');
  }
  const body = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: clientId,
    client_secret: clientSecret
  });
  const res = await fetch(`${loginUrl}/services/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  });
  if (!res.ok) throw new Error(`OAuth token request failed: ${res.status} ${await res.text()}`);
  const json = await res.json();
  cachedToken = {
    access_token: json.access_token,
    instance_url: json.instance_url,
    // tokens last ~ minutes-to-hours; refresh defensively after ~10 min.
    expiresAt: now + 10 * 60 * 1000
  };
  return cachedToken;
}

/** OAuth mode: Client Credentials -> Bearer POST to the Apex REST endpoint. */
async function callViaOAuth(payload) {
  const tok = await getOAuthToken();
  const base = process.env.SF_APEX_BASE || tok.instance_url;
  const res = await fetch(`${base}${APEX_PATH}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${tok.access_token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(payload)
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Apex REST call failed: ${res.status} ${text}`);
  return JSON.parse(text);
}

async function askAgent({ agentApiName, message, sessionId }) {
  const payload = { agentApiName, message, sessionId: sessionId || '' };
  return AUTH_MODE === 'oauth' ? callViaOAuth(payload) : callViaCli(payload);
}

// ---------------------------------------------------------------------------
// MCP server
// ---------------------------------------------------------------------------

const TOOL = {
  name: 'ask_kwitko_agent',
  description:
    'Send a message to a Kwitko Agentforce agent and get its reply. Pass sessionId to continue a multi-turn conversation.',
  inputSchema: {
    type: 'object',
    properties: {
      agentApiName: {
        type: 'string',
        description:
          'Agent developer name, e.g. Product_Advisor, Inside_Sales, Post_Purchase_Growth, Kwitko_Concierge'
      },
      message: { type: 'string', description: 'Natural-language message to the agent' },
      sessionId: { type: 'string', description: 'Optional: continue an existing agent session' }
    },
    required: ['agentApiName', 'message']
  }
};

const server = new Server(
  { name: 'kwitko-agents', version: '0.1.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: [TOOL] }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (req.params.name !== 'ask_kwitko_agent') {
    return { isError: true, content: [{ type: 'text', text: `Unknown tool: ${req.params.name}` }] };
  }
  const { agentApiName, message, sessionId } = req.params.arguments || {};
  if (!agentApiName || !message) {
    return {
      isError: true,
      content: [{ type: 'text', text: 'agentApiName and message are required' }]
    };
  }
  try {
    const r = await askAgent({ agentApiName, message, sessionId });
    if (r && r.success === false) {
      return { isError: true, content: [{ type: 'text', text: `Agent error: ${r.error || 'unknown'}` }] };
    }
    const reply = (r && r.agentResponse) || '';
    const newSession = (r && r.sessionId) || '';
    return {
      content: [
        { type: 'text', text: reply },
        { type: 'text', text: `\n[sessionId: ${newSession}]` }
      ]
    };
  } catch (e) {
    return { isError: true, content: [{ type: 'text', text: `Call failed: ${e.message}` }] };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`kwitko-agent-mcp running (AUTH_MODE=${AUTH_MODE})`);
