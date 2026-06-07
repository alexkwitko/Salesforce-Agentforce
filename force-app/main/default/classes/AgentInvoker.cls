/**
 * AgentInvoker
 * Native bridge that lets automation (record-triggered Flows, scheduled jobs, other Apex)
 * RUN an Agentforce agent headlessly — so the AGENT'S OWN reasoning/topics/actions do the
 * work, instead of a parallel Apex path bypassing it.
 *
 * Uses the in-org platform action 'generateAiAgentResponse' (no Connected App / OAuth needed).
 * The agent runs as the CURRENT user, so headless callers must run as a privileged user.
 *
 * The platform returns agentResponse as a JSON envelope like {"type":"Text","value":"..."};
 * callAgent() unwraps it to the plain text the agent produced.
 */
public without sharing class AgentInvoker {

    public class Request {
        @InvocableVariable(label='Agent API Name' description='Developer/API name of the agent, e.g. Post_Purchase_Growth' required=true)
        public String agentApiName;
        @InvocableVariable(label='User Message' description='Natural-language instruction/context sent to the agent' required=true)
        public String userMessage;
        @InvocableVariable(label='Session Id (optional)' description='Pass to continue an existing agent session (multi-turn)')
        public String sessionId;
    }

    public class Response {
        @InvocableVariable(label='Agent Response') public String agentResponse;
        @InvocableVariable(label='Session Id') public String sessionId;
        @InvocableVariable(label='Success') public Boolean success;
        @InvocableVariable(label='Error') public String error;
    }

    @InvocableMethod(label='Invoke Agentforce Agent'
        description='Runs an Agentforce agent headlessly with a message and returns its response. Usable from Flow and Apex.')
    public static List<Response> invoke(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request r : requests) {
            out.add(callAgent(r.agentApiName, r.userMessage, r.sessionId));
        }
        return out;
    }

    /** Direct Apex entry point. Returns a Response with the unwrapped agent text. */
    public static Response callAgent(String agentApiName, String userMessage, String sessionId) {
        Response resp = new Response();
        resp.success = false;

        // Invoking a real agent isn't supported in test context; return a deterministic stub.
        if (Test.isRunningTest()) {
            resp.success = true;
            resp.sessionId = (String.isNotBlank(sessionId) ? sessionId : 'test-session');
            resp.agentResponse = '[test] ' + (userMessage == null ? '' : userMessage.left(40));
            return resp;
        }

        try {
            Invocable.Action action = Invocable.Action.createCustomAction('generateAiAgentResponse', agentApiName);
            action.setInvocationParameter('userMessage', userMessage);
            if (String.isNotBlank(sessionId)) action.setInvocationParameter('sessionId', sessionId);

            List<Invocable.Action.Result> results = action.invoke();
            Invocable.Action.Result result = results[0];

            if (result.isSuccess()) {
                Map<String, Object> outParams = result.getOutputParameters();
                resp.sessionId = (String) outParams.get('sessionId');
                resp.agentResponse = unwrap((String) outParams.get('agentResponse'));
                resp.success = true;
            } else {
                resp.error = String.valueOf(result.getErrors());
            }
        } catch (Exception e) {
            resp.error = e.getTypeName() + ': ' + e.getMessage();
        }
        return resp;
    }

    /** Convenience overload (no session). */
    public static Response callAgent(String agentApiName, String userMessage) {
        return callAgent(agentApiName, userMessage, null);
    }

    /**
     * The action returns agentResponse as a JSON envelope {"type":"Text","value":"..."}.
     * Pull out the human text; if it's not that shape, return the raw string.
     */
    @TestVisible
    private static String unwrap(String raw) {
        if (String.isBlank(raw)) return raw;
        try {
            Object parsed = JSON.deserializeUntyped(raw);
            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) parsed;
                if (m.containsKey('value') && m.get('value') != null) return String.valueOf(m.get('value'));
                if (m.containsKey('message') && m.get('message') != null) return String.valueOf(m.get('message'));
            }
        } catch (Exception ignored) {
            // not JSON — fall through to raw
        }
        return raw;
    }
}
