#!/usr/bin/env bash
# Runs the vetted Kwitko storage cleanup steps in a safe order and captures
# before/after evidence. This script avoids live chat/email/refund actions.
#
# Usage:
#   ./tools/clean_kwitko_storage_safe.sh [org]
#   RUN_GENERATED_HIST_CLEANUP=1 ./tools/clean_kwitko_storage_safe.sh AgentforceDev
#
# Default cleanup removes only transient/proof/recycle-bin artifacts:
# - expired OTP rows
# - synthetic STORAGE-PROBE web events and Churn_Training__c rows
# - stale Codex proof rows
# - old service/chat test artifacts
# - already-deleted recycle-bin rows where Salesforce still allows purge
#
# Generated historical prediction rows are opt-in because they are useful when
# retraining or re-certifying the prediction demo.
set -u

ORG="${1:-AgentforceDev}"
RUN_GENERATED_HIST_CLEANUP="${RUN_GENERATED_HIST_CLEANUP:-0}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="tmp/storage-cleanup/${STAMP}"
PASS=0
FAIL=0

mkdir -p "$OUT_DIR"

section() {
  printf '\n== %s ==\n' "$1"
}

run_step() {
  local label="$1"
  shift
  local slug
  slug="$(printf '%s' "$label" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9_-')"
  local log_file="${OUT_DIR}/${slug}.log"

  printf '\n-- %s --\n' "$label"
  "$@" 2>&1 | tee "$log_file"
  local cmd_status=${PIPESTATUS[0]}

  if [ "$cmd_status" -eq 0 ]; then
    printf 'STEP PASS: %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf 'STEP FAIL: %s (exit %s)\n' "$label" "$cmd_status"
    FAIL=$((FAIL + 1))
  fi
}

run_apex() {
  local file="$1"
  sf apex run --target-org "$ORG" --file "$file"
}

section "Inputs"
printf 'org=%s\nrun_generated_hist_cleanup=%s\nlog_dir=%s\n' \
  "$ORG" "$RUN_GENERATED_HIST_CLEANUP" "$OUT_DIR"

section "API Availability"
if ! sf limits api display --target-org "$ORG" --json >"${OUT_DIR}/limits-before.json" 2>"${OUT_DIR}/limits-before.err"; then
  cat "${OUT_DIR}/limits-before.err"
  if jq -e '.message' "${OUT_DIR}/limits-before.json" >/dev/null 2>&1; then
    jq '{name, message, code, status}' "${OUT_DIR}/limits-before.json"
  else
    cat "${OUT_DIR}/limits-before.json"
  fi
  printf '\nABORT: Salesforce API is not available for %s. No cleanup ran.\n' "$ORG"
  printf 'Saved evidence under %s\n' "$OUT_DIR"
  exit 2
fi
cat "${OUT_DIR}/limits-before.json" | jq '.result[] | select(.name=="DataStorageMB" or .name=="FileStorageMB" or .name=="SingleEmail")'

section "Before Counts"
run_step "Storage pressure before" run_apex tools/diagnose_storage_pressure.apex

section "Safe Cleanup"
run_step "Expired verification cleanup" run_apex tools/cleanup_expired_verifications.apex
run_step "Transient storage cleanup" run_apex tools/cleanup_transient_storage.apex
run_step "Stale Codex proof cleanup" run_apex tools/cleanup_stale_codex_proof_storage.apex
run_step "Old service artifact cleanup" run_apex tools/cleanup_old_service_test_artifacts.apex

if [ "$RUN_GENERATED_HIST_CLEANUP" = "1" ]; then
  section "Generated Historical Cleanup"
  run_step "Generated hist order cleanup" run_apex tools/cleanup_generated_hist_orders.apex
  run_step "Generated hist account cleanup" run_apex tools/cleanup_generated_hist_accounts.apex
  run_step "Generated hist recycle purge" run_apex tools/purge_generated_hist_recycle_bin.apex
else
  printf '\n== Generated Historical Cleanup ==\n'
  printf 'SKIP  RUN_GENERATED_HIST_CLEANUP is not 1.\n'
fi

section "Recycle Bin Purge"
run_step "Service recycle-bin purge" run_apex tools/purge_service_recycle_bin.apex
run_step "Broad recycle-bin batch purge" run_apex tools/purge_recycle_bin_storage_batches.apex
run_step "Recycle-bin purge diagnostics" run_apex tools/diagnose_recycle_bin_purge_errors.apex

section "After Counts"
run_step "Storage pressure after" run_apex tools/diagnose_storage_pressure.apex
run_step "Key limits after" bash -c \
  'sf limits api display --target-org "$0" --json | tee "$1" | jq ".result[] | select(.name==\"DataStorageMB\" or .name==\"FileStorageMB\" or .name==\"SingleEmail\")"' \
  "$ORG" "${OUT_DIR}/limits-after.json"

printf '\nSUMMARY: %d steps passed, %d steps failed\n' "$PASS" "$FAIL"
printf 'Saved evidence under %s\n' "$OUT_DIR"
exit "$FAIL"
