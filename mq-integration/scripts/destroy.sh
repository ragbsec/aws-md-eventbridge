#!/usr/bin/env bash
###############################################################################
# destroy.sh — tear down the mq-integration stack and PROVE nothing is left.
#
# terraform destroy (same S3 backend as deploy.sh), then leftover-check.sh.
# Never prints a success banner unless the leftover sweep is clean. The bundle
# bucket is emptied by Terraform (force_destroy). The main lab and the shared
# state bucket are NOT touched; destroy the main lab with scripts/destroy-prod.sh
# only AFTER this succeeds.
#
# Usage:  mq-integration/scripts/destroy.sh --yes
# Env:    OPERATOR_PROFILE, REGION, FORCE_UNLOCK=1 (clear one stale state lock)
# Safety class: DESTROYS AWS resources.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ "${1:-}" == "--yes" && $# -eq 1 ]] || die "refusing to destroy without --yes (usage: destroy.sh --yes)"
require_tools terraform aws jq
assert_profile "$OPERATOR_PROFILE"

IDENT="$(aws_op sts get-caller-identity --output json)"
info "operator identity: account $(jq -r .Account <<<"$IDENT"), $(jq -r .Arn <<<"$IDENT")"
if [[ -n "${EXPECTED_AWS_ACCOUNT_ID:-}" && "$(jq -r .Account <<<"$IDENT")" != "$EXPECTED_AWS_ACCOUNT_ID" ]]; then
  die "account mismatch against EXPECTED_AWS_ACCOUNT_ID"
fi

info "STEP 1 — terraform init"
mq_tf_init || die "init failed; cannot destroy blind"
mq_tf_vars
mq_tf_env

info "STEP 2 — terraform destroy"
DESTROY_FAILED=()
tf_destroy_layer mq-integration "$MQ_TF_DIR" "${MQ_TF_VARS[@]}" || true
if [[ "${#DESTROY_FAILED[@]}" -gt 0 ]]; then
  err "DESTROY INCOMPLETE — ${DESTROY_FAILED[*]}; fix the cause above and re-run (idempotent; FORCE_UNLOCK=1 for a stale lock)"
  exit 1
fi

info "STEP 3 — verifying nothing is left behind"
bash "${MQ_SCRIPTS}/leftover-check.sh" \
  || die "destroy finished but the sweep did NOT prove clean (leftovers listed above, or exit 2 = an AWS call failed so cleanliness is unproven) — fix and re-run leftover-check.sh before ending the session"

echo "======================================================================"
ok "MQ INTEGRATION FULLY DESTROYED (verified)"
echo "======================================================================"
