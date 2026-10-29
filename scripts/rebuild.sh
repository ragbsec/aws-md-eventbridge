#!/usr/bin/env bash
###############################################################################
# rebuild.sh — destroy everything, then create it again from scratch.
# Proves the code is fully reproducible: clean account -> full lab -> clean.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

info "REBUILD: destroying current lab (if any)..."
bash "${LAB_ROOT}/scripts/destroy.sh" || warn "destroy reported issues; continuing to create"

info "REBUILD: creating lab fresh..."
bash "${LAB_ROOT}/scripts/create.sh"

ok "REBUILD complete"
