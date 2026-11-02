#!/usr/bin/env bash
###############################################################################
# install-tools.sh — install the CLI tools this lab needs on a Linux cloud box
# (Claude Code cloud session, CI runner, fresh VM). Idempotent: a tool that is
# already on PATH at an acceptable version is left alone.
#
#   terraform  (pinned TERRAFORM_VERSION, >= 1.10 required by every root (S3-native state locking: use_lockfile))
#   tflint     (pinned TFLINT_VERSION,   >= 0.50 required by .tflint.hcl)
#   jq         (pinned JQ_VERSION)
#   aws        (AWS CLI v2 from awscli.amazonaws.com; falls back to the PyPI
#               `awscli` package when that host is blocked by the sandbox)
#
# Installs into INSTALL_DIR (default: /usr/local/bin when writable, else
# ~/.local/bin). Usable two ways:
#   1. As the Claude cloud ENVIRONMENT "setup script" (runs as root, once per
#      new session, before Claude starts):  bash scripts/cloud/install-tools.sh
#   2. Automatically from scripts/cloud/session-start.sh (SessionStart hook).
#
# Diagnostics go to STDERR; the final one-line-per-tool summary to STDOUT.
###############################################################################
set -Eeuo pipefail

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.10.5}"
TFLINT_VERSION="${TFLINT_VERSION:-0.53.0}"
JQ_VERSION="${JQ_VERSION:-1.7.1}"

if [[ -z "${INSTALL_DIR:-}" ]]; then
  if [[ -w /usr/local/bin ]]; then INSTALL_DIR=/usr/local/bin; else INSTALL_DIR="${HOME}/.local/bin"; fi
fi
mkdir -p "$INSTALL_DIR"
export PATH="${INSTALL_DIR}:${HOME}/.local/bin:${PATH}"

log()  { printf '[install-tools] %s\n' "$*" >&2; }

[[ "$(uname -s)" == "Linux" ]] || { log "not Linux ($(uname -s)) — install tools with your OS package manager instead"; exit 0; }
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64; AWS_ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64; AWS_ARCH=aarch64 ;;
  *) log "unsupported CPU architecture: $(uname -m)"; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"; }

# version_ge A B  -> true when A >= B (dotted numeric)
version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }

# Extract a zip with unzip, or Python's zipfile when unzip is missing.
unzip_to() {
  local zip="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$zip" -d "$dest"
  else
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$dest"
  fi
}

STATUS=()

# ---- terraform -------------------------------------------------------------
install_terraform() {
  if command -v terraform >/dev/null 2>&1; then
    local have; have="$(terraform version -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || echo 0)"
    if version_ge "$have" "1.10.0"; then STATUS+=("terraform $have (already installed)"); return; fi
  fi
  log "installing terraform ${TERRAFORM_VERSION}"
  fetch "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" "$WORK/tf.zip" \
    || { STATUS+=("terraform FAILED (releases.hashicorp.com unreachable?)"); return; }
  unzip_to "$WORK/tf.zip" "$WORK/tf"
  install -m 0755 "$WORK/tf/terraform" "$INSTALL_DIR/terraform"
  STATUS+=("terraform ${TERRAFORM_VERSION} (installed)")
}

# ---- tflint ----------------------------------------------------------------
install_tflint() {
  if command -v tflint >/dev/null 2>&1; then
    local have; have="$(tflint --version 2>/dev/null | sed -nE 's/.*version ([0-9.]+).*/\1/p' | head -1)"
    if [[ -n "$have" ]] && version_ge "$have" "0.50.0"; then STATUS+=("tflint $have (already installed)"); return; fi
  fi
  log "installing tflint ${TFLINT_VERSION}"
  fetch "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${ARCH}.zip" "$WORK/tflint.zip" \
    || { STATUS+=("tflint FAILED (github.com unreachable?) — verify.sh will SKIP lint"); return; }
  unzip_to "$WORK/tflint.zip" "$WORK/tflint"
  install -m 0755 "$WORK/tflint/tflint" "$INSTALL_DIR/tflint"
  STATUS+=("tflint ${TFLINT_VERSION} (installed)")
}

# ---- jq --------------------------------------------------------------------
install_jq() {
  if command -v jq >/dev/null 2>&1; then STATUS+=("jq $(jq --version 2>/dev/null) (already installed)"); return; fi
  log "installing jq ${JQ_VERSION}"
  if fetch "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${ARCH}" "$WORK/jq"; then
    install -m 0755 "$WORK/jq" "$INSTALL_DIR/jq"
    STATUS+=("jq ${JQ_VERSION} (installed)")
  elif command -v apt-get >/dev/null 2>&1 && [[ $EUID -eq 0 ]] && apt-get install -y -qq jq >&2; then
    STATUS+=("jq (installed via apt)")
  else
    STATUS+=("jq FAILED")
  fi
}

# ---- aws cli ---------------------------------------------------------------
install_aws() {
  if command -v aws >/dev/null 2>&1; then STATUS+=("aws $(aws --version 2>&1 | awk '{print $1}') (already installed)"); return; fi
  log "installing AWS CLI v2"
  if fetch "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" "$WORK/awscli.zip"; then
    unzip_to "$WORK/awscli.zip" "$WORK/awscli"
    chmod +x "$WORK"/awscli/aws/install "$WORK"/awscli/aws/dist/aws* 2>/dev/null || true
    if "$WORK/awscli/aws/install" --install-dir "${HOME}/.local/aws-cli" --bin-dir "$INSTALL_DIR" --update >&2; then
      STATUS+=("aws $(aws --version 2>&1 | awk '{print $1}') (installed)"); return
    fi
  fi
  # Fallback: AWS CLI v1 from PyPI (pypi.org is normally reachable from the
  # sandbox). Covers every call the lab scripts make (sts, s3, s3api, lambda,
  # events, logs, sqs). Note: v1 does not bundle CRT, so `put-events
  # --endpoint-id` (SigV4a, global endpoint) needs `pip install awscrt` too.
  log "awscli.amazonaws.com unreachable or install failed — falling back to PyPI awscli (v1) + awscrt"
  if python3 -m pip install --quiet --user --break-system-packages awscli awscrt >&2 2>/dev/null \
     || python3 -m pip install --quiet --user awscli awscrt >&2; then
    STATUS+=("aws $(aws --version 2>&1 | awk '{print $1}') (installed from PyPI)")
  else
    STATUS+=("aws FAILED")
  fi
}

install_terraform
install_tflint
install_jq
install_aws

printf 'Tools (install dir: %s):\n' "$INSTALL_DIR"
for s in "${STATUS[@]}"; do printf '  - %s\n' "$s"; done
