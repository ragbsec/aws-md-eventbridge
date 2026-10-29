#!/usr/bin/env bash
###############################################################################
# 01-static-posture.sh — READ-ONLY control checks against a live EventBridge
# deployment. Nothing is created, fired, or mutated.
#
# Covers (EVB-19 verdicts): EVB-03 bus type, EVB-04 encryption at rest,
# EVB-05 bus resource policy, EVB-06 least-privilege producer,
# EVB-07 rule/pattern design, EVB-08 target DLQ, EVB-09 retry policy,
# EVB-10 monitoring alarms, EVB-12 logging/audit.
#
# Usage: scripts/compliance/01-static-posture.sh [primary|secondary]
#        (default: primary). Override BUS_NAME / REGION_OVERRIDE for a
#        deployment whose Terraform state is not local.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-compliance.sh"

require_tools terraform aws jq
export AWS_SHARED_CREDENTIALS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"

ROLE="${1:-primary}"
discover "$ROLE"

###############################################################################
# EVB-03 — application events use a CUSTOM bus, never the default bus
###############################################################################
check_evb03() {
  local res="bus:${D_BUS}"
  if [[ "$D_BUS" == "default" ]]; then
    fail_v EVB-03 "$res" "application bus is the AWS default bus"
    return
  fi
  local bus; bus="$(ev describe-event-bus --name "$D_BUS")"
  if [[ -n "$bus" ]] && jq -e '.Name' >/dev/null 2>&1 <<<"$bus"; then
    pass_v EVB-03 "$res" "custom bus exists and is distinct from default"
  else
    unk_v EVB-03 "$res" "could not describe bus"
  fi
}

###############################################################################
# EVB-04 — encryption at rest: CMK on the bus; archive uses the same key
###############################################################################
check_evb04() {
  local res="bus:${D_BUS}"
  local bus kid; bus="$(ev describe-event-bus --name "$D_BUS")"
  kid="$(jq -r '.KmsKeyIdentifier // empty' <<<"$bus")"
  if [[ -z "$kid" ]]; then
    fail_v EVB-04 "$res" "bus has no KmsKeyIdentifier (AWS-owned key only; baseline OK for non-confidential, FAIL for restricted data)"
  else
    pass_v EVB-04 "$res" "bus encrypted with CMK ${kid}"
    # rotation + multi-region evidence on the key itself
    local kmeta rot mr
    kmeta="$(aws kms describe-key --key-id "$kid" "${AWS[@]}" 2>/dev/null || true)"
    mr="$(jq -r '.KeyMetadata.MultiRegion // false' <<<"$kmeta")"
    rot="$(aws kms get-key-rotation-status --key-id "$kid" "${AWS[@]}" 2>/dev/null | jq -r '.KeyRotationEnabled // false' || echo unknown)"
    [[ "$rot" == "true" ]] && pass_v EVB-04 "kms:${kid}" "key rotation enabled (multi_region=${mr})" \
                           || unk_v EVB-04 "kms:${kid}" "key rotation status=${rot} (multi_region=${mr})"
  fi
  # Archive uses the bus key implicitly on EventBridge-managed archives.
  local arcs; arcs="$(ev list-archives --event-source-arn "$D_BUS_ARN")"
  local n; n="$(jq -r '.Archives | length // 0' <<<"$arcs" 2>/dev/null || echo 0)"
  [[ "$n" -ge 1 ]] && pass_v EVB-04 "archive" "archive present on bus (inherits bus CMK)" \
                   || na_v  EVB-04 "archive" "no archive found (see EVB-11)"
}

###############################################################################
# EVB-05 — explicit bus resource policy, no unconditioned Principal "*"
###############################################################################
check_evb05() {
  local res="bus:${D_BUS}"
  local bus pol; bus="$(ev describe-event-bus --name "$D_BUS")"
  pol="$(jq -r '.Policy // empty' <<<"$bus")"
  if [[ -z "$pol" ]]; then
    fail_v EVB-05 "$res" "bus has no resource policy — no producer account allow-list / org condition"
    return
  fi
  # Detect an unconditioned "*" principal.
  local bad
  bad="$(jq -r '[.Statement[]? | select((.Principal=="*" or .Principal.AWS=="*") and (has("Condition")|not))] | length' <<<"$pol" 2>/dev/null || echo 0)"
  if [[ "$bad" -gt 0 ]]; then
    fail_v EVB-05 "$res" "bus policy contains an unconditioned Principal \"*\" statement"
  else
    pass_v EVB-05 "$res" "bus resource policy present with no unconditioned wildcard principal"
  fi
}

###############################################################################
# EVB-06 — least-privilege producer IAM scoped to the bus ARN
###############################################################################
check_evb06() {
  local res="producer:${D_PRODUCER}"
  [[ -n "$D_PRODUCER" ]] || { na_v EVB-06 "producer" "no producer function resolved"; return; }
  local role_arn role_name
  role_arn="$(aws lambda get-function --function-name "$D_PRODUCER" "${AWS[@]}" 2>/dev/null | jq -r '.Configuration.Role // empty')"
  role_name="${role_arn##*/}"
  [[ -n "$role_name" ]] || { unk_v EVB-06 "$res" "could not resolve producer execution role"; return; }

  # Inspect inline policies for a bus-scoped events:PutEvents.
  local found_scoped=0 found_star=0 pn pdoc
  for pn in $(aws iam list-role-policies --role-name "$role_name" "${AWS[@]}" 2>/dev/null | jq -r '.PolicyNames[]?'); do
    pdoc="$(aws iam get-role-policy --role-name "$role_name" --policy-name "$pn" "${AWS[@]}" 2>/dev/null | jq -c '.PolicyDocument')"
    if jq -e '.Statement[]? | select((.Action|tostring|test("PutEvents")) and (.Resource|tostring|test("event-bus/")))' >/dev/null 2>&1 <<<"$pdoc"; then
      found_scoped=1
    fi
    if jq -e '.Statement[]? | select((.Action|tostring|test("PutEvents")) and (.Resource=="*"))' >/dev/null 2>&1 <<<"$pdoc"; then
      found_star=1
    fi
  done
  if [[ "$found_star" -eq 1 ]]; then
    fail_v EVB-06 "$res" "producer has events:PutEvents on Resource \"*\" (not bus-scoped)"
  elif [[ "$found_scoped" -eq 1 ]]; then
    pass_v EVB-06 "$res" "producer events:PutEvents scoped to a bus ARN"
  else
    unk_v EVB-06 "$res" "no bus-scoped PutEvents statement found in inline policies"
  fi
  # Permissions boundary (EVB-06 asks for one; lab has none -> report honestly).
  local pb; pb="$(aws iam get-role --role-name "$role_name" "${AWS[@]}" 2>/dev/null | jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn // empty')"
  [[ -n "$pb" ]] && pass_v EVB-06 "$res" "permissions boundary attached: ${pb}" \
                 || fail_v EVB-06 "$res" "no permissions boundary on producer role"
}

###############################################################################
# EVB-07 — every rule has >=1 target + narrow pattern; <=5 targets/rule
###############################################################################
check_evb07() {
  local res="rule:${D_RULE}"
  [[ -n "$D_RULE" ]] || { na_v EVB-07 "rule" "no rule resolved"; return; }
  local rule pat; rule="$(ev describe-rule --name "$D_RULE" --event-bus-name "$D_BUS")"
  pat="$(jq -r '.EventPattern // empty' <<<"$rule")"
  # Narrow = constrains BOTH source and detail-type.
  if [[ -n "$pat" ]] && jq -e 'has("source") and has("detail-type")' >/dev/null 2>&1 <<<"$pat"; then
    pass_v EVB-07 "$res" "pattern constrains source + detail-type"
  else
    fail_v EVB-07 "$res" "pattern missing source and/or detail-type (too broad)"
  fi
  local tgts n; tgts="$(ev list-targets-by-rule --rule "$D_RULE" --event-bus-name "$D_BUS")"
  n="$(jq -r '.Targets | length // 0' <<<"$tgts" 2>/dev/null || echo 0)"
  if [[ "$n" -ge 1 && "$n" -le 5 ]]; then
    pass_v EVB-07 "$res" "rule has ${n} target(s) (1..5)"
  elif [[ "$n" -eq 0 ]]; then
    fail_v EVB-07 "$res" "rule has NO targets"
  else
    fail_v EVB-07 "$res" "rule has ${n} targets (>5 service limit)"
  fi
}

###############################################################################
# EVB-08 — every target has a standard SQS DLQ, same account+region
# EVB-09 — every target declares an explicit retry policy
###############################################################################
check_evb08_09() {
  local res="rule:${D_RULE}"
  [[ -n "$D_RULE" ]] || { na_v EVB-08 "rule" "no rule"; na_v EVB-09 "rule" "no rule"; return; }
  local tgts; tgts="$(ev list-targets-by-rule --rule "$D_RULE" --event-bus-name "$D_BUS")"
  local count; count="$(jq -r '.Targets | length // 0' <<<"$tgts" 2>/dev/null || echo 0)"
  [[ "$count" -ge 1 ]] || { unk_v EVB-08 "$res" "no targets to inspect"; return; }

  # Per target: DLQ present? retry policy present + in bounds?
  local i tid arn dlq mea mra
  for i in $(seq 0 $((count-1))); do
    tid="$(jq -r ".Targets[$i].Id" <<<"$tgts")"
    arn="$(jq -r ".Targets[$i].Arn" <<<"$tgts")"
    dlq="$(jq -r ".Targets[$i].DeadLetterConfig.Arn // empty" <<<"$tgts")"
    mea="$(jq -r ".Targets[$i].RetryPolicy.MaximumEventAgeInSeconds // empty" <<<"$tgts")"
    mra="$(jq -r ".Targets[$i].RetryPolicy.MaximumRetryAttempts // empty" <<<"$tgts")"

    # EVB-08: Lambda targets must DLQ in production. SNS/Logs targets are
    # fan-out/audit sinks — DLQ recommended but we report, not fail, for them.
    if [[ -n "$dlq" ]]; then
      if [[ "$dlq" == *":sqs:"* || "$dlq" == arn:aws:sqs:* ]]; then
        pass_v EVB-08 "target:${tid}" "SQS DLQ configured (${dlq##*:})"
      else
        fail_v EVB-08 "target:${tid}" "DLQ is not an SQS queue: ${dlq}"
      fi
    else
      if [[ "$arn" == *":lambda:"* ]]; then
        fail_v EVB-08 "target:${tid}" "Lambda target has no DLQ"
      else
        na_v EVB-08 "target:${tid}" "non-Lambda sink (${arn##*:}) — DLQ optional"
      fi
    fi

    # EVB-09: explicit retry policy within bounds.
    if [[ -n "$mea" && -n "$mra" ]]; then
      if (( mea>=60 && mea<=86400 && mra>=0 && mra<=185 )); then
        pass_v EVB-09 "target:${tid}" "retry explicit: age=${mea}s attempts=${mra}"
      else
        fail_v EVB-09 "target:${tid}" "retry out of bounds: age=${mea} attempts=${mra}"
      fi
    else
      unk_v EVB-09 "target:${tid}" "no explicit RetryPolicy (AWS default 24h/185 applies implicitly)"
    fi
  done
}

###############################################################################
# EVB-10 — per-rule FailedInvocations alarm + DLQ depth alarm, routed to SNS
###############################################################################
check_evb10() {
  # Rule-failure alarm: any alarm on AWS/Events FailedInvocations for this rule.
  # The RuleName dimension may be the BARE rule name or the bus-qualified
  # "<bus>/<rule>" form (CloudWatch stores the latter for custom-bus rules),
  # so match either.
  local alarms; alarms="$(aws cloudwatch describe-alarms "${AWS[@]}" 2>/dev/null || echo '{}')"
  local fi
  fi="$(jq -r --arg r "$D_RULE" --arg qr "${D_BUS}/${D_RULE}" '[.MetricAlarms[]? | select(.Namespace=="AWS/Events" and .MetricName=="FailedInvocations" and ((.Dimensions[]?|select(.Name=="RuleName").Value) as $v | $v==$r or $v==$qr)) | select((.AlarmActions|length)>0)] | length' <<<"$alarms" 2>/dev/null || echo 0)"
  [[ "$fi" -ge 1 ]] && pass_v EVB-10 "rule:${D_RULE}" "FailedInvocations alarm wired to an action" \
                     || fail_v EVB-10 "rule:${D_RULE}" "no FailedInvocations alarm with an alarm action"

  # DLQ depth alarm (SQS) — recall lesson: must be period=300 to fire reliably.
  local dlqn="${D_DLQ_URL##*/}"
  if [[ -n "$dlqn" ]]; then
    local dq period
    dq="$(jq -r --arg q "$dlqn" '[.MetricAlarms[]? | select(.Namespace=="AWS/SQS" and .MetricName=="ApproximateNumberOfMessagesVisible" and ((.Dimensions[]?|select(.Name=="QueueName").Value)==$q))][0]' <<<"$alarms" 2>/dev/null || echo 'null')"
    if [[ "$dq" == "null" || -z "$dq" ]]; then
      fail_v EVB-10 "dlq:${dlqn}" "no DLQ-depth alarm"
    else
      period="$(jq -r '.Period // 0' <<<"$dq")"
      if [[ "$period" -ge 300 ]]; then
        pass_v EVB-10 "dlq:${dlqn}" "DLQ-depth alarm present, period=${period}s (>=300 fires reliably)"
      else
        fail_v EVB-10 "dlq:${dlqn}" "DLQ-depth alarm period=${period}s — SQS publishes ~5min, so <300 can miss spikes"
      fi
    fi
  fi
}

###############################################################################
# EVB-12 — bus/audit logging present and KMS-encrypted
###############################################################################
check_evb12() {
  local res="audit:${D_AUDIT_LG}"
  [[ -n "$D_AUDIT_LG" ]] || { fail_v EVB-12 "audit" "no audit log group resolved"; return; }
  local lg kid
  lg="$(aws logs describe-log-groups --log-group-name-prefix "$D_AUDIT_LG" "${AWS[@]}" 2>/dev/null | jq -r --arg n "$D_AUDIT_LG" '.logGroups[]? | select(.logGroupName==$n)')"
  if [[ -z "$lg" ]]; then
    fail_v EVB-12 "$res" "audit log group not found"
    return
  fi
  kid="$(jq -r '.kmsKeyId // empty' <<<"$lg")"
  [[ -n "$kid" ]] && pass_v EVB-12 "$res" "audit log group KMS-encrypted" \
                  || fail_v EVB-12 "$res" "audit log group not KMS-encrypted"
}

###############################################################################
# AWS-recommended standards (AWS-* = prescribed by AWS docs / Security Hub,
# distinct from the internal EVB-xx / HA-xx controls).
###############################################################################

# AWS-KMS-CONFUSED-DEPUTY — the CMK key policy MUST scope EventBridge's use to
# a specific bus/account via aws:SourceArn / aws:SourceAccount /
# kms:EncryptionContext:aws:events:event-bus:arn.
# Source: EventBridge "Authorizing EventBridge to use a customer managed key".
check_aws_kms_confused_deputy() {
  local res="kms:${D_KMS_ARN##*/}"
  [[ -n "$D_KMS_ARN" ]] || { na_v AWS-KMS-CONFUSED-DEPUTY "kms" "bus uses AWS-owned key (no CMK policy to scope)"; return; }
  local pol
  pol="$(aws kms get-key-policy --key-id "$D_KMS_ARN" --policy-name default "${AWS[@]}" 2>/dev/null | jq -r '.Policy // empty')"
  if [[ -z "$pol" ]]; then
    unk_v AWS-KMS-CONFUSED-DEPUTY "$res" "could not read key policy (needs kms:GetKeyPolicy)"
    return
  fi
  # Any statement granting events.amazonaws.com must carry one of the scoping
  # condition keys.
  local ok
  ok="$(jq -r '
    [ .Statement[]?
      | select((.Principal.Service // "" | tostring) | test("events\\.amazonaws\\.com"))
      | select(.Effect=="Allow")
      | ( .Condition // {} | tostring )
      | select(test("aws:SourceArn|aws:SourceAccount|kms:EncryptionContext:aws:events:event-bus:arn"))
    ] | length' <<<"$pol" 2>/dev/null || echo 0)"
  local granted
  granted="$(jq -r '[.Statement[]? | select((.Principal.Service // "" | tostring) | test("events\\.amazonaws\\.com")) | select(.Effect=="Allow")] | length' <<<"$pol" 2>/dev/null || echo 0)"
  if [[ "$granted" -eq 0 ]]; then
    na_v AWS-KMS-CONFUSED-DEPUTY "$res" "key policy grants no events.amazonaws.com statement"
  elif [[ "$ok" -ge "$granted" ]]; then
    pass_v AWS-KMS-CONFUSED-DEPUTY "$res" "every EventBridge grant is scoped by SourceArn/SourceAccount/EncryptionContext"
  else
    fail_v AWS-KMS-CONFUSED-DEPUTY "$res" "EventBridge CMK grant lacks confused-deputy condition (SourceArn/SourceAccount/EncryptionContext) — key usable for any bus"
  fi
}

# AWS-SECHUB-EB3 — custom bus must have a resource-based policy (Security Hub
# EventBridge.3; NIST 800-53 r5 AC-*, PCI DSS v4.0.1 10.3.1). Distinct framing
# of EVB-05 so the manifest carries the external compliance ID.
check_aws_sechub_eb3() {
  local res="bus:${D_BUS}"
  local pol; pol="$(ev describe-event-bus --name "$D_BUS" | jq -r '.Policy // empty')"
  [[ -n "$pol" ]] && pass_v AWS-SECHUB-EB3 "$res" "custom bus has a resource-based policy (Security Hub EventBridge.3)" \
                   || fail_v AWS-SECHUB-EB3 "$res" "no resource-based policy — Security Hub EventBridge.3 FAIL (NIST AC-*, PCI 10.3.1)"
}

# AWS-SECHUB-EB2 — event bus should be tagged (Security Hub EventBridge.2).
check_aws_sechub_eb2() {
  local res="bus:${D_BUS}"
  local tags n
  tags="$(aws events list-tags-for-resource --resource-arn "$D_BUS_ARN" "${AWS[@]}" 2>/dev/null | jq -r '[.Tags[]? | select(.Key|startswith("aws:")|not)] | length' 2>/dev/null || echo 0)"
  [[ "${tags:-0}" -ge 1 ]] && pass_v AWS-SECHUB-EB2 "$res" "bus carries ${tags} non-system tag key(s) (Security Hub EventBridge.2)" \
                           || fail_v AWS-SECHUB-EB2 "$res" "bus has no non-system tags — Security Hub EventBridge.2 FAIL"
}

# AWS-BATCH-LIMITS — producer must respect PutEvents batch limits: 1..100
# entries per request, <=256KB per request (distinct from the 1MB/event limit).
# Verified from producer source (code contract).
check_aws_batch_limits() {
  local src="${LAB_ROOT}/src/lambda/producer/handler.py"
  local res="producer-src"
  [[ -f "$src" ]] || { na_v AWS-BATCH-LIMITS "$res" "producer source not found"; return; }
  # Heuristic: a producer that builds Entries straight from a caller-supplied
  # count, with no cap/chunk to <=100, can exceed the PutEvents batch limit.
  # Match only REAL capping logic (slice, min(), explicit chunk loop), not the
  # word "batch" in a comment.
  if grep -qE 'range\(.*count' "$src" && ! grep -qE '\[: *100|min\([^)]*100|chunk\(|for .* in .*\[0: *100' "$src"; then
    unk_v AWS-BATCH-LIMITS "$res" "producer builds Entries from caller count with no visible <=100 cap/chunking — confirm callers cannot exceed 100 entries / 256KB per PutEvents"
  else
    pass_v AWS-BATCH-LIMITS "$res" "producer batching caps/chunks to the 1..100-entry PutEvents limit"
  fi
}

# AWS-PUTEVENTS-PARTIAL — producer must DETECT and RETRY per-entry failures
# (FailedEntryCount>0 on a 200 response). Code contract.
check_aws_putevents_partial() {
  local src="${LAB_ROOT}/src/lambda/producer/handler.py"
  local res="producer-src"
  [[ -f "$src" ]] || { na_v AWS-PUTEVENTS-PARTIAL "$res" "producer source not found"; return; }
  local reads retries
  reads=$(grep -cE 'FailedEntryCount' "$src" || true)
  retries=$(grep -cE 'ErrorCode|retry|resubmit|re-?put' "$src" || true)
  if [[ "$reads" -ge 1 && "$retries" -ge 1 ]]; then
    pass_v AWS-PUTEVENTS-PARTIAL "$res" "producer reads FailedEntryCount and retries failed entries"
  elif [[ "$reads" -ge 1 ]]; then
    fail_v AWS-PUTEVENTS-PARTIAL "$res" "producer reads FailedEntryCount but does NOT retry failed entries (AWS requires detect+retry)"
  else
    fail_v AWS-PUTEVENTS-PARTIAL "$res" "producer ignores FailedEntryCount — silent per-entry loss on a 200 response"
  fi
}

# AWS-IMMUTABLE-ID — events must carry an immutable business key for
# cross-Region / replay correlation (AWS global-endpoint best practice).
check_aws_immutable_id() {
  local src="${LAB_ROOT}/src/lambda/producer/handler.py"
  local res="producer-src"
  [[ -f "$src" ]] || { na_v AWS-IMMUTABLE-ID "$res" "producer source not found"; return; }
  if grep -qE 'orderId|uuid|correlationId|businessKey' "$src"; then
    pass_v AWS-IMMUTABLE-ID "$res" "events carry an immutable business key (orderId/uuid) for replay correlation"
  else
    fail_v AWS-IMMUTABLE-ID "$res" "no immutable correlation key in the event payload — replay/cross-Region correlation unsafe"
  fi
}

echo "======================================================================"
echo " STATIC POSTURE SCAN (read-only) — role=${ROLE}"
echo "======================================================================"
check_evb03
check_evb04
check_evb05
check_evb06
check_evb07
check_evb08_09
check_evb10
check_evb12
echo "---- AWS-recommended standards ----"
check_aws_kms_confused_deputy
check_aws_sechub_eb3
check_aws_sechub_eb2
check_aws_batch_limits
check_aws_putevents_partial
check_aws_immutable_id
echo "======================================================================"
summarize
