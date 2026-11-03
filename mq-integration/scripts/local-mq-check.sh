#!/usr/bin/env bash
###############################################################################
# local-mq-check.sh — PRE-DEPLOY proof that the MQ side works, on any machine with
# Docker, with NO AWS and NO cost. It starts the SAME IBM MQ image the EC2 host will
# run, with docker/mqsc/20-eventbridge.mqsc mounted exactly as docker-compose.yml
# does, then runs verify-mq-objects.sh --smoke against it and removes the container.
#
# What it proves BEFORE you spend anything on EC2:
#   * the pinned image tag pulls and the queue manager QM1 starts and turns healthy
#   * all MQSC commands in 20-eventbridge.mqsc load with 0 errors (AMQ8939I)
#   * the queue manager, queues, channel, auth objects exist with the right attributes
#   * a real client login through APP.SVRCONN works for 'app', is refused for a wrong
#     password, and is blocked for 'admin'
#
# Usage:  mq-integration/scripts/local-mq-check.sh
# Env:    MQ_IMAGE        image to test (default: the pinned image in docker-compose.yml)
#         LOCAL_NETWORK   docker --network for the container (default: docker's default;
#                         use "none" on hosts without a bridge network: all checks use
#                         `docker exec`, so no port is needed)
#         KEEP=1          leave the container running afterwards (name: eb-mq-local-check)
#         HEALTH_TIMEOUT  seconds to wait for a healthy queue manager (default 180)
# Safety class: local only. Pulls an image (~1 GB) and starts one container, with
#         throwaway random passwords that are never printed. Touches no AWS.
# Licence: running the image sets LICENSE=accept. That is YOUR acceptance of the IBM MQ
#         Advanced for Developers licence (see docker/docker-compose.yml). Do not run
#         this on behalf of someone who has not accepted it.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_tools docker openssl
docker info >/dev/null 2>&1 || die "cannot reach a Docker daemon (is Docker running?)"

NAME="eb-mq-local-check"
MQSC="${MQ_ROOT}/docker/mqsc/20-eventbridge.mqsc"
[[ -f "$MQSC" ]] || die "missing ${MQSC}"
IMAGE="${MQ_IMAGE:-$(sed -n 's/.*image: \${MQ_IMAGE:-\(.*\)}.*/\1/p' "${MQ_ROOT}/docker/docker-compose.yml" | head -1)}"
[[ -n "$IMAGE" ]] || die "could not determine the MQ image (set MQ_IMAGE)"
NET=(); [[ -n "${LOCAL_NETWORK:-}" ]] && NET=(--network "$LOCAL_NETWORK")

cleanup() { [[ "${KEEP:-0}" == 1 ]] || docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker rm -f "$NAME" >/dev/null 2>&1 || true

info "image: ${IMAGE}"
docker image inspect "$IMAGE" >/dev/null 2>&1 || { info "pulling (linux/amd64)..."; docker pull --platform linux/amd64 "$IMAGE" >&2; }

# Throwaway passwords: random, only ever handed to the container's environment.
APP_PW="$(openssl rand -hex 12)"; ADMIN_PW="$(openssl rand -hex 12)"
docker run -d --name "$NAME" --hostname mq "${NET[@]}" \
  -e LICENSE=accept -e MQ_QMGR_NAME=QM1 -e MQ_ENABLE_METRICS=false \
  -e MQ_ADMIN_PASSWORD="$ADMIN_PW" -e MQ_APP_PASSWORD="$APP_PW" \
  -v "${MQSC}:/etc/mqm/20-eventbridge.mqsc:ro" --memory 1536m "$IMAGE" >/dev/null
unset APP_PW ADMIN_PW

info "waiting for QM1 to become healthy..."
deadline=$(( $(date +%s) + ${HEALTH_TIMEOUT:-180} ))
until docker exec "$NAME" chkmqhealthy >/dev/null 2>&1; do
  [[ "$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null)" == running ]] \
    || { docker logs "$NAME" 2>&1 | tail -15 >&2; die "container exited during startup"; }
  [[ $(date +%s) -lt $deadline ]] || { docker logs "$NAME" 2>&1 | tail -15 >&2; die "QM1 not healthy within ${HEALTH_TIMEOUT:-180}s"; }
  sleep 3
done
ok "QM1 is healthy"

# 1. every MQSC command must have loaded
SUMMARY="$(docker logs "$NAME" 2>&1 | grep -a 'AMQ8939I' | tail -1 || true)"
if [[ "$SUMMARY" =~ \[ArithInsert1\(([0-9]+)\),\ ArithInsert2\(([0-9]+)\) ]]; then
  echo "MQSC: ${BASH_REMATCH[1]} commands, ${BASH_REMATCH[2]} with errors"
  [[ "${BASH_REMATCH[2]}" -eq 0 ]] || { docker logs "$NAME" 2>&1 | grep -a 'AMQ8940E' | cut -c1-400 >&2; die "20-eventbridge.mqsc had command errors (AMQ8940E above)"; }
elif grep -aq 'AMQ8939I.*contained [0-9]* command(s), of which 0 had errors' <<<"$SUMMARY"; then
  echo "MQSC: all commands loaded with 0 errors"
else
  docker logs "$NAME" 2>&1 | grep -aE 'AMQ89[0-9]+' | cut -c1-300 >&2 || true
  die "could not find the MQSC completion message (AMQ8939I) in the queue manager log"
fi

# 2. objects + real client logins
bash "${MQ_SCRIPTS}/verify-mq-objects.sh" --container "$NAME" --smoke
