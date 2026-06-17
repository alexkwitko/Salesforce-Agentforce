AgentInvoker.Response r = AgentInvoker.callAgent('Kwitko_Concierge_Web', 'Is my espresso machine covered for maintenance, and can I book a service visit?');
System.debug('MAINT_RESP_START');
System.debug(r.success + ' :: ' + r.agentResponse);
System.debug('MAINT_RESP_END');
