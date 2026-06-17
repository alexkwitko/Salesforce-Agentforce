String agent='Quote_Copilot';
AgentInvoker.Response r = AgentInvoker.callAgent(agent, 'Quote Bluebird Cafe for 15 of the Coffee Club subscription at 5% off.');
System.debug('AGENT>> '+r.agentResponse);
