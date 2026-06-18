#!/usr/bin/env bash
#
# secret-scan.sh — fail CI if a real secret value is committed.
#
# Two passes:
#   1. FORMAT  — secret strings that are self-identifying by shape (private keys,
#                SFDX auth URLs, Slack/GitHub tokens). A match anywhere = leak.
#   2. ASSIGN  — a secret-ish KEY assigned a literal VALUE (>=8 secret chars).
#                Bare tokens in prose, placeholders (`...`, `<your-secret>`),
#                env reads (`process.env.X`, `${X}`), and variable references
#                (RHS is a plain identifier) are NOT secrets and are filtered out.
#
set -euo pipefail

# Pass 1: high-confidence secret formats (the value IS the match).
FORMAT='(-----BEGIN ((RSA|EC|OPENSSH) )?PRIVATE KEY-----|SFDX_AUTH_URL=|force://[A-Za-z0-9._-]+|xox[baprs]-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{20,})'

# Pass 2: KEY = LITERAL-VALUE (the value must look like a real secret: >=8 chars).
ASSIGN='(client_secret|consumerSecret|refresh_token|password|passwd)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9._/+-]{8,}'

# Lines that match ASSIGN but are demonstrably NOT a real value:
#   placeholders / env reads / template vars ...
SAFE_VALUE='(\.\.\.|process\.env|\$\{|<[A-Za-z_]|your[_-]|example|placeholder|REDACTED|xxxx|CHANGEME|\bnull\b|undefined)'
#   ... or the right-hand side is a bare identifier (a variable reference, no digits/quotes), e.g. `: clientSecret`.
VAR_REF='[:=][[:space:]]*[A-Za-z_][A-Za-z_]*[[:space:]]*[,;)}]*[[:space:]]*$'

EXCLUDES=(
  ':!docs/CI_CD_RUNBOOK.md'
  ':!tools/inchat-auth/README.md'
  ':!.github/workflows/*.yml'
  ':!scripts/ci/*.sh'
)

fail=0

set +e
M1="$(git grep -nIE "$FORMAT" -- "${EXCLUDES[@]}")"
M2="$(git grep -nIE "$ASSIGN" -- "${EXCLUDES[@]}" | grep -vE "$SAFE_VALUE" | grep -vE "$VAR_REF")"
set -e

if [[ -n "$M1" ]]; then printf '%s\n' "$M1"; fail=1; fi
if [[ -n "$M2" ]]; then printf '%s\n' "$M2"; fail=1; fi

if [[ "$fail" -eq 1 ]]; then
  echo "Potential secret found. Remove it from the commit and rotate if needed." >&2
  exit 1
fi

echo "Secret scan passed."
