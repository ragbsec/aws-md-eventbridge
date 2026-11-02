#!/usr/bin/env bash
###############################################################################
# preflight.sh — cloud-environment readiness check for the EventBridge lab.
#
# Read-only. Prints a PASS / WARN / FAIL matrix and a verdict:
#   READY (offline)  — tools + network OK: verify-prod.sh / contract tests can run
#   READY (deploy)   — also valid AWS identity in the expected account
#   NOT READY        — something blocking; the FAIL lines say what to fix
#
# Sections: runtime · tools · network · repository/release · AWS identity ·
#           deployment state.
#
# Env (all optional):
#   OPERATOR_PROFILE        operator profile name            (default: default)
#   REGION / PRIMARY_REGION primary region                   (default: us-east-1)
#   SECONDARY_REGION        secondary region                 (default: us-west-2)
#   EXPECTED_AWS_ACCOUNT_ID FAIL if credentials resolve to another account
#   STATE_BUCKET_NAME       existing state bucket to reuse / detect a deployment
#
# Usage: scripts/cloud/preflight.sh [--strict]   (--strict: exit 1 on any FAIL)
###############################################################################
set -Euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

STRICT=0; [[ "${1:-}" == "--strict" ]] && STRICT=1
PROFILE="${OPERATOR_PROFILE:-default}"
PRI="${PRIMARY_REGION:-${REGION:-us-east-1}}"
SEC="${SECONDARY_REGION:-us-west-2}"

NFAIL=0; NWARN=0; OFFLINE_BLOCKED=0; AWS_OK=0
pass() { printf '  PASS  %-22s %s\n' "$1" "$2"; }
warn() { printf '  WARN  %-22s %s\n' "$1" "$2"; NWARN=$((NWARN+1)); }
fail() { printf '  FAIL  %-22s %s\n' "$1" "$2"; NFAIL=$((NFAIL+1)); [[ "${3:-}" == offline ]] && OFFLINE_BLOCKED=1; }
section() { printf '\n[%s]\n' "$1"; }
version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }

echo "======================================================================"
echo " EventBridge lab — cloud environment preflight"
echo "======================================================================"

# ---------------------------------------------------------------------------
section "runtime"
if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then
  pass "claude-cloud" "running in a Claude Code cloud session"
else
  warn "claude-cloud" "CLAUDE_CODE_REMOTE not set — running outside a Claude cloud session"
fi
pass "platform" "$(uname -s) $(uname -m)"
if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then
  warn "ephemeral-disk" "container is discarded when the session ends: .runtime/ and bootstrap state are lost — destroy in the same session or use restore-runtime.sh"
fi

# ---------------------------------------------------------------------------
section "tools"
if command -v terraform >/dev/null 2>&1; then
  v="$(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null || terraform version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  if version_ge "$v" "1.10.0" && ! version_ge "$v" "2.0.0"; then pass "terraform" "$v (need >=1.10,<2.0 (S3 use_lockfile))"; else fail "terraform" "$v (need >=1.10,<2.0 (S3 use_lockfile))" offline; fi
else fail "terraform" "not installed — run scripts/cloud/install-tools.sh" offline; fi

if command -v tflint >/dev/null 2>&1; then
  v="$(tflint --version 2>/dev/null | sed -nE 's/.*version ([0-9.]+).*/\1/p' | head -1)"
  if version_ge "${v:-0}" "0.50.0"; then pass "tflint" "$v"; else warn "tflint" "${v:-unknown} (need >=0.50) — lint step will fail"; fi
else warn "tflint" "not installed — verify scripts will SKIP the lint step"; fi

for t in jq aws python3 git curl; do
  if command -v "$t" >/dev/null 2>&1; then
    case "$t" in
      aws)     pass "$t" "$(aws --version 2>&1 | awk '{print $1}')" ;;
      python3) pass "$t" "$(python3 --version 2>&1 | awk '{print $2}')" ;;
      jq)      pass "$t" "$(jq --version)" ;;
      *)       pass "$t" "present" ;;
    esac
  else
    case "$t" in
      aws) fail "$t" "not installed — needed for every create/test/destroy script" ;;
      jq)  fail "$t" "not installed — needed by verify/compliance scripts" offline ;;
      *)   fail "$t" "not installed" offline ;;
    esac
  fi
done
if python3 -m pip --version >/dev/null 2>&1; then pass "pip" "present (build-producer.sh bundles awscrt)"; else warn "pip" "missing — build-producer.sh cannot bundle awscrt"; fi
if python3 -c 'import awscrt' >/dev/null 2>&1 || aws --version 2>&1 | grep -q 'aws-cli/2'; then
  pass "sigv4a" "CRT available (put-events --endpoint-id works from this shell)"
else
  warn "sigv4a" "no awscrt — 'aws events put-events --endpoint-id' (global endpoint) will fail from this shell"
fi

# ---------------------------------------------------------------------------
section "network (sandbox allow-list)"
# Any HTTP status means the host is reachable through the sandbox proxy;
# 000 means blocked / no route. AWS hosts are probed regionally.
probe() {
  local name="$1" url="$2" need="$3" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 10 "$url" 2>/dev/null || true)"
  code="${code:-000}"
  if [[ "$code" != "000" ]]; then pass "$name" "reachable (HTTP $code)"
  elif [[ "$need" == offline ]]; then fail "$name" "BLOCKED — add to the environment's allowed domains" offline
  elif [[ "$need" == deploy ]]; then fail "$name" "BLOCKED — needed to deploy; allow *.amazonaws.com or use Full network access"
  else warn "$name" "BLOCKED — $need"; fi
}
probe "registry.terraform.io" "https://registry.terraform.io/.well-known/terraform.json" offline
probe "releases.hashicorp.com" "https://releases.hashicorp.com/" offline
probe "github.com" "https://github.com/" offline
probe "api.github.com" "https://api.github.com/" "tflint --init (aws ruleset) may fail"
probe "pypi.org" "https://pypi.org/simple/awscrt/" "build-producer.sh cannot fetch awscrt"
probe "files.pythonhosted.org" "https://files.pythonhosted.org/" "build-producer.sh cannot fetch awscrt"
probe "sts.${PRI}" "https://sts.${PRI}.amazonaws.com/" deploy
probe "events.${PRI}" "https://events.${PRI}.amazonaws.com/" deploy
probe "s3.${PRI}" "https://s3.${PRI}.amazonaws.com/" deploy
probe "events.${SEC}" "https://events.${SEC}.amazonaws.com/" "secondary region unreachable (multi-region stack)"
probe "route53" "https://route53.amazonaws.com/" "global endpoint health check cannot be managed"

# ---------------------------------------------------------------------------
section "repository / release"
if git -C "$LAB_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$LAB_ROOT" rev-parse --abbrev-ref HEAD)"
  head_sha="$(git -C "$LAB_ROOT" rev-parse --short HEAD)"
  here_tag="$(git -C "$LAB_ROOT" describe --tags --exact-match 2>/dev/null || true)"
  pass "checkout" "branch ${branch} @ ${head_sha}${here_tag:+ (tag ${here_tag})}"
  remote="$(git -C "$LAB_ROOT" remote get-url origin 2>/dev/null || echo '')"
  latest="$(git -C "$LAB_ROOT" ls-remote --tags --refs origin 'v*' 2>/dev/null | awk -F/ '{print $3}' | sort -V | tail -1)"
  if [[ -z "$latest" ]]; then
    warn "latest-release" "could not list release tags from origin (${remote:-no origin})"
  else
    git -C "$LAB_ROOT" fetch -q --tags origin 2>/dev/null || true
    latest_sha="$(git -C "$LAB_ROOT" rev-parse --short "${latest}^{commit}" 2>/dev/null || echo '?')"
    if git -C "$LAB_ROOT" merge-base --is-ancestor "${latest}" HEAD 2>/dev/null; then
      pass "latest-release" "${latest} (${latest_sha}) is included in HEAD"
    else
      warn "latest-release" "HEAD does not contain ${latest} — run: scripts/cloud/clone-latest.sh --here"
    fi
  fi
  if [[ -z "$(git -C "$LAB_ROOT" status --porcelain 2>/dev/null)" ]]; then pass "worktree" "clean"; else warn "worktree" "uncommitted changes present"; fi
  n_lock="$(find "$LAB_ROOT" -name .terraform.lock.hcl -not -path '*/.terraform/*' | wc -l | tr -d ' ')"
  if [[ "$n_lock" -ge 6 ]]; then pass "provider-locks" "${n_lock} .terraform.lock.hcl files (providers pinned)"; else warn "provider-locks" "only ${n_lock} lock files — providers will float"; fi
else
  fail "checkout" "${LAB_ROOT} is not a git checkout" offline
fi

# ---------------------------------------------------------------------------
section "AWS identity (operator profile: ${PROFILE})"
case "$PRI" in
  us-east-1|us-west-2) pass "primary-region" "$PRI" ;;
  *) warn "primary-region" "$PRI — the sandbox rule allows only us-east-1 / us-west-2" ;;
esac
pass "secondary-region" "$SEC"
if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
  warn "raw-env-creds" "AWS_ACCESS_KEY_ID is set in the environment — it overrides profile switching; prefer OPERATOR_AWS_* names"
fi
if ! command -v aws >/dev/null 2>&1; then
  fail "sts" "aws CLI missing — cannot check identity"
elif ! aws configure list-profiles 2>/dev/null | grep -qx "$PROFILE"; then
  warn "credentials" "profile '${PROFILE}' not configured — set OPERATOR_AWS_* env vars, then run scripts/cloud/configure-aws.sh (offline checks still work)"
else
  if ident="$(aws sts get-caller-identity --profile "$PROFILE" --region "$PRI" --output json 2>&1)"; then
    AWS_OK=1
    acct="$(jq -r .Account <<<"$ident")"; arn="$(jq -r .Arn <<<"$ident")"
    pass "sts" "${arn}"
    if [[ -n "${EXPECTED_AWS_ACCOUNT_ID:-}" ]]; then
      if [[ "$acct" == "$EXPECTED_AWS_ACCOUNT_ID" ]]; then pass "account" "${acct} matches EXPECTED_AWS_ACCOUNT_ID"
      else fail "account" "${acct} != EXPECTED_AWS_ACCOUNT_ID ${EXPECTED_AWS_ACCOUNT_ID} — WRONG ACCOUNT, do not deploy"; AWS_OK=0; fi
    else
      warn "account" "${acct} — set EXPECTED_AWS_ACCOUNT_ID to guard against deploying into the wrong account"
    fi
    if grep -A3 "^\[${PROFILE}\]" "${HOME}/.aws/credentials" 2>/dev/null | grep -q aws_session_token; then
      warn "credential-type" "temporary STS credentials — long deploys can outlive them; refresh if calls start failing with ExpiredToken"
    else
      pass "credential-type" "long-lived key (rotate/delete it after testing)"
    fi
  else
    fail "sts" "get-caller-identity failed: $(grep -m1 . <<<"$ident" | cut -c1-160)"
  fi
fi

# ---------------------------------------------------------------------------
section "deployment state"
if [[ -d "${LAB_ROOT}/.runtime" && -f "${LAB_ROOT}/.runtime/deployer.aws-credentials" ]]; then
  pass "runtime" ".runtime/ has deployer credentials (test/destroy scripts can run)"
else
  pass "runtime" "no .runtime/ deployer credentials (fresh session — create*.sh will mint them)"
fi
if [[ -n "${STATE_BUCKET_NAME:-}" ]]; then
  if [[ "$AWS_OK" -eq 1 ]]; then
    if aws s3api head-bucket --bucket "$STATE_BUCKET_NAME" --profile "$PROFILE" --region "$PRI" >/dev/null 2>&1; then
      pass "state-bucket" "s3://${STATE_BUCKET_NAME} reachable (will be reused)"
      if aws s3api head-object --bucket "$STATE_BUCKET_NAME" --key eventbridge-lab/bootstrap/terraform.tfstate \
           --profile "$PROFILE" --region "$PRI" >/dev/null 2>&1; then
        if [[ -f "${LAB_ROOT}/.runtime/deployer.aws-credentials" ]]; then
          pass "existing-deploy" "bootstrap state found in bucket and .runtime/ is populated"
        else
          warn "existing-deploy" "a previous deployment exists — run scripts/cloud/restore-runtime.sh before test/destroy"
        fi
      else
        pass "existing-deploy" "no bootstrap state in bucket (nothing deployed from it yet)"
      fi
    else
      fail "state-bucket" "s3://${STATE_BUCKET_NAME} not reachable with profile ${PROFILE}"
    fi
  else
    warn "state-bucket" "STATE_BUCKET_NAME=${STATE_BUCKET_NAME} set but AWS identity not verified — skipped"
  fi
else
  warn "state-bucket" "STATE_BUCKET_NAME unset — create*.sh will mint a NEW bucket; note its name so a later session can restore/destroy"
fi

# ---------------------------------------------------------------------------
echo
echo "----------------------------------------------------------------------"
if [[ "$OFFLINE_BLOCKED" -eq 1 ]]; then
  VERDICT="NOT READY — fix the FAIL lines (tools/network) first"
elif [[ "$AWS_OK" -eq 1 && "$NFAIL" -eq 0 ]]; then
  VERDICT="READY (deploy) — offline checks and AWS deploys can run"
else
  VERDICT="READY (offline) — verify-prod.sh / contract tests can run; AWS deploys cannot yet"
fi
printf ' VERDICT: %s   (%d FAIL, %d WARN)\n' "$VERDICT" "$NFAIL" "$NWARN"
echo "----------------------------------------------------------------------"
cat <<'EOF'
 Next steps:
   1. scripts/verify-prod.sh                          # offline: fmt + validate + tflint
   2. python3 scripts/contract_test.py validate schemas/prod.orders__OrderPlaced.json \
        schemas/samples/prod.orders__OrderPlaced/valid-1.json   # offline: event contract
   3. (needs READY (deploy) + your OK) scripts/create-prod.sh -> test-prod.sh -> destroy-prod.sh
EOF

[[ "$STRICT" -eq 1 && "$NFAIL" -gt 0 ]] && exit 1
exit 0
