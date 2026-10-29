#!/usr/bin/env bash
###############################################################################
# run-compliance.sh — orchestrates the EventBridge control test suite and
# emits a single EVB-19 compliance manifest (PASS/FAIL/UNKNOWN/NOT_APPLICABLE
# per control, with evidence) as both a table and machine-readable JSON.
#
# Usage:
#   scripts/compliance/run-compliance.sh                 # static + functional, primary
#   scripts/compliance/run-compliance.sh --both-regions  # + secondary
#   scripts/compliance/run-compliance.sh --drills        # also run mutating drills
#   scripts/compliance/run-compliance.sh --static-only   # read-only, CI-safe
#
# CI contract: exits non-zero if any control is FAIL. UNKNOWN does not fail
# the build but is surfaced (missing evidence cannot PASS — EVB-19).
###############################################################################
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib-compliance.sh"

require_tools terraform aws jq

RUN_FUNCTIONAL=1
RUN_DRILLS=0
BOTH=0
for a in "$@"; do
  case "$a" in
    --static-only) RUN_FUNCTIONAL=0 ;;
    --drills)      RUN_DRILLS=1 ;;
    --both-regions) BOTH=1 ;;
  esac
done

ROLES=(primary)
[[ "$BOTH" -eq 1 ]] && ROLES=(primary secondary)

# Fresh evidence file for this run.
: > "$_EVIDENCE_FILE"

for role in "${ROLES[@]}"; do
  info ">>> role=${role}: static posture"
  "${HERE}/01-static-posture.sh" "$role" >/dev/null || true
  if [[ "$RUN_FUNCTIONAL" -eq 1 ]]; then
    info ">>> role=${role}: functional"
    "${HERE}/02-functional.sh" "$role" >/dev/null || true
  fi
  if [[ "$RUN_DRILLS" -eq 1 ]]; then
    info ">>> role=${role}: failure drills"
    "${HERE}/03-failure-drills.sh" --confirm "$role" >/dev/null || true
  fi
done

# AWS global-endpoint standards span both regions — run once, not per role.
info ">>> AWS multi-region / global-endpoint standards"
"${HERE}/04-aws-multiregion.sh" >/dev/null || true

###############################################################################
# Record the controls that are governance/process/design — NOT a runtime probe
# — so the manifest is COMPLETE. Each is NOT_APPLICABLE *to automated runtime
# testing* with the verification method named. These are verified by repo/plan
# inspection or evidence review, not by a command against the cluster.
###############################################################################
declare -A PROCESS=(
  [EVB-01]="supply-chain: verify module source/version pinning + committed .terraform.lock.hcl by repo/plan inspection"
  [EVB-02]="tagging policy: verify tags_all on bus/rules in the plan; targets/archives/schedules untaggable by design"
  [EVB-13]="cross-account routing: verify receiving-bus policy + bus-to-bus role by topology/evidence review (no 2nd account in lab)"
  [EVB-14]="features outside wrapper (Pipes/Scheduler/API-dest): confirmed disabled by wrapper-input/architecture review"
  [EVB-16]="regional resilience: signed HA-13 decision record; global endpoint config (disabled in this deploy)"
  [EVB-17]="change safety/drift: gated-change policy MSG-GOV-07 + scheduled drift/inventory (pipeline, not a probe)"
  [EVB-18]="capacity/cost: quota model + load test + per-GB cost comparison (evidence review)"
  [EVB-19]="evidence/exceptions: THIS manifest + exception register (<=90d, independently approved)"
  [EVB-20]="trusted CI/AI boundaries: protected pipeline, OIDC short-lived roles, reviewed plan digest (CI config review)"
  [EVB-21]="enhanced eventsv2 bus adoption gate: ARB pilot approval; not deployed in this stack"
  [EVB-22]="enhanced-bus subscriber design: applies only to an eventsv2 pilot (not deployed)"
  [EVB-23]="enhanced-bus sharing/retention/SCP: applies only to an eventsv2 pilot (not deployed)"
  [HA-03]="network/AZ path resilience: serverless EventBridge is regional-managed; evidence review of VPC-endpoint paths if producers are in-VPC"
  [HA-04]="downstream failover: dependency fault-domain map + failover drill (evidence review)"
  [HA-05]="failure-capacity: peak load with a fault domain down + scale-out delay (load test)"
  [HA-06]="operations detect/restore: synthetic failure + paging/ack/runbook timing (operational drill, see HA-14)"
  [HA-07]="Well-Architected traceability: control->question->best-practice mapping doc"
  [HA-08]="availability objective: numeric SLO + SLI definition + business sign-off"
  [HA-09]="recovery objectives: approved RTO/RPO per scenario (decision record)"
  [HA-10]="AZ-failure design: as-built topology + SPOF review (managed-service responsibility doc)"
  [HA-11]="failure capacity test: measured sustainable throughput under impairment (load test)"
  [HA-13]="regional-outage decision: single vs multi-Region justification (decision record)"
)
for c in "${!PROCESS[@]}"; do
  na_v "$c" "process" "${PROCESS[$c]}"
done

###############################################################################
# Render the manifest.
###############################################################################
MANIFEST_JSON="${EVIDENCE_DIR}/manifest.json"
MANIFEST_MD="${EVIDENCE_DIR}/manifest.md"

jq -s '
  group_by(.control)
  | map({
      control: .[0].control,
      # worst status wins: FAIL > UNKNOWN > PASS > NOT_APPLICABLE
      status: (
        if any(.status=="FAIL") then "FAIL"
        elif any(.status=="UNKNOWN") then "UNKNOWN"
        elif any(.status=="PASS") then "PASS"
        else "NOT_APPLICABLE" end),
      evidence: map({status,resource,reason})
    })
  | sort_by(.control)
' "$_EVIDENCE_FILE" > "$MANIFEST_JSON"

{
  echo "# EventBridge Compliance Manifest (EVB-19)"
  echo
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) · roles: ${ROLES[*]}"
  echo
  echo "| Control | Status | Evidence |"
  echo "|---------|--------|----------|"
  jq -r '.[] | "| \(.control) | \(.status) | \(.evidence | map(.resource + ": " + .reason) | join("; ")) |"' "$MANIFEST_JSON"
} > "$MANIFEST_MD"

echo "======================================================================"
echo " COMPLIANCE MANIFEST"
echo "======================================================================"
jq -r '.[] | "\(.control)\t\(.status)"' "$MANIFEST_JSON" | column -t
echo "----------------------------------------------------------------------"
echo "JSON:     $MANIFEST_JSON"
echo "Markdown: $MANIFEST_MD"

FAILS="$(jq -r '[.[] | select(.status=="FAIL")] | length' "$MANIFEST_JSON")"
UNK="$(jq -r '[.[] | select(.status=="UNKNOWN")] | length' "$MANIFEST_JSON")"
echo "FAIL=${FAILS} UNKNOWN=${UNK}"
[[ "$FAILS" -eq 0 ]] || { err "compliance gate: ${FAILS} control(s) FAILED"; exit 1; }
ok "compliance gate passed (no FAIL)"
