String agent='Maintenance_Concierge';
List<String> turns = new List<String>{
  'Hi, this is Blue Bottle Cafe. Is my espresso machine covered for maintenance?',
  'Great. Can you book a maintenance visit for 2026-08-05?',
  'Actually, please move it to 2026-08-20.',
  'You know what, please cancel it.',
  'Yes, I confirm - cancel the visit.'
};
String sid=null; Integer n=1;
for(String m: turns){
  AgentInvoker.Response r = (sid==null)?AgentInvoker.callAgent(agent,m):AgentInvoker.callAgent(agent,m,sid);
  sid=r.sessionId;
  System.debug('T'+n+' USER: '+m);
  System.debug('T'+n+' AGENT(ok='+r.success+'): '+r.agentResponse);
  n++;
}
