import json, urllib.request, urllib.error, uuid, threading, time, ssl
CTX=ssl.create_default_context(); CTX.check_hostname=False; CTX.verify_mode=ssl.CERT_NONE
SCRT="https://MYDOMAIN.develop.my.salesforce-scrt.com"
ORG="00DXX0000000000"; ESDEV="Kwitko_Web_Chat_V2"
def post(path, body, token=None):
    req=urllib.request.Request(SCRT+path, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type","application/json")
    if token: req.add_header("Authorization","Bearer "+token)
    try:
        r=urllib.request.urlopen(req, timeout=30, context=CTX); return r.status, r.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()

EMAIL = __import__("sys").argv[1] if len(__import__("sys").argv)>1 else "alexkwitko@gmail.com"
st,b=post("/iamessage/v1/authorization/unauthenticated/accessToken",{"orgId":ORG,"developerName":ESDEV,"capabilitiesVersion":"260"})
tok=json.loads(b)["accessToken"]; CONV=str(uuid.uuid4())
events=[]
def sse():
    req=urllib.request.Request(SCRT+"/eventrouter/v1/sse", method="GET")
    req.add_header("Authorization","Bearer "+tok); req.add_header("X-Org-Id",ORG); req.add_header("Accept","text/event-stream")
    try:
        r=urllib.request.urlopen(req, timeout=230, context=CTX); ev=None
        for raw in r:
            line=raw.decode(errors="replace").rstrip("\n")
            if line.startswith("event:"): ev=line[6:].strip()
            elif line.startswith("data:"): events.append((ev,line[5:].strip()))
    except Exception as e: events.append(("__err__",str(e)))
threading.Thread(target=sse,daemon=True).start(); time.sleep(2)
ra={
    "Kwitko_Logged_In_Email__c": EMAIL,
    "Kwitko_Logged_In_First_Name__c": "Alex",
} if EMAIL else {}
st,b=post("/iamessage/v1/conversation",{"conversationId":CONV,"routingAttributes":ra},tok)
print("CONV",CONV,"| routingAttributes:",ra if ra else "(none = guest)")
time.sleep(3)
st,b=post("/iamessage/v1/conversation/"+CONV+"/message",
          {"id":str(uuid.uuid4()),"messageType":"StaticContentMessage","staticContent":{"formatType":"Text","text":"Hi, where is my last order?"}},tok)
print("send:",st)
def agent_texts():
    out=[]
    for e,d in events:
        if e=="CONVERSATION_MESSAGE":
            try:
                j=json.loads(d); ce=j.get("conversationEntry",{})
                sender=ce.get("sender",{}).get("role") or ce.get("senderDisplayName")
                ep=ce.get("entryPayload")
                if isinstance(ep,str): ep=json.loads(ep)
                txt=""
                if isinstance(ep,dict):
                    ac=ep.get("abstractMessage",{}).get("staticContent",{}) or ep.get("staticContent",{})
                    txt=ac.get("text","")
                disp=ce.get("senderDisplayName","?")
                if txt: out.append((disp,txt))
            except Exception as ex: pass
    return out
# Poll up to 200s for a REAL agent reply (guest/verification path is slow ~100-200s because it
# runs an email-send action). Break only on an AGENT message that isn't the static welcome — NOT
# on the user's own echoed message. Fixed-sleep windows were too short and gave false "no reply".
AGENT_NAME = "Kwitko Concierge Web"
_deadline = time.time() + 200
while time.time() < _deadline:
    if [x for x in agent_texts() if x[0] == AGENT_NAME and "Welcome to Kwitko" not in x[1]]:
        break
    time.sleep(5)
print("=== TRANSCRIPT ===")
for d,t in agent_texts(): print(f"[{d}] {t}")
print("CONV_ID",CONV)

# USAGE:
#   python3 tools/live_agent_e2e.py alexkwitko@gmail.com   # signed-in: agent should recognize + return order, never ask for email
#   python3 tools/live_agent_e2e.py ""                     # guest: agent must ask for email / expose nothing
# Drives the REAL live Service Agent over the SCRT2 REST + SSE API (Enhanced Messaging V2).
# Creates a real MessagingSession but NO AI-Evaluation records => does NOT consume the 5MB storage
# that `sf agent test`/run-eval burns. This is the storage-free way to certify the live agent.
# Chain proven: routingAttributes(Kwitko_Logged_In_Email__c) -> routing flow Set_Identity_On_Session
#   -> MessagingSession.Kwitko_Logged_In_Email__c -> agent `linked` var loggedInEmail -> recognition.
