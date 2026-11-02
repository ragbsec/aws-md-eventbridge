#!/usr/bin/env bash
###############################################################################
# restore-runtime.sh — rebuild the gitignored local state a NEW session needs to
# test or destroy an EXISTING deployment (cloud containers are ephemeral, so the
# session that ran create*.sh may be gone).
#
# create*.sh mirrors the bootstrap state to
#   s3://<STATE_BUCKET_NAME>/eventbridge-lab/bootstrap/terraform.tfstate
# This script pulls it back and re-renders, exactly as create*.sh did:
#   bootstrap/terraform.tfstate
#   .runtime/deployer.aws-credentials   (from bootstrap outputs, mode 600)
#   .runtime/backend.hcl                (prod or lab format)
#
# Usage: STATE_BUCKET_NAME=<bucket> scripts/cloud/restore-runtime.sh [prod|lab]
#        (default: prod — the platform-*/application stack)
###############################################################################
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

STACK="${1:-prod}"
[[ "$STACK" == prod || "$STACK" == lab ]] || die "usage: $0 [prod|lab]"
: "${STATE_BUCKET_NAME:?set STATE_BUCKET_NAME to the bucket create*.sh used}"
PRIMARY_REGION="${PRIMARY_REGION:-${REGION}}"

require_tools terraform aws jq
assert_profile "$OPERATOR_PROFILE"

STATE_FILE="${BOOTSTRAP_DIR}/terraform.tfstate"
if [[ -f "$STATE_FILE" ]] && [[ "$(jq '.resources | length' "$STATE_FILE")" -gt 0 ]]; then
  die "bootstrap/terraform.tfstate already tracks resources — refusing to overwrite it"
fi

info "pulling bootstrap state from s3://${STATE_BUCKET_NAME}/eventbridge-lab/bootstrap/"
aws s3 cp "s3://${STATE_BUCKET_NAME}/eventbridge-lab/bootstrap/terraform.tfstate" "$STATE_FILE" \
  --profile "$OPERATOR_PROFILE" --region "$PRIMARY_REGION" >&2
[[ "$(jq '.resources | length' "$STATE_FILE")" -gt 0 ]] || die "restored bootstrap state is empty — nothing to restore"

terraform -chdir="$BOOTSTRAP_DIR" init -input=false >&2
STATE_BUCKET="$(tf_output "$BOOTSTRAP_DIR" state_bucket_name)"
AK_ID="$(tf_output "$BOOTSTRAP_DIR" deployer_access_key_id)"
AK_SECRET="$(tf_output "$BOOTSTRAP_DIR" deployer_secret_access_key)"

umask 077
cat > "${RUNTIME_DIR}/deployer.aws-credentials" <<EOF
[${DEPLOYER_PROFILE}]
aws_access_key_id = ${AK_ID}
aws_secret_access_key = ${AK_SECRET}
region = ${PRIMARY_REGION}
EOF

if [[ "$STACK" == prod ]]; then
  cat > "${RUNTIME_DIR}/backend.hcl" <<EOF
bucket       = "${STATE_BUCKET}"
region       = "${PRIMARY_REGION}"
profile      = "${DEPLOYER_PROFILE}"
use_lockfile = true
encrypt      = true
EOF
else
  cat > "${RUNTIME_DIR}/backend.hcl" <<EOF
bucket       = "${STATE_BUCKET}"
key          = "eventbridge-lab/app/terraform.tfstate"
region       = "${PRIMARY_REGION}"
profile      = "${DEPLOYER_PROFILE}"
use_lockfile = true
encrypt      = true
EOF
fi

AWS_SHARED_CREDENTIALS_FILE="${RUNTIME_DIR}/deployer.aws-credentials" assert_profile "$DEPLOYER_PROFILE"
ok "restored ${STACK} runtime: bootstrap state, deployer profile '${DEPLOYER_PROFILE}', backend.hcl (bucket ${STATE_BUCKET})"
ok "you can now run scripts/test-prod.sh / destroy-prod.sh (or test.sh / destroy.sh for lab)"
