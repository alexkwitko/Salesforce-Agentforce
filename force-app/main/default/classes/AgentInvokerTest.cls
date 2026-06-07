@isTest
private class AgentInvokerTest {

    @isTest
    static void testInvokeStubInTestContext() {
        AgentInvoker.Request req = new AgentInvoker.Request();
        req.agentApiName = 'Post_Purchase_Growth';
        req.userMessage = 'Write an offer email for order 123';

        Test.startTest();
        List<AgentInvoker.Response> out = AgentInvoker.invoke(new List<AgentInvoker.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, out.size());
        System.assertEquals(true, out[0].success, 'stub should succeed in test context');
        System.assert(out[0].agentResponse.startsWith('[test]'), 'should return deterministic stub');
        System.assertEquals('test-session', out[0].sessionId);
    }

    @isTest
    static void testCallAgentOverloadAndSession() {
        AgentInvoker.Response r = AgentInvoker.callAgent('Inside_Sales', 'hello', 'sess-abc');
        System.assertEquals(true, r.success);
        System.assertEquals('sess-abc', r.sessionId, 'passed session id should be preserved');
    }

    @isTest
    static void testUnwrapEnvelope() {
        System.assertEquals('Hello there',
            AgentInvoker.unwrap('{"type":"Text","value":"Hello there"}'));
        System.assertEquals('plain text',
            AgentInvoker.unwrap('plain text'), 'non-JSON returns raw');
        System.assertEquals(null, AgentInvoker.unwrap(null));
    }
}
