#!/usr/bin/env bash
###############################################################################
# destroy-prod.sh — tear down the production lab in reverse dependency order
# (Option C — four deployer roots + bootstrap):
#   1. application        4. platform-primary
#   2. platform-global    5. bootstrap (operator)
#   3. platform-secondary
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform aws jq
assert_profile "$OPERATOR_PROFILE"

PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
NAME_PREFIX="${NAME_PREFIX:-eb-prod}"
BUS_NAME="${BUS_NAME:-eb-prod-orders}"
ENABLE_GLOBAL_ENDPOINT="${ENABLE_GLOBAL_ENDPOINT:-false}"
PLATFORM_PRIMARY_DIR="${LAB_ROOT}/platform-primary"
PLATFORM_SECONDARY_DIR="${LAB_ROOT}/platform-secondary"
PLATFORM_GLOBAL_DIR="${LAB_ROOT}/platform-global"
APPLICATION_DIR="${LAB_ROOT}/application"
DEPLOYER_CREDS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"
BACKEND_HCL="${RUNTIME_DIR}/backend.hcl"

COMMON_SHARE_VARS=(
  -var "name_prefix=${NAME_PREFIX}"
  -var "bus_name=${BUS_NAME}"
  -var "deployer_profile=${DEPLOYER_PROFILE}"
)

if [[ -f "$DEPLOYER_CREDS_FILE" && -f "$BACKEND_HCL" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"
  STATE_BUCKET="$(tf_output "$BOOTSTRAP_DIR" state_bucket_name 2>/dev/null || echo "")"

  info "STEP 1 — destroy application"
  terraform -chdir="$APPLICATION_DIR" init -input=false -reconfigure -backend-config="$BACKEND_HCL" >&2 || true
  terraform -chdir="$APPLICATION_DIR" destroy -auto-approve -input=false \
    -var "primary_region=${PRIMARY_REGION}" -var "secondary_region=${SECONDARY_REGION}" \
    -var "deployer_profile=${DEPLOYER_PROFILE}" -var "name_prefix=${NAME_PREFIX}" \
    -var "state_bucket=${STATE_BUCKET}" >&2 || warn "application destroy reported issues"

  info "STEP 2 — destroy platform-global (global endpoint + health check)"
  terraform -chdir="$PLATFORM_GLOBAL_DIR" init -input=false -reconfigure -backend-config="$BACKEND_HCL" >&2 || true
  terraform -chdir="$PLATFORM_GLOBAL_DIR" destroy -auto-approve -input=false \
    -var "name_prefix=${NAME_PREFIX}" -var "deployer_profile=${DEPLOYER_PROFILE}" \
    -var "primary_region=${PRIMARY_REGION}" -var "secondary_region=${SECONDARY_REGION}" \
    -var "state_bucket=${STATE_BUCKET}" -var "state_region=${PRIMARY_REGION}" >&2 \
    || warn "platform-global destroy reported issues (may already be absent if endpoint was never enabled)"

  info "STEP 3 — destroy platform-secondary"
  terraform -chdir="$PLATFORM_SECONDARY_DIR" init -input=false -reconfigure -backend-config="$BACKEND_HCL" >&2 || true
  terraform -chdir="$PLATFORM_SECONDARY_DIR" destroy -auto-approve -input=false \
    "${COMMON_SHARE_VARS[@]}" \
    -var "region=${SECONDARY_REGION}" \
    -var "state_bucket=${STATE_BUCKET}" -var "state_region=${PRIMARY_REGION}" >&2 \
    || warn "platform-secondary destroy reported issues"

  info "STEP 4 — destroy platform-primary"
  terraform -chdir="$PLATFORM_PRIMARY_DIR" init -input=false -reconfigure -backend-config="$BACKEND_HCL" >&2 || true
  terraform -chdir="$PLATFORM_PRIMARY_DIR" destroy -auto-approve -input=false \
    "${COMMON_SHARE_VARS[@]}" \
    -var "region=${PRIMARY_REGION}" -var "secondary_region=${SECONDARY_REGION}" >&2 \
    || warn "platform-primary destroy reported issues"

  unset AWS_SHARED_CREDENTIALS_FILE
else
  warn "no deployer creds/backend; platform/application may already be gone"
fi

info "STEP 5 — destroy bootstrap (operator)"
terraform -chdir="$BOOTSTRAP_DIR" init -input=false >&2
STATE_BUCKET="$(tf_output "$BOOTSTRAP_DIR" state_bucket_name 2>/dev/null || echo "")"
CREATED="$(tf_output "$BOOTSTRAP_DIR" state_bucket_created 2>/dev/null || echo false)"
if [[ -n "$STATE_BUCKET" && "$CREATED" == "true" ]]; then
  info "emptying state bucket s3://${STATE_BUCKET}"
  for q in "Versions" "DeleteMarkers"; do
    aws s3api list-object-versions --bucket "$STATE_BUCKET" --profile "$OPERATOR_PROFILE" --region "$PRIMARY_REGION" \
      --output json --query "{Objects: ${q}[].{Key:Key,VersionId:VersionId}}" > "${RUNTIME_DIR}/del.json" 2>/dev/null || echo '{"Objects":null}' > "${RUNTIME_DIR}/del.json"
    if [[ "$(jq '.Objects | length // 0' "${RUNTIME_DIR}/del.json")" -gt 0 ]]; then
      aws s3api delete-objects --bucket "$STATE_BUCKET" --delete "file://${RUNTIME_DIR}/del.json" \
        --profile "$OPERATOR_PROFILE" --region "$PRIMARY_REGION" >&2 || true
    fi
  done
fi
terraform -chdir="$BOOTSTRAP_DIR" destroy -auto-approve -input=false \
  -var "region=${PRIMARY_REGION}" -var "operator_profile=${OPERATOR_PROFILE}" \
  -var "state_bucket_name=${STATE_BUCKET_NAME:-}" >&2

rm -f "$DEPLOYER_CREDS_FILE" "$BACKEND_HCL" "${RUNTIME_DIR}"/*.json 2>/dev/null || true
echo "======================================================================"
ok "PRODUCTION LAB FULLY DESTROYED"
echo "======================================================================"
