#!/usr/bin/env bash
# Shared helpers for the mq-integration scripts. Sourced, not executed.
# Builds on ../../scripts/lib.sh (logging, paths, profiles).
# Safety class: offline (defines functions only; calls nothing at source time
# except lib.sh's mkdir of .runtime / .tftmp).

set -Eeuo pipefail
# shellcheck source=../../scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib.sh"

MQ_ROOT="${LAB_ROOT}/mq-integration"
MQ_TF_DIR="${MQ_ROOT}/terraform"
MQ_SCRIPTS="${MQ_ROOT}/scripts"
MQ_STATE_KEY="eventbridge-lab/mq-integration/terraform.tfstate"
BACKEND_HCL="${RUNTIME_DIR}/backend.hcl"
DEPLOYER_CREDS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"

BUS_NAME="${BUS_NAME:-eb-prod-orders}"
EVENT_SOURCE="${EVENT_SOURCE:-prod.orders}"
MQ_SECRET_NAME="eb-mq/credentials"
export AWS_PAGER=""

# A raw key in the environment would override --profile; drop it.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# mq_global_endpoint_values — print "<endpoint-id> <secondary-bus-arn> <secondary-kms-arn>" read from the
# lab's platform-global / platform-secondary roots (deployer credentials; read-only).
mq_global_endpoint_values() {
  local id bus key
  id="$(  unset AWS_PROFILE; export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"; terraform -chdir="${LAB_ROOT}/platform-global"    output -raw global_endpoint_id 2>/dev/null)" || true
  bus="$( unset AWS_PROFILE; export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"; terraform -chdir="${LAB_ROOT}/platform-secondary" output -raw bus_arn 2>/dev/null)" || true
  key="$( unset AWS_PROFILE; export AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE"; terraform -chdir="${LAB_ROOT}/platform-secondary" output -raw kms_key_arn 2>/dev/null)" || true
  [[ -n "$id" && -n "$bus" && -n "$key" ]] || die "could not read the global endpoint id / secondary bus / key from the lab outputs: deploy the main lab with ENABLE_GLOBAL_ENDPOINT=true first"
  printf '%s %s %s\n' "$id" "$bus" "$key"
}

# Terraform -var flags: only pass optional overrides when the caller set them.
# GLOBAL_ENDPOINT=true makes the bridge publish THROUGH the global endpoint (EB_ENDPOINT_ID, SigV4a)
# and grants the instance role PutEvents/KMS on the failover region's bus and key.
mq_tf_vars() {
  MQ_TF_VARS=(-var "region=${REGION}" -var "bus_name=${BUS_NAME}" -var "event_source=${EVENT_SOURCE}")
  if [[ "${GLOBAL_ENDPOINT:-false}" == "true" ]]; then
    local gid gbus gkey
    read -r gid gbus gkey <<<"$(mq_global_endpoint_values)"
    MQ_TF_VARS+=(-var "eb_endpoint_id=${gid}" -var "failover_bus_arns=[\"${gbus}\"]" -var "failover_kms_key_arns=[\"${gkey}\"]")
    info "global endpoint ON: bridge publishes via endpoint ${gid}; failover bus/key granted"
  fi
  [[ -n "${INSTANCE_TYPE:-}" ]] && MQ_TF_VARS+=(-var "instance_type=${INSTANCE_TYPE}")
  [[ -n "${VPC_ID:-}"        ]] && MQ_TF_VARS+=(-var "vpc_id=${VPC_ID}")
  [[ -n "${SUBNET_ID:-}"     ]] && MQ_TF_VARS+=(-var "subnet_id=${SUBNET_ID}")
  [[ -n "${MQ_IMAGE:-}"      ]] && MQ_TF_VARS+=(-var "mq_image=${MQ_IMAGE}")
  return 0
}

# Read one key from .runtime/backend.hcl WITHOUT printing it.
backend_value() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\\(.*\\)\"[[:space:]]*$/\\1/p" "$BACKEND_HCL" | head -1
}

# Terraform runs with the OPERATOR profile (EC2 + instance profile need more
# than the deployer user may do). The shared backend.hcl names the deployer
# profile; the later -backend-config flag overrides it.
mq_tf_env() {
  unset AWS_SHARED_CREDENTIALS_FILE
  export AWS_PROFILE="$OPERATOR_PROFILE"
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
}

# mq_tf_init — init the S3 backend for the mq-integration root (idempotent).
mq_tf_init() {
  [[ -f "$BACKEND_HCL" ]] || die "missing ${BACKEND_HCL}; deploy the main lab first (scripts/create-prod.sh) or restore it (scripts/cloud/restore-runtime.sh)"
  local bucket bregion
  bucket="$(backend_value bucket)"; bregion="$(backend_value region)"
  [[ -n "$bucket" && -n "$bregion" ]] || die "backend.hcl has no bucket/region"
  mq_tf_env
  terraform -chdir="$MQ_TF_DIR" init -input=false -reconfigure \
    -backend-config="$BACKEND_HCL" \
    -backend-config="bucket=${bucket}" \
    -backend-config="region=${bregion}" \
    -backend-config="key=${MQ_STATE_KEY}" \
    -backend-config="profile=${OPERATOR_PROFILE}" >&2
}

# aws_dep ARGS... — run the aws CLI as the lab DEPLOYER (read logs etc.).
aws_dep() {
  AWS_SHARED_CREDENTIALS_FILE="$DEPLOYER_CREDS_FILE" aws --profile "$DEPLOYER_PROFILE" --region "$REGION" "$@"
}
# aws_op ARGS... — run the aws CLI as the OPERATOR.
aws_op() {
  aws --profile "$OPERATOR_PROFILE" --region "$REGION" "$@"
}

# mq_check_instance_quota — account policy: NO MORE THAN 9 CONCURRENT EC2 INSTANCES
# (stopped instances count, terminated ones do not). This deploy adds exactly one.
# Read-only. Fails CLOSED in the deploy region (cannot count -> do not deploy); other
# enabled regions are counted best-effort (a region you cannot query is reported, not
# silently ignored). Prints counts only. Override the limit with MQ_MAX_INSTANCES.
MQ_MAX_INSTANCES="${MQ_MAX_INSTANCES:-9}"
mq_check_instance_quota() {
  local regions r out total=0 unchecked=""
  regions="$(aws_op ec2 describe-regions --query 'Regions[].RegionName' --output text 2>&1)" \
    || die "cannot list regions ($(head -c 160 <<<"$regions")): the instance limit cannot be proven"
  [[ " ${regions//$'\t'/ } " == *" ${REGION} "* ]] || regions="${REGION} ${regions}"
  for r in ${regions}; do
    if out="$(aws --profile "$OPERATOR_PROFILE" --region "$r" ec2 describe-instances \
        --filters "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
        --query 'length(Reservations[].Instances[])' --output text 2>&1)" && [[ "$out" =~ ^[0-9]+$ ]]; then
      total=$(( total + out ))
      [[ "$out" -eq 0 ]] || info "  ${r}: ${out} instance(s)"
    elif [[ "$r" == "$REGION" ]]; then
      die "cannot count instances in ${REGION} ($(head -c 160 <<<"$out")): the instance limit cannot be proven"
    else
      unchecked+=" ${r}"
    fi
  done
  [[ -z "$unchecked" ]] || warn "could not count instances in:${unchecked} (not counted above)"
  info "existing EC2 instances (terminated excluded, stopped included): ${total}; limit ${MQ_MAX_INSTANCES}; this deploy adds 1"
  (( total + 1 <= MQ_MAX_INSTANCES )) \
    || die "instance limit: ${total} existing + 1 new exceeds ${MQ_MAX_INSTANCES}. Terminate unused instances first."
}
