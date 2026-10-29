#!/usr/bin/env bash
###############################################################################
# 02-functional.sh — LIVE functional + delivery-correctness checks. Fires real
# events through the deployed producer and the bus. Non-destructive (adds no
# infra) but it does invoke Lambdas and publish events.
#
# Covers: HA-01 producer publish acknowledgement, HA-02 end-to-end consumer
# processing, EVB-07 negative routing (non-matching event is NOT routed),
# EVB-15 at-least-once / consumer idempotency on a repeated business key.
#
# Usage: scripts/compliance/02-functional.sh [primary|secondary]
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-compliance.sh"

require_tools terraform aws jq
export AWS_SHARED_CREDENTIALS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"

ROLE="${1:-primary}"
discover "$ROLE"
[[ -n "$D_PRODUCER" && -n "$D_CONSUMER_LG" ]] || die "functional checks need producer + consumer log group"

# Poll a log group for a pattern after a start marker. Returns 0 on match.
wait_for_log() {
  local lg="$1" marker="$2" pattern="$3" tries="${4:-12}"
  local i
  for ((i=0;i<tries;i++)); do
    sleep 5
    if aws logs filter-log-events --log-group-name "$lg" --start-time "$marker" \
         --filter-pattern "$pattern" "${AWS[@]}" \
         --query 'events[].message' --output text 2>/dev/null | grep -q "${pattern//\"/}"; then
      return 0
    fi
  done
  return 1
}

###############################################################################
# HA-01 — producer publish acknowledgement (no failed entries)
###############################################################################
check_ha01() {
  local out; out="${RUNTIME_DIR}/compliance/ha01-${ROLE}.json"
  if aws lambda invoke --function-name "$D_PRODUCER" --payload '{"count":3}' \
       --cli-binary-format raw-in-base64-out "${AWS[@]}" "$out" >/dev/null 2>&1; then
    local pub failed
    pub="$(jq -r '.published // 0' "$out" 2>/dev/null || echo 0)"
    failed="$(jq -r '.failed // 0' "$out" 2>/dev/null || echo 0)"
    if [[ "$pub" -ge 1 && "$failed" -eq 0 ]]; then
      pass_v HA-01 "producer:${D_PRODUCER}" "published ${pub} events, 0 failed entries (durable accept)"
    else
      fail_v HA-01 "producer:${D_PRODUCER}" "published=${pub} failed=${failed}"
    fi
  else
    fail_v HA-01 "producer:${D_PRODUCER}" "producer invocation failed"
  fi
}

###############################################################################
# HA-02 — end-to-end: matched event reaches the consumer
###############################################################################
check_ha02() {
  local marker; marker=$(($(date +%s)*1000))
  aws lambda invoke --function-name "$D_PRODUCER" --payload '{"count":1}' \
    --cli-binary-format raw-in-base64-out "${AWS[@]}" /dev/null >/dev/null 2>&1 || true
  if wait_for_log "$D_CONSUMER_LG" "$marker" '"processed order"' 12; then
    pass_v HA-02 "consumer:${D_CONSUMER}" "consumer processed a routed event end-to-end"
  else
    fail_v HA-02 "consumer:${D_CONSUMER}" "no consumer processing within ~60s"
  fi
}

###############################################################################
# EVB-07 (negative) — an event with the WRONG source must NOT be routed
###############################################################################
check_evb07_negative() {
  local marker; marker=$(($(date +%s)*1000))
  # Put a mismatching event directly on the bus (wrong source).
  aws events put-events --entries \
    "[{\"Source\":\"evb.compliance.negative\",\"DetailType\":\"OrderPlaced\",\"Detail\":\"{\\\"orderId\\\":\\\"neg-$marker\\\"}\",\"EventBusName\":\"$D_BUS\"}]" \
    "${AWS[@]}" >/dev/null 2>&1 || true
  # Give it a window; the consumer must NOT log this orderId.
  sleep 20
  if aws logs filter-log-events --log-group-name "$D_CONSUMER_LG" --start-time "$marker" \
       "${AWS[@]}" --query 'events[].message' --output text 2>/dev/null | grep -q "neg-$marker"; then
    fail_v EVB-07 "rule:${D_RULE}" "non-matching source WAS routed — pattern too broad"
  else
    pass_v EVB-07 "rule:${D_RULE}" "non-matching source correctly not routed (negative test)"
  fi
}

###############################################################################
# EVB-15 — at-least-once / idempotency: publish the SAME business key twice;
# consumer behaviour must be idempotent (no corrupt/duplicate side effect).
# The lab consumer logs the orderId; we assert it HANDLES a repeat without
# error. True idempotency needs a dedup store — reported as UNKNOWN if absent.
###############################################################################
check_evb15() {
  local marker; marker=$(($(date +%s)*1000))
  local oid="dup-$marker"
  local entry="[{\"Source\":\"${EVENT_SOURCE:-prod.orders}\",\"DetailType\":\"OrderPlaced\",\"Detail\":\"{\\\"orderId\\\":\\\"$oid\\\"}\",\"EventBusName\":\"$D_BUS\"}]"
  aws events put-events --entries "$entry" "${AWS[@]}" >/dev/null 2>&1 || true
  sleep 3
  aws events put-events --entries "$entry" "${AWS[@]}" >/dev/null 2>&1 || true
  if wait_for_log "$D_CONSUMER_LG" "$marker" "$oid" 12; then
    # Consumer handled the duplicate business key without crashing.
    local errs
    errs="$(aws logs filter-log-events --log-group-name "$D_CONSUMER_LG" --start-time "$marker" \
             --filter-pattern '?ERROR ?Exception ?Traceback' "${AWS[@]}" \
             --query 'events[].message' --output text 2>/dev/null || true)"
    if [[ -z "$errs" ]]; then
      unk_v EVB-15 "consumer:${D_CONSUMER}" "duplicate business key processed without error, but no explicit dedup store observed — confirm idempotency contract"
    else
      fail_v EVB-15 "consumer:${D_CONSUMER}" "duplicate delivery caused an error in the consumer"
    fi
  else
    fail_v EVB-15 "consumer:${D_CONSUMER}" "duplicate-key event not processed"
  fi
}

echo "======================================================================"
echo " FUNCTIONAL + DELIVERY CHECKS (live) — role=${ROLE}"
echo "======================================================================"
check_ha01
check_ha02
check_evb07_negative
check_evb15
echo "======================================================================"
summarize
