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
