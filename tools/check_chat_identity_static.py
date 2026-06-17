#!/usr/bin/env python3
"""Static guardrails for Kwitko chat identity, logout, and Data Cloud SDK snippets."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


FILES = {
    "chat_bridge": "tools/wpcode_chat_auth_bridge.php",
    "session_reset": "tools/wpcode_chat_verified_session_reset.php",
    "dc_sdk": "tools/wpcode_datacloud_sdk.php",
    "controller": "tools/inchat-auth/kwitko_chat_controller.js",
    "plugin_controller": "tools/inchat-auth/kwitko-agentforce-bridge/assets/kwitko_chat_controller.js",
}


texts = {name: read(path) for name, path in FILES.items()}
checks = []


def check(label, ok, detail=""):
    checks.append((label, bool(ok), detail))


def has(name, *needles):
    text = texts[name]
    return all(needle in text for needle in needles)


def lacks_regex(name, pattern):
    return re.search(pattern, texts[name]) is None


check(
    "chat bridge version bumped past stale live version",
    "20260615.6" in texts["chat_bridge"],
)
check(
    "chat bridge sets only valid Kwitko hidden identity fields",
    has("chat_bridge", '"Kwitko_Logged_In_Email__c"', '"Kwitko_Logged_In_First_Name__c"')
    and lacks_regex("chat_bridge", r'"(?:Logged_In_Email|Logged_In_First_Name|loggedInEmail|loggedInFirstName)"'),
)
check(
    "chat bridge clears Salesforce session on logout",
    has("chat_bridge", "resetMessagingOnLogout", "clearSession({ shouldEndSession: true })", "userVerificationAPI.clearSession"),
)
check(
    "chat bridge resets Data Cloud identity on logout",
    has("chat_bridge", "kwitkoDataCloudReset", "kwitko_dc_reset_requested"),
)
check(
    "chat bridge prevents stale conversation identity reuse",
    has("chat_bridge", "kwitko_chat_identity", "ensureFreshConversationForIdentity", "endStaleConversation"),
)
check(
    "chat bridge sends JWT identity token when available",
    has("chat_bridge", "setIdentityToken", 'identityTokenType: "JWT"', "onEmbeddedMessagingIdentityTokenExpired"),
)
check(
    "session reset clears stale guest conversation once for logged-in users",
    has("session_reset", "kwitko_verified_reset_", "clearSalesforceChatSession", "sessionStorage.setItem"),
)
check(
    "session reset preserves correct hidden identity fields",
    has("session_reset", '"Kwitko_Logged_In_Email__c"', '"Kwitko_Logged_In_First_Name__c"')
    and lacks_regex("session_reset", r'"(?:Logged_In_Email|Logged_In_First_Name|loggedInEmail|loggedInFirstName)"'),
)
check(
    "Data Cloud SDK loads beacon as non-blocking script",
    '<script defer src="https://cdn.c360a.salesforce.com/beacon/' in texts["dc_sdk"],
)
check(
    "Data Cloud SDK emits identity schema events",
    has("dc_sdk", 'eventType: "contactPointEmail"', 'eventType: "identity"', 'eventType: "partyIdentification"', 'IDName: "WooCommerce User ID"'),
)
check(
    "Data Cloud SDK tracks browsing and add-to-cart events",
    has("dc_sdk", "initSitemap", "ViewCatalogObjectDetail", "ViewCatalogObject", "AddToCart"),
)
check(
    "Data Cloud SDK resets identity on logout or identity change",
    has("dc_sdk", "kwitko_dc_identity", "kwitko_dc_reset_requested", "resetSdkIdentity", "SalesforceInteractions.reset", "kwitkoDataCloudReset"),
)
legacy_alias_pattern = r'"(?:Logged_In_Email|Logged_In_First_Name|loggedInEmail|loggedInFirstName|cartToken|Kwitko_Cart_Token)"'
check(
    "standalone controller cannot emit legacy hidden-prechat aliases",
    lacks_regex("controller", legacy_alias_pattern),
)
check(
    "plugin controller cannot emit legacy hidden-prechat aliases",
    lacks_regex("plugin_controller", legacy_alias_pattern),
)


failed = 0
for label, ok, detail in checks:
    if ok:
        print(f"PASS  {label}")
    else:
        failed += 1
        suffix = f"  {detail}" if detail else ""
        print(f"FAIL  {label}{suffix}")

print(f"\nRESULT: {len(checks) - failed} passed, {failed} failed")
sys.exit(1 if failed else 0)
