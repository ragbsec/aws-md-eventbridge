#!/usr/bin/env bash
###############################################################################
# leftover-check.sh — READ-ONLY proof that mq-integration left nothing behind.
#
# Sweeps us-east-1 (REGION) with the OPERATOR profile for: EC2 instances tagged
# Component=mq-integration (not terminated), security groups, IAM roles /
# instance profiles named eb-mq*, SQS eb-mq-outbound*, EventBridge rule
# mq-outbound-rule on the bus, S3 buckets with the bundle prefix, the Secrets
# Manager secret eb-mq/credentials, and eb-mq* log groups.
#
# Exit codes: 0 = proven clean, 1 = leftovers found, 2 = INCOMPLETE (an AWS call
# failed, e.g. AccessDenied, so cleanliness could not be proven - never treated as clean).
#
# A secret in its scheduled-deletion window (DeletedDate set) is INFO only.
#
# Usage:  mq-integration/scripts/leftover-check.sh
# Env:    OPERATOR_PROFILE, REGION, BUS_NAME, MQ_BUCKET_PREFIX (default eb-mq-bundle-)
# Safety class: read-only
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_tools aws jq
assert_profile "$OPERATOR_PROFILE"
PFX="${MQ_BUCKET_PREFIX:-eb-mq-bundle-}"   # matches Terraform bucket_prefix; narrow on purpose
FOUND=0
A=(--profile "$OPERATOR_PROFILE" --region "$REGION")

# Fail CLOSED: every AWS read goes through awsq. If a call fails (AccessDenied,
# throttling, wrong profile...) we record it and print nothing for that check, and
# the script finishes as INCOMPLETE (exit 2) instead of reporting "clean".
# (A flag FILE is used because $(...) runs in a subshell: variables would be lost.)
ERRDIR="$(mktemp -d)"; trap 'rm -rf "$ERRDIR"' EXIT
awsq() {
  local out rc=0
  out="$("$@" 2>"$ERRDIR/stderr")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    : > "$ERRDIR/failed"
    err "AWS call failed (rc=${rc}): ${*:1:3}: $(head -c 240 "$ERRDIR/stderr" | tr '\n' ' ')"
    return 0
  fi
  printf '%s\n' "$out"
}

report() {
  local label="$1"; shift
  local v; v="$(printf '%s\n' "$@" | sed '/^$/d;/^None$/d')"
  if [[ -n "$v" ]]; then
    FOUND=1; err "leftover ${label}:"
    while IFS= read -r line; do printf '         %s\n' "$line" >&2; done <<<"$v"
  fi
}

info "checking ${REGION} for mq-integration resources"
report "EC2 instances" "$(awsq aws ec2 describe-instances "${A[@]}" \
  --filters "Name=tag:Component,Values=mq-integration" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text | tr '\t' ' ')"
report "security groups" "$(awsq aws ec2 describe-security-groups "${A[@]}" \
  --filters "Name=tag:Component,Values=mq-integration" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text | tr '\t' ' ')"
report "security groups (by name)" "$(awsq aws ec2 describe-security-groups "${A[@]}" \
  --filters "Name=group-name,Values=eb-mq*" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text | tr '\t' ' ')"
report "IAM roles" "$(awsq aws iam list-roles "${A[@]}" --query 'Roles[?starts_with(RoleName,`eb-mq`)].RoleName' --output text | tr '\t' '\n')"
report "IAM instance profiles" "$(awsq aws iam list-instance-profiles "${A[@]}" --query 'InstanceProfiles[?starts_with(InstanceProfileName,`eb-mq`)].InstanceProfileName' --output text | tr '\t' '\n')"
report "IAM policies" "$(awsq aws iam list-policies --scope Local "${A[@]}" --query 'Policies[?starts_with(PolicyName,`eb-mq`)].PolicyName' --output text | tr '\t' '\n')"
report "SQS queues" "$(awsq aws sqs list-queues "${A[@]}" --queue-name-prefix eb-mq-outbound --query 'QueueUrls' --output text | tr '\t' '\n')"
BUS_OUT="$(aws events describe-event-bus "${A[@]}" --name "$BUS_NAME" 2>&1)" && BUS_RC=0 || BUS_RC=$?
if [[ "$BUS_RC" -eq 0 ]]; then
  report "EventBridge rule mq-outbound-rule on ${BUS_NAME}" "$(awsq aws events list-rules "${A[@]}" --event-bus-name "$BUS_NAME" \
    --name-prefix mq-outbound-rule --query 'Rules[].Name' --output text | tr '\t' '\n')"
elif grep -q 'ResourceNotFoundException' <<<"$BUS_OUT"; then
  info "event bus ${BUS_NAME} absent (main lab destroyed) - rule check not applicable"
else
  : > "$ERRDIR/failed"
  err "could not describe event bus ${BUS_NAME}: $(head -c 240 <<<"$BUS_OUT" | tr '\n' ' ')"
fi
report "S3 buckets" "$(awsq aws s3api list-buckets "${A[@]}" --query "Buckets[?starts_with(Name,\`${PFX}\`)].Name" --output text | tr '\t' '\n')"
report "log groups" "$(awsq aws logs describe-log-groups "${A[@]}" --query 'logGroups[?contains(logGroupName,`eb-mq`)].logGroupName' --output text | tr '\t' '\n')"

# Secret: scheduled deletion is expected (recovery window) -> INFO only.
SECRET_OUT="$(aws secretsmanager describe-secret "${A[@]}" --secret-id "$MQ_SECRET_NAME" --output json 2>&1)" && SECRET_RC=0 || SECRET_RC=$?
if [[ "$SECRET_RC" -eq 0 ]]; then
  if [[ "$(jq -r '.DeletedDate // empty' <<<"$SECRET_OUT")" != "" ]]; then
    info "secret ${MQ_SECRET_NAME} is scheduled for deletion (recovery window; expected)"
  else
    report "Secrets Manager secret" "$MQ_SECRET_NAME"
  fi
elif grep -q 'ResourceNotFoundException' <<<"$SECRET_OUT"; then
  :   # absent: good
else
  : > "$ERRDIR/failed"
  err "could not describe secret ${MQ_SECRET_NAME}: $(head -c 240 <<<"$SECRET_OUT" | tr '\n' ' ')"
fi

if [[ -e "$ERRDIR/failed" ]]; then
  err "INCOMPLETE - one or more AWS calls failed (see above); cleanliness NOT proven"
  [[ "$FOUND" -eq 0 ]] || err "(leftovers were also found)"
  exit 2
fi
if [[ "$FOUND" -eq 0 ]]; then
  ok "no mq-integration resources remain in ${REGION}"
else
  err "leftovers found - the account is NOT clean (see above)"
  exit 1
fi
