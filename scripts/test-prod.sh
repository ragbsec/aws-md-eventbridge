#!/usr/bin/env bash
###############################################################################
# test-prod.sh — functional proof for BOTH regions of the production lab.
# For each region: invoke the producer, confirm the consumer processed a routed
# event via CloudWatch Logs, confirm the audit log received it.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform aws jq
DEPLOYER_CREDS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"
[[ -f "$DEPLOYER_CREDS_FILE" ]] || die "no deployer creds; run scripts/create-prod.sh first"
export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"

APPLICATION_DIR="${LAB_ROOT}/application"
PLATFORM_PRIMARY_DIR="${LAB_ROOT}/platform-primary"
PLATFORM_SECONDARY_DIR="${LAB_ROOT}/platform-secondary"

FAILED=0
pass() { printf "PASS  %s\n" "$1"; }
fail() { printf "FAIL  %s\n" "$1"; FAILED=1; }

test_region() {
  local role="$1"   # primary | secondary
  local region producer consumer_lg audit_lg platform_dir
  region="$(terraform -chdir="$APPLICATION_DIR" output -json "$role" | jq -r .region)"
  producer="$(terraform -chdir="$APPLICATION_DIR" output -json "$role" | jq -r .producer)"
  consumer_lg="$(terraform -chdir="$APPLICATION_DIR" output -json "$role" | jq -r .consumer_logs)"
  # Option C: the audit log lives in the per-region platform root's `platform`
  # output object, not a single platform/ root.
  if [[ "$role" == "primary" ]]; then platform_dir="$PLATFORM_PRIMARY_DIR"; else platform_dir="$PLATFORM_SECONDARY_DIR"; fi
  audit_lg="$(terraform -chdir="$platform_dir" output -json platform | jq -r .audit_log)"

  local P=(--profile "$DEPLOYER_PROFILE" --region "$region")
  info "=== ${role} region: ${region} ==="

  local marker=$(($(date +%s) * 1000))
  if aws lambda invoke --function-name "$producer" --payload '{"count":5}' \
       --cli-binary-format raw-in-base64-out \
       "${P[@]}" "${RUNTIME_DIR}/invoke-${role}.json" >&2; then
    local pub; pub="$(jq -r '.published // 0' "${RUNTIME_DIR}/invoke-${role}.json" 2>/dev/null || echo 0)"
    [[ "$pub" -ge 1 ]] && pass "${region}: producer published $pub events" || fail "${region}: producer published nothing"
  else
    fail "${region}: producer invocation failed"
  fi

  local found=0
  for _ in $(seq 1 12); do
    sleep 5
    if aws logs filter-log-events --log-group-name "$consumer_lg" --start-time "$marker" \
         --filter-pattern '"processed order"' "${P[@]}" \
         --query 'events[].message' --output text 2>/dev/null | grep -q "processed order"; then
      found=1; break
    fi
  done
  [[ "$found" -eq 1 ]] && pass "${region}: consumer processed routed event" || fail "${region}: no consumer processing within 60s"

  local afound=0
  for _ in $(seq 1 6); do
    sleep 5
    if aws logs filter-log-events --log-group-name "$audit_lg" --start-time "$marker" \
         "${P[@]}" --query 'events[0].message' --output text 2>/dev/null | grep -q "OrderPlaced"; then
      afound=1; break
    fi
  done
  [[ "$afound" -eq 1 ]] && pass "${region}: audit log received event" || fail "${region}: audit log missing event"
}

echo "======================================================================"
echo " PRODUCTION FUNCTIONAL TEST (multi-region)"
echo "======================================================================"
test_region primary
test_region secondary
echo "======================================================================"
if [[ "$FAILED" -ne 0 ]]; then err "FUNCTIONAL TEST FAILED"; exit 1; fi
ok "ALL REGIONS PASSED — production event flow proven"
