#!/usr/bin/env bash
set -euo pipefail

PATTERN='(-----BEGIN ((RSA|EC|OPENSSH) )?PRIVATE KEY-----|SFDX_AUTH_URL|refresh_token|consumerSecret|client_secret|password=|passwd=|xox[baprs]-|gh[pousr]_)'

set +e
MATCHES="$(git grep -nIE "$PATTERN" -- \
  ':!docs/CI_CD_RUNBOOK.md' \
  ':!tools/inchat-auth/README.md' \
  ':!.github/workflows/*.yml' \
  ':!scripts/ci/*.sh')"
STATUS="$?"
set -e

if [[ "$STATUS" -eq 0 ]]; then
  printf '%s\n' "$MATCHES"
  echo "Potential secret found. Remove it from the commit and rotate if needed." >&2
  exit 1
fi

if [[ "$STATUS" -ne 1 ]]; then
  echo "Secret scan failed to run." >&2
  exit "$STATUS"
fi

echo "Secret scan passed."
