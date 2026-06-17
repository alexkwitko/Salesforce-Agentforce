String agent = 'Subscription_Concierge';
List<String> turns = new List<String>{
    'Hi, my email is dana.demo@example.com. What am I subscribed to?',
    'Please start me on the coffee club with 6 bags.',
    'Actually, can you make it 12 bags?',
    'Great. Please renew me for another year.',
    'You know what, please cancel it.'
};
String sid = null;
Integer n = 1;
for (String msg : turns) {
    AgentInvoker.Response r = (sid == null)
        ? AgentInvoker.callAgent(agent, msg)
        : AgentInvoker.callAgent(agent, msg, sid);
    sid = r.sessionId;
    System.debug('TURN ' + n + ' USER: ' + msg);
    System.debug('TURN ' + n + ' AGENT(ok=' + r.success + '): ' + r.agentResponse);
    n++;
}
