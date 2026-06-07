#!/usr/bin/env bash
set -euo pipefail

ORG_ALIAS="${1:-ci}"

echo "Checking web messaging channel and deployment config..."
sf data query --target-org "$ORG_ALIAS" --query "
  SELECT Id, DeveloperName, IsActive, PlatformType, SessionHandlerId, FallbackQueueId
  FROM MessagingChannel
  WHERE DeveloperName = 'Kwitko_Web_Chat'
" --result-format human

echo "Checking stuck open messaging sessions..."
OPEN_SESSIONS_JSON="$(sf data query --target-org "$ORG_ALIAS" --query "
  SELECT Id, Name, Status, CreatedDate
  FROM MessagingSession
  WHERE EndTime = null
  ORDER BY CreatedDate ASC
" --json)"
OPEN_COUNT="$(printf '%s' "$OPEN_SESSIONS_JSON" | jq '.result.totalSize')"
if [[ "$OPEN_COUNT" -gt 0 ]]; then
  echo "Open MessagingSession records exist. Review before production promotion." >&2
  printf '%s\n' "$OPEN_SESSIONS_JSON" | jq '.result.records[] | {Id, Name, Status, CreatedDate}' >&2
  exit 1
fi

echo "Checking Agentforce runtime users..."
BOTS_JSON="$(sf data query --target-org "$ORG_ALIAS" --query "
  SELECT Id, DeveloperName, MasterLabel, Type, BotUserId
  FROM BotDefinition
  WHERE DeveloperName IN ('Kwitko_Concierge_Web','Kwitko_Concierge','Product_Advisor','Inside_Sales','Post_Purchase_Growth')
  ORDER BY DeveloperName
" --json)"
printf '%s\n' "$BOTS_JSON" | jq '.result.records[] | {DeveloperName, Type, BotUserIdPresent: (.BotUserId != null)}'
MISSING_BOT_USERS="$(printf '%s' "$BOTS_JSON" | jq '[.result.records[] | select(.BotUserId == null)] | length')"
if [[ "$MISSING_BOT_USERS" -gt 0 ]]; then
  echo "One or more Agentforce bots have no runtime BotUserId." >&2
  exit 1
fi

echo "Checking Data Cloud calculated insight metadata visibility..."
sf data query --target-org "$ORG_ALIAS" --query "
  SELECT QualifiedApiName, MasterLabel
  FROM EntityDefinition
  WHERE QualifiedApiName LIKE '%__cio'
  ORDER BY QualifiedApiName
  LIMIT 20
" --result-format human || true

echo "Checking Account augmented field metadata..."
sf data query --target-org "$ORG_ALIAS" --query "
  SELECT QualifiedApiName, DataType
  FROM FieldDefinition
  WHERE EntityDefinition.QualifiedApiName = 'Account'
  AND QualifiedApiName LIKE 'Data_Cloud_%'
  ORDER BY QualifiedApiName
" --result-format human

echo "Salesforce smoke checks passed."

