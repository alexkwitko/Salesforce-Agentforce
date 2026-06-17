#!/usr/bin/env python3
from pathlib import Path
import sys


DEFAULT_BODY = Path("tmp/wpcode/wpcode_305_combined_datacloud_routes_20260615_9.wpcode-body.txt")


def check(label, ok, details=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {label}")
    else:
        failed += 1
        print(f"FAIL  {label}{': ' + details if details else ''}")


body_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_BODY
passed = 0
failed = 0

if not body_path.exists():
    print(f"FAIL  combined WPCode body exists: missing {body_path}")
    raise SystemExit(1)

body = body_path.read_text()

check("paste body omits opening PHP tag", not body.lstrip().startswith("<?php"))
check("combined patch version", "KWITKO_LIVE_ROUTES_PATCH_VERSION', '20260615.13'" in body)
check("Data Cloud SDK beacon configured", "cdn.c360a.salesforce.com/beacon" in body)
check("Data Cloud identify alias", "window.kwitkoDataCloudIdentify = window.kwitkoIdentify" in body)
check("Data Cloud logout reset", "kwitkoDataCloudReset" in body and "SalesforceInteractions.reset" in body)

for route in [
    "/me",
    "/jwt",
    "/cart",
    "/identify",
    "/verification-code-email",
    "/return-label-email",
    "/service-interaction",
    "/service-interactions/pull",
    "/service-interactions/ack",
]:
    check(f"REST route {route}", f"'{route}'" in body)

for label, needle in [
    ("signed POST protection helper", "kwitko_live_verify_signature( WP_REST_Request $request"),
    ("cart POST signature protected", "kwitko_live_verify_signature( $request )"),
    ("OTP email route body", "Your Kwitko Coffee verification code"),
    ("return label email route body", "Your Kwitko Coffee return label - "),
    ("return label page", "Kwitko Coffee Returns"),
    ("kc_add cart link handler", "empty( $_GET['kc_add'] )"),
    ("frontend service interaction URL", "serviceInteractionUrl:"),
    ("frontend service logging function", "function logServiceInteraction(message, category)"),
    ("frontend conversation id capture", 'sessionStorage.setItem("kwitko_conversation_id", id)'),
    ("frontend service log dedupe", "kwitko_last_service_log"),
    ("service log option storage", "kwitko_service_interaction_logs"),
    ("service log pull endpoint skips exported logs", "! empty( $entry['exportedAt'] )"),
    ("service log ack endpoint", "/service-interactions/ack"),
    ("Woo admin return receipt action", "kwitko_mark_return_received"),
    ("logout clears Salesforce chat", "clearSalesforceChatSession"),
    ("auth pending gate hides chat until identity settles", "kwitko-chat-auth-pending"),
    ("auth pending gate waits for prechat attempt", "prechatAttempted"),
    ("logged-in load clears stale guest chat once", "resetLoggedInStaleGuestConversationOnce"),
    ("session reset marker exposed", "KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION"),
    ("prechat waits for Embedded Messaging ready", "if (!messagingReady) return"),
    ("logout resets Data Cloud identity", "kwitko_dc_reset_requested"),
    ("JWT gated until SF auth mode enabled", "jwtUserVerification"),
    ("hidden prechat email field", "Kwitko_Logged_In_Email__c"),
    ("hidden prechat first name field", "Kwitko_Logged_In_First_Name__c"),
    ("hidden prechat cart token", "Kwitko_Cart_Token__c"),
]:
    check(label, needle in body)

for legacy in ['"Logged_In_Email"', '"Logged_In_First_Name"', '"loggedInEmail"', '"loggedInFirstName"']:
    check(f"legacy alias absent {legacy}", legacy not in body)

print(f"\nRESULT: {passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
