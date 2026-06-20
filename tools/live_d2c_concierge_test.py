import json, urllib.request, urllib.error, uuid, threading, time, ssl
CTX=ssl.create_default_context(); CTX.check_hostname=False; CTX.verify_mode=ssl.CERT_NONE
SCRT="https://orgfarm-162e45523f-dev-ed.develop.my.salesforce-scrt.com"
ORG="00Dfj00000QEVrQ"; ESDEV="Bean_Brew_Web_Chat"   # the D2C (Bean & Brew) chat deployment
def post(p,b,t=None):
    r=urllib.request.Request(SCRT+p,data=json.dumps(b).encode(),method="POST"); r.add_header("Content-Type","application/json")
    if t: r.add_header("Authorization","Bearer "+t)
    try:
        x=urllib.request.urlopen(r,timeout=30,context=CTX); return x.status,x.read().decode()
    except urllib.error.HTTPError as e: return e.code,e.read().decode()
st,b=post("/iamessage/v1/authorization/unauthenticated/accessToken",{"orgId":ORG,"developerName":ESDEV,"capabilitiesVersion":"260"})
if st>=400: print("accessToken FAILED",st,b[:300]); raise SystemExit
tok=json.loads(b)["accessToken"]; CONV=str(uuid.uuid4())
events=[]
def sse():
    req=urllib.request.Request(SCRT+"/eventrouter/v1/sse",method="GET")
    req.add_header("Authorization","Bearer "+tok); req.add_header("X-Org-Id",ORG); req.add_header("Accept","text/event-stream")
    try:
        r=urllib.request.urlopen(req,timeout=300,context=CTX); ev=None
        for raw in r:
            line=raw.decode(errors="replace").rstrip("\n")
            if line.startswith("event:"): ev=line[6:].strip()
            elif line.startswith("data:"): events.append((ev,line[5:].strip()))
    except Exception as e: events.append(("__err__",str(e)))
threading.Thread(target=sse,daemon=True).start(); time.sleep(2)
post("/iamessage/v1/conversation",{"conversationId":CONV,"routingAttributes":{}},tok)
print("CONV",CONV,"(Bean & Brew D2C deployment)")
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
def send_and_wait(text, secs=120):
    base=len([x for x in texts() if x[0]==AGENT and not is_greet(x[1])])
    time.sleep(2)
    post("/iamessage/v1/conversation/"+CONV+"/message",{"id":str(uuid.uuid4()),"messageType":"StaticContentMessage","staticContent":{"formatType":"Text","text":text}},tok)
    print("\n>>> USER:",text)
    dl=time.time()+secs; first=None
    while time.time()<dl:
        if len([x for x in texts() if x[0]==AGENT and not is_greet(x[1])])>base:
            if first is None: first=time.time()
            if time.time()-first>10: break
        time.sleep(4)
for msg in ["do you sell whole beans?",
            "i want to buy a grinder, add it to my cart"]:
    send_and_wait(msg)
print("\n=== FULL TRANSCRIPT ===")
for d,t in texts(): print(f"[{d}] {t}")
