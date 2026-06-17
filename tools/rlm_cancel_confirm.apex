AgentInvoker.Response r1 = AgentInvoker.callAgent('Subscription_Concierge', 'Please cancel my coffee subscription. My email is dana.demo@example.com.');
System.debug('T1 AGENT: ' + r1.agentResponse);
AgentInvoker.Response r2 = AgentInvoker.callAgent('Subscription_Concierge', 'Yes, I confirm, cancel it.', r1.sessionId);
System.debug('T2 AGENT: ' + r2.agentResponse);
