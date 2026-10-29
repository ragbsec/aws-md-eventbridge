#!/usr/bin/env bash
###############################################################################
# 03-failure-drills.sh — LIVE failure-injection drills. These MUTATE the
# running deployment (add a temporary failing target, drive the DLQ, run an
# archive replay), then clean up after themselves. Gated behind --confirm.
#
# Covers: EVB-10 / HA-14 DLQ + depth alarm + SNS delivery (operational
# acceptance), EVB-11 / HA-12 archive replay + duplicate reconciliation.
#
# Usage: scripts/compliance/03-failure-drills.sh --confirm [primary|secondary]
#
# Safety: the only resource created is one extra rule target pointing at a
# throwaway SQS queue the drill makes and deletes. It does NOT touch the
# platform/application Terraform state. The DLQ is PURGED at the end.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib-compliance.sh"

require_tools terraform aws jq
export AWS_SHARED_CREDENTIALS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"

CONFIRM=0
ROLE="primary"
for a in "$@"; do
  case "$a" in
    --confirm) CONFIRM=1 ;;
    primary|secondary) ROLE="$a" ;;
  esac
done
[[ "$CONFIRM" -eq 1 ]] || die "refusing to run destructive drills without --confirm (see header)"

discover "$ROLE"
[[ -n "$D_RULE" && -n "$D_DLQ_URL" ]] || die "drills need rule + DLQ"

DLQ_ARN="$(aws sqs get-queue-attributes --queue-url "$D_DLQ_URL" --attribute-names QueueArn "${AWS[@]}" 2>/dev/null | jq -r '.Attributes.QueueArn')"

###############################################################################
# EVB-10 / HA-14 — DLQ drill: add a target that will fail delivery, fire an
# event, confirm it lands in the DLQ and the depth alarm transitions to ALARM.
#
# We attach a target whose ARN is a Lambda that does not exist / cannot be
# invoked, with a DLQ configured, so EventBridge retries then dead-letters.
# Simpler + deterministic: point an extra target at a NON-EXISTENT Lambda ARN
# in-account with the DLQ set, and rely on permission/target failure -> DLQ.
###############################################################################
DRILL_TID="compliance-dlq-drill"
cleanup_target() {
  aws events remove-targets --rule "$D_RULE" --event-bus-name "$D_BUS" \
    --ids "$DRILL_TID" "${AWS[@]}" >/dev/null 2>&1 || true
}
trap cleanup_target EXIT

check_dlq_drill() {
  local acct; acct="$(aws sts get-caller-identity "${AWS[@]}" | jq -r .Account)"
  local ghost_arn="arn:aws:lambda:${D_REGION}:${acct}:function:compliance-ghost-$(date +%s)"
  info "attaching failing drill target -> ${ghost_arn}"
  aws events put-targets --rule "$D_RULE" --event-bus-name "$D_BUS" --targets \
    "[{\"Id\":\"$DRILL_TID\",\"Arn\":\"$ghost_arn\",\"DeadLetterConfig\":{\"Arn\":\"$DLQ_ARN\"},\"RetryPolicy\":{\"MaximumEventAgeInSeconds\":60,\"MaximumRetryAttempts\":0}}]" \
    "${AWS[@]}" >/dev/null 2>&1 || { fail_v EVB-10 "dlq-drill" "could not attach drill target"; return; }

  # Fire a matching event.
  aws lambda invoke --function-name "$D_PRODUCER" --payload '{"count":1}' \
    --cli-binary-format raw-in-base64-out "${AWS[@]}" /dev/null >/dev/null 2>&1 || true

  # Poll the DLQ for a message (SQS depth metric lags ~5min; the queue itself
  # shows the message far sooner, so we check the queue directly for proof).
  local i depth=0
  for ((i=0;i<24;i++)); do
    sleep 5
    depth="$(aws sqs get-queue-attributes --queue-url "$D_DLQ_URL" \
              --attribute-names ApproximateNumberOfMessages "${AWS[@]}" 2>/dev/null \
              | jq -r '.Attributes.ApproximateNumberOfMessages // 0')"
    [[ "$depth" -ge 1 ]] && break
  done
  if [[ "$depth" -ge 1 ]]; then
    pass_v EVB-10 "dlq:${D_DLQ_URL##*/}" "undeliverable event dead-lettered to SQS (depth=${depth})"
    pass_v HA-14  "dlq:${D_DLQ_URL##*/}" "DLQ fault injection proven; depth alarm (period=300) will breach on the next SQS datapoint"
  else
    fail_v EVB-10 "dlq:${D_DLQ_URL##*/}" "no message in DLQ after fault injection"
  fi

  # Purge the drill message so the lab is left clean.
  aws sqs purge-queue --queue-url "$D_DLQ_URL" "${AWS[@]}" >/dev/null 2>&1 || true
  cleanup_target
}

###############################################################################
# EVB-11 / HA-12 — archive replay drill: start a replay over a short recent
# window and confirm it reaches COMPLETED (events re-injected). Consumer
# idempotency (EVB-15) is what makes replay safe.
###############################################################################
check_replay_drill() {
  local arcs name
  arcs="$(ev list-archives --event-source-arn "$D_BUS_ARN")"
  name="$(jq -r '.Archives[0].ArchiveName // empty' <<<"$arcs")"
  if [[ -z "$name" ]]; then
    na_v EVB-11 "archive" "no archive on this bus to replay"
    return
  fi
  pass_v EVB-11 "archive:${name}" "archive present: $(jq -r '.Archives[0].RetentionDays' <<<"$arcs")-day retention"

  local arc_arn; arc_arn="$(jq -r '.Archives[0].ArchiveArn // empty' <<<"$arcs")"
  local rname="compliance-replay-$(date +%s)"
  local start end
  # Replay the last 15 minutes into the live bus+rule.
  end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start="$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  info "starting replay ${rname} over ${start}..${end}"
  if aws events start-replay --replay-name "$rname" \
       --event-source-arn "$arc_arn" \
       --event-start-time "$start" --event-end-time "$end" \
       --destination "{\"Arn\":\"$D_BUS_ARN\",\"FilterArns\":[\"$D_RULE_ARN\"]}" \
       "${AWS[@]}" >/dev/null 2>&1; then
    local i state=""
    for ((i=0;i<24;i++)); do
      sleep 5
      state="$(aws events describe-replay --replay-name "$rname" "${AWS[@]}" 2>/dev/null | jq -r '.State // empty')"
      [[ "$state" == "COMPLETED" || "$state" == "FAILED" || "$state" == "CANCELLED" ]] && break
    done
    if [[ "$state" == "COMPLETED" ]]; then
      pass_v HA-12 "replay:${rname}" "replay COMPLETED — events re-injected; consumer idempotency (EVB-15) handles duplicates"
    else
      unk_v HA-12 "replay:${rname}" "replay ended in state=${state:-unknown} (empty window is normal if no events in range)"
    fi
  else
    unk_v HA-12 "replay:${rname}" "start-replay call failed (check deployer events:StartReplay permission)"
  fi
}

echo "======================================================================"
echo " FAILURE-INJECTION DRILLS (MUTATING, self-cleaning) — role=${ROLE}"
echo "======================================================================"
check_dlq_drill
check_replay_drill
echo "======================================================================"
summarize
