#!/usr/bin/env bash
###############################################################################
# deploy.sh — stand up IBM MQ (Docker on EC2) + bridge next to the main lab.
#
# Order: guards -> verify.sh -> terraform init (S3 backend, key
# eventbridge-lab/mq-integration/terraform.tfstate) -> apply -> wait for the
# instance to be SSM-online and /opt/eb-mq/READY (up to ~15 min).
#
# Guards (all required):
#   --yes                         explicit approval flag
#   EXPECTED_AWS_ACCOUNT_ID       must equal the OPERATOR profile's account
#   main lab deployed             event bus ${BUS_NAME} must exist
#   instance limit                existing EC2 instances + 1 must be <= 9 (stopped count,
#                                 terminated do not); counted read-only, fails closed
#
# Usage:  EXPECTED_AWS_ACCOUNT_ID=123456789012 mq-integration/scripts/deploy.sh --yes
# Env:    OPERATOR_PROFILE (default: default), REGION (us-east-1),
#         BUS_NAME (eb-prod-orders), EVENT_SOURCE (prod.orders),
#         INSTANCE_TYPE (t2|t3|t3a micro|small|medium; t4g rejected: x86_64 stack),
#         VPC_ID, SUBNET_ID, MQ_IMAGE (optional overrides), MQ_MAX_INSTANCES (9),
#         READY_TIMEOUT seconds (default 900)
# Safety class: CREATES BILLABLE AWS RESOURCES (EC2, IAM, SQS, S3, Secrets
#         Manager, EventBridge rule). Tear down with destroy.sh.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

YES=0
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    *) die "unknown argument: $a (usage: deploy.sh --yes)" ;;
  esac
done
[[ "$YES" -eq 1 ]] || die "refusing to deploy without --yes (this creates billable AWS resources)"
[[ -n "${EXPECTED_AWS_ACCOUNT_ID:-}" ]] || die "set EXPECTED_AWS_ACCOUNT_ID to the account you intend to deploy into"

require_tools terraform aws jq

# ---- guard: account identity -------------------------------------------------
IDENT="$(aws_op sts get-caller-identity --output json 2>/dev/null)" \
  || die "operator profile '${OPERATOR_PROFILE}' has no valid credentials"
ACCOUNT="$(jq -r .Account <<<"$IDENT")"
info "operator identity: account ${ACCOUNT}, $(jq -r .Arn <<<"$IDENT")"
[[ "$ACCOUNT" == "$EXPECTED_AWS_ACCOUNT_ID" ]] \
  || die "account mismatch: credentials are for ${ACCOUNT}, EXPECTED_AWS_ACCOUNT_ID=${EXPECTED_AWS_ACCOUNT_ID}"

# ---- guard: main lab present -------------------------------------------------
aws_op events describe-event-bus --name "$BUS_NAME" >/dev/null 2>&1 \
  || die "event bus '${BUS_NAME}' not found in ${REGION}: deploy the main lab first (scripts/create-prod.sh)"
ok "main lab present (bus ${BUS_NAME})"

# ---- guard: account instance limit (max 9 concurrent; stopped count) ----------
mq_check_instance_quota
ok "instance limit respected"

warn "COST: this launches an EC2 instance (plus EBS, SQS, Secrets Manager) that bills until destroyed."
warn "      Destroy it with: mq-integration/scripts/destroy.sh --yes"

# ---- STEP 0: offline verification -------------------------------------------
info "STEP 0 — static verification"
bash "${MQ_SCRIPTS}/verify.sh"

# ---- STEP 1: init + apply ----------------------------------------------------
info "STEP 1 — terraform init (S3 backend, operator profile)"
mq_tf_init
mq_tf_vars
info "STEP 2 — terraform apply"
mq_tf_env
terraform -chdir="$MQ_TF_DIR" apply -auto-approve -input=false "${MQ_TF_VARS[@]}" >&2
ok "mq-integration applied"

INSTANCE_ID="$(tf_output "$MQ_TF_DIR" instance_id)"
QUEUE_URL="$(tf_output "$MQ_TF_DIR" outbound_queue_url)"
SSM_CMD="$(tf_output "$MQ_TF_DIR" ssm_session_command)"

# ---- STEP 3: wait for SSM + READY -------------------------------------------
info "STEP 3 — waiting for ${INSTANCE_ID} to be SSM-online and MQ READY (up to ${READY_TIMEOUT:-900}s)"
deadline=$(( $(date +%s) + ${READY_TIMEOUT:-900} ))
phase=ssm
while :; do
  now=$(date +%s)
  [[ $now -lt $deadline ]] || die "timed out waiting for ${phase}; inspect with: mq-integration/scripts/ssm-run.sh ${INSTANCE_ID} 'tail -n 50 /var/log/cloud-init-output.log'"
  if [[ "$phase" == "ssm" ]]; then
    ping="$(aws_op ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
    if [[ "$ping" == "Online" ]]; then ok "instance is SSM-online"; phase=ready; continue; fi
    info "waiting for SSM agent (status: ${ping:-none}) — $((deadline - now))s left"
  else
    out="$(SSM_TIMEOUT=30 bash "${MQ_SCRIPTS}/ssm-run.sh" "$INSTANCE_ID" 'test -f /opt/eb-mq/READY && echo READY || echo WAITING' 2>/dev/null || true)"
    if [[ "$out" == *READY* && "$out" != *WAITING* ]]; then ok "MQ is healthy (/opt/eb-mq/READY present)"; break; fi
    info "waiting for MQ to become healthy — $((deadline - now))s left"
  fi
  sleep 20
done

echo "======================================================================"
echo " MQ INTEGRATION IS UP"
echo "======================================================================"
echo " instance      : ${INSTANCE_ID}"
echo " SSM session   : ${SSM_CMD}"
echo " outbound queue: ${QUEUE_URL}"
echo " next          : mq-integration/scripts/test.sh"
echo " teardown      : mq-integration/scripts/destroy.sh --yes   (REQUIRED — the instance bills until then)"
