#!/usr/bin/env bash
set -euo pipefail

export CI="${CI:-true}"

MODE="${1:?Usage: salesforce-deploy-core.sh <dry-run|deploy|validate-json> <org-alias> [test-level] [wait-minutes] [results-dir]}"
ORG_ALIAS="${2:?Usage: salesforce-deploy-core.sh <dry-run|deploy|validate-json> <org-alias> [test-level] [wait-minutes] [results-dir]}"
TEST_LEVEL="${3:-RunLocalTests}"
WAIT_MINUTES="${4:-60}"
RESULTS_DIR="${5:-test-results/salesforce-deploy}"

DEPLOY_SOURCE_DIRS=(
  "force-app/main/default/classes"
  "force-app/main/default/objects"
  "force-app/main/default/customMetadata"
  "force-app/main/default/flows"
  "force-app/main/default/flowDefinitions"
  "force-app/main/default/permissionsets"
  "force-app/main/default/profiles"
  "force-app/main/default/layouts"
  "force-app/main/default/namedCredentials"
  "force-app/main/default/cspTrustedSites"
  "force-app/main/default/queues"
  "force-app/main/default/queueRoutingConfigs"
  "force-app/main/default/settings"
  "force-app/main/default/dataSourceObjects"
  "force-app/main/default/objectSourceTargetMaps"
  "force-app/main/default/mktCalcInsightObjectDefs"
  "force-app/main/default/messagingChannels"
  "force-app/main/default/EmbeddedServiceConfig"
  "force-app/main/default/sites"
  "force-app/main/default/lwc"
  "force-app/main/default/aura"
  "force-app/main/default/staticresources"
  "force-app/main/default/applications"
  "force-app/main/default/flexipages"
  "force-app/main/default/tabs"
  "force-app/main/default/contentassets"
)

source_args=()
for source_dir in "${DEPLOY_SOURCE_DIRS[@]}"; do
  if [[ -d "$source_dir" ]] && find "$source_dir" -type f -print -quit | grep -q .; then
    source_args+=(--source-dir "$source_dir")
  fi
done

if [[ "${#source_args[@]}" -eq 0 ]]; then
  echo "No deployable Salesforce source directories found." >&2
  exit 1
fi

case "$MODE" in
  dry-run)
    sf project deploy start \
      --dry-run \
      "${source_args[@]}" \
      --target-org "$ORG_ALIAS" \
      --test-level "$TEST_LEVEL" \
      --concise \
      --coverage-formatters json-summary \
      --junit \
      --results-dir "$RESULTS_DIR" \
      --wait "$WAIT_MINUTES"
    ;;
  deploy)
    sf project deploy start \
      "${source_args[@]}" \
      --target-org "$ORG_ALIAS" \
      --test-level "$TEST_LEVEL" \
      --concise \
      --coverage-formatters json-summary \
      --junit \
      --results-dir "$RESULTS_DIR" \
      --wait "$WAIT_MINUTES"
    ;;
  validate-json)
    sf project deploy validate \
      "${source_args[@]}" \
      --target-org "$ORG_ALIAS" \
      --test-level "$TEST_LEVEL" \
      --json \
      --wait "$WAIT_MINUTES"
    ;;
  *)
    echo "Unknown deploy mode: $MODE" >&2
    exit 1
    ;;
esac
