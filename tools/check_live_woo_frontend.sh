#!/usr/bin/env bash
set -euo pipefail

SITE="${1:-https://deepskyblue-deer-920559.hostingersite.com}"
HTML="$(mktemp)"
trap 'rm -f "$HTML"' EXIT

curl -fsSL "$SITE/" -o "$HTML"

pass=0
fail=0

check_present() {
  local label="$1"
  local pattern="$2"
  if rg -q "$pattern" "$HTML"; then
    printf 'PASS  %s\n' "$label"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n' "$label"
    fail=$((fail + 1))
  fi
}

check_absent() {
  local label="$1"
  local pattern="$2"
  if rg -q "$pattern" "$HTML"; then
    printf 'FAIL  %s\n' "$label"
    fail=$((fail + 1))
  else
    printf 'PASS  %s\n' "$label"
    pass=$((pass + 1))
  fi
}

check_deferred_script() {
  local label="$1"
  local src_pattern="$2"
  if python3 - "$HTML" "$src_pattern" <<'PY'
import re
import sys

html = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
src_pattern = re.compile(sys.argv[2], re.I)
for match in re.finditer(r"<script\b[^>]*\bsrc=['\"]([^'\"]+)['\"][^>]*>", html, re.I):
    tag = match.group(0)
    src = match.group(1)
    if src_pattern.search(src):
        if re.search(r"\b(async|defer)\b", tag, re.I):
            sys.exit(0)
        sys.exit(1)
sys.exit(1)
PY
  then
    printf 'PASS  %s\n' "$label"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s\n' "$label"
    fail=$((fail + 1))
  fi
}

check_present "KWITKO_AUTH present" "window\\.KWITKO_AUTH"
check_present "chat auth bridge present" "kwitko-chat-auth-bridge|KWITKO_CHAT_AUTH_BRIDGE_VERSION"
check_present "session reset present" "kwitko-chat-verified-session-reset|KWITKO_WIDGET_IDENTITY_HOTFIX_VERSION"
check_present "cart URL exposed" "cartUrl"
check_present "Woo Store API exposed" "storeApi"
check_present "guarded cart poller active" "KWITKO_CART_POLLER_VERSION|kwitko_chat_controller\\.js"
check_present "identity hardening active" "KWITKO_LIVE_IDENTITY_HARDENING_VERSION"
check_present "sign-in modal fallback active" "openLoginFallback"
check_deferred_script "Data Cloud SDK script non-blocking" "c360a\\.salesforce\\.com"
check_deferred_script "Agentforce bootstrap script non-blocking" "ESWKwitkoWebChat|embeddedservice"
check_absent "legacy invalid prechat aliases absent" "\"Logged_In_Email\"|\"Logged_In_First_Name\""

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
test "$fail" -eq 0
