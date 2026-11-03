#!/usr/bin/env bash
###############################################################################
# verify.sh — OFFLINE static verification of mq-integration/.
#
# terraform fmt/init(-backend=false)/validate (+ tflint), bash -n + shellcheck
# on every mq-integration script, python compile + pytest for the bridge, and
# `docker compose config -q` for the compose project. Missing optional tools
# are SKIP, not FAIL. Never calls AWS.
#
# Usage:  mq-integration/scripts/verify.sh
# Safety class: offline (safe anywhere)
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

if ! command -v tflint >/dev/null 2>&1 && [[ -x "${LAB_ROOT}/.bin/tflint" ]]; then
  export PATH="${LAB_ROOT}/.bin:${PATH}"
fi

FAILED=0
pass()  { printf "PASS  %-12s %s\n" "$1" "${2:-}"; }
fail()  { printf "FAIL  %-12s %s\n" "$1" "${2:-}"; FAILED=1; }
warn_() { printf "WARN  %-12s %s\n" "$1" "${2:-}"; }
skip()  { printf "SKIP  %-12s %s\n" "$1" "${2:-}"; }

# Provider config may be resolved during init/validate; give it a dummy profile
# so it never needs real credentials (nothing here calls AWS).
STUB="${RUNTIME_DIR}/mq-verify-stub.aws-credentials"
( umask 077; cat > "$STUB" <<STUBEOF
[default]
aws_access_key_id = AKIAVERIFYSTUB000000
aws_secret_access_key = verifystubsecretkeyverifystubsecretkey00
region = us-east-1
STUBEOF
)
trap 'rm -f "$STUB"' EXIT

echo "======================================================================"
echo " MQ INTEGRATION STATIC VERIFICATION (offline)"
echo "======================================================================"

# ---- terraform --------------------------------------------------------------
if ! command -v terraform >/dev/null 2>&1; then
  skip terraform "terraform not installed"
elif [[ ! -d "$MQ_TF_DIR" ]]; then
  fail terraform "missing ${MQ_TF_DIR}"
else
  if terraform -chdir="$MQ_TF_DIR" fmt -check -recursive >&2; then pass terraform fmt; else fail terraform fmt; fi
  init_log="${RUNTIME_DIR}/.mq-verify-init.log"
  if env AWS_SHARED_CREDENTIALS_FILE="$STUB" AWS_PROFILE=default \
       terraform -chdir="$MQ_TF_DIR" init -backend=false -input=false >"$init_log" 2>&1; then
    pass terraform init
    if env AWS_SHARED_CREDENTIALS_FILE="$STUB" AWS_PROFILE=default \
         terraform -chdir="$MQ_TF_DIR" validate >&2; then pass terraform validate; else fail terraform validate; fi
  else
    fail terraform init; cat "$init_log" >&2
  fi
  rm -f "$init_log"
  if command -v tflint >/dev/null 2>&1; then
    if ( cd "$MQ_TF_DIR" && tflint -f compact >&2 ); then pass tflint; else warn_ tflint "advisory findings above"; fi
  else
    skip tflint "not installed"
  fi
fi

# ---- shell scripts ----------------------------------------------------------
shopt -s nullglob
SCRIPTS=("${MQ_SCRIPTS}"/*.sh)
bad=0
for s in "${SCRIPTS[@]}"; do bash -n "$s" 2>&1 || { bad=1; err "bash -n failed: $s"; }; done
if [[ "$bad" -eq 0 ]]; then pass bash-n "${#SCRIPTS[@]} scripts"; else fail bash-n "syntax errors above"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -S warning "${SCRIPTS[@]}" >&2; then pass shellcheck "${#SCRIPTS[@]} scripts"; else fail shellcheck "findings above"; fi
else
  skip shellcheck "not installed"
fi

# ---- bridge (python) --------------------------------------------------------
BRIDGE="${MQ_ROOT}/bridge"
if [[ ! -d "$BRIDGE" ]]; then
  skip bridge "no mq-integration/bridge directory"
elif ! command -v python3 >/dev/null 2>&1; then
  skip bridge "python3 not installed"
else
  if python3 -I -m compileall -q "$BRIDGE" >&2; then pass py-compile bridge; else fail py-compile bridge; fi
  if python3 -c 'import pytest' >/dev/null 2>&1; then
    if ( cd "$BRIDGE" && python3 -m pytest -q -p no:cacheprovider >&2 ); then pass pytest bridge; else fail pytest bridge; fi
  else
    skip pytest "pytest not installed"
  fi
  find "$BRIDGE" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
fi

# ---- MQSC objects declared (offline) -----------------------------------------
if [[ -f "${MQ_ROOT}/docker/mqsc/20-eventbridge.mqsc" ]]; then
  if bash "${MQ_SCRIPTS}/verify-mq-objects.sh" --static >&2; then pass mqsc "all expected MQ objects declared"; else fail mqsc "an expected MQ object is missing from 20-eventbridge.mqsc"; fi
else
  skip mqsc "no mqsc file"
fi

# ---- docker compose ---------------------------------------------------------
DOCKER_DIR="${MQ_ROOT}/docker"
if ! command -v docker >/dev/null 2>&1; then
  skip compose "docker not installed — compose config not checked"
elif [[ ! -d "$DOCKER_DIR" ]]; then
  skip compose "no mq-integration/docker directory"
elif ! docker compose version >/dev/null 2>&1; then
  skip compose "docker compose plugin not available"
else
  # Some env vars may be required by the file; give inert placeholders only.
  # bridge.env is rendered on the host at boot and is gitignored, so validate a
  # scratch copy that has an empty one (never writes into the repo tree).
  CMP_TMP="$(mktemp -d)"
  mkdir -p "${CMP_TMP}/docker" "${CMP_TMP}/bridge"
  cp -R "${DOCKER_DIR}/." "${CMP_TMP}/docker/"
  : > "${CMP_TMP}/docker/bridge.env"
  if ( cd "${CMP_TMP}/docker" && MQ_APP_PASSWORD=x MQ_ADMIN_PASSWORD=x docker compose config -q ) >&2; then
    rm -rf "$CMP_TMP"
    pass compose config
  else
    rm -rf "$CMP_TMP"; fail compose config
  fi
fi

echo "======================================================================"
if [[ "$FAILED" -ne 0 ]]; then err "mq-integration verification FAILED"; exit 1; fi
ok "mq-integration verification passed"
