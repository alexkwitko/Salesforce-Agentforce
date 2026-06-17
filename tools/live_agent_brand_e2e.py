import json, urllib.request, urllib.error, uuid, threading, time, ssl, sys
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

# argv[1]=brand ("Bean & Brew" | "Kwitko Coffee"), argv[2]=email (signed-in; "" for guest)
BRAND = sys.argv[1] if len(sys.argv)>1 else "Bean & Brew"
EMAIL = sys.argv[2] if len(sys.argv)>2 else "alexkwitko@gmail.com"
MSG   = sys.argv[3] if len(sys.argv)>3 else "I'm browsing — what would you recommend for me today?"

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
ra={"Brand__c": BRAND}
if EMAIL:
    ra["Kwitko_Logged_In_Email__c"]=EMAIL
    ra["Kwitko_Logged_In_First_Name__c"]="Alex"
st,b=post("/iamessage/v1/conversation",{"conversationId":CONV,"routingAttributes":ra},tok)
print("CONV",CONV,"| Brand:",BRAND,"| email:",EMAIL or "(guest)")
def send(text):
    time.sleep(2)
    s,_=post("/iamessage/v1/conversation/"+CONV+"/message",
          {"id":str(uuid.uuid4()),"messageType":"StaticContentMessage","staticContent":{"formatType":"Text","text":text}},tok)
    print("send:",s,"| msg:",text)
def agent_texts():
    out=[]
    for e,d in events:
        if e=="CONVERSATION_MESSAGE":
            try:
                j=json.loads(d); ce=j.get("conversationEntry",{})
                ep=ce.get("entryPayload")
                if isinstance(ep,str): ep=json.loads(ep)
                txt=""
                if isinstance(ep,dict):
                    ac=ep.get("abstractMessage",{}).get("staticContent",{}) or ep.get("staticContent",{})
                    txt=ac.get("text","")
                disp=ce.get("senderDisplayName","?")
                if txt: out.append((disp,txt))
            except Exception: pass
    return out
AGENT_NAME = "Kwitko Concierge Web"
def is_greeting(t):
    tl=t.lower()
    return tl.startswith("welcome") or "i can help you find what you're looking for" in tl or "what can i do for you" in tl
def substantive():
    # agent replies that are NOT the generic greeting/menu (i.e., real content like a recommendation)
    return [x for x in agent_texts() if x[0]==AGENT_NAME and not is_greeting(x[1])]
def wait_for_substantive(seconds, prev_count):
    dl=time.time()+seconds; first=None
    while time.time()<dl:
        if len(substantive())>prev_count:
            if first is None: first=time.time()
            if time.time()-first>12: break   # capture follow-on bubbles
        time.sleep(4)

# Turn 1: explicit shopping intent
send(MSG); wait_for_substantive(90, 0)
# Turn 2: if still only the greeting/menu, push for a concrete pick
if len(substantive())==0:
    send("Yes — please recommend one specific product for me to buy right now."); wait_for_substantive(110, 0)
# Turn 3: last nudge
if len(substantive())==0:
    send("Just give me your single best product recommendation."); wait_for_substantive(110, 0)

print("=== TRANSCRIPT ("+BRAND+") ===")
for d,t in agent_texts(): print(f"[{d}] {t}")
print("CONV_ID",CONV)
# Proves: routingAttributes(Brand__c) -> routing flow -> MessagingSession.Brand__c
#   -> agent linked var `brand` -> build_strategy(brand=...) -> brand-scoped catalog.
