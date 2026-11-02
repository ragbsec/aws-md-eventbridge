#!/usr/bin/env bash
# Shared helpers for the EventBridge lab scripts.
# Sourced by the top-level scripts; no executable bit needed.
#
# Diagnostic/status output goes to STDERR so that `$(...)` capture of a
# function's real data stays clean. PASS/FAIL/result lines go to STDOUT.

set -Eeuo pipefail

# ---- paths -----------------------------------------------------------------
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_DIR="${LAB_ROOT}/bootstrap"
APP_DIR="${LAB_ROOT}/app"
RUNTIME_DIR="${LAB_ROOT}/.runtime"   # gitignored; holds secrets + rendered config

mkdir -p "${RUNTIME_DIR}"

# Keep Terraform's provider cache and temp files on a writable path. Some
# sandboxed shells restrict the default $TMPDIR, which breaks provider install.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${LAB_ROOT}/.tf-plugin-cache}"
export TMPDIR="${LAB_ROOT}/.tftmp"
mkdir -p "${TF_PLUGIN_CACHE_DIR}" "${TMPDIR}"

# ---- config (override via environment) -------------------------------------
OPERATOR_PROFILE="${OPERATOR_PROFILE:-default}"      # privileged bootstrap runner (cloud_user)
DEPLOYER_PROFILE="${DEPLOYER_PROFILE:-eventbridge-lab-deployer}"  # dedicated app deployer
REGION="${REGION:-us-east-1}"

# ---- logging (STDERR) ------------------------------------------------------
_c_reset='\033[0m'; _c_blue='\033[0;34m'; _c_green='\033[0;32m'
_c_yellow='\033[0;33m'; _c_red='\033[0;31m'

info()  { printf "${_c_blue}[INFO]${_c_reset}  %s\n"  "$*" >&2; }
ok()    { printf "${_c_green}[ OK ]${_c_reset}  %s\n" "$*" >&2; }
warn()  { printf "${_c_yellow}[WARN]${_c_reset}  %s\n" "$*" >&2; }
err()   { printf "${_c_red}[FAIL]${_c_reset}  %s\n"   "$*" >&2; }
die()   { err "$*"; exit 1; }

# ---- preconditions ---------------------------------------------------------
require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found on PATH: $t"
  done
}

# Confirm a profile actually resolves to an identity.
assert_profile() {
  local profile="$1"
  aws sts get-caller-identity --profile "$profile" --region "$REGION" >/dev/null 2>&1 \
    || die "AWS profile '$profile' is not configured or has no valid credentials"
}

# Read a Terraform output value (STDOUT = the value only).
tf_output() {
  local dir="$1" name="$2"
  terraform -chdir="$dir" output -raw "$name"
}

# ---- safe layer destroy ----------------------------------------------------
# Layers that failed to destroy. Callers MUST check this before destroying
# bootstrap: bootstrap owns the S3 state bucket, and removing it while a layer
# still has resources strands them with no state to destroy them from.
DESTROY_FAILED=()

# tf_destroy_layer LABEL DIR [terraform destroy args...]
#   Runs `terraform destroy` for one already-initialised layer. Waits up to 60s
#   for a state lock. If the lock is STALE (left by an interrupted run) and
#   FORCE_UNLOCK=1, clears exactly that lock ID once and retries. Any other
#   failure is recorded in DESTROY_FAILED — never swallowed.
tf_destroy_layer() {
  local label="$1" dir="$2"; shift 2
  local log attempt lock_id
  log="$(mktemp "${RUNTIME_DIR}/destroy-${label}.XXXXXX")"
  for attempt in 1 2; do
    if terraform -chdir="$dir" destroy -auto-approve -input=false -lock-timeout=60s "$@" 2>&1 | tee "$log" >&2; then
      rm -f "$log"; ok "${label} destroyed"; return 0
    fi
    lock_id=""
    if grep -q "Error acquiring the state lock" "$log"; then
      lock_id="$(grep -oE 'ID:[[:space:]]+[0-9a-f-]{36}' "$log" | head -1 | awk '{print $2}')"
    fi
    if [[ -n "$lock_id" && "${FORCE_UNLOCK:-0}" == "1" && "$attempt" -eq 1 ]]; then
      warn "${label}: stale state lock ${lock_id} — FORCE_UNLOCK=1, clearing it and retrying once"
      terraform -chdir="$dir" force-unlock -force "$lock_id" >&2 || break
      continue
    fi
    [[ -n "$lock_id" ]] && err "${label}: state is locked (lock ${lock_id}). If no other terraform is running (e.g. an earlier run was interrupted), re-run with FORCE_UNLOCK=1"
    break
  done
  rm -f "$log"
  DESTROY_FAILED+=("$label")
  err "${label}: destroy FAILED"
  return 1
}

# tf_init_layer LABEL DIR BACKEND_HCL — init a layer; a failure is recorded.
tf_init_layer() {
  local label="$1" dir="$2" backend="$3"
  terraform -chdir="$dir" init -input=false -reconfigure -backend-config="$backend" >&2 \
    || { DESTROY_FAILED+=("$label (init)"); err "${label}: init FAILED"; return 1; }
}
