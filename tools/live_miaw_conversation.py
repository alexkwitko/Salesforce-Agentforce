#!/usr/bin/env python3
import argparse
import json
import ssl
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

SCRT = "https://MYDOMAIN.develop.my.salesforce-scrt.com"
ORG = "00DXX0000000000"
ESDEV = "Kwitko_Web_Chat_V2"
AGENT_NAME = "Kwitko Concierge Web"


def post(path, body, token=None):
    req = urllib.request.Request(SCRT + path, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        res = urllib.request.urlopen(req, timeout=30, context=CTX)
        return res.status, res.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()


def delete(path, token=None):
    req = urllib.request.Request(SCRT + path, method="DELETE")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        res = urllib.request.urlopen(req, timeout=30, context=CTX)
        return res.status, res.read().decode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode()


def parse_texts(events):
    out = []
    for event, data in events:
        if event != "CONVERSATION_MESSAGE":
            continue
        try:
            entry = json.loads(data).get("conversationEntry", {})
            payload = entry.get("entryPayload")
            if isinstance(payload, str):
                payload = json.loads(payload)
            text = ""
            if isinstance(payload, dict):
                content = payload.get("abstractMessage", {}).get("staticContent", {}) or payload.get("staticContent", {})
                text = content.get("text", "")
            if text:
                out.append((entry.get("senderDisplayName", "?"), text))
        except Exception:
            pass
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--email", default="")
    parser.add_argument("--first-name", default="Alex")
    parser.add_argument("--turn", action="append", default=[])
    parser.add_argument("--stdin-turn", action="store_true", help="Read one extra turn from stdin when reached.")
    parser.add_argument(
        "--close-at-end",
        action="store_true",
        help="Attempt the v2 closeConversation API after the smoke run. Embedded deployments can reject this unless deploymentType=api.",
    )
    args = parser.parse_args()

    status, body = post(
        "/iamessage/v1/authorization/unauthenticated/accessToken",
        {"orgId": ORG, "developerName": ESDEV, "capabilitiesVersion": "260"},
    )
    token = json.loads(body)["accessToken"]
    conversation_id = str(uuid.uuid4())
    events = []

    def sse():
        req = urllib.request.Request(SCRT + "/eventrouter/v1/sse", method="GET")
        req.add_header("Authorization", "Bearer " + token)
        req.add_header("X-Org-Id", ORG)
        req.add_header("Accept", "text/event-stream")
        try:
            res = urllib.request.urlopen(req, timeout=600, context=CTX)
            current_event = None
            for raw in res:
                line = raw.decode(errors="replace").rstrip("\n")
                if line.startswith("event:"):
                    current_event = line[6:].strip()
                elif line.startswith("data:"):
                    events.append((current_event, line[5:].strip()))
        except Exception as exc:
            events.append(("__err__", str(exc)))

    threading.Thread(target=sse, daemon=True).start()
    time.sleep(2)

    routing = {}
    if args.email:
        routing = {
            "Kwitko_Logged_In_Email__c": args.email,
            "Kwitko_Logged_In_First_Name__c": args.first_name,
        }
    post("/iamessage/v1/conversation", {"conversationId": conversation_id, "routingAttributes": routing}, token)
    print(f"CONV_ID {conversation_id}", flush=True)
    print(f"ROUTING {json.dumps(routing)}", flush=True)

    def agent_text_count():
        return len([1 for sender, _ in parse_texts(events) if sender == AGENT_NAME])

    def wait_for_agent(before, seconds=240):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if agent_text_count() > before:
                return True
            time.sleep(3)
        return False

    print("WAIT_WELCOME", wait_for_agent(0, 90), flush=True)

    turns = list(args.turn)
    if args.stdin_turn:
        turns.append("__STDIN__")

    for turn in turns:
        if turn == "__STDIN__":
            print("NEED_STDIN_TURN", flush=True)
            turn = sys.stdin.readline().strip()
            print(f"GOT_STDIN_TURN {turn}", flush=True)
        before = agent_text_count()
        status, _ = post(
            "/iamessage/v1/conversation/" + conversation_id + "/message",
            {
                "id": str(uuid.uuid4()),
                "messageType": "StaticContentMessage",
                "staticContent": {"formatType": "Text", "text": turn},
            },
            token,
        )
        print(f"USER_SEND {status} {turn}", flush=True)
        ok = wait_for_agent(before)
        print(f"AGENT_REPLIED {ok}", flush=True)
        agent_texts = [text for sender, text in parse_texts(events) if sender == AGENT_NAME]
        if agent_texts:
            print("LAST_AGENT " + agent_texts[-1].replace("\n", " ")[:900], flush=True)

    print("=== TRANSCRIPT ===", flush=True)
    for sender, text in parse_texts(events):
        print(f"[{sender}] {text}", flush=True)

    if args.close_at_end:
        status, body = delete(
            "/iamessage/api/v2/conversation/" + conversation_id + "?esDeveloperName=" + ESDEV,
            token,
        )
        print(f"CLOSE_CONVERSATION {status} {body[:500]}", flush=True)
        if status == 401:
            print("CLOSE_CONVERSATION_NOTE closeConversation is v2/custom-client only for this org; this embedded deployment may leave the MessagingSession active until Salesforce lifecycle cleanup.", flush=True)


if __name__ == "__main__":
    main()
