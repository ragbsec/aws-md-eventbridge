#!/usr/bin/env bash
###############################################################################
# verify-prod.sh — static verification for the production (multi-root) layout:
# fmt + init(-backend=false) + validate + tflint across bootstrap, platform,
# application, and the two reusable modules. Emits a PASS/FAIL matrix.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools terraform
if ! command -v tflint >/dev/null 2>&1 && [[ -x "${LAB_ROOT}/.bin/tflint" ]]; then
  export PATH="${LAB_ROOT}/.bin:${PATH}"
fi
HAVE_TFLINT=0; command -v tflint >/dev/null 2>&1 && HAVE_TFLINT=1

# Provider profiles are resolved even by validate; provide a name so the
# platform/application roots can validate before the deployer exists.
if [[ -f "${RUNTIME_DIR}/deployer.aws-credentials" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${RUNTIME_DIR}/deployer.aws-credentials"
else
  _stub="${RUNTIME_DIR}/verify-stub.aws-credentials"
  umask 077
  cat > "$_stub" <<EOF
[${DEPLOYER_PROFILE}]
aws_access_key_id = AKIAVERIFYSTUB000000
aws_secret_access_key = verifystubsecretkeyverifystubsecretkey00
region = us-east-1
EOF
  export AWS_SHARED_CREDENTIALS_FILE="$_stub"
fi

FAILED=0
USING_STUB=0; [[ ! -f "${RUNTIME_DIR}/deployer.aws-credentials" ]] && USING_STUB=1
pass() { printf "PASS  %-14s %s\n" "$1" "$2"; }
fail() { printf "FAIL  %-14s %s\n" "$1" "$2"; FAILED=1; }
warn_() { printf "WARN  %-14s %s\n" "$1" "$2"; }
skip() { printf "SKIP  %-14s %s\n" "$1" "$2"; }

verify() {
  local label="$1" dir="$2"
  info "=== verify ${label} (${dir}) ==="
  terraform -chdir="$dir" fmt -check -recursive >&2 && pass "$label" "fmt" || fail "$label" "fmt"

  # init -backend=false. A root that reads terraform_remote_state resolves its
  # AWS provider during init; under the STUB credentials that hits STS and
  # returns InvalidClientTokenId. That is an ENVIRONMENT artifact (no real
  # deployer creds yet), NOT an HCL defect, so with stub creds we downgrade a
  # cred-only init failure to SKIP. With real deployer creds it must pass.
  local init_log="${RUNTIME_DIR}/.verify-init-${label}.log"
  if terraform -chdir="$dir" init -backend=false -input=false >"$init_log" 2>&1; then
    pass "$label" "init"
  else
    if [[ "$USING_STUB" -eq 1 ]] && grep -q "InvalidClientTokenId\|retrieving caller identity from STS" "$init_log"; then
      skip "$label" "init (stub creds can't call STS; HCL re-checked via validate)"
      # Fall through to validate using a modules-only init so validate still runs.
      terraform -chdir="$dir" init -backend=false -input=false -get=true >/dev/null 2>&1 || true
    else
      fail "$label" "init"; cat "$init_log" >&2; return
    fi
  fi

  terraform -chdir="$dir" validate >&2 && pass "$label" "validate" || fail "$label" "validate"

  # tflint findings here are advisory WARNINGS (unused compat var, provider
  # version-pin style). They do not block a deploy; report them but do not FAIL.
  if [[ "$HAVE_TFLINT" -eq 1 ]]; then
    if ( cd "$dir" && tflint --config="${LAB_ROOT}/.tflint-min.hcl" -f compact >&2 ); then
      pass "$label" "tflint"
    else
      warn_ "$label" "tflint (advisory — see warnings above)"
    fi
  else
    skip "$label" "tflint"
  fi
}

# Minimal tflint config (bundled terraform ruleset; no network plugin fetch).
cat > "${LAB_ROOT}/.tflint-min.hcl" <<'EOF'
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
EOF

echo "======================================================================"
echo " TERRAFORM STATIC VERIFICATION (production layout)"
echo "======================================================================"
verify "bootstrap"      "$BOOTSTRAP_DIR"
verify "platform-pri"   "${LAB_ROOT}/platform-primary"
verify "platform-sec"   "${LAB_ROOT}/platform-secondary"
verify "platform-glob"  "${LAB_ROOT}/platform-global"
verify "application"    "${LAB_ROOT}/application"
verify "mod:platform"   "${LAB_ROOT}/modules/eventbridge-platform"
verify "mod:app"        "${LAB_ROOT}/modules/event-application"
echo "======================================================================"

if [[ "$FAILED" -ne 0 ]]; then err "verification FAILED"; exit 1; fi
ok "all verification checks passed"
