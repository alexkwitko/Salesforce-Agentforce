String agent='Maintenance_Concierge';
List<String> turns = new List<String>{
  'This is Blue Bottle Cafe. Please book a maintenance visit for 2026-10-10.',
  'Please cancel that visit.',
  'Yes, I confirm.'
};
String sid=null; Integer n=1;
for(String m: turns){
  AgentInvoker.Response r = (sid==null)?AgentInvoker.callAgent(agent,m):AgentInvoker.callAgent(agent,m,sid);
  sid=r.sessionId;
  System.debug('T'+n+' AGENT(ok='+r.success+'): '+r.agentResponse);
  n++;
}
