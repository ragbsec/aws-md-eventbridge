#!/usr/bin/env bash
###############################################################################
# session-start.sh — Claude Code SessionStart hook (wired in .claude/settings.json).
#
# Runs automatically when a Claude Code CLOUD session starts on this repo:
#   1. install-tools.sh   — terraform / tflint / jq / aws (skips what exists)
#   2. configure-aws.sh   — env-var credentials -> named operator profile
#   3. preflight.sh       — PASS/WARN/FAIL readiness matrix + verdict
#
# Its STDOUT is added to Claude's context, so the session starts grounded in
# what is (and is not) available. It never deploys anything and never fails
# the session start (always exits 0).
#
# Local (non-cloud) sessions: no-op unless CLOUD_SETUP_FORCE=1.
###############################################################################
set -Euo pipefail

if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" && "${CLOUD_SETUP_FORCE:-}" != "1" ]]; then
  exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${TMPDIR:-/tmp}/eventbridge-lab-session-start.log"

# Make installed tools visible to every later Bash command in the session.
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  echo 'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

echo "## EventBridge lab — cloud session setup"
bash "${HERE}/install-tools.sh" 2>>"$LOG" || echo "install-tools.sh reported errors (details: ${LOG})"
bash "${HERE}/configure-aws.sh" 2>>"$LOG" || echo "configure-aws.sh reported errors (details: ${LOG})"
bash "${HERE}/preflight.sh"     2>>"$LOG" || true

cat <<'EOF'

Session rules (see CLAUDE.md): run only offline checks until the user explicitly
approves an AWS deploy; never print credentials; destroy what you create before
the session ends.
EOF
exit 0
