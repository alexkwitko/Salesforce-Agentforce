#!/usr/bin/env bash
set -euo pipefail

SITE="${1:-https://deepskyblue-deer-920559.hostingersite.com}"

pass=0
fail=0

check_status() {
  local label="$1"
  local expected="$2"
  shift 2
  local status
  status="$(curl -sS -o /tmp/kwitko_route_body.$$ -w '%{http_code}' "$@")"
  local body
  body="$(cat /tmp/kwitko_route_body.$$)"
  rm -f /tmp/kwitko_route_body.$$
  if [[ "$status" =~ ^($expected)$ ]]; then
    printf 'PASS  %-32s HTTP %s\n' "$label" "$status"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-32s HTTP %s expected %s\n' "$label" "$status" "$expected"
    printf '      %s\n' "${body:0:220}"
    fail=$((fail + 1))
  fi
}

check_contains() {
  local label="$1"
  local needle="$2"
  shift 2
  local body
  body="$(curl -sS "$@")"
  if [[ "$body" == *"$needle"* ]]; then
    printf 'PASS  %-32s contains %s\n' "$label" "$needle"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-32s missing %s\n' "$label" "$needle"
    printf '      %s\n' "${body:0:220}"
    fail=$((fail + 1))
  fi
}

check_version_at_least() {
  local label="$1"
  local minimum="$2"
  shift 2
  local body version ok
  body="$(curl -sS "$@")"
  version="$(python3 - "$body" <<'PY'
import json
import re
import sys

raw = sys.argv[1]
try:
    data = json.loads(raw)
    print(str(data.get("bridge_version") or ""))
except Exception:
    match = re.search(r"\d{8}\.\d+", raw)
    print(match.group(0) if match else "")
PY
)"
  ok="$(python3 - "$version" "$minimum" <<'PY'
import sys

def parts(value):
    try:
        return [int(piece) for piece in value.split(".")]
    except Exception:
        return []

current = parts(sys.argv[1])
minimum = parts(sys.argv[2])
length = max(len(current), len(minimum))
current += [0] * (length - len(current))
minimum += [0] * (length - len(minimum))
print("1" if current >= minimum else "0")
PY
)"
  if [[ "$ok" == "1" ]]; then
    printf 'PASS  %-32s %s >= %s\n' "$label" "$version" "$minimum"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-32s version %s < %s\n' "$label" "${version:-missing}" "$minimum"
    printf '      %s\n' "${body:0:220}"
    fail=$((fail + 1))
  fi
}

check_version_at_least "me route version" "20260615.7" "$SITE/wp-json/kwitko/v1/me"
check_status "jwt guest protected" "401" "$SITE/wp-json/kwitko/v1/jwt"
check_status "cart GET exists" "200" "$SITE/wp-json/kwitko/v1/cart?token=codex-route-check"
check_status "cart POST protected" "401" -X POST "$SITE/wp-json/kwitko/v1/cart" -H 'Content-Type: application/json' -d '{}'
check_status "identify POST protected" "401" -X POST "$SITE/wp-json/kwitko/v1/identify" -H 'Content-Type: application/json' -d '{}'
check_status "otp POST protected" "401" -X POST "$SITE/wp-json/kwitko/v1/verification-code-email" -H 'Content-Type: application/json' -d '{}'
check_status "return email POST protected" "401" -X POST "$SITE/wp-json/kwitko/v1/return-label-email" -H 'Content-Type: application/json' -d '{}'
check_status "return label page" "200" "$SITE/return-label/?tracking=KWRETROUTECHECK&order=%23ROUTECHECK"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then exit 1; fi
