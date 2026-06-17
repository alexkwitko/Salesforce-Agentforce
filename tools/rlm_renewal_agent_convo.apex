String agent='Renewal_Retention';
List<String> turns = new List<String>{
  'Review my renewal book for the next 60 days.',
  'Renew Downtown Diner for another year.',
  'Log a retention save for Acme Roasters - offer 15% loyalty discount before renewal.'
};
String sid=null; Integer n=1;
for(String m: turns){
  AgentInvoker.Response r = (sid==null)?AgentInvoker.callAgent(agent,m):AgentInvoker.callAgent(agent,m,sid);
  sid=r.sessionId;
  System.debug('T'+n+' USER: '+m);
  System.debug('T'+n+' AGENT(ok='+r.success+'): '+r.agentResponse);
  n++;
}
