#!/usr/bin/env bash
set -euo pipefail

SITE="${1:-https://deepskyblue-deer-920559.hostingersite.com}"
PRODUCT_ID="${2:-56}"
EXPECTED_QTY="${3:-2}"

JAR="$(mktemp)"
HTML="$(mktemp)"
trap 'rm -f "$JAR" "$HTML"' EXIT

ADD_URL="$SITE/?kc_add=$PRODUCT_ID"
for _ in $(seq 2 "$EXPECTED_QTY"); do
  ADD_URL="$ADD_URL,$PRODUCT_ID"
done
ADD_URL="$ADD_URL&kc_clear=1"

final_url="$(
  curl -sS -L -c "$JAR" -b "$JAR" "$ADD_URL" -o "$HTML" -w '%{url_effective}'
)"

cart_json="$(curl -sS -b "$JAR" "$SITE/wp-json/wc/store/v1/cart")"
qty="$(
  jq -r --argjson id "$PRODUCT_ID" '[.items[]? | select(.id == $id) | .quantity] | add // 0' <<<"$cart_json"
)"
items_count="$(jq -r '.items_count // 0' <<<"$cart_json")"
name="$(jq -r --argjson id "$PRODUCT_ID" '.items[]? | select(.id == $id) | .name' <<<"$cart_json" | head -n 1)"

if [[ "$qty" == "$EXPECTED_QTY" ]]; then
  printf 'PASS  kc_add quantity preserved       product=%s qty=%s name=%s\n' "$PRODUCT_ID" "$qty" "${name:-unknown}"
else
  printf 'FAIL  kc_add quantity preserved       product=%s expected=%s actual=%s items_count=%s\n' "$PRODUCT_ID" "$EXPECTED_QTY" "$qty" "$items_count"
  jq '{items_count, items:[.items[]? | {id,name,quantity}]}' <<<"$cart_json"
  exit 1
fi

if [[ "$final_url" == "$SITE/cart-2/"* ]]; then
  printf 'PASS  kc_add redirects to live cart   %s\n' "$final_url"
else
  printf 'FAIL  kc_add redirects to live cart   %s\n' "$final_url"
  exit 1
fi
