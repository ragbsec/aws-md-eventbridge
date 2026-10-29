#!/usr/bin/env bash
###############################################################################
# 04-aws-multiregion.sh — AWS global-endpoint best-practice checks that span
# BOTH regions or inspect the global endpoint. Read-only.
#
# Covers (AWS-* standards from the EventBridge global-endpoints best-practices
# page and Security Hub EventBridge.4):
#   AWS-GE-REPLICATION     — global endpoint has event replication ENABLED
#   AWS-GE-QUOTA-PARITY    — PutEvents throttle quota equal across both regions
#   AWS-GE-HEALTHCHECK     — Route 53 health check excludes subscriber metrics
#
# Usage: scripts/compliance/04-aws-multiregion.sh
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-compliance.sh"

require_tools terraform aws jq
export AWS_SHARED_CREDENTIALS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"

# Resolve both regions + global-endpoint coordinates from platform outputs.
PRI_REGION="$(terraform -chdir="$PLATFORM_DIR" output -json primary 2>/dev/null | jq -r '.region // empty')"
SEC_REGION="$(terraform -chdir="$PLATFORM_DIR" output -json secondary 2>/dev/null | jq -r '.region // empty')"
GE_URL="$(terraform -chdir="$PLATFORM_DIR" output -raw global_endpoint_url 2>/dev/null || echo '')"
GE_ID="$(terraform -chdir="$PLATFORM_DIR" output -raw global_endpoint_id 2>/dev/null || echo '')"
HC_ID="$(terraform -chdir="$PLATFORM_DIR" output -raw health_check_id 2>/dev/null || echo '')"

echo "======================================================================"
echo " AWS GLOBAL-ENDPOINT STANDARDS (multi-region, read-only)"
echo "======================================================================"

###############################################################################
# AWS-GE-REPLICATION / AWS-GE-HEALTHCHECK — require a deployed global endpoint
###############################################################################
if [[ -z "$GE_ID" ]]; then
  na_v AWS-GE-REPLICATION "global-endpoint" "no global endpoint deployed (enable_global_endpoint=false) — Security Hub EventBridge.4 N/A until enabled"
  na_v AWS-GE-HEALTHCHECK "global-endpoint" "no global endpoint / health check deployed"
else
  AWS=(--profile "${DEPLOYER_PROFILE}" --region "${PRI_REGION}" --output json)
  # The endpoint NAME is "<name_prefix>-endpoint"; GE_ID is only the URL
  # subdomain. Resolve the real name by listing endpoints and matching the id.
  EP_NAME="$(aws events list-endpoints "${AWS[@]}" 2>/dev/null \
    | jq -r --arg sub "${GE_ID%%.*}" '.Endpoints[]? | select((.EndpointUrl // "") | contains($sub)) | .Name' | head -1)"
  [[ -n "$EP_NAME" ]] || EP_NAME="$(aws events list-endpoints "${AWS[@]}" 2>/dev/null | jq -r '.Endpoints[0].Name // empty')"
  EP="$(aws events describe-endpoint --name "$EP_NAME" "${AWS[@]}" 2>/dev/null || echo '{}')"
  # Replication state
  local_state="$(jq -r '.ReplicationConfig.State // empty' <<<"$EP")"
  [[ "$local_state" == "ENABLED" ]] \
    && pass_v AWS-GE-REPLICATION "endpoint:${EP_NAME}" "event replication ENABLED (Security Hub EventBridge.4)" \
    || fail_v AWS-GE-REPLICATION "endpoint:${EP_NAME:-$GE_ID}" "event replication not ENABLED (state=${local_state:-none}) — Security Hub EventBridge.4 FAIL"

  # Route 53 health check must NOT be driven by subscriber (SQS/Lambda) metrics.
  HC_ID_RESOLVED="$HC_ID"
  [[ -n "$HC_ID_RESOLVED" ]] || HC_ID_RESOLVED="$(jq -r '.RoutingConfig.FailoverConfig.Primary.HealthCheck // empty' <<<"$EP" | sed 's#.*/##')"
  if [[ -n "$HC_ID_RESOLVED" ]]; then
    HC="$(aws route53 get-health-check --health-check-id "$HC_ID_RESOLVED" --profile "${DEPLOYER_PROFILE}" --output json 2>/dev/null || echo '{}')"
    local_type="$(jq -r '.HealthCheck.HealthCheckConfig.Type // empty' <<<"$HC")"
    if [[ "$local_type" == "CLOUDWATCH_METRIC" ]]; then
      local_ns="$(jq -r '.HealthCheck.HealthCheckConfig.AlarmIdentifier.Name // empty' <<<"$HC")"
      fail_v AWS-GE-HEALTHCHECK "healthcheck:${HC_ID_RESOLVED}" "health check is CLOUDWATCH_METRIC (${local_ns}) — verify it does NOT track subscriber SQS/Lambda metrics (causes false failover)"
    else
      pass_v AWS-GE-HEALTHCHECK "healthcheck:${HC_ID_RESOLVED}" "${local_type:-endpoint-level} health check — not driven by subscriber metrics"
    fi
  else
    unk_v AWS-GE-HEALTHCHECK "global-endpoint" "global endpoint present but no health check id resolved"
  fi
fi

###############################################################################
# AWS-GE-QUOTA-PARITY — PutEvents throttle quota must match across regions so
# the secondary can absorb the primary's full rate on failover.
# Quota L-7B264GC8 = "PutEvents throttle limit in transactions per second".
###############################################################################
check_quota_parity() {
  [[ -n "$PRI_REGION" && -n "$SEC_REGION" ]] || { na_v AWS-GE-QUOTA-PARITY "quota" "could not resolve both regions"; return; }
  local q_pri q_sec
  q_pri="$(aws service-quotas get-service-quota --service-code events --quota-code L-7B264GC8 \
            --profile "${DEPLOYER_PROFILE}" --region "$PRI_REGION" --output json 2>/dev/null | jq -r '.Quota.Value // empty')"
  q_sec="$(aws service-quotas get-service-quota --service-code events --quota-code L-7B264GC8 \
            --profile "${DEPLOYER_PROFILE}" --region "$SEC_REGION" --output json 2>/dev/null | jq -r '.Quota.Value // empty')"
  # Fall back to default if an applied quota isn't returned.
  [[ -n "$q_pri" ]] || q_pri="$(aws service-quotas get-aws-default-service-quota --service-code events --quota-code L-7B264GC8 --profile "${DEPLOYER_PROFILE}" --region "$PRI_REGION" --output json 2>/dev/null | jq -r '.Quota.Value // empty')"
  [[ -n "$q_sec" ]] || q_sec="$(aws service-quotas get-aws-default-service-quota --service-code events --quota-code L-7B264GC8 --profile "${DEPLOYER_PROFILE}" --region "$SEC_REGION" --output json 2>/dev/null | jq -r '.Quota.Value // empty')"
  if [[ -z "$q_pri" || -z "$q_sec" ]]; then
    unk_v AWS-GE-QUOTA-PARITY "quota" "could not read PutEvents quota in one/both regions (needs servicequotas:GetServiceQuota)"
  elif [[ "$q_pri" == "$q_sec" ]]; then
    pass_v AWS-GE-QUOTA-PARITY "quota" "PutEvents quota matches across regions (${PRI_REGION}=${q_pri}, ${SEC_REGION}=${q_sec} tps)"
  else
    fail_v AWS-GE-QUOTA-PARITY "quota" "PutEvents quota mismatch (${PRI_REGION}=${q_pri} vs ${SEC_REGION}=${q_sec} tps) — secondary may throttle on failover"
  fi
}
check_quota_parity || true

echo "======================================================================"
summarize
