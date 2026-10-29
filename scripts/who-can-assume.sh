#!/usr/bin/env bash
###############################################################################
# who-can-assume.sh — READ-ONLY. Enumerate which principals a role's trust
# policy permits to assume it, and whether each is actually wired end-to-end.
#
# AssumeRole is a TWO-SIDED check:
#   (1) the role's trust policy must name the principal (this script), AND
#   (2) the principal's own identity policy must allow sts:AssumeRole.
# This script reports (1) fully and probes (2) for IAM users in THIS account.
#
# Usage:
#   scripts/who-can-assume.sh <role-name> [--profile <p>] [--region <r>]
#
# Makes ONLY iam:GetRole / iam:GetUser / iam:SimulatePrincipalPolicy calls.
# Never creates, modifies, assumes, or deletes anything.
###############################################################################
set -Eeuo pipefail

ROLE="${1:-}"
PROFILE="${AWS_PROFILE:-default}"
REGION="${AWS_REGION:-us-east-1}"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ROLE" ]]; then
  echo "usage: $0 <role-name> [--profile <p>] [--region <r>]" >&2
  exit 2
fi

export AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" AWS_PAGER=""

# --- log to stderr so stdout stays clean data ------------------------------
info() { echo "$@" >&2; }

ACCT=$(aws sts get-caller-identity --query Account --output text)
info "Account: $ACCT   Profile: $PROFILE   Role: $ROLE"
info "========================================================================"

# --- 1. fetch the trust policy --------------------------------------------
TRUST=$(aws iam get-role --role-name "$ROLE" \
          --query 'Role.AssumeRolePolicyDocument' --output json)

info ">> Trust policy principals that MAY assume '$ROLE':"
info ""

# Walk each Allow statement that includes sts:AssumeRole* and print its
# principals + any conditions. Pure jq, no mutation.
echo "$TRUST" | jq -r '
  .Statement[]
  | select(
      (.Effect=="Allow") and
      ( (.Action // empty) as $a
        | ($a|type=="string" and ($a|test("sts:AssumeRole";"i")))
          or ($a|type=="array" and (any(.[]; test("sts:AssumeRole";"i")))) )
    )
  | . as $s
  | ( $s.Principal // {} ) as $p
  | [
      "  AWS:       " + ((($p.AWS      // []) | if type=="string" then . else join(", ") end) // "-"),
      "  Service:   " + ((($p.Service  // []) | if type=="string" then . else join(", ") end) // "-"),
      "  Federated: " + ((($p.Federated// []) | if type=="string" then . else join(", ") end) // "-"),
      "  Condition: " + (($s.Condition // {}) | tojson)
    ] | .[]
'

# --- 2. resolve wildcard/root principals ----------------------------------
ROOT_TRUST=$(echo "$TRUST" | jq -r '
  [ .Statement[]
    | select(.Effect=="Allow")
    | (.Principal.AWS // empty)
    | if type=="array" then .[] else . end
  ] | map(select(test(":root$") or .=="*")) | length')

info ""
if [[ "$ROOT_TRUST" -gt 0 ]]; then
  info ">> Trust includes account-root (or *). ANY principal in the account that"
  info "   ALSO has sts:AssumeRole in its identity policy can assume this role."
  info "   Enumerating same-account IAM users and probing their permission:"
  info ""
  for U in $(aws iam list-users --query 'Users[].UserName' --output text); do
    UARN="arn:aws:iam::${ACCT}:user/${U}"
    DECISION=$(aws iam simulate-principal-policy \
        --policy-source-arn "$UARN" \
        --action-names "sts:AssumeRole" \
        --resource-arns "arn:aws:iam::${ACCT}:role/${ROLE}" \
        --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null || echo "unknown")
    printf '  %-30s sts:AssumeRole -> %s\n' "$U" "$DECISION"
  done
else
  info ">> Trust names SPECIFIC principals only (no root/*). Only the AWS/Federated"
  info "   principals listed above can assume it — a different user is NOT allowed"
  info "   unless its exact ARN appears in the trust policy."
fi

info ""
info "Done (read-only)."
