#!/usr/bin/env python3
from pathlib import Path


PATCH = Path("tools/wpcode_kwitko_live_routes_patch.php")
BODY = Path("tools/wpcode_kwitko_live_routes_patch.wpcode-body.txt")


def check(label, ok, details=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"PASS  {label}")
    else:
        failed += 1
        print(f"FAIL  {label}{': ' + details if details else ''}")


passed = 0
failed = 0
php = PATCH.read_text()
body = BODY.read_text()

check("paste body omits opening PHP tag", not body.lstrip().startswith("<?php"))
check("paste body matches PHP without opening tag", body == php.split("\n", 1)[1])
check("expected patch version", "KWITKO_LIVE_ROUTES_PATCH_VERSION', '20260615.13'" in php)

for route in [
    "/me",
    "/jwt",
    "/cart",
    "/identify",
    "/verification-code-email",
    "/return-label-email",
]:
    check(f"REST route {route}", f"'/ {route.lstrip('/')}'" not in php and f"'{route}'" in php)

for label, needle in [
    ("cart POST signature protected", "kwitko_live_verify_signature( $request )" ),
    ("OTP email route present", "Your Kwitko Coffee verification code"),
    ("return label email route present", "Your Kwitko Coffee return label - "),
    ("return label page present", "Kwitko Coffee Returns"),
    ("kc_add cart link handler", "empty( $_GET['kc_add'] )"),
    ("cartUrl exposed to frontend", "cartUrl:"),
    ("Woo Store API exposed to frontend", "storeApi:"),
    ("guarded cart poller", "KWITKO_CART_POLLER_VERSION"),
    ("login fallback exposed", "openLoginFallback"),
    ("Data Cloud SDK defer pattern", "c360a\\.salesforce\\.com"),
    ("Agentforce bootstrap defer pattern", "ESWKwitkoWebChat"),
    ("Woo admin return receipt action", "kwitko_mark_return_received"),
    ("identity hardening guard", "KWITKO_LIVE_IDENTITY_HARDENING_VERSION"),
    ("logout clears Salesforce chat", "clearSalesforceChatSession"),
    ("auth pending gate hides chat until identity settles", "kwitko-chat-auth-pending"),
    ("auth pending gate waits for prechat attempt", "prechatAttempted"),
    ("logout resets Data Cloud identity", "kwitko_dc_reset_requested"),
    ("JWT identity token gated until Salesforce auth mode is enabled", "jwtUserVerification"),
    ("hidden prechat identity fields", "Kwitko_Logged_In_Email__c"),
    ("hidden prechat cart token", "Kwitko_Cart_Token__c"),
]:
    check(label, needle in php)

for legacy in ['"Logged_In_Email"', '"Logged_In_First_Name"', '"loggedInEmail"', '"loggedInFirstName"']:
    check(f"legacy alias absent {legacy}", legacy not in php)

print(f"\nRESULT: {passed} passed, {failed} failed")
raise SystemExit(1 if failed else 0)
