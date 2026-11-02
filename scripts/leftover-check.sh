#!/usr/bin/env bash
###############################################################################
# leftover-check.sh — READ-ONLY proof that a destroy left nothing behind.
#
# Lists lab-named resources in BOTH regions (plus account-global IAM/S3/
# dashboards) using the OPERATOR profile and exits 1 if any remain. Safe to run
# any time; it never changes anything.
#
# KMS keys cannot be deleted instantly (7-30 day wait). Keys in PendingDeletion
# or PendingReplicaDeletion are expected and only reported as INFO.
#
# Env: PRIMARY_REGION, SECONDARY_REGION, NAME_PREFIX (default eb-prod),
#      STATE_BUCKET_NAME (if set, the state bucket is user-owned and ignored)
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools aws jq
export AWS_PAGER=""
# A raw AWS_ACCESS_KEY_ID in the environment overrides --profile; drop it.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
NAME_PREFIX="${NAME_PREFIX:-eb-prod}"
assert_profile "$OPERATOR_PROFILE"

FOUND=0
A=(--profile "$OPERATOR_PROFILE")

# report LABEL VALUE... — VALUE lines that are non-empty count as leftovers.
report() {
  local label="$1"; shift
  local v; v="$(printf '%s\n' "$@" | sed '/^$/d;/^None$/d')"
  if [[ -n "$v" ]]; then
    FOUND=1; err "leftover ${label}:"
    while IFS= read -r line; do printf '         %s\n' "$line" >&2; done <<<"$v"
  fi
}

check_region() {
  local r="$1" R=(--region "$1")
  info "checking ${r} for '${NAME_PREFIX}*' resources"
  report "event buses (${r})"      "$(aws events list-event-buses "${A[@]}" "${R[@]}" --query 'EventBuses[?Name!=`default`].Name' --output text | tr '\t' '\n')"
  report "event archives (${r})"   "$(aws events list-archives "${A[@]}" "${R[@]}" --query "Archives[?contains(ArchiveName,\`${NAME_PREFIX}\`)].ArchiveName" --output text | tr '\t' '\n')"
  report "rules (${r})"            "$(aws events list-rules "${A[@]}" "${R[@]}" --query "Rules[?contains(Name,\`${NAME_PREFIX}\`)].Name" --output text | tr '\t' '\n')"
  report "KMS aliases (${r})"      "$(aws kms list-aliases "${A[@]}" "${R[@]}" --query "Aliases[?contains(AliasName,\`${NAME_PREFIX}\`)].AliasName" --output text | tr '\t' '\n')"
  local k meta st mgr desc pending=0 live=""
  for k in $(aws kms list-keys "${A[@]}" "${R[@]}" --query 'Keys[].KeyId' --output text); do
    meta="$(aws kms describe-key --key-id "$k" "${A[@]}" "${R[@]}" --output json 2>/dev/null)" || continue
    mgr="$(jq -r '.KeyMetadata.KeyManager' <<<"$meta")"
    [[ "$mgr" == "CUSTOMER" ]] || continue
    st="$(jq -r '.KeyMetadata.KeyState' <<<"$meta")"
    desc="$(jq -r '.KeyMetadata.Description // ""' <<<"$meta")"
    case "$st" in
      PendingDeletion|PendingReplicaDeletion) pending=$((pending+1));;
      *) if [[ "$desc" == *"$NAME_PREFIX"* ]]; then live+="${k} (${st})"$'\n'; fi;;
    esac
  done
  report "KMS keys (${r})" "$live"
  [[ "$pending" -gt 0 ]] && info "${r}: ${pending} KMS key(s) pending deletion (expected; AWS waits 7-30 days)"
  report "log delivery sources (${r})"      "$(aws logs describe-delivery-sources "${A[@]}" "${R[@]}" --query "deliverySources[?contains(name,\`${NAME_PREFIX}\`)].name" --output text | tr '\t' '\n')"
  report "log delivery destinations (${r})" "$(aws logs describe-delivery-destinations "${A[@]}" "${R[@]}" --query "deliveryDestinations[?contains(name,\`${NAME_PREFIX}\`)].name" --output text | tr '\t' '\n')"
  report "log groups (${r})"       "$(aws logs describe-log-groups "${A[@]}" "${R[@]}" --query "logGroups[?contains(logGroupName,\`${NAME_PREFIX}\`)].logGroupName" --output text | tr '\t' '\n')"
  report "SNS topics (${r})"       "$(aws sns list-topics "${A[@]}" "${R[@]}" --query "Topics[?contains(TopicArn,\`${NAME_PREFIX}\`)].TopicArn" --output text | tr '\t' '\n')"
  report "SQS queues (${r})"       "$(aws sqs list-queues "${A[@]}" "${R[@]}" --query "QueueUrls[?contains(@,\`${NAME_PREFIX}\`)]" --output text 2>/dev/null | tr '\t' '\n')"
  report "alarms (${r})"           "$(aws cloudwatch describe-alarms "${A[@]}" "${R[@]}" --query "MetricAlarms[?contains(AlarmName,\`${NAME_PREFIX}\`)].AlarmName" --output text | tr '\t' '\n')"
  report "Lambda functions (${r})" "$(aws lambda list-functions "${A[@]}" "${R[@]}" --query "Functions[?contains(FunctionName,\`${NAME_PREFIX}\`)].FunctionName" --output text | tr '\t' '\n')"
  report "schema registries (${r})" "$(aws schemas list-registries "${A[@]}" "${R[@]}" --query 'Registries[?!starts_with(RegistryName,`aws.`)].RegistryName' --output text | tr '\t' '\n')"
  report "schedules (${r})"        "$(aws scheduler list-schedules "${A[@]}" "${R[@]}" --query "Schedules[?contains(Name,\`${NAME_PREFIX}\`)].Name" --output text | tr '\t' '\n')"
  report "pipes (${r})"            "$(aws pipes list-pipes "${A[@]}" "${R[@]}" --query "Pipes[?contains(Name,\`${NAME_PREFIX}\`)].Name" --output text | tr '\t' '\n')"
}

check_region "$PRIMARY_REGION"
[[ "$SECONDARY_REGION" != "$PRIMARY_REGION" ]] && check_region "$SECONDARY_REGION"

info "checking account-global resources"
report "CloudWatch dashboards" "$(aws cloudwatch list-dashboards "${A[@]}" --region "$PRIMARY_REGION" --query "DashboardEntries[?contains(DashboardName,\`${NAME_PREFIX}\`)].DashboardName" --output text | tr '\t' '\n')"
report "IAM roles"  "$(aws iam list-roles "${A[@]}" --query "Roles[?contains(RoleName,\`${NAME_PREFIX}\`)||contains(RoleName,\`eventbridge-lab\`)].RoleName" --output text | tr '\t' '\n')"
report "IAM users"  "$(aws iam list-users "${A[@]}" --query 'Users[?contains(UserName,`eventbridge-lab`)].UserName' --output text | tr '\t' '\n')"
report "Route 53 health checks" "$(aws route53 list-health-checks "${A[@]}" --query "HealthChecks[?contains(HealthCheckConfig.FullyQualifiedDomainName||'',\`${NAME_PREFIX}\`)].Id" --output text 2>/dev/null | tr '\t' '\n')"
if [[ -z "${STATE_BUCKET_NAME:-}" ]]; then
  report "state buckets" "$(aws s3api list-buckets "${A[@]}" --query 'Buckets[?starts_with(Name,`eventbridge-lab-tfstate-`)].Name' --output text | tr '\t' '\n')"
fi

if [[ "$FOUND" -eq 0 ]]; then
  ok "no '${NAME_PREFIX}*' lab resources remain in ${PRIMARY_REGION} / ${SECONDARY_REGION}"
else
  err "leftovers found — the account is NOT clean (see above)"
  exit 1
fi
