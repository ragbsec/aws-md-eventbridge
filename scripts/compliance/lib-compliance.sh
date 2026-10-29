#!/usr/bin/env bash
###############################################################################
# lib-compliance.sh — shared assertion + discovery layer for the EventBridge
# control test suite (EVB-xx / HA-xx).
#
# Sourced by the per-family check scripts. No executable bit needed.
#
# Design goals:
#   * Portable across ANY EventBridge deployment: all target coordinates are
#     DISCOVERED from Terraform outputs (or env overrides), never hard-coded.
#   * Emits the EVB-19 evidence model verdicts: PASS / FAIL / UNKNOWN /
#     NOT_APPLICABLE, one line per control, with a human reason.
#   * Diagnostic chatter -> STDERR; machine-readable verdict lines -> STDOUT,
#     so an aggregator can capture results cleanly (matches repo convention).
###############################################################################
set -Eeuo pipefail

# Reuse the repo's base helpers (paths, logging, require_tools, tf_output).
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

APPLICATION_DIR="${LAB_ROOT}/application"
PLATFORM_DIR="${LAB_ROOT}/platform"

# Where verdict JSONL is written (one object per control per resource).
EVIDENCE_DIR="${EVIDENCE_DIR:-${RUNTIME_DIR}/compliance}"
mkdir -p "${EVIDENCE_DIR}"

# ---- verdict emission ------------------------------------------------------
# A verdict is: CONTROL  STATUS  RESOURCE  REASON
# STATUS in {PASS, FAIL, UNKNOWN, NOT_APPLICABLE}.
# Written to STDOUT (tab-separated) AND appended as JSONL to the evidence file.
: "${_EVIDENCE_FILE:=${EVIDENCE_DIR}/verdicts.jsonl}"

_json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

verdict() {
  local control="$1" status="$2" resource="$3" reason="$4"
  printf "%s\t%s\t%s\t%s\n" "$control" "$status" "$resource" "$reason"
  printf '{"control":%s,"status":%s,"resource":%s,"reason":%s,"ts":%s}\n' \
    "$(_json_escape "$control")" "$(_json_escape "$status")" \
    "$(_json_escape "$resource")" "$(_json_escape "$reason")" \
    "$(_json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" >> "$_EVIDENCE_FILE"
}

pass_v() { verdict "$1" PASS           "$2" "$3"; }
fail_v() { verdict "$1" FAIL           "$2" "$3"; }
unk_v()  { verdict "$1" UNKNOWN        "$2" "$3"; }
na_v()   { verdict "$1" NOT_APPLICABLE "$2" "$3"; }

# ---- discovery -------------------------------------------------------------
# Resolve the deployment coordinates for a region ROLE (primary|secondary).
# Prefers Terraform outputs; each may be overridden by env for a fresh cluster
# where Terraform state is not local (e.g. BUS_NAME=..., REGION=...).
#
# Populates these globals for the given role:
#   D_REGION D_BUS D_BUS_ARN D_RULE D_RULE_ARN D_AUDIT_LG D_AUDIT_ARN
#   D_ALERTS_TOPIC D_KMS_ARN D_PRODUCER D_CONSUMER D_CONSUMER_LG D_DLQ_URL
#   D_SNS_TOPIC
discover() {
  local role="$1"
  local pj aj
  pj="$(terraform -chdir="$PLATFORM_DIR" output -json "$role" 2>/dev/null || echo '{}')"
  aj="$(terraform -chdir="$APPLICATION_DIR" output -json "$role" 2>/dev/null || echo '{}')"

  D_REGION="${REGION_OVERRIDE:-$(jq -r '.region // empty' <<<"$pj")}"
  D_BUS="${BUS_NAME:-$(jq -r '.bus_name // empty' <<<"$pj")}"
  D_BUS_ARN="$(jq -r '.bus_arn // empty' <<<"$pj")"
  D_RULE="$(jq -r '.rule_name // empty' <<<"$pj")"
  D_RULE_ARN="$(jq -r '.rule_arn // empty' <<<"$pj")"
  D_AUDIT_LG="$(jq -r '.audit_log // empty' <<<"$pj")"
  D_AUDIT_ARN="$(jq -r '.audit_log_arn // empty' <<<"$pj")"
  D_ALERTS_TOPIC="$(jq -r '.alerts_topic // empty' <<<"$pj")"
  D_KMS_ARN="$(jq -r '.kms_key_arn // empty' <<<"$pj")"

  D_PRODUCER="$(jq -r '.producer // empty' <<<"$aj")"
  D_CONSUMER="$(jq -r '.consumer // empty' <<<"$aj")"
  D_CONSUMER_LG="$(jq -r '.consumer_logs // empty' <<<"$aj")"
  D_DLQ_URL="$(jq -r '.dlq_url // empty' <<<"$aj")"
  D_SNS_TOPIC="$(jq -r '.sns_topic // empty' <<<"$aj")"

  [[ -n "$D_REGION" && -n "$D_BUS" ]] || die "discover($role): could not resolve region/bus from Terraform outputs or env. Set BUS_NAME and REGION_OVERRIDE for a non-TF deployment."
  AWS=(--profile "${DEPLOYER_PROFILE}" --region "${D_REGION}" --output json)
  info "discover($role): region=${D_REGION} bus=${D_BUS}"
}

# Convenience: run a describe and return JSON, or empty on error.
ev() { aws events "$@" "${AWS[@]}" 2>/dev/null || true; }

# ---- summary ---------------------------------------------------------------
summarize() {
  local f="$_EVIDENCE_FILE"
  [[ -f "$f" ]] || { warn "no verdicts recorded"; return 0; }
  local p u k n a
  p=$(grep -c '"status": *"PASS"' "$f" 2>/dev/null || echo 0)
  a=$(grep -c '"status": *"FAIL"' "$f" 2>/dev/null || echo 0)
  u=$(grep -c '"status": *"UNKNOWN"' "$f" 2>/dev/null || echo 0)
  n=$(grep -c '"status": *"NOT_APPLICABLE"' "$f" 2>/dev/null || echo 0)
  info "evidence written to: $f"
  printf "SUMMARY  PASS=%s FAIL=%s UNKNOWN=%s NOT_APPLICABLE=%s\n" "$p" "$a" "$u" "$n"
  [[ "$a" -eq 0 ]]
}
