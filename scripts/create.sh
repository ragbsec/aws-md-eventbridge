#!/usr/bin/env bash
###############################################################################
# create.sh — stand the whole lab up from scratch.
#
# Sequence (each step verified before the next):
#   0. Static verify (fmt/validate/tflint) both layers.
#   1. BOOTSTRAP (run by the OPERATOR profile = cloud_user):
#        - S3 state bucket (create new, or reuse STATE_BUCKET_NAME if set)
#          with S3-native state locking (use_lockfile; no DynamoDB needed)
#        - dedicated deployer IAM user + access key
#      Mirror bootstrap state into S3 for durability.
#   2. Write the deployer's credentials to a NAMED AWS profile in .runtime/
#      and render the app backend config from the bootstrap outputs.
#   3. APP (run by the DEPLOYER profile — never cloud_user):
#        - init against the S3 backend, apply the EventBridge stack.
#
# Idempotent: re-running applies only diffs.
#
# Env overrides: OPERATOR_PROFILE, REGION, STATE_BUCKET_NAME (reuse existing).
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform aws jq
assert_profile "$OPERATOR_PROFILE"

STATE_BUCKET_NAME="${STATE_BUCKET_NAME:-}"

###############################################################################
info "STEP 0 — static verification"
###############################################################################
bash "${LAB_ROOT}/scripts/verify.sh"

###############################################################################
info "STEP 1 — bootstrap (operator profile: ${OPERATOR_PROFILE})"
###############################################################################
terraform -chdir="$BOOTSTRAP_DIR" init -input=false >&2
terraform -chdir="$BOOTSTRAP_DIR" apply -auto-approve -input=false \
  -var "region=${REGION}" \
  -var "operator_profile=${OPERATOR_PROFILE}" \
  -var "state_bucket_name=${STATE_BUCKET_NAME}" >&2

STATE_BUCKET="$(tf_output "$BOOTSTRAP_DIR" state_bucket_name)"
DEPLOYER_USER="$(tf_output "$BOOTSTRAP_DIR" deployer_user_name)"
AK_ID="$(tf_output "$BOOTSTRAP_DIR" deployer_access_key_id)"
AK_SECRET="$(tf_output "$BOOTSTRAP_DIR" deployer_secret_access_key)"
ok "bootstrap done — state bucket: ${STATE_BUCKET}, deployer: ${DEPLOYER_USER}"

# Mirror the bootstrap layer's own local state into S3 for durability/rebuild.
info "mirroring bootstrap state into s3://${STATE_BUCKET}/eventbridge-lab/bootstrap/"
aws s3 cp "${BOOTSTRAP_DIR}/terraform.tfstate" \
  "s3://${STATE_BUCKET}/eventbridge-lab/bootstrap/terraform.tfstate" \
  --profile "$OPERATOR_PROFILE" --region "$REGION" >&2

###############################################################################
info "STEP 2 — write deployer profile + render app backend config"
###############################################################################
# Store the deployer credentials in an ISOLATED, gitignored credentials file so
# we never touch the user's real ~/.aws and never print the secret.
DEPLOYER_CREDS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"
umask 077
cat > "$DEPLOYER_CREDS_FILE" <<EOF
[${DEPLOYER_PROFILE}]
aws_access_key_id = ${AK_ID}
aws_secret_access_key = ${AK_SECRET}
region = ${REGION}
EOF
ok "deployer credentials written to ${DEPLOYER_CREDS_FILE} (mode 600)"

# Point AWS SDK/CLI at this isolated credentials file for the deployer profile.
export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"

# IAM eventual consistency: a brand-new access key can take a few seconds.
info "waiting for deployer credentials to become active..."
for _ in $(seq 1 30); do
  if aws sts get-caller-identity --profile "$DEPLOYER_PROFILE" --region "$REGION" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
assert_profile "$DEPLOYER_PROFILE"
ok "deployer profile '${DEPLOYER_PROFILE}' is active"

# Render the partial S3 backend config from bootstrap outputs.
# The `profile` is what lets Terraform's S3 BACKEND authenticate as the deployer
# (the AWS provider block reads it too, but the backend needs it explicitly).
BACKEND_HCL="${RUNTIME_DIR}/backend.hcl"
cat > "$BACKEND_HCL" <<EOF
bucket       = "${STATE_BUCKET}"
key          = "eventbridge-lab/app/terraform.tfstate"
region       = "${REGION}"
profile      = "${DEPLOYER_PROFILE}"
use_lockfile = true
encrypt      = true
EOF
ok "app backend config rendered to ${BACKEND_HCL}"

###############################################################################
info "STEP 3 — app apply (deployer profile: ${DEPLOYER_PROFILE})"
###############################################################################
terraform -chdir="$APP_DIR" init -input=false -reconfigure \
  -backend-config="$BACKEND_HCL" >&2

# Plan first (verification artifact), then apply.
terraform -chdir="$APP_DIR" plan -input=false \
  -var "region=${REGION}" \
  -var "deployer_profile=${DEPLOYER_PROFILE}" \
  -out="${RUNTIME_DIR}/app.plan" >&2

terraform -chdir="$APP_DIR" apply -input=false -auto-approve \
  "${RUNTIME_DIR}/app.plan" >&2

ok "app apply complete"
echo "======================================================================"
echo " LAB IS UP"
echo "======================================================================"
terraform -chdir="$APP_DIR" output >&2
echo
ok "next: run  ./scripts/test.sh  to exercise the event flow end to end"
