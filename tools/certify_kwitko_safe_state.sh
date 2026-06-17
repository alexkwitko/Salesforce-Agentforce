#!/usr/bin/env bash
# Safe current-state certification for the Kwitko Salesforce/Woo/Data Cloud build.
#
# Default behavior avoids email sends, real refunds, purchases, and new chat sessions.
# The legacy Apex engagement endpoint smoke is opt-in via RUN_LEGACY_ENGAGEMENT=1;
# the default web-activity proof path is SDK/Data Cloud, not custom Apex web events.
#
# Usage:
#   ./tools/certify_kwitko_safe_state.sh [org] [email] [site]
#   LOCAL_ONLY=1 ./tools/certify_kwitko_safe_state.sh
#   RUN_LIVE_CHAT=1 ./tools/certify_kwitko_safe_state.sh
#
# LOCAL_ONLY=1 runs only source-level Agentforce/WPCode gates and skips live Woo,
# Data Cloud, Salesforce org, storage, email-limit, and live-chat checks.
#
# RUN_LIVE_CHAT=1 adds one headless MIAW order-status smoke. That creates a real
# closed service Case, MessagingSession, Task, and Agent_Interaction__c.
set -u

ORG="${1:-AgentforceDev}"
EMAIL="${2:-alexkwitko@gmail.com}"
SITE="${3:-https://deepskyblue-deer-920559.hostingersite.com}"
LOCAL_ONLY="${LOCAL_ONLY:-0}"
RUN_LIVE_CHAT="${RUN_LIVE_CHAT:-0}"
WPCODE_305_BODY="tmp/wpcode/wpcode_305_combined_datacloud_routes_20260615_9.wpcode-body.txt"

PASS=0
FAIL=0

section() {
  printf '\n== %s ==\n' "$1"
}

run_step() {
  local label="$1"
  shift
  printf '\n-- %s --\n' "$label"
  "$@"
  local status=$?
  if [ "$status" -eq 0 ]; then
    printf 'STEP PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'STEP FAIL: %s (exit %s)\n' "$label" "$status"
    FAIL=$((FAIL + 1))
  fi
}

lint_wpcode_305_body() {
  local tmp
  tmp="$(mktemp)"
  {
    printf '%s\n' '<?php'
    cat "$WPCODE_305_BODY"
  } > "$tmp"
  php -l "$tmp"
  local status=$?
  rm -f "$tmp"
  return "$status"
}

section "Inputs"
printf 'org=%s\nemail=%s\nsite=%s\nlocal_only=%s\nrun_live_chat=%s\n' "$ORG" "$EMAIL" "$SITE" "$LOCAL_ONLY" "$RUN_LIVE_CHAT"

section "Local WPCode Readiness"
run_step "Agentforce action contract static surface" python3 tools/check_agentforce_contracts_static.py
run_step "Latest planner bundle contract static surface" python3 tools/check_latest_planner_bundle_contracts_static.py
run_step "Service case coverage static surface" python3 tools/check_service_case_coverage_static.py
run_step "Revenue and Data Cloud contract static surface" python3 tools/check_revenue_datacloud_contracts_static.py
run_step "WPCode static surface" python3 tools/check_wpcode_patch_static.py
run_step "WPCode snippet 305 combined static surface" python3 tools/check_wpcode_305_combined_static.py "$WPCODE_305_BODY"
run_step "Chat identity/logout static surface" python3 tools/check_chat_identity_static.py
run_step "WPCode PHP syntax" php -l tools/wpcode_kwitko_live_routes_patch.php
run_step "WPCode snippet 305 combined PHP syntax" lint_wpcode_305_body

if [ "$LOCAL_ONLY" = "1" ]; then
  printf '\nSUMMARY: %d local steps passed, %d local steps failed\n' "$PASS" "$FAIL"
  exit "$FAIL"
fi

section "Live Woo Surface"
run_step "Woo REST routes" ./tools/check_live_woo_routes.sh "$SITE"
run_step "Woo frontend bridge" ./tools/check_live_woo_frontend.sh "$SITE"

section "Data Cloud, IR, Unified Profile"
run_step "SDK Data Cloud pipeline" ./tools/verify_sdk_datacloud_pipeline.sh "$ORG" "$EMAIL"
run_step "Unified Profile surface" ./tools/verify_unified_profile_surface.sh "$ORG" "$EMAIL"

section "Engagement, Prediction, Activation"
run_step "Engagement + prediction pipeline" ./tools/verify_pipeline.sh "$ORG"

section "Storage And Email Limits"
run_step "Storage pressure report" sf apex run --target-org "$ORG" --file tools/diagnose_storage_pressure.apex
run_step "Key org limits" bash -c 'sf limits api display --target-org "$0" --json | jq ".result[] | select(.name==\"DataStorageMB\" or .name==\"FileStorageMB\" or .name==\"SingleEmail\")"' "$ORG"

if [ "$RUN_LIVE_CHAT" = "1" ]; then
  section "Optional Live Chat Smoke"
  run_step "MIAW signed-in order-status smoke" python3 tools/live_miaw_conversation.py --email "$EMAIL" --first-name Alex --turn "where is my last order?"
else
  printf '\n== Optional Live Chat Smoke ==\nSKIP  RUN_LIVE_CHAT is not 1, so no new chat/session/case was created.\n'
fi

printf '\nSUMMARY: %d steps passed, %d steps failed\n' "$PASS" "$FAIL"
exit "$FAIL"
