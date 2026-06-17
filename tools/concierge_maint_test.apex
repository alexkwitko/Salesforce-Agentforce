String agent='Kwitko_Concierge_Web';
List<String> turns = new List<String>{
  'Is my espresso machine covered for maintenance, and can I book a service visit?',
  'Can you recommend a good coffee for a light-roast fan?'
};
String sid=null; Integer n=1;
for(String m: turns){
  AgentInvoker.Response r = (sid==null)?AgentInvoker.callAgent(agent,m):AgentInvoker.callAgent(agent,m,sid);
  sid=r.sessionId;
  System.debug('T'+n+' USER: '+m);
  System.debug('T'+n+' AGENT(ok='+r.success+'): '+r.agentResponse);
  n++;
}
