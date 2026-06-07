#!/usr/bin/env bash
set -euo pipefail

ALIAS="${1:-ci}"

if [[ -z "${SFDX_AUTH_URL:-}" ]]; then
  echo "Missing SFDX_AUTH_URL for alias ${ALIAS}. Configure the matching GitHub environment/repository secret." >&2
  exit 1
fi

AUTH_FILE="$(mktemp)"
trap 'rm -f "$AUTH_FILE"' EXIT

printf '%s' "$SFDX_AUTH_URL" > "$AUTH_FILE"
sf org login sfdx-url --sfdx-url-file "$AUTH_FILE" --alias "$ALIAS" --set-default
sf org display --target-org "$ALIAS" --json >/dev/null

