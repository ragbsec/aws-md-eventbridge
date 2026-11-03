#!/usr/bin/env bash
###############################################################################
# test-global-endpoint.sh — prove that IBM MQ orders travel THROUGH the EventBridge
# GLOBAL ENDPOINT (not just the regional bus), including across a regional failover.
#
# Prerequisites: the main lab built with ENABLE_GLOBAL_ENDPOINT=true, and the MQ stack
# deployed with:   deploy.sh --yes --global-endpoint
# (that makes the bridge publish with EndpointId, signed with SigV4a via awscrt).
#
# Phase 1 — always (puts a few test orders on ORDERS.OUT; changes no infrastructure):
#   g0  the bridge container is configured with the endpoint id
#   g1  an MQ order is processed by the PRIMARY region's consumer (us-east-1)
#   g2  the SAME order is REPLICATED to the secondary region (us-west-2) and processed
#       there. Nothing but the global endpoint copies events between the two regional
#       buses, so this proves the bridge used the endpoint.
#   g3  the replica keeps the original envelope (region us-east-1) and detail.origin=ibm-mq
#
# Phase 2 — only with  --failover --confirm   (MUTATING, self-restoring, ~15-25 min):
#   Sets the health Lambda's HEALTHY=false (simulated primary outage), waits for Route 53 to
#   report Unhealthy, then keeps feeding orders through MQ WITHOUT restarting the bridge.
#   f1  Route 53 reports the primary Unhealthy
#   f2  an MQ order is RECEIVED natively in us-west-2 (envelope region us-west-2): the bridge
#       followed the endpoint's failover with no restart. If this fails, the bridge's HTTP
#       connection is probably pinned to the old region (see docs): that is a finding.
#   f3  HEALTHY=true is restored and Route 53 sees the primary healthy again
#   f4  an MQ order is received natively in us-east-1 again (fail back)
#   An EXIT trap always restores HEALTHY=true.
#
# Usage:  mq-integration/scripts/test-global-endpoint.sh [--failover --confirm]
# Env:    INSTANCE_ID (else read from terraform outputs), OPERATOR_PROFILE, DEPLOYER_PROFILE
# Safety class: LIVE (phase 1); MUTATING (phase 2: changes the health Lambda, restores it).
#         "test" scripts are deploy-class per CLAUDE.md: run only with user approval.
# Output: PASS/FAIL per step; message bodies are never printed (only order ids). Exit 1 on FAIL.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

FAILOVER=0; CONFIRM=0
for a in "$@"; do
  case "$a" in
    --failover) FAILOVER=1 ;;
    --confirm)  CONFIRM=1 ;;
    -h|--help)  sed -n 2,40p "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done
[[ "$FAILOVER" -eq 0 || "$CONFIRM" -eq 1 ]] || die "the failover phase changes the health Lambda; add --confirm"

require_tools terraform aws jq
[[ -f "$DEPLOYER_CREDS_FILE" ]] || die "no deployer creds; run scripts/create-prod.sh first"
assert_profile "$OPERATOR_PROFILE"

PRI_REGION="${PRIMARY_REGION:-us-east-1}"; SEC_REGION="${SECONDARY_REGION:-us-west-2}"
PRI_CONSUMER_LG="/aws/lambda/eb-prod-pri-consumer"; SEC_CONSUMER_LG="/aws/lambda/eb-prod-sec-consumer"
PRI_AUDIT_LG="/aws/events/eb-prod-pri/audit";       SEC_AUDIT_LG="/aws/events/eb-prod-sec/audit"
SAMPLE="${LAB_ROOT}/schemas/samples/prod.orders__OrderPlaced/valid-1.json"
[[ -f "$SAMPLE" ]] || die "missing sample ${SAMPLE}"

gout() { ( unset AWS_PROFILE; export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"; terraform -chdir="${LAB_ROOT}/platform-global" output -raw "$1" 2>/dev/null ); }
GE_ID="$(gout global_endpoint_id || true)"; HC_ID="$(gout health_check_id || true)"; HEALTH_FN="$(gout health_function_name || true)"
[[ -n "$GE_ID" && -n "$HC_ID" && -n "$HEALTH_FN" ]] || die "no global endpoint in the lab outputs: build the main lab with ENABLE_GLOBAL_ENDPOINT=true"

if [[ -z "${INSTANCE_ID:-}" ]]; then
  info "reading terraform outputs (operator profile)"
  mq_tf_init
  INSTANCE_ID="$(tf_output "$MQ_TF_DIR" instance_id)"
fi

FAILED=0
pass() { printf "PASS  %s\n" "$1"; }
fail() { printf "FAIL  %s\n" "$1"; FAILED=1; }

# ---- helpers ------------------------------------------------------------------
run() { bash "${MQ_SCRIPTS}/ssm-run.sh" "$INSTANCE_ID" "$1"; }
dep() { local region="$1"; shift; AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE" aws --profile "$DEPLOYER_PROFILE" --region "$region" "$@"; }
new_id() { cat /proc/sys/kernel/random/uuid; }
order_json() { jq -c --arg id "$1" '.orderId=$id' "$SAMPLE"; }
now_ms() { echo $(( $(date +%s) * 1000 )); }

put_order() {   # $1 = orderId : put one order on ORDERS.OUT (amqsput, local bindings, one line = one message)
  local b; b="$(order_json "$1" | base64 -w0)"
  run "MQC=\$(cd /opt/eb-mq/docker && docker compose ps -q mq); echo ${b} | base64 -d | docker exec -i \"\$MQC\" /opt/mqm/samp/bin/amqsput ORDERS.OUT QM1 >/dev/null 2>&1"
}

# consumer_saw REGION LOGGROUP ORDERID MARKER  -> 0 if the consumer logged "processed order" for it
consumer_saw() {
  dep "$1" logs filter-log-events --log-group-name "$2" --start-time "$4" \
    --filter-pattern "\"processed order\" \"$3\"" --query 'events[].message' --output text 2>/dev/null | grep -q "$3"
}
# wait_consumer REGION LOGGROUP ORDERID MARKER TIMEOUT_S
wait_consumer() {
  local end=$(( $(date +%s) + $5 ))
  while [[ $(date +%s) -lt $end ]]; do consumer_saw "$1" "$2" "$3" "$4" && return 0; sleep 5; done
  return 1
}
# audit_field REGION AUDITLOGGROUP ORDERID MARKER JQEXPR -> prints the jq field of the audited envelope
audit_field() {
  local msg
  msg="$(dep "$1" logs filter-log-events --log-group-name "$2" --start-time "$4" \
          --filter-pattern "\"$3\"" --query 'events[0].message' --output text 2>/dev/null || true)"
  [[ -n "$msg" && "$msg" != None ]] && jq -r "$5" <<<"$msg" 2>/dev/null || true
}
hc_counts() {   # prints "<success> <failure>" checker counts
  AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE" aws --profile "$DEPLOYER_PROFILE" route53 get-health-check-status \
    --health-check-id "$HC_ID" --output json 2>/dev/null \
  | jq -r '[(.HealthCheckObservations // [] | map(select(.StatusReport.Status|startswith("Success")))|length),
            (.HealthCheckObservations // [] | map(select(.StatusReport.Status|startswith("Failure")))|length)] | @tsv'
}

ORIG_ENV=""
restore_health() {
  [[ -n "$ORIG_ENV" ]] || return 0
  info "restoring ${HEALTH_FN} HEALTHY=true"
  local env; env="$(jq -c '.Environment.Variables // {} | .HEALTHY="true" | {Variables:.}' <<<"$ORIG_ENV")"
  dep "$PRI_REGION" lambda update-function-configuration --function-name "$HEALTH_FN" --environment "$env" >/dev/null 2>&1 \
    || warn "COULD NOT RESTORE ${HEALTH_FN}: set HEALTHY=true by hand"
  ORIG_ENV=""
}

echo "======================================================================"
echo " MQ -> GLOBAL ENDPOINT TEST   (endpoint ${GE_ID}, instance ${INSTANCE_ID})"
echo "======================================================================"

# ---- Phase 1 ------------------------------------------------------------------
info "phase 1: replication through the global endpoint"
cfg_id="$(run 'cd /opt/eb-mq/docker && docker compose exec -T bridge printenv EB_ENDPOINT_ID' 2>/dev/null | tr -d '[:space:]' || true)"
if [[ "$cfg_id" == "$GE_ID" ]]; then pass "g0 bridge is configured with EB_ENDPOINT_ID=${GE_ID}"
else fail "g0 bridge EB_ENDPOINT_ID is '${cfg_id:-empty}', expected ${GE_ID}: deploy with  deploy.sh --yes --global-endpoint"; exit 1; fi

ORDER1="$(new_id)"; M1="$(now_ms)"
put_order "$ORDER1" && pass "g1a put order ${ORDER1} on ORDERS.OUT" || fail "g1a could not put the order"
if wait_consumer "$PRI_REGION" "$PRI_CONSUMER_LG" "$ORDER1" "$M1" 90; then
  pass "g1 processed by the PRIMARY consumer (${PRI_REGION})"
else fail "g1 not processed in ${PRI_REGION} within 90s (bridge not publishing? check: docker compose logs bridge)"; fi
if wait_consumer "$SEC_REGION" "$SEC_CONSUMER_LG" "$ORDER1" "$M1" 240; then
  pass "g2 REPLICATED to ${SEC_REGION} and processed there (only the global endpoint does this)"
else fail "g2 not seen in ${SEC_REGION} within 240s: the bridge is not publishing through the endpoint, or replication is down"; fi
reg="$(audit_field "$SEC_REGION" "$SEC_AUDIT_LG" "$ORDER1" "$M1" '.region')"
org="$(audit_field "$SEC_REGION" "$SEC_AUDIT_LG" "$ORDER1" "$M1" '.detail.origin')"
[[ "$reg" == "$PRI_REGION" && "$org" == "ibm-mq" ]] \
  && pass "g3 replica keeps envelope region=${reg} and detail.origin=${org}" \
  || fail "g3 replica envelope region='${reg:-?}' origin='${org:-?}' (expected ${PRI_REGION} / ibm-mq)"

if [[ "$FAILOVER" -ne 1 ]]; then
  echo "======================================================================"
  [[ "$FAILED" -eq 0 ]] && ok "PHASE 1 PASSED: MQ orders go through the global endpoint (failover not run: add --failover --confirm)" \
                        || { err "GLOBAL ENDPOINT TEST FAILED"; exit 1; }
  exit 0
fi

# ---- Phase 2: failover ----------------------------------------------------------
info "phase 2: simulated primary outage (HEALTHY=false on ${HEALTH_FN})"
read -r ok0 bad0 <<<"$(hc_counts)"
if [[ "${ok0:-0}" -gt 0 && "${bad0:-1}" -eq 0 ]]; then pass "f0 Route 53 sees the primary healthy before the drill (${ok0} checkers)"
else fail "f0 primary is not healthy before the drill (success=${ok0:-?} failure=${bad0:-?}): not starting"; exit 1; fi

trap restore_health EXIT
ORIG_ENV="$(dep "$PRI_REGION" lambda get-function-configuration --function-name "$HEALTH_FN" --output json)"
cur_env="$(jq -c '.Environment.Variables // {} | .HEALTHY="false" | {Variables:.}' <<<"$ORIG_ENV")"
dep "$PRI_REGION" lambda update-function-configuration --function-name "$HEALTH_FN" --environment "$cur_env" >/dev/null
dep "$PRI_REGION" lambda wait function-updated --function-name "$HEALTH_FN" 2>/dev/null || sleep 10
T_OUTAGE=$(date +%s)

unhealthy=0
for i in $(seq 1 24); do
  sleep 30; read -r ok bad <<<"$(hc_counts)"
  info "health check: success=${ok:-?} failure=${bad:-?} (poll ${i}/24)"
  if [[ "${bad:-0}" -gt "${ok:-0}" ]]; then unhealthy=1; break; fi
done
[[ "$unhealthy" -eq 1 ]] && pass "f1 Route 53 reports the primary Unhealthy after $(( $(date +%s) - T_OUTAGE ))s" \
                         || { fail "f1 Route 53 never reported Unhealthy within 12 min"; exit 1; }
T_UNHEALTHY=$(date +%s)

found=0
for i in $(seq 1 20); do
  OID="$(new_id)"; MK="$(now_ms)"
  put_order "$OID" || true
  sleep 45
  r="$(audit_field "$SEC_REGION" "$SEC_AUDIT_LG" "$OID" "$MK" '.region')"
  info "order ${OID}: envelope region in ${SEC_REGION} audit = '${r:-not seen}' (try ${i}/20)"
  if [[ "$r" == "$SEC_REGION" ]]; then found=1; break; fi
done
if [[ "$found" -eq 1 ]]; then
  pass "f2 MQ order ${OID} RECEIVED natively in ${SEC_REGION} $(( $(date +%s) - T_UNHEALTHY ))s after Unhealthy; the bridge was NOT restarted"
  consumer_saw "$SEC_REGION" "$SEC_CONSUMER_LG" "$OID" "$MK" && pass "f2b the ${SEC_REGION} consumer processed it" || fail "f2b ${SEC_REGION} consumer did not log it"
else
  fail "f2 no MQ order was received natively in ${SEC_REGION} within ~15 min of Unhealthy: the bridge keeps sending to the primary (warm connection pinned to the old region?)"
fi

restore_health
recovered=0
for i in $(seq 1 24); do
  sleep 30; read -r ok bad <<<"$(hc_counts)"
  info "recovery: success=${ok:-?} failure=${bad:-?} (poll ${i}/24)"
  if [[ "${ok:-0}" -gt 0 && "${bad:-1}" -eq 0 ]]; then recovered=1; break; fi
done
[[ "$recovered" -eq 1 ]] && pass "f3 HEALTHY=true restored; Route 53 sees the primary healthy again" || fail "f3 health check did not recover within 12 min: check ${HEALTH_FN}"

back=0
for i in $(seq 1 16); do
  OID="$(new_id)"; MK="$(now_ms)"
  put_order "$OID" || true
  sleep 45
  r="$(audit_field "$PRI_REGION" "$PRI_AUDIT_LG" "$OID" "$MK" '.region')"
  info "order ${OID}: envelope region in ${PRI_REGION} audit = '${r:-not seen}' (try ${i}/16)"
  if [[ "$r" == "$PRI_REGION" ]]; then back=1; break; fi
done
[[ "$back" -eq 1 ]] && pass "f4 MQ order ${OID} received natively in ${PRI_REGION} again (failed back)" \
                    || fail "f4 orders did not return to ${PRI_REGION} within ~12 min after recovery"

echo "======================================================================"
if [[ "$FAILED" -ne 0 ]]; then err "GLOBAL ENDPOINT TEST FAILED"; exit 1; fi
ok "ALL PASSED: MQ orders go through the global endpoint, replicate, fail over and fail back"
