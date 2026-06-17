import json, urllib.request, urllib.error, uuid, time, ssl
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
def newtok():
    st,b=post("/iamessage/v1/authorization/unauthenticated/accessToken",{"orgId":ORG,"developerName":ESDEV,"capabilitiesVersion":"260"})
    return json.loads(b)["accessToken"]
# Each probe: distinct sentinel value under a different key variant. Email key is the KNOWN-WORKING control.
probes = [
    {"label":"control_email", "ra":{"Kwitko_Logged_In_Email__c":"ZZPROBE-EMAIL@x.com"}},
    {"label":"brand_fieldname","ra":{"Brand__c":"ZZBRANDFIELD"}},
    {"label":"brand_actionvar","ra":{"brand":"ZZBRANDACTION"}},
    {"label":"brand_label",    "ra":{"Brand":"ZZBRANDLABEL"}},
    {"label":"cart_control",   "ra":{"Kwitko_Cart_Token__c":"ZZCARTPROBE"}},
]
for p in probes:
    tok=newtok(); CONV=str(uuid.uuid4())
    st,b=post("/iamessage/v1/conversation",{"conversationId":CONV,"routingAttributes":p["ra"]},tok)
    print(p["label"], "create:", st, "| ra:", p["ra"], "| CONV:", CONV)
    time.sleep(3)
print("\nWaiting 12s for routing flows to write fields...")
time.sleep(12)
print("Now query: SELECT Id, Brand__c, Kwitko_Logged_In_Email__c, Kwitko_Cart_Token__c, CreatedDate FROM MessagingSession ORDER BY CreatedDate DESC LIMIT 6")
