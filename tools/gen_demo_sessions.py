#!/usr/bin/env python3
"""Generate REAL multi-turn MIAW sessions (for Agentforce Studio evidence).
Fires varied, topic-switching conversations through the live agent via SCRT.
No reply-waiting (headless can't read Enhanced Messaging replies) — it just
sends turns so the agent processes them server-side and the session registers.
Usage: gen_demo_sessions.py <channelDevName> <brand: kwitko|beanbrew> [limit] [startIndex]
"""
import json, ssl, sys, time, uuid, threading, urllib.error, urllib.request

CTX = ssl.create_default_context(); CTX.check_hostname=False; CTX.verify_mode=ssl.CERT_NONE
SCRT = "https://orgfarm-162e45523f-dev-ed.develop.my.salesforce-scrt.com"
ORG  = "00Dfj00000QEVrQEAX"

def post(path, body, token=None):
    req = urllib.request.Request(SCRT+path, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type","application/json")
    if token: req.add_header("Authorization","Bearer "+token)
    try:
        r=urllib.request.urlopen(req, timeout=30, context=CTX); return r.status, r.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()

def open_sse(token, sink):
    """Keep an SSE event stream alive — required precondition for conversation create."""
    def run():
        req=urllib.request.Request(SCRT+"/eventrouter/v1/sse", method="GET")
        req.add_header("Authorization","Bearer "+token); req.add_header("X-Org-Id",ORG[:15])
        req.add_header("Accept","text/event-stream")
        try:
            res=urllib.request.urlopen(req, timeout=600, context=CTX)
            for raw in res: sink.append(1)
        except Exception: pass
    t=threading.Thread(target=run, daemon=True); t.start(); return t

# Topic-switching scripts: shopping -> service -> maintenance -> off-topic (varied)
KWITKO = [
 ["Recommend a coffee for a strong morning espresso.","Actually, where's my most recent order?","Can you service my espresso machine too?","By the way, who do you think wins the World Cup?"],
 ["I want a smooth medium-roast for pour over.","Hold on — I need to return a bag that arrived stale.","Is my grinder still under warranty?","Also, what's the weather tomorrow?"],
 ["What's a good decaf that still tastes rich?","Can you check the tracking on my last shipment?","My machine is leaking — can a technician come?","Random q: what's your favorite movie?"],
 ["Suggest a single-origin for a French press.","I think I was double-charged on an order.","Do you offer a maintenance plan for equipment?","Tell me a joke about coffee."],
 ["I like chocolatey, low-acid coffee — what do you have?","Cancel my most recent order please.","When is my next service visit scheduled?","What time is it in Tokyo?"],
 ["Recommend something fruity and bright for drip.","My delivery is 5 days late, what's going on?","Is a descaling service covered for me?","Who painted the Mona Lisa?"],
 ["What's your best espresso blend for milk drinks?","I need to change the shipping address on an order.","Can you book a repair visit for my grinder?","Recommend a good sci-fi book."],
 ["I want a bold dark roast, whole bean, 2 bags.","Open a complaint — my last order was damaged.","Is my equipment covered under a care plan?","What's 17 times 23?"],
 ["Suggest a holiday gift coffee set.","Where is order number 00000745?","My espresso machine won't heat — help?","What's the capital of Australia?"],
 ["Recommend a cold brew concentrate.","I want a refund for a missing item.","Schedule a maintenance visit next week.","Do you like cats or dogs?"],
]
BEANBREW = [
 ["Recommend a good entry-level espresso grinder.","Where is my most recent order?","Book a maintenance visit for my machine.","Off topic — what's the weather?"],
 ["I need a dual-boiler espresso machine for a small cafe.","I want to return a frother that broke.","Is my machine still under warranty?","Who won the game last night?"],
 ["What's a quiet burr grinder for home?","Track my last shipment please.","My machine is leaking — send a technician.","Tell me a fun fact."],
 ["Suggest a descaling and cleaning kit.","I think my order was charged twice.","Do you have a maintenance/care plan?","What's your favorite song?"],
 ["Recommend a milk frother for lattes.","Cancel my most recent order.","When is my next service appointment?","What's the capital of France?"],
 ["I want a commercial-grade grinder for volume.","My delivery is late — what's happening?","Is a tune-up covered for me, or is it billable?","Recommend a good movie."],
 ["What knock box and tamper do you recommend?","Change the shipping address on my order.","Book a repair for my espresso machine.","What's 42 divided by 6?"],
 ["I need a pour-over kit and a gooseneck kettle.","Open a complaint — item arrived damaged.","Is my equipment under a service contract?","Who wrote Romeo and Juliet?"],
 ["Suggest a prosumer espresso machine under budget.","Where is order 00000750?","My grinder won't turn on — help.","What's the weather in London?"],
 ["Recommend replacement filters and a water softener.","I want a refund for a missing accessory.","Schedule a maintenance visit for next week.","Do you prefer tea or coffee?"],
]

def main():
    channel=sys.argv[1]; brand=sys.argv[2]
    limit=int(sys.argv[3]) if len(sys.argv)>3 else 10
    start=int(sys.argv[4]) if len(sys.argv)>4 else 0
    scripts = (KWITKO if brand=="kwitko" else BEANBREW)[start:start+limit]
    for i, turns in enumerate(scripts, start=start+1):
        status, body = post("/iamessage/v1/authorization/unauthenticated/accessToken",
                            {"orgId":ORG,"developerName":channel,"capabilitiesVersion":"260"})
        if status!=200:
            print(f"SESSION {i} TOKEN_FAIL {status} {body[:120]}", flush=True); continue
        token=json.loads(body)["accessToken"]
        open_sse(token, [])      # required precondition for conversation create
        time.sleep(2)
        conv=str(uuid.uuid4())
        # alternate signed-in / guest for variety/evidence
        routing = {"Kwitko_Logged_In_Email__c":"alexkwitko@gmail.com","Kwitko_Logged_In_First_Name__c":"Alex"} if i%2==0 else {}
        cs,_=post("/iamessage/v1/conversation",{"conversationId":conv,"routingAttributes":routing},token)
        print(f"SESSION {i} CREATE {cs} signedin={i%2==0} conv={conv}", flush=True)
        time.sleep(6)  # let the session establish + welcome
        for t,turn in enumerate(turns,1):
            ms,_=post("/iamessage/v1/conversation/"+conv+"/message",
                      {"id":str(uuid.uuid4()),"messageType":"StaticContentMessage",
                       "staticContent":{"formatType":"Text","text":turn}},token)
            print(f"  turn{t} {ms} {turn[:40]}", flush=True)
            time.sleep(7)  # let the agent process each turn
        print(f"SESSION {i} DONE", flush=True)
        time.sleep(2)

if __name__=="__main__":
    main()
