#!/usr/bin/env bash
###############################################################################
# verify.sh — static verification of the Terraform code.
#
# Runs, per layer, in sequence and reports PASS/FAIL for each object:
#   1. terraform fmt -check   (style)
#   2. terraform init         (module + provider resolution)
#   3. terraform validate     (config correctness)
#   4. tflint                 (lint rules; auto-installed via brew if missing)
#
# STDOUT carries the PASS/FAIL matrix; diagnostics go to STDERR.
# Exit non-zero if any check fails.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform

# Prefer a project-local tflint (installed to .bin) if PATH has none.
if ! command -v tflint >/dev/null 2>&1 && [[ -x "${LAB_ROOT}/.bin/tflint" ]]; then
  export PATH="${LAB_ROOT}/.bin:${PATH}"
fi

# --- ensure tflint is available (best-effort install) ----------------------
if ! command -v tflint >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    info "tflint not found; installing via brew..."
    brew install tflint >&2 || warn "brew install tflint failed; skipping lint step"
  else
    warn "tflint not found and brew unavailable; skipping lint step"
  fi
fi
HAVE_TFLINT=0
command -v tflint >/dev/null 2>&1 && HAVE_TFLINT=1

# The app provider references a named profile (the deployer). Static checks
# (init -backend=false / validate) still resolve provider config, so the profile
# must exist as a name. If real deployer creds are present, use them; otherwise
# point at a throwaway credentials file carrying just the profile NAME so
# validation can run before the deployer user exists (no real creds needed to
# validate configuration).
if [[ -f "${RUNTIME_DIR}/deployer.aws-credentials" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"
else
  _stub_creds="${RUNTIME_DIR}/verify-stub.aws-credentials"
  umask 077
  cat > "$_stub_creds" <<EOF
[${DEPLOYER_PROFILE}]
aws_access_key_id = AKIAVERIFYSTUB000000
aws_secret_access_key = verifystubsecretkeyverifystubsecretkey00
region = ${REGION}
EOF
  export AWS_SHARED_CREDENTIALS_FILE="$_stub_creds"
fi

FAILED=0
pass_line() { printf "PASS  %-10s  %s\n" "$1" "$2"; }
fail_line() { printf "FAIL  %-10s  %s\n" "$1" "$2"; FAILED=1; }

verify_layer() {
  local layer="$1" dir="$2"
  info "=== verifying layer: ${layer} (${dir}) ==="

  if terraform -chdir="$dir" fmt -check -recursive >&2; then
    pass_line "$layer" "terraform fmt"
  else
    fail_line "$layer" "terraform fmt (run: terraform -chdir=$dir fmt -recursive)"
  fi

  # init without backend so validate works before the backend exists.
  if terraform -chdir="$dir" init -backend=false -input=false >&2; then
    pass_line "$layer" "terraform init"
  else
    fail_line "$layer" "terraform init"
    return
  fi

  if terraform -chdir="$dir" validate >&2; then
    pass_line "$layer" "terraform validate"
  else
    fail_line "$layer" "terraform validate"
  fi

  if [[ "$HAVE_TFLINT" -eq 1 ]]; then
    ( cd "$dir" && tflint --init >&2 2>/dev/null || true )
    if ( cd "$dir" && tflint --format compact >&2 ); then
      pass_line "$layer" "tflint"
    else
      fail_line "$layer" "tflint"
    fi
  else
    printf "SKIP  %-10s  %s\n" "$layer" "tflint (not installed)"
  fi
}

echo "======================================================================"
echo " TERRAFORM STATIC VERIFICATION"
echo "======================================================================"
verify_layer "bootstrap" "$BOOTSTRAP_DIR"
verify_layer "app"       "$APP_DIR"
echo "======================================================================"

if [[ "$FAILED" -ne 0 ]]; then
  err "one or more verification checks FAILED"
  exit 1
fi
ok "all verification checks passed"
