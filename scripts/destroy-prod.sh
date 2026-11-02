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
  [[ -n "$STATE_BUCKET" ]] || die "cannot read state_bucket_name from bootstrap state; refusing to destroy blind"

  # Every layer is attempted (so one failure does not hide another), but any
  # failure is RECORDED and blocks the bootstrap/state-bucket destroy below.
  info "STEP 1 — destroy application"
  tf_init_layer application "$APPLICATION_DIR" "$BACKEND_HCL" && tf_destroy_layer application "$APPLICATION_DIR" \
    -var "primary_region=${PRIMARY_REGION}" -var "secondary_region=${SECONDARY_REGION}" \
    -var "deployer_profile=${DEPLOYER_PROFILE}" -var "name_prefix=${NAME_PREFIX}" \
    -var "state_bucket=${STATE_BUCKET}" || true

  info "STEP 2 — destroy platform-global (global endpoint + health check)"
  tf_init_layer platform-global "$PLATFORM_GLOBAL_DIR" "$BACKEND_HCL" && tf_destroy_layer platform-global "$PLATFORM_GLOBAL_DIR" \
    -var "name_prefix=${NAME_PREFIX}" -var "deployer_profile=${DEPLOYER_PROFILE}" \
    -var "primary_region=${PRIMARY_REGION}" -var "secondary_region=${SECONDARY_REGION}" \
    -var "state_bucket=${STATE_BUCKET}" -var "state_region=${PRIMARY_REGION}" || true

  info "STEP 3 — destroy platform-secondary"
  tf_init_layer platform-secondary "$PLATFORM_SECONDARY_DIR" "$BACKEND_HCL" && tf_destroy_layer platform-secondary "$PLATFORM_SECONDARY_DIR" \
    "${COMMON_SHARE_VARS[@]}" \
    -var "region=${SECONDARY_REGION}" \
    -var "state_bucket=${STATE_BUCKET}" -var "state_region=${PRIMARY_REGION}" || true

  # platform-primary owns the KMS primary key that platform-secondary replicates:
  # never destroy it while the secondary layer still has resources.
  info "STEP 4 — destroy platform-primary"
  if [[ " ${DESTROY_FAILED[*]:-} " == *" platform-secondary"* ]]; then
    err "skipping platform-primary: platform-secondary still has resources that depend on it"
  else
    tf_init_layer platform-primary "$PLATFORM_PRIMARY_DIR" "$BACKEND_HCL" && tf_destroy_layer platform-primary "$PLATFORM_PRIMARY_DIR" \
      "${COMMON_SHARE_VARS[@]}" \
      -var "region=${PRIMARY_REGION}" -var "secondary_region=${SECONDARY_REGION}" || true
  fi

  unset AWS_SHARED_CREDENTIALS_FILE
else
  warn "no deployer creds/backend; platform/application may already be gone"
fi

# ---- GUARD: never remove the state bucket while any layer still has resources.
if [[ "${#DESTROY_FAILED[@]}" -gt 0 ]]; then
  echo "======================================================================" >&2
  err "DESTROY INCOMPLETE — failed layer(s): ${DESTROY_FAILED[*]}"
  err "Bootstrap (state bucket + deployer user) was NOT destroyed, so state is intact."
  err "Fix the cause (see terraform output above) and re-run this script — it is idempotent."
  err "Interrupted earlier and see 'state is locked'?  Re-run with FORCE_UNLOCK=1."
  echo "======================================================================" >&2
  exit 1
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

# ---- PROOF: read-only sweep of both regions + global; fails if anything remains.
info "STEP 6 — verifying nothing is left behind"
bash "${LAB_ROOT}/scripts/leftover-check.sh" \
  || die "destroy finished but leftovers remain (listed above) — NOT clean; remove them before ending the session"

echo "======================================================================"
ok "PRODUCTION LAB FULLY DESTROYED (verified)"
echo "======================================================================"
