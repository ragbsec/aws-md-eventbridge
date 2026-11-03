#!/usr/bin/env bash
###############################################################################
# 05-global-endpoint.sh — LIVE tests of the EventBridge GLOBAL ENDPOINT.
#
# Needs a stack built with ENABLE_GLOBAL_ENDPOINT=true (platform-global applied).
#
# Default run (adds no infrastructure, changes nothing; publishes 1 event):
#   GE-CONFIG    endpoint ACTIVE, replication ENABLED, both buses, failover health check
#   GE-HEALTH    Route 53 health check currently sees the primary as healthy
#   GE-SEND      PutEvents --endpoint-id (SigV4a) succeeds with 0 failed entries and the
#                event is routed + processed by the PRIMARY consumer
#   GE-REPL      the event is REPLICATED to the secondary bus and processed there
#
# Failover drill (MUTATING — gated; self-restoring):
#   --failover --confirm
#   Sets the health Lambda's HEALTHY env var to "false" (simulated primary outage),
#   waits for Route 53 to report Unhealthy, keeps publishing through the endpoint
#   until an event is received by the SECONDARY region, then ALWAYS restores
#   HEALTHY=true (EXIT trap) and waits for the health check to recover.
#   Takes ~10-20 minutes (AWS documents RTO of 360-420s plus detection time).
#
# Usage:
#   scripts/compliance/05-global-endpoint.sh
#   scripts/compliance/05-global-endpoint.sh --failover --confirm
#
# Verdicts follow the same PASS / FAIL / UNKNOWN / NOT_APPLICABLE model as 01-04.
# See docs/AWS_CLI_TEST_COOKBOOK.md section 6 for the same steps as plain CLI.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-compliance.sh"

require_tools terraform aws jq
export AWS_SHARED_CREDENTIALS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"

FAILOVER=0; CONFIRM=0
for a in "$@"; do
  case "$a" in
    --failover) FAILOVER=1 ;;
    --confirm)  CONFIRM=1 ;;
    -h|--help)  sed -n 2,30p "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done
if [[ "$FAILOVER" -eq 1 && "$CONFIRM" -ne 1 ]]; then
  die "the failover drill changes the health Lambda; re-run with: --failover --confirm"
fi

# ---- discover both regions + the global endpoint ---------------------------
discover primary
P_REGION="$D_REGION"; P_BUS="$D_BUS"; P_CONSUMER_LG="$D_CONSUMER_LG"; P_AUDIT_LG="$D_AUDIT_LG"
discover secondary
S_REGION="$D_REGION"; S_BUS="$D_BUS"; S_CONSUMER_LG="$D_CONSUMER_LG"; S_AUDIT_LG="$D_AUDIT_LG"

GE_ID="$(terraform -chdir="$PLATFORM_GLOBAL_DIR" output -raw global_endpoint_id 2>/dev/null || echo '')"
HC_ID="$(terraform -chdir="$PLATFORM_GLOBAL_DIR" output -raw health_check_id 2>/dev/null || echo '')"
HEALTH_FN="$(terraform -chdir="$PLATFORM_GLOBAL_DIR" output -raw health_function_name 2>/dev/null || echo '')"

PRI=(--profile "$DEPLOYER_PROFILE" --region "$P_REGION" --output json)
SEC=(--profile "$DEPLOYER_PROFILE" --region "$S_REGION" --output json)
SOURCE="${EVENT_SOURCE:-prod.orders}"

echo "======================================================================"
echo " GLOBAL ENDPOINT TESTS (live) — ${P_REGION} <-> ${S_REGION}"
echo "======================================================================"

if [[ -z "$GE_ID" ]]; then
  na_v GE-CONFIG "global-endpoint" "no global endpoint deployed — rebuild with ENABLE_GLOBAL_ENDPOINT=true"
  echo "======================================================================"
  summarize; exit $?
fi

# ---- helpers ----------------------------------------------------------------
# Does <log group> contain <pattern> after <marker ms>?  args: region_flags lg marker pattern
log_has() {
  local -n _fl="$1"; local lg="$2" marker="$3" pat="$4"
  aws logs filter-log-events --log-group-name "$lg" --start-time "$marker" \
    --filter-pattern "\"$pat\"" "${_fl[@]}" --query 'events[].message' --output text 2>/dev/null \
    | grep -q "$pat"
}
# Poll until found or timeout.  args: flags_array_name lg marker pattern tries sleep
wait_log() {
  local fl="$1" lg="$2" marker="$3" pat="$4" tries="${5:-12}" nap="${6:-5}" i
  for ((i=0;i<tries;i++)); do
    sleep "$nap"
    log_has "$fl" "$lg" "$marker" "$pat" && return 0
  done
  return 1
}
# First audit-log message that mentions <pattern>.
audit_msg() {
  local -n _fl="$1"; local lg="$2" marker="$3" pat="$4"
  aws logs filter-log-events --log-group-name "$lg" --start-time "$marker" \
    --filter-pattern "\"$pat\"" "${_fl[@]}" --query 'events[0].message' --output text 2>/dev/null || true
}
# Publish one OrderPlaced event THROUGH the global endpoint (needs awscrt: AWS CLI v2 has it).
put_via_endpoint() {
  local oid="$1" entries
  entries="$(jq -nc --arg id "$oid" --arg bus "$P_BUS" --arg src "$SOURCE" \
    '[{Source:$src,DetailType:"OrderPlaced",EventBusName:$bus,
       Detail:({orderId:$id,quantity:1,amount:9.99,customer:"ge-test"}|tojson)}]')"
  aws events put-events --endpoint-id "$GE_ID" --entries "$entries" "${PRI[@]}" 2>&1
}
# Number of Route 53 checkers that currently report Success / Failure.
hc_counts() {
  local out; out="$(aws route53 get-health-check-status --health-check-id "$HC_ID" \
    --profile "$DEPLOYER_PROFILE" --output json 2>/dev/null || echo '{}')"
  jq -r '[(.HealthCheckObservations // [] | map(select(.StatusReport.Status | startswith("Success"))) | length),
          (.HealthCheckObservations // [] | map(select(.StatusReport.Status | startswith("Failure"))) | length)] | @tsv' <<<"$out"
}

###############################################################################
# GE-CONFIG — endpoint is active, replicating, spans both buses, has a failover health check
###############################################################################
check_config() {
  local name ep state repl nbus hc secr
  name="$(aws events list-endpoints "${PRI[@]}" 2>/dev/null \
    | jq -r --arg sub "${GE_ID%%.*}" '.Endpoints[]? | select((.EndpointUrl // "") | contains($sub)) | .Name' | head -1)"
  [[ -n "$name" ]] || { fail_v GE-CONFIG "endpoint:${GE_ID}" "could not find the endpoint in ${P_REGION}"; return; }
  ep="$(aws events describe-endpoint --name "$name" "${PRI[@]}" 2>/dev/null || echo '{}')"
  state="$(jq -r '.State // empty' <<<"$ep")"
  repl="$(jq -r '.ReplicationConfig.State // empty' <<<"$ep")"
  nbus="$(jq -r '.EventBuses | length' <<<"$ep" 2>/dev/null || echo 0)"
  hc="$(jq -r '.RoutingConfig.FailoverConfig.Primary.HealthCheck // empty' <<<"$ep")"
  secr="$(jq -r '.RoutingConfig.FailoverConfig.Secondary.Route // empty' <<<"$ep")"
  if [[ "$state" == "ACTIVE" && "$repl" == "ENABLED" && "$nbus" -eq 2 && -n "$hc" && "$secr" == "$S_REGION" ]]; then
    pass_v GE-CONFIG "endpoint:${name}" "ACTIVE, replication ENABLED, 2 buses, failover to ${secr} gated by a health check"
  else
    fail_v GE-CONFIG "endpoint:${name}" "state=${state:-?} replication=${repl:-?} buses=${nbus} healthcheck=${hc:+set} secondaryRoute=${secr:-?}"
  fi
}

###############################################################################
# GE-HEALTH — Route 53 currently sees the primary as healthy
###############################################################################
check_health() {
  [[ -n "$HC_ID" ]] || { unk_v GE-HEALTH "healthcheck" "no health check id from platform-global"; return; }
  local ok bad; read -r ok bad <<<"$(hc_counts)"
  if [[ -z "${ok:-}" ]]; then
    unk_v GE-HEALTH "healthcheck:${HC_ID}" "could not read health-check status (needs route53:GetHealthCheckStatus)"
  elif [[ "$ok" -gt 0 && "$bad" -eq 0 ]]; then
    pass_v GE-HEALTH "healthcheck:${HC_ID}" "primary healthy: ${ok} checker(s) Success, ${bad} Failure"
  else
    fail_v GE-HEALTH "healthcheck:${HC_ID}" "primary NOT healthy: ${ok} Success, ${bad} Failure — a failover test now would prove nothing"
  fi
}

# Region field of the replicated copy in the secondary audit log, used to calibrate
# the failover check (set by check_send_and_replication).
REPLICA_REGION_FIELD=""

###############################################################################
# GE-SEND / GE-REPL — publish through the endpoint; primary processes; secondary gets a replica
###############################################################################
check_send_and_replication() {
  local marker oid out failed
  marker=$(( $(date +%s) * 1000 )); oid="ge-$(date +%s)"
  out="$(put_via_endpoint "$oid")" || true
  failed="$(jq -r '.FailedEntryCount // empty' <<<"$out" 2>/dev/null || true)"
  if [[ "$out" == *MissingDependencyException* || "$out" == *crt* ]]; then
    fail_v GE-SEND "endpoint:${GE_ID}" "client lacks awscrt (SigV4a) — see docs/CICD_AND_OPERATIONS.md section 2"; return
  elif [[ "$out" == *AccessDenied* || "$out" == *not\ authorized* ]]; then
    fail_v GE-SEND "endpoint:${GE_ID}" "AccessDenied calling PutEvents with --endpoint-id for the deployer profile"; return
  elif [[ "$failed" != "0" ]]; then
    fail_v GE-SEND "endpoint:${GE_ID}" "PutEvents via endpoint failed (FailedEntryCount=${failed:-n/a})"; return
  fi
  if wait_log PRI "$P_CONSUMER_LG" "$marker" "$oid" 12 5; then
    pass_v GE-SEND "endpoint:${GE_ID}" "PutEvents via SigV4a OK, 0 failed; ${oid} processed by the ${P_REGION} consumer"
  else
    fail_v GE-SEND "endpoint:${GE_ID}" "accepted by the endpoint but ${oid} not processed in ${P_REGION} within 60s"
  fi
  # Replication is asynchronous (AWS documents minutes of lag): be patient.
  if wait_log SEC "$S_CONSUMER_LG" "$marker" "$oid" 24 5; then
    REPLICA_REGION_FIELD="$(audit_msg SEC "$S_AUDIT_LG" "$marker" "$oid" | jq -r '.region // empty' 2>/dev/null || true)"
    pass_v GE-REPL "endpoint:${GE_ID}" "${oid} replicated to ${S_REGION} and processed there (event 'region' field on the replica: ${REPLICA_REGION_FIELD:-unknown})"
  else
    fail_v GE-REPL "endpoint:${GE_ID}" "${oid} not seen in ${S_REGION} within 120s — replication not working (check the replication role + KMS grants)"
  fi
}

###############################################################################
# GE-FAILOVER / GE-FAILBACK — simulated primary outage via the health Lambda (MUTATING)
###############################################################################
ORIG_ENV_JSON=""
restore_health() {
  [[ -n "$ORIG_ENV_JSON" ]] || return 0
  info "restoring ${HEALTH_FN} HEALTHY=true"
  local env; env="$(jq -c '.Environment.Variables // {} | .HEALTHY="true" | {Variables:.}' <<<"$ORIG_ENV_JSON")"
  aws lambda update-function-configuration --function-name "$HEALTH_FN" --environment "$env" \
    "${PRI[@]}" >/dev/null 2>&1 || warn "COULD NOT RESTORE ${HEALTH_FN} — set HEALTHY=true by hand (cookbook section 6)"
  ORIG_ENV_JSON=""
}

set_healthy() {   # $1 = true|false
  local env cur
  cur="$(aws lambda get-function-configuration --function-name "$HEALTH_FN" "${PRI[@]}")" || return 1
  [[ -n "$ORIG_ENV_JSON" ]] || ORIG_ENV_JSON="$cur"      # remember the original for the trap
  env="$(jq -c --arg h "$1" '.Environment.Variables // {} | .HEALTHY=$h | {Variables:.}' <<<"$cur")"
  aws lambda update-function-configuration --function-name "$HEALTH_FN" --environment "$env" "${PRI[@]}" >/dev/null || return 1
  aws lambda wait function-updated --function-name "$HEALTH_FN" "${PRI[@]}" 2>/dev/null || sleep 10
}

check_failover() {
  [[ -n "$HEALTH_FN" && -n "$HC_ID" ]] || { unk_v GE-FAILOVER "health-lambda" "no health function / health check from platform-global"; return; }
  trap restore_health EXIT
  info "simulating primary outage: ${HEALTH_FN} HEALTHY=false"
  if ! set_healthy false; then
    unk_v GE-FAILOVER "lambda:${HEALTH_FN}" "could not update the health Lambda (needs lambda:UpdateFunctionConfiguration)"; return
  fi

  # 1) Route 53 must notice (3 failures x 30s interval, plus checker spread).
  local ok bad i unhealthy=0
  for ((i=0;i<24;i++)); do
    sleep 30; read -r ok bad <<<"$(hc_counts)"
    info "health check: Success=${ok:-?} Failure=${bad:-?} (poll $((i+1))/24)"
    if [[ "${ok:-1}" -eq 0 && "${bad:-0}" -gt 0 ]] || [[ "${bad:-0}" -gt "${ok:-0}" ]]; then unhealthy=1; break; fi
  done
  [[ "$unhealthy" -eq 1 ]] || { fail_v GE-FAILOVER "healthcheck:${HC_ID}" "Route 53 never reported the primary Unhealthy within 12 min"; return; }

  # 2) Keep publishing THROUGH the endpoint until the secondary region receives one.
  #    Every probe is a fresh CLI process (cold client: no cached DNS to the primary).
  local probe marker found=0 region_seen=""
  for ((i=0;i<20;i++)); do
    marker=$(( $(date +%s) * 1000 )); probe="ge-fo-$(date +%s)"
    put_via_endpoint "$probe" >/dev/null || true
    sleep 30
    region_seen="$(audit_msg SEC "$S_AUDIT_LG" "$marker" "$probe" | jq -r '.region // empty' 2>/dev/null || true)"
    info "probe ${probe}: secondary region field='${region_seen:-none}' (poll $((i+1))/20)"
    # A failed-over event is RECEIVED in the secondary: its region field is the secondary.
    # A mere replica keeps the original (primary) region — calibrated in GE-REPL above.
    if [[ "$region_seen" == "$S_REGION" ]]; then found=1; break; fi
  done
  if [[ "$found" -eq 1 && "$REPLICA_REGION_FIELD" == "$P_REGION" ]]; then
    pass_v GE-FAILOVER "endpoint:${GE_ID}" "with the primary Unhealthy, ${probe} was received in ${S_REGION} (region field ${region_seen}; replicas keep ${P_REGION})"
  elif [[ "$found" -eq 1 ]]; then
    unk_v GE-FAILOVER "endpoint:${GE_ID}" "secondary received ${probe} but the replica region field could not be calibrated (was '${REPLICA_REGION_FIELD:-unknown}') — confirm by hand"
  else
    fail_v GE-FAILOVER "endpoint:${GE_ID}" "no probe was received natively in ${S_REGION} within ~10 min of Unhealthy"
  fi

  # 3) Fail back: restore, wait for Route 53 to see the primary again.
  restore_health
  local recovered=0
  for ((i=0;i<24;i++)); do
    sleep 30; read -r ok bad <<<"$(hc_counts)"
    info "recovery: Success=${ok:-?} Failure=${bad:-?} (poll $((i+1))/24)"
    if [[ "${ok:-0}" -gt 0 && "${bad:-1}" -eq 0 ]]; then recovered=1; break; fi
  done
  [[ "$recovered" -eq 1 ]] \
    && pass_v GE-FAILBACK "healthcheck:${HC_ID}" "HEALTHY=true restored; Route 53 sees the primary healthy again" \
    || fail_v GE-FAILBACK "healthcheck:${HC_ID}" "health check did not recover within 12 min — check ${HEALTH_FN} HEALTHY"
}

check_config
check_health
check_send_and_replication
if [[ "$FAILOVER" -eq 1 ]]; then
  check_failover
else
  na_v GE-FAILOVER "endpoint:${GE_ID}" "not run (needs --failover --confirm): simulates a primary outage via the health Lambda"
fi
echo "======================================================================"
summarize
