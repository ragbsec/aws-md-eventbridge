#!/usr/bin/env bash
###############################################################################
# create-prod.sh — stand up the PRODUCTION-grade, multi-region lab (Option C).
#
# Layers, applied in order (each a SEPARATE Terraform state — full isolation):
#   1. bootstrap          (operator) — S3 state bucket + deployer IAM user
#   2. platform-primary   (deployer) — primary-region KMS primary key + bus/...
#   3. platform-secondary (deployer) — secondary-region KMS replica + bus/...
#                                       (reads platform-primary state for the key)
#   4. platform-global    (deployer) — global endpoint + Route53 health check +
#                                       replication role + KMS grants
#                                       (reads BOTH regional states; only when
#                                        ENABLE_GLOBAL_ENDPOINT=true)
#   5. application        (deployer) — producer/consumer Lambdas + DLQ + SNS +
#                                       targets, reading both regional states
#
# Sandbox test defaults: PRIMARY=us-east-1, SECONDARY=us-west-2, global
# endpoint OFF (Route 53 health checks need a public domain). For real prod set
# SECONDARY_REGION=us-east-2 and ENABLE_GLOBAL_ENDPOINT=true.
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

# ---- STEP 0: static verification of all layers ----------------------------
info "STEP 0 — static verification"
bash "${LAB_ROOT}/scripts/verify-prod.sh"

# ---- STEP 1: bootstrap (operator) -----------------------------------------
info "STEP 1 — bootstrap (operator: ${OPERATOR_PROFILE})"
terraform -chdir="$BOOTSTRAP_DIR" init -input=false >&2
terraform -chdir="$BOOTSTRAP_DIR" apply -auto-approve -input=false \
  -var "region=${PRIMARY_REGION}" \
  -var "operator_profile=${OPERATOR_PROFILE}" \
  -var "state_bucket_name=${STATE_BUCKET_NAME:-}" >&2

STATE_BUCKET="$(tf_output "$BOOTSTRAP_DIR" state_bucket_name)"
AK_ID="$(tf_output "$BOOTSTRAP_DIR" deployer_access_key_id)"
AK_SECRET="$(tf_output "$BOOTSTRAP_DIR" deployer_secret_access_key)"

aws s3 cp "${BOOTSTRAP_DIR}/terraform.tfstate" \
  "s3://${STATE_BUCKET}/eventbridge-lab/bootstrap/terraform.tfstate" \
  --profile "$OPERATOR_PROFILE" --region "$PRIMARY_REGION" >&2

# ---- write deployer profile ------------------------------------------------
DEPLOYER_CREDS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"
umask 077
cat > "$DEPLOYER_CREDS_FILE" <<EOF
[${DEPLOYER_PROFILE}]
aws_access_key_id = ${AK_ID}
aws_secret_access_key = ${AK_SECRET}
region = ${PRIMARY_REGION}
EOF
export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"

info "waiting for deployer credentials to activate..."
for _ in $(seq 1 30); do
  aws sts get-caller-identity --profile "$DEPLOYER_PROFILE" --region "$PRIMARY_REGION" >/dev/null 2>&1 && break
  sleep 2
done
assert_profile "$DEPLOYER_PROFILE"

# ---- shared backend config (state bucket lives in the PRIMARY region) ------
BACKEND_HCL="${RUNTIME_DIR}/backend.hcl"
cat > "$BACKEND_HCL" <<EOF
bucket       = "${STATE_BUCKET}"
region       = "${PRIMARY_REGION}"
profile      = "${DEPLOYER_PROFILE}"
use_lockfile = true
encrypt      = true
EOF

COMMON_SHARE_VARS=(
  -var "name_prefix=${NAME_PREFIX}"
  -var "bus_name=${BUS_NAME}"
  -var "deployer_profile=${DEPLOYER_PROFILE}"
)

# ---- STEP 2: platform-primary ---------------------------------------------
info "STEP 2 — platform-primary apply (deployer, ${PRIMARY_REGION})"
terraform -chdir="$PLATFORM_PRIMARY_DIR" init -input=false -reconfigure -backend-config="$BACKEND_HCL" >&2
terraform -chdir="$PLATFORM_PRIMARY_DIR" apply -auto-approve -input=false \
  "${COMMON_SHARE_VARS[@]}" \
  -var "region=${PRIMARY_REGION}" \
  -var "secondary_region=${SECONDARY_REGION}" >&2
ok "platform-primary applied"

# ---- STEP 3: platform-secondary (reads platform-primary state) ------------
info "STEP 3 — platform-secondary apply (deployer, ${SECONDARY_REGION})"
terraform -chdir="$PLATFORM_SECONDARY_DIR" init -input=false -reconfigure -backend-config="$BACKEND_HCL" >&2
terraform -chdir="$PLATFORM_SECONDARY_DIR" apply -auto-approve -input=false \
  "${COMMON_SHARE_VARS[@]}" \
  -var "region=${SECONDARY_REGION}" \
  -var "state_bucket=${STATE_BUCKET}" \
  -var "state_region=${PRIMARY_REGION}" >&2
ok "platform-secondary applied"

# ---- STEP 4: platform-global (reads BOTH regional states) -----------------
if [[ "$ENABLE_GLOBAL_ENDPOINT" == "true" ]]; then
  info "STEP 4 — platform-global apply (deployer, global endpoint + health check)"
  terraform -chdir="$PLATFORM_GLOBAL_DIR" init -input=false -reconfigure -backend-config="$BACKEND_HCL" >&2
  terraform -chdir="$PLATFORM_GLOBAL_DIR" apply -auto-approve -input=false \
    -var "name_prefix=${NAME_PREFIX}" \
    -var "deployer_profile=${DEPLOYER_PROFILE}" \
    -var "primary_region=${PRIMARY_REGION}" \
    -var "secondary_region=${SECONDARY_REGION}" \
    -var "state_bucket=${STATE_BUCKET}" \
    -var "state_region=${PRIMARY_REGION}" >&2
  ok "platform-global applied"
else
  warn "STEP 4 — platform-global SKIPPED (ENABLE_GLOBAL_ENDPOINT=false)"
fi

# ---- STEP 5: application (both regions) -----------------------------------
info "STEP 5 — application apply (deployer, ${PRIMARY_REGION} + ${SECONDARY_REGION})"
terraform -chdir="$APPLICATION_DIR" init -input=false -reconfigure -backend-config="$BACKEND_HCL" >&2
terraform -chdir="$APPLICATION_DIR" apply -auto-approve -input=false \
  -var "primary_region=${PRIMARY_REGION}" \
  -var "secondary_region=${SECONDARY_REGION}" \
  -var "deployer_profile=${DEPLOYER_PROFILE}" \
  -var "name_prefix=${NAME_PREFIX}" \
  -var "state_bucket=${STATE_BUCKET}" >&2
ok "application applied"

echo "======================================================================"
echo " PRODUCTION LAB IS UP  (${PRIMARY_REGION} primary, ${SECONDARY_REGION} secondary)"
echo "======================================================================"
terraform -chdir="$PLATFORM_PRIMARY_DIR" output >&2
terraform -chdir="$PLATFORM_SECONDARY_DIR" output >&2
[[ "$ENABLE_GLOBAL_ENDPOINT" == "true" ]] && terraform -chdir="$PLATFORM_GLOBAL_DIR" output >&2
terraform -chdir="$APPLICATION_DIR" output >&2
ok "next: run  ./scripts/test-prod.sh  to exercise both regions"
