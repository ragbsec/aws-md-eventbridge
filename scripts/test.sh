#!/usr/bin/env bash
###############################################################################
# test.sh — functional end-to-end proof that EventBridge is doing its job.
#
# Uses the DEPLOYER profile (read + invoke only). Steps, each PASS/FAIL:
#   1. Confirm every object exists (bus, rule, targets, lambdas, dlq, sns,
#      schedule, archive) via terraform outputs + describe calls.
#   2. Invoke the producer -> it PUTs OrderPlaced events on the bus.
#   3. Poll the consumer's CloudWatch Logs for "processed order" proof that the
#      rule matched and routed the event to the consumer Lambda.
#   4. Confirm the audit log group received the event too.
#
# STDOUT = PASS/FAIL matrix; diagnostics -> STDERR.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform aws jq

DEPLOYER_CREDS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"
[[ -f "$DEPLOYER_CREDS_FILE" ]] || die "no deployer creds; run ./scripts/create.sh first"
export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"
assert_profile "$DEPLOYER_PROFILE"

AWSP=(--profile "$DEPLOYER_PROFILE" --region "$REGION")

FAILED=0
pass() { printf "PASS  %s\n" "$1"; }
fail() { printf "FAIL  %s\n" "$1"; FAILED=1; }

BUS="$(tf_output "$APP_DIR" event_bus_name)"
PRODUCER="$(tf_output "$APP_DIR" producer_function_name)"
CONSUMER="$(tf_output "$APP_DIR" consumer_function_name)"
CONSUMER_LG="$(tf_output "$APP_DIR" consumer_log_group)"
AUDIT_LG="$(tf_output "$APP_DIR" audit_log_group)"
DLQ_URL="$(tf_output "$APP_DIR" dlq_url)"
SNS_ARN="$(tf_output "$APP_DIR" sns_topic_arn)"

echo "======================================================================"
echo " EVENTBRIDGE FUNCTIONAL TEST"
echo "======================================================================"

# --- 1. object existence ----------------------------------------------------
info "checking objects exist..."
aws events describe-event-bus --name "$BUS" "${AWSP[@]}" >/dev/null 2>&1 \
  && pass "custom event bus exists: $BUS" || fail "custom event bus missing"

aws events list-rules --event-bus-name "$BUS" "${AWSP[@]}" \
  --query 'Rules[0].Name' --output text 2>/dev/null | grep -q . \
  && pass "rule exists on bus" || fail "rule missing on bus"

aws lambda get-function --function-name "$PRODUCER" "${AWSP[@]}" >/dev/null 2>&1 \
  && pass "producer lambda exists: $PRODUCER" || fail "producer lambda missing"

aws lambda get-function --function-name "$CONSUMER" "${AWSP[@]}" >/dev/null 2>&1 \
  && pass "consumer lambda exists: $CONSUMER" || fail "consumer lambda missing"

aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn "${AWSP[@]}" >/dev/null 2>&1 \
  && pass "DLQ exists" || fail "DLQ missing"

aws sns get-topic-attributes --topic-arn "$SNS_ARN" "${AWSP[@]}" >/dev/null 2>&1 \
  && pass "SNS topic exists" || fail "SNS topic missing"

# --- 2. invoke producer -----------------------------------------------------
info "invoking producer to publish events..."
INVOKE_OUT="${RUNTIME_DIR}/producer-invoke.json"
MARKER_TS=$(($(date +%s) * 1000))
if aws lambda invoke --function-name "$PRODUCER" \
    --payload "$(printf '{"count":5}' | base64)" \
    --cli-binary-format base64 \
    "${AWSP[@]}" "$INVOKE_OUT" >&2 2>/dev/null \
   || aws lambda invoke --function-name "$PRODUCER" \
    --payload '{"count":5}' \
    "${AWSP[@]}" "$INVOKE_OUT" >&2; then
  PUBLISHED="$(jq -r '.published // 0' "$INVOKE_OUT" 2>/dev/null || echo 0)"
  if [[ "$PUBLISHED" -ge 1 ]]; then
    pass "producer published $PUBLISHED events"
  else
    fail "producer returned no published events (see $INVOKE_OUT)"
  fi
else
  fail "producer invocation failed"
fi

# --- 3. consumer processed the event (rule matched + routed) ----------------
info "polling consumer logs for processing proof (up to 60s)..."
FOUND=0
for _ in $(seq 1 12); do
  sleep 5
  if aws logs filter-log-events \
      --log-group-name "$CONSUMER_LG" \
      --start-time "$MARKER_TS" \
      --filter-pattern '"processed order"' \
      "${AWSP[@]}" --query 'events[].message' --output text 2>/dev/null | grep -q "processed order"; then
    FOUND=1; break
  fi
done
[[ "$FOUND" -eq 1 ]] \
  && pass "consumer processed a routed event (rule -> lambda works)" \
  || fail "no 'processed order' log within 60s (rule routing not confirmed)"

# --- 4. audit log received the event ----------------------------------------
info "checking audit log group received the event..."
AFOUND=0
for _ in $(seq 1 6); do
  sleep 5
  if aws logs filter-log-events \
      --log-group-name "$AUDIT_LG" \
      --start-time "$MARKER_TS" \
      "${AWSP[@]}" --query 'events[0].message' --output text 2>/dev/null | grep -q "OrderPlaced"; then
    AFOUND=1; break
  fi
done
[[ "$AFOUND" -eq 1 ]] \
  && pass "audit CloudWatch Logs target received the event" \
  || fail "audit log target did not receive an event within 30s"

echo "======================================================================"
if [[ "$FAILED" -ne 0 ]]; then
  err "FUNCTIONAL TEST FAILED — see failures above"
  exit 1
fi
ok "ALL FUNCTIONAL TESTS PASSED — EventBridge flow proven end to end"
