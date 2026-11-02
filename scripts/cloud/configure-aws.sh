#!/usr/bin/env bash
###############################################################################
# configure-aws.sh — turn credentials supplied as environment variables (the
# Claude cloud environment's "Environment variables" box) into the NAMED
# operator profile the lab scripts expect (OPERATOR_PROFILE, default "default").
#
# Why a profile and not plain env vars: every lab script authenticates with
# `--profile` / provider `profile =` and swaps AWS_SHARED_CREDENTIALS_FILE to
# the minted deployer mid-run. Raw AWS_ACCESS_KEY_ID in the environment would
# silently override that switch and run the app layers as the operator.
#
# Input (first set found wins):
#   OPERATOR_AWS_ACCESS_KEY_ID / OPERATOR_AWS_SECRET_ACCESS_KEY / OPERATOR_AWS_SESSION_TOKEN  (preferred)
#   AWS_ACCESS_KEY_ID          / AWS_SECRET_ACCESS_KEY          / AWS_SESSION_TOKEN           (fallback)
# Region: REGION, else AWS_REGION, else AWS_DEFAULT_REGION, else us-east-1.
#
# Writes ~/.aws/credentials + ~/.aws/config (mode 600). Never prints secrets.
# When the fallback AWS_* names were used and CLAUDE_ENV_FILE is set (a
# SessionStart hook), it appends `unset AWS_ACCESS_KEY_ID ...` there so later
# shell commands in the session use the profile only.
###############################################################################
set -Eeuo pipefail

PROFILE="${OPERATOR_PROFILE:-default}"
REGION_VAL="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"

SRC=""
if [[ -n "${OPERATOR_AWS_ACCESS_KEY_ID:-}" && -n "${OPERATOR_AWS_SECRET_ACCESS_KEY:-}" ]]; then
  SRC="OPERATOR_AWS_*"
  KEY_ID="$OPERATOR_AWS_ACCESS_KEY_ID"; SECRET="$OPERATOR_AWS_SECRET_ACCESS_KEY"; TOKEN="${OPERATOR_AWS_SESSION_TOKEN:-}"
elif [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  SRC="AWS_*"
  KEY_ID="$AWS_ACCESS_KEY_ID"; SECRET="$AWS_SECRET_ACCESS_KEY"; TOKEN="${AWS_SESSION_TOKEN:-}"
fi

if [[ -z "$SRC" ]]; then
  if [[ -f "${HOME}/.aws/credentials" ]] && grep -q "^\[${PROFILE}\]" "${HOME}/.aws/credentials"; then
    echo "AWS: profile '${PROFILE}' already present in ~/.aws/credentials (no env credentials supplied)"
  else
    echo "AWS: NO credentials supplied — set OPERATOR_AWS_ACCESS_KEY_ID / OPERATOR_AWS_SECRET_ACCESS_KEY (+ OPERATOR_AWS_SESSION_TOKEN) in the cloud environment. Offline checks still work."
  fi
  exit 0
fi

mkdir -p "${HOME}/.aws"
umask 077
CREDS="${HOME}/.aws/credentials"
CONF="${HOME}/.aws/config"

# Replace (not append) this profile's section in a file; other sections kept.
write_section() {
  local file="$1" header="$2" body="$3"
  touch "$file"
  awk -v h="$header" '
    $0 == h { skip = 1; next }
    /^\[/   { skip = 0 }
    !skip
  ' "$file" > "${file}.tmp"
  { cat "${file}.tmp"; printf '%s\n%s\n' "$header" "$body"; } > "$file"
  rm -f "${file}.tmp"
  chmod 600 "$file"
}

body="aws_access_key_id = ${KEY_ID}
aws_secret_access_key = ${SECRET}"
[[ -n "$TOKEN" ]] && body="${body}
aws_session_token = ${TOKEN}"
write_section "$CREDS" "[${PROFILE}]" "$body"

conf_header="[profile ${PROFILE}]"; [[ "$PROFILE" == "default" ]] && conf_header="[default]"
write_section "$CONF" "$conf_header" "region = ${REGION_VAL}
output = json"

TYPE="long-lived access key"; [[ -n "$TOKEN" ]] && TYPE="temporary STS credentials (expire — refresh the env vars when they do)"
echo "AWS: profile '${PROFILE}' written from ${SRC} (${TYPE}), region ${REGION_VAL}"

if [[ "$SRC" == "AWS_*" && -n "${CLAUDE_ENV_FILE:-}" ]]; then
  echo 'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN' >> "$CLAUDE_ENV_FILE"
  echo "AWS: raw AWS_* credential vars will be unset for later commands (profile-based auth only)"
fi
