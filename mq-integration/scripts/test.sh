#!/usr/bin/env bash
###############################################################################
# test.sh — end-to-end proof of the IBM MQ <-> EventBridge integration.
#
#   (a) health      MQ container healthy, bridge running, queues exist
#   (b) MQ -> EB    sample order put on ORDERS.OUT (amqsput in the mq container);
#                   consumer Lambda logs "processed order" with the orderId;
#                   ORDERS.OUT depth returns to 0
#   (c) EB -> MQ    put-events (source prod.orders, OrderPlaced, NO origin);
#                   message arrives on ORDERS.IN (amqsget); SQS queue drains
#   (d) anti-loop   the origin=ibm-mq event from (b) did NOT reach ORDERS.IN
#   (e) poison      non-JSON on ORDERS.OUT lands in ORDERS.DLQ and does not
#                   block the next valid message
#
# All MQ interaction goes through SSM (ssm-run.sh); the host has no SSH.
# Message bodies are never printed (only orderIds, which are not secrets);
# no credentials are read or printed. Prints PASS/FAIL per step; exits 1 on any
# FAIL.
#
# Usage:  mq-integration/scripts/test.sh
# Env:    INSTANCE_ID / OUTBOUND_QUEUE_URL (skip terraform lookup),
#         OPERATOR_PROFILE, DEPLOYER_PROFILE, REGION, BUS_NAME, EVENT_SOURCE,
#         CONSUMER_LOG_GROUP (default /aws/lambda/eb-prod-pri-consumer)
# Safety class: mutates the lab's own MQ queues + puts test events on the bus
#         (small cost; requires a deployed mq-integration — "test" scripts are
#         deploy-class per CLAUDE.md, run only with user approval).
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_tools terraform aws jq
[[ -f "$DEPLOYER_CREDS_FILE" ]] || die "no deployer creds; run scripts/create-prod.sh first"
assert_profile "$OPERATOR_PROFILE"

SAMPLE="${LAB_ROOT}/schemas/samples/prod.orders__OrderPlaced/valid-1.json"
[[ -f "$SAMPLE" ]] || die "missing sample ${SAMPLE}"
CONSUMER_LG="${CONSUMER_LOG_GROUP:-/aws/lambda/eb-prod-pri-consumer}"

if [[ -z "${INSTANCE_ID:-}" || -z "${OUTBOUND_QUEUE_URL:-}" ]]; then
  info "reading terraform outputs (operator profile)"
  mq_tf_init
  INSTANCE_ID="${INSTANCE_ID:-$(tf_output "$MQ_TF_DIR" instance_id)}"
  OUTBOUND_QUEUE_URL="${OUTBOUND_QUEUE_URL:-$(tf_output "$MQ_TF_DIR" outbound_queue_url)}"
fi

FAILED=0
pass() { printf "PASS  %s\n" "$1"; }
fail() { printf "FAIL  %s\n" "$1"; FAILED=1; }

# ---- helpers -----------------------------------------------------------------
run() { bash "${MQ_SCRIPTS}/ssm-run.sh" "$INSTANCE_ID" "$1"; }

# Resolve the MQ container on the host, then run an inner bash -c script in it.
# $1 must not contain single quotes.
MQC_EXPR='MQC=$(cd /opt/eb-mq/docker && docker compose ps -q mq)'
mq_sh() { run "${MQC_EXPR}; docker exec -i \"\$MQC\" bash -c '$1'"; }

new_id() { cat /proc/sys/kernel/random/uuid; }

# qdepth QUEUE -> prints CURDEPTH (empty on failure)
qdepth() {
  mq_sh "echo \"DISPLAY QLOCAL($1) CURDEPTH\" | runmqsc QM1" 2>/dev/null \
    | grep -o 'CURDEPTH([0-9]*)' | grep -o '[0-9]*' | head -1 || true
}

# put_line QUEUE BASE64_OF_ONE_LINE — amqsput runs as the container's default
# (mqm) user via local bindings; one stdin line = one message.
put_line() {
  run "${MQC_EXPR}; echo $2 | base64 -d | docker exec -i \"\$MQC\" /opt/mqm/samp/bin/amqsput $1 QM1 >/dev/null 2>&1"
}

order_json() { jq -c --arg id "$1" '.orderId=$id' "$SAMPLE"; }
b64() { base64 -w0; }

# wait_consumer_log ORDERID MARKER_MS TIMEOUT_S
wait_consumer_log() {
  local id="$1" marker="$2" end=$(( $(date +%s) + $3 ))
  while [[ $(date +%s) -lt $end ]]; do
    if aws_dep logs filter-log-events --log-group-name "$CONSUMER_LG" --start-time "$marker" \
         --filter-pattern "\"processed order\" \"${id}\"" \
         --query 'events[].message' --output text 2>/dev/null | grep -q "$id"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# wait_depth QUEUE PREDICATE(op value) TIMEOUT_S  e.g. wait_depth ORDERS.OUT eq 0 60
wait_depth() {
  local q="$1" op="$2" want="$3" end=$(( $(date +%s) + $4 )) d
  while [[ $(date +%s) -lt $end ]]; do
    d="$(qdepth "$q")"
    if [[ -n "$d" ]]; then
      case "$op" in eq) [[ "$d" -eq "$want" ]] && return 0 ;; gt) [[ "$d" -gt "$want" ]] && return 0 ;; esac
    fi
    sleep 5
  done
  return 1
}

# drain_in IDC IDB -> "<count of IDC> <count of IDB>" seen while draining
# ORDERS.IN (amqsget waits ~15s for new messages). Bodies are never printed.
drain_in() {
  mq_sh "OUT=\$(/opt/mqm/samp/bin/amqsget ORDERS.IN QM1 2>&1 || true); printf \"C=%s B=%s\\n\" \"\$(printf %s \"\$OUT\" | grep -c $1 || true)\" \"\$(printf %s \"\$OUT\" | grep -c $2 || true)\"" 2>/dev/null \
    | sed -n 's/.*C=\([0-9][0-9]*\) B=\([0-9][0-9]*\).*/\1 \2/p' | tail -1
}

echo "======================================================================"
echo " MQ <-> EVENTBRIDGE END-TO-END TEST  (instance ${INSTANCE_ID})"
echo "======================================================================"

# ---- (a) health --------------------------------------------------------------
info "(a) health"
if [[ "$(aws_op ssm describe-instance-information --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)" == "Online" ]]; then
  pass "a0 instance is SSM-online"
else
  fail "a0 instance not SSM-online — cannot continue"; exit 1
fi
health="$(run "${MQC_EXPR}; docker inspect -f '{{.State.Health.Status}}' \"\$MQC\"" 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$health" == "healthy" ]] && pass "a1 MQ container healthy" || fail "a1 MQ container health='${health:-unknown}'"
brun="$(run 'cd /opt/eb-mq/docker && docker inspect -f "{{.State.Running}}" "$(docker compose ps -q bridge)"' 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$brun" == "true" ]] && pass "a2 bridge container running" || fail "a2 bridge container running='${brun:-unknown}'"
queues="$(mq_sh 'echo "DISPLAY QLOCAL(ORDERS.*)" | runmqsc QM1' 2>/dev/null | grep -o 'QUEUE(ORDERS\.[A-Z]*)' | sort -u | tr '\n' ' ' || true)"
missing=""
for q in ORDERS.OUT ORDERS.IN ORDERS.DLQ; do [[ "$queues" == *"QUEUE(${q})"* ]] || missing+="${q} "; done
[[ -z "$missing" ]] && pass "a3 queues exist (ORDERS.OUT, ORDERS.IN, ORDERS.DLQ)" || fail "a3 missing queues: ${missing}"
if INSTANCE_ID="$INSTANCE_ID" OUTBOUND_QUEUE_URL="$OUTBOUND_QUEUE_URL" bash "${MQ_SCRIPTS}/verify-mq-objects.sh" >&2; then
  pass "a4 queue manager and all MQ objects verified (verify-mq-objects.sh)"
else
  fail "a4 MQ objects verification failed (see FAIL lines above)"
fi
if [[ "$FAILED" -ne 0 ]]; then err "health checks failed — skipping functional steps"; exit 1; fi

# ---- (b) MQ -> EventBridge ----------------------------------------------------
info "(b) MQ -> EventBridge"
ORDER_B="$(new_id)"
marker=$(( $(date +%s) * 1000 ))
if put_line ORDERS.OUT "$(order_json "$ORDER_B" | b64)"; then
  pass "b1 put order ${ORDER_B} on ORDERS.OUT"
else
  fail "b1 amqsput to ORDERS.OUT failed"
fi
if wait_consumer_log "$ORDER_B" "$marker" 90; then
  pass "b2 consumer Lambda processed ${ORDER_B} (via MQ -> bridge -> EventBridge)"
else
  fail "b2 consumer did not log ${ORDER_B} within 90s"
fi
if wait_depth ORDERS.OUT eq 0 60; then pass "b3 ORDERS.OUT depth is 0"; else fail "b3 ORDERS.OUT depth did not return to 0"; fi

# ---- (c) EventBridge -> MQ ----------------------------------------------------
info "(c) EventBridge -> MQ"
ORDER_C="$(new_id)"
ENTRIES="$(jq -cn --arg bus "$BUS_NAME" --arg src "$EVENT_SOURCE" \
  --arg detail "$(order_json "$ORDER_C")" \
  '[{EventBusName:$bus, Source:$src, DetailType:"OrderPlaced", Detail:$detail}]')"
failed_entries="$(aws_op events put-events --entries "$ENTRIES" --query 'FailedEntryCount' --output text 2>/dev/null || echo err)"
if [[ "$failed_entries" == "0" ]]; then pass "c1 put-events ${ORDER_C} (no detail.origin)"; else fail "c1 put-events failed (${failed_entries})"; fi

c_seen=0; b_seen=0
for _ in 1 2 3 4; do
  res="$(drain_in "$ORDER_C" "$ORDER_B")"
  read -r c n <<<"${res:-0 0}"
  c_seen=$(( c_seen + ${c:-0} )); b_seen=$(( b_seen + ${n:-0} ))
  [[ "$c_seen" -ge 1 ]] && break
done
[[ "$c_seen" -ge 1 ]] && pass "c2 ${ORDER_C} arrived on ORDERS.IN" || fail "c2 ${ORDER_C} never arrived on ORDERS.IN"

drained=0
for _ in $(seq 1 12); do
  attrs="$(aws_op sqs get-queue-attributes --queue-url "$OUTBOUND_QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --output json 2>/dev/null || true)"
  if [[ -n "$attrs" ]] && [[ "$(jq -r '[.Attributes[]|tonumber]|add' <<<"$attrs")" == "0" ]]; then drained=1; break; fi
  sleep 5
done
[[ "$drained" -eq 1 ]] && pass "c3 SQS outbound queue drained" || fail "c3 SQS outbound queue still holds messages"

# ---- (d) anti-loop ------------------------------------------------------------
info "(d) anti-loop"
res="$(drain_in "$ORDER_C" "$ORDER_B")"
read -r _ n <<<"${res:-0 0}"
b_seen=$(( b_seen + ${n:-0} ))
if [[ "$b_seen" -eq 0 ]]; then
  pass "d1 origin=ibm-mq event ${ORDER_B} did NOT loop back to ORDERS.IN"
else
  fail "d1 ${ORDER_B} (origin ibm-mq) reappeared on ORDERS.IN ${b_seen}x — loop!"
fi

# ---- (e) poison message -------------------------------------------------------
info "(e) poison message"
dlq_before="$(qdepth ORDERS.DLQ)"; dlq_before="${dlq_before:-0}"
POISON="not-json-$(new_id)"
ORDER_E="$(new_id)"
marker=$(( $(date +%s) * 1000 ))
put_line ORDERS.OUT "$(printf '%s\n' "$POISON" | b64)" && pass "e1 put non-JSON message on ORDERS.OUT" || fail "e1 poison put failed"
put_line ORDERS.OUT "$(order_json "$ORDER_E" | b64)" && pass "e2 put valid order ${ORDER_E} behind it" || fail "e2 valid put failed"
if wait_consumer_log "$ORDER_E" "$marker" 90; then pass "e3 valid message ${ORDER_E} processed (not blocked by poison)"; else fail "e3 valid message ${ORDER_E} blocked or lost"; fi
if wait_depth ORDERS.DLQ gt "$dlq_before" 90; then pass "e4 poison message reached ORDERS.DLQ"; else fail "e4 ORDERS.DLQ depth did not increase"; fi
if wait_depth ORDERS.OUT eq 0 30; then pass "e5 ORDERS.OUT depth is 0"; else fail "e5 ORDERS.OUT not empty after poison handling"; fi
# Leave the lab clean: drain the DLQ without printing bodies.
mq_sh '/opt/mqm/samp/bin/amqsget ORDERS.DLQ QM1 >/dev/null 2>&1 || true' >/dev/null 2>&1 || true

echo "======================================================================"
if [[ "$FAILED" -ne 0 ]]; then err "MQ INTEGRATION TEST FAILED"; exit 1; fi
ok "ALL STEPS PASSED — MQ <-> EventBridge flow proven (remember: destroy.sh --yes)"
