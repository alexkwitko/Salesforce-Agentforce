#!/usr/bin/env bash
set -euo pipefail

SCRT_BASE_URL="${KWITKO_SCRT_BASE_URL:-https://MYDOMAIN.develop.my.salesforce-scrt.com}"
ORG_ID="${KWITKO_SALESFORCE_ORG_ID:-00DXX0000000000}"
DEPLOYMENT_NAME="${KWITKO_EMBEDDED_SERVICE_NAME:-Kwitko_Web_Chat_V2}"
LANGUAGE="${KWITKO_CHAT_LANGUAGE:-en_US}"
CAPABILITIES_VERSION="${KWITKO_CHAT_CAPABILITIES_VERSION:-260}"

echo "Checking live Embedded Messaging config..."
CONFIG_JSON="$(
  curl -fsSL \
    "${SCRT_BASE_URL}/embeddedservice/v1/embedded-service-config?orgId=${ORG_ID}&esConfigName=${DEPLOYMENT_NAME}&language=${LANGUAGE}"
)"

printf '%s' "$CONFIG_JSON" | jq -e '.embeddedServiceConfig.embeddedServiceMessagingChannel.esClientVersion == "WebV2"' >/dev/null
printf '%s' "$CONFIG_JSON" | jq -e '.embeddedServiceConfig.name == "'"${DEPLOYMENT_NAME}"'"' >/dev/null

FORMS_COUNT="$(printf '%s' "$CONFIG_JSON" | jq '.embeddedServiceConfig.forms | length')"
if [[ "${KWITKO_REQUIRE_PRECHAT_FORMS:-false}" == "true" && "$FORMS_COUNT" -eq 0 ]]; then
  echo "Embedded Messaging deployment exposes no pre-chat forms/hidden fields." >&2
  exit 1
fi

echo "Checking live conversation creation..."
AUTH_JSON="$(
  curl -fsSL \
    -X POST \
    -H 'Content-Type: application/json' \
    --data '{"orgId":"'"${ORG_ID}"'","developerName":"'"${DEPLOYMENT_NAME}"'","capabilitiesVersion":"'"${CAPABILITIES_VERSION}"'"}' \
    "${SCRT_BASE_URL}/iamessage/v1/authorization/unauthenticated/accessToken"
)"

ACCESS_TOKEN="$(printf '%s' "$AUTH_JSON" | jq -r '.accessToken // empty')"
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Could not obtain Embedded Messaging unauthenticated access token." >&2
  exit 1
fi

CONVERSATION_BODY='{"language":"'"${LANGUAGE}"'","conversationModes":["Messaging"]}'
CONVERSATION_RESPONSE_FILE="$(mktemp)"
HTTP_STATUS="$(
  curl -sS \
    -o "$CONVERSATION_RESPONSE_FILE" \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    --data "$CONVERSATION_BODY" \
    "${SCRT_BASE_URL}/iamessage/v1/conversation"
)"

if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "201" ]]; then
  echo "Conversation create failed with HTTP ${HTTP_STATUS}." >&2
  jq . "$CONVERSATION_RESPONSE_FILE" >&2 || cat "$CONVERSATION_RESPONSE_FILE" >&2
  rm -f "$CONVERSATION_RESPONSE_FILE"
  exit 1
fi

rm -f "$CONVERSATION_RESPONSE_FILE"
echo "Live web chat conversation creation passed."
