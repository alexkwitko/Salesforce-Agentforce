import json, urllib.request, uuid, threading, time, ssl, subprocess, sys
CTX=ssl.create_default_context(); CTX.check_hostname=False; CTX.verify_mode=ssl.CERT_NONE
SCRT="https://MYDOMAIN.develop.my.salesforce-scrt.com"
ORG="00DXX0000000000"; ESDEV="Kwitko_Web_Chat_V2"
BRAND=sys.argv[1] if len(sys.argv)>1 else "Bean & Brew"
MSG=sys.argv[2] if len(sys.argv)>2 else "I'm setting up my home espresso bar. What one product do you recommend I buy?"
def post(p,b,t=None):
    r=urllib.request.Request(SCRT+p,data=json.dumps(b).encode(),method="POST"); r.add_header("Content-Type","application/json")
    if t: r.add_header("Authorization","Bearer "+t)
    try:
        x=urllib.request.urlopen(r,timeout=30,context=CTX); return x.status,x.read().decode()
    except urllib.error.HTTPError as e: return e.code,e.read().decode()
def sf_json(args):
    out=subprocess.run(args,capture_output=True,text=True).stdout
    return json.loads(out)
st,b=post("/iamessage/v1/authorization/unauthenticated/accessToken",{"orgId":ORG,"developerName":ESDEV,"capabilitiesVersion":"260"})
tok=json.loads(b)["accessToken"]; CONV=str(uuid.uuid4())
events=[]
def sse():
    req=urllib.request.Request(SCRT+"/eventrouter/v1/sse",method="GET")
    req.add_header("Authorization","Bearer "+tok); req.add_header("X-Org-Id",ORG); req.add_header("Accept","text/event-stream")
    try:
        r=urllib.request.urlopen(req,timeout=240,context=CTX); ev=None
        for raw in r:
            line=raw.decode(errors="replace").rstrip("\n")
            if line.startswith("event:"): ev=line[6:].strip()
            elif line.startswith("data:"): events.append((ev,line[5:].strip()))
    except Exception as e: events.append(("__err__",str(e)))
threading.Thread(target=sse,daemon=True).start(); time.sleep(2)
# Identified session (so the agent engages shopping), brand intentionally NOT passed (param transport blocked)
ra={"Kwitko_Logged_In_Email__c":"alexkwitko@gmail.com","Kwitko_Logged_In_First_Name__c":"Alex"}
post("/iamessage/v1/conversation",{"conversationId":CONV,"routingAttributes":ra},tok)
print("CONV",CONV)
time.sleep(5)
# Simulate the published-param outcome: write Brand__c onto the just-created session BEFORE the shopping turn
q=sf_json(["sf","data","query","--query","SELECT Id FROM MessagingSession ORDER BY CreatedDate DESC LIMIT 1","--json"])
sid=q["result"]["records"][0]["Id"]; print("session",sid)
u=sf_json(["sf","data","update","record","--sobject","MessagingSession","--record-id",sid,"--values","Brand__c='%s'"%BRAND,"--json"])
print("set Brand__c=%s -> status"%BRAND, u.get("status"))
v=sf_json(["sf","data","query","--query","SELECT Brand__c FROM MessagingSession WHERE Id='%s'"%sid,"--json"])
print("  stored Brand__c =", v["result"]["records"][0]["Brand__c"])
time.sleep(2)
post("/iamessage/v1/conversation/"+CONV+"/message",{"id":str(uuid.uuid4()),"messageType":"StaticContentMessage","staticContent":{"formatType":"Text","text":MSG}},tok)
print("send msg:",MSG)
AGENT="Kwitko Concierge Web"
def texts():
    out=[]
    for e,d in events:
        if e=="CONVERSATION_MESSAGE":
            try:
                j=json.loads(d); ce=j.get("conversationEntry",{}); ep=ce.get("entryPayload")
                if isinstance(ep,str): ep=json.loads(ep)
                ac=ep.get("abstractMessage",{}).get("staticContent",{}) or ep.get("staticContent",{})
                t=ac.get("text","")
                if t: out.append((ce.get("senderDisplayName","?"),t))
            except Exception: pass
    return out
def is_greet(t):
    tl=t.lower(); return tl.startswith("welcome") or "i can help you find" in tl or "what can i do for you" in tl
dl=time.time()+200; first=None
while time.time()<dl:
    sub=[x for x in texts() if x[0]==AGENT and not is_greet(x[1])]
    if sub:
        if first is None: first=time.time()
        if time.time()-first>12: break
    time.sleep(4)
print("=== TRANSCRIPT (Brand__c=%s set on session) ==="%BRAND)
for d,t in texts(): print(f"[{d}] {t}")
