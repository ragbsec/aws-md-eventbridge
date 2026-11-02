#!/usr/bin/env bash
###############################################################################
# clone-latest.sh — get the LATEST RELEASE (highest v* tag) of the lab and put
# you on a working branch cut from it.
#
#   scripts/cloud/clone-latest.sh [DEST]   fresh clone into DEST (default: aws-md-eventbridge)
#   scripts/cloud/clone-latest.sh --here   inside an existing checkout (e.g. the one a
#                                          Claude cloud session already cloned): fetch
#                                          tags and switch to work/<tag>
#
# Env: REPO_URL (default https://github.com/ragbsec/aws-md-eventbridge.git)
#      RELEASE_TAG (pin a specific tag instead of the latest, e.g. v1.0.1)
###############################################################################
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/ragbsec/aws-md-eventbridge.git}"

latest_tag() {
  git ls-remote --tags --refs "$1" 'v*' | awk -F/ '{print $3}' | sort -V | tail -1
}

if [[ "${1:-}" == "--here" ]]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not inside a git checkout" >&2; exit 1; }
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "uncommitted changes present — commit or stash them first" >&2; exit 1
  fi
  REMOTE="$(git remote get-url origin)"
  TAG="${RELEASE_TAG:-$(latest_tag "$REMOTE")}"
  [[ -n "$TAG" ]] || { echo "no v* release tags found on ${REMOTE}" >&2; exit 1; }
  git fetch -q --tags origin
  BR="work/${TAG}"
  if git show-ref -q --verify "refs/heads/${BR}"; then git switch -q "$BR"; else git switch -q -c "$BR" "$TAG"; fi
  echo "On branch ${BR} at release ${TAG} ($(git rev-parse --short HEAD)) in $(pwd)"
  exit 0
fi

DEST="${1:-aws-md-eventbridge}"
[[ -e "$DEST" ]] && { echo "${DEST} already exists — pick another DEST or use --here inside it" >&2; exit 1; }
TAG="${RELEASE_TAG:-$(latest_tag "$REPO_URL")}"
[[ -n "$TAG" ]] || { echo "no v* release tags found on ${REPO_URL}" >&2; exit 1; }

echo "Cloning ${REPO_URL} at latest release ${TAG} -> ${DEST}"
git -c advice.detachedHead=false clone -q --branch "$TAG" "$REPO_URL" "$DEST"
git -C "$DEST" switch -q -c "work/${TAG}"
chmod +x "$DEST"/scripts/*.sh "$DEST"/scripts/cloud/*.sh 2>/dev/null || true
echo "Ready: cd ${DEST}   (branch work/${TAG} @ $(git -C "$DEST" rev-parse --short HEAD))"
echo "Next:  bash scripts/cloud/session-start.sh   # or CLOUD_SETUP_FORCE=1 outside Claude cloud"
