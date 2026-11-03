#!/usr/bin/env bash
###############################################################################
# ssm-run.sh — run a shell command on the MQ host through SSM Run Command.
#
# Waits for completion and prints ONLY the command's stdout (to stdout) and
# stderr (to stderr). Exit code = the remote command's exit code (1 when SSM
# itself failed/timed out). The instance has no SSH; this is the only path.
#
# Usage:  mq-integration/scripts/ssm-run.sh <instance-id> '<command>'
# Env:    SSM_TIMEOUT  seconds to wait for the command (default 120)
#         OPERATOR_PROFILE, REGION
# Note:   the command text is stored in SSM command history: never put
#         passwords or other secrets in it.
# Safety class: read-only toward AWS control plane, but EXECUTES the given
#         command on the host (can mutate MQ state) — caller's responsibility.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

[[ $# -eq 2 ]] || die "usage: ssm-run.sh <instance-id> '<command>'"
IID="$1"; CMD="$2"
[[ "$IID" =~ ^i-[0-9a-f]+$ ]] || die "not an instance id: ${IID}"
require_tools aws jq
TIMEOUT="${SSM_TIMEOUT:-120}"

PARAMS="$(jq -cn --arg c "$CMD" --arg t "$TIMEOUT" '{commands:[$c], executionTimeout:[$t]}')"
CID="$(aws_op ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
        --comment "eb-mq ssm-run" --timeout-seconds 30 --parameters "$PARAMS" \
        --query 'Command.CommandId' --output text)" || die "ssm send-command failed"

deadline=$(( $(date +%s) + TIMEOUT + 30 ))
inv=""
while :; do
  sleep 2
  if inv="$(aws_op ssm get-command-invocation --command-id "$CID" --instance-id "$IID" --output json 2>/dev/null)"; then
    status="$(jq -r .Status <<<"$inv")"
    case "$status" in Pending|InProgress|Delayed) ;; *) break ;; esac
  fi
  if [[ $(date +%s) -ge $deadline ]]; then err "timed out waiting for SSM command ${CID}"; exit 1; fi
done

jq -j '.StandardOutputContent' <<<"$inv"
jq -j '.StandardErrorContent' <<<"$inv" >&2
if [[ "$status" == "Success" ]]; then exit 0; fi
rc="$(jq -r '.ResponseCode' <<<"$inv")"
err "remote command ${status} (exit ${rc})"
[[ "$rc" =~ ^[0-9]+$ && "$rc" -gt 0 ]] && exit "$rc"
exit 1
