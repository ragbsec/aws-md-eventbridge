#!/usr/bin/env bash
###############################################################################
# destroy.sh — tear the whole lab down cleanly, in reverse dependency order.
#
# Sequence:
#   1. APP destroy (DEPLOYER profile) — removes EventBridge, Lambdas, SQS, SNS,
#      logs, schedules, archives, and every app-owned IAM role.
#   2. BOOTSTRAP destroy (OPERATOR profile) — removes the deployer user, lock
#      table, and (if we created it) the state bucket. The bucket is emptied of
#      all object versions first so `force_destroy` succeeds cleanly.
#
# State mapping guarantees a clean destroy:
#   - app state lives in S3 (bucket + lock table from bootstrap),
#   - bootstrap state lives locally AND mirrored in S3,
#   so ordering app-before-bootstrap never orphans a resource.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform aws jq
assert_profile "$OPERATOR_PROFILE"

DEPLOYER_CREDS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"
BACKEND_HCL="${RUNTIME_DIR}/backend.hcl"

###############################################################################
info "STEP 1 — destroy app layer (deployer profile: ${DEPLOYER_PROFILE})"
###############################################################################
if [[ -f "$DEPLOYER_CREDS_FILE" && -f "$BACKEND_HCL" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"

  if aws sts get-caller-identity --profile "$DEPLOYER_PROFILE" --region "$REGION" >/dev/null 2>&1; then
    terraform -chdir="$APP_DIR" init -input=false -reconfigure \
      -backend-config="$BACKEND_HCL" >&2 || warn "app init failed; continuing"
    terraform -chdir="$APP_DIR" destroy -auto-approve -input=false \
      -var "region=${REGION}" \
      -var "deployer_profile=${DEPLOYER_PROFILE}" >&2
    ok "app layer destroyed"
  else
    warn "deployer profile not usable; skipping app destroy (already gone?)"
  fi
  # Clear the SDK override before touching bootstrap (operator profile).
  unset AWS_SHARED_CREDENTIALS_FILE
else
  warn "no deployer creds/backend in .runtime; app may already be destroyed"
fi

###############################################################################
info "STEP 2 — destroy bootstrap layer (operator profile: ${OPERATOR_PROFILE})"
###############################################################################
terraform -chdir="$BOOTSTRAP_DIR" init -input=false >&2

# If we own the state bucket, empty ALL object versions first so force_destroy
# on a versioned bucket cannot fail.
STATE_BUCKET="$(tf_output "$BOOTSTRAP_DIR" state_bucket_name 2>/dev/null || echo "")"
CREATED="$(tf_output "$BOOTSTRAP_DIR" state_bucket_created 2>/dev/null || echo "false")"

if [[ -n "$STATE_BUCKET" && "$CREATED" == "true" ]]; then
  info "emptying versioned state bucket s3://${STATE_BUCKET} before destroy"
  # Delete all versions and delete-markers.
  aws s3api list-object-versions --bucket "$STATE_BUCKET" \
    --profile "$OPERATOR_PROFILE" --region "$REGION" \
    --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    > "${RUNTIME_DIR}/versions.json" 2>/dev/null || echo '{"Objects":null}' > "${RUNTIME_DIR}/versions.json"

  if [[ "$(jq '.Objects | length // 0' "${RUNTIME_DIR}/versions.json")" -gt 0 ]]; then
    aws s3api delete-objects --bucket "$STATE_BUCKET" \
      --delete "file://${RUNTIME_DIR}/versions.json" \
      --profile "$OPERATOR_PROFILE" --region "$REGION" >&2 || true
  fi

  aws s3api list-object-versions --bucket "$STATE_BUCKET" \
    --profile "$OPERATOR_PROFILE" --region "$REGION" \
    --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    > "${RUNTIME_DIR}/markers.json" 2>/dev/null || echo '{"Objects":null}' > "${RUNTIME_DIR}/markers.json"

  if [[ "$(jq '.Objects | length // 0' "${RUNTIME_DIR}/markers.json")" -gt 0 ]]; then
    aws s3api delete-objects --bucket "$STATE_BUCKET" \
      --delete "file://${RUNTIME_DIR}/markers.json" \
      --profile "$OPERATOR_PROFILE" --region "$REGION" >&2 || true
  fi
fi

terraform -chdir="$BOOTSTRAP_DIR" destroy -auto-approve -input=false \
  -var "region=${REGION}" \
  -var "operator_profile=${OPERATOR_PROFILE}" \
  -var "state_bucket_name=${STATE_BUCKET_NAME:-}" >&2

ok "bootstrap layer destroyed"

# Scrub local secrets.
rm -f "$DEPLOYER_CREDS_FILE" "$BACKEND_HCL" \
      "${RUNTIME_DIR}/versions.json" "${RUNTIME_DIR}/markers.json" \
      "${RUNTIME_DIR}/app.plan" 2>/dev/null || true
ok "local runtime secrets scrubbed"

echo "======================================================================"
ok "LAB FULLY DESTROYED — account is clean"
echo "======================================================================"
