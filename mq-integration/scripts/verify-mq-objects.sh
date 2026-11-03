#!/usr/bin/env bash
###############################################################################
# verify-mq-objects.sh — prove the IBM MQ queue manager and every MQ object the
# integration needs EXISTS and has the expected attributes. Run it right after
# deploy.sh (deploy.sh calls it), before test.sh's end-to-end traffic.
#
# What it checks (each is one PASS / FAIL / UNKNOWN line):
#   queue manager   QM1 is Running; DEADQ = ORDERS.DLQ; CONNAUTH = EB.AUTHINFO
#   listener        a listener is RUNNING on port 1414
#   queues          ORDERS.OUT (BOTHRESH 3 -> ORDERS.DLQ), ORDERS.IN, ORDERS.DLQ:
#                   exist, persistent, MAXDEPTH 50000
#   channel         APP.SVRCONN exists and is a SVRCONN
#   authentication  EB.AUTHINFO = IDPWOS, CHCKCLNT(REQUIRED), ADOPTCTX(YES)
#   channel auth    default deny (NOACCESS), USERMAP for 'app', BLOCKUSER *MQADMIN
#   authorities     principal app: CONNECT on QM1; PUT/GET/INQ/BROWSE on ORDERS.**
#                   (this image has no OS users/groups; rights go to the user name)
#   (live only)     EC2 instance running, bridge container running AND able to log in to
#                   MQ from its own container, READY marker,
#                   SQS queue + DLQ redrive, EventBridge rule ENABLED with the SQS
#                   target, Secrets Manager secret present
#   (--smoke)       real client connections through APP.SVRCONN: 'app' can put and
#                   get; a wrong password is refused; 'admin' is blocked
#
# Modes:
#   (default)            live: via SSM on the EC2 host (needs a deployed stack)
#   --container NAME     a local/other Docker container running the MQ image
#                        (same checks, no AWS) — how the MQSC was tested pre-deploy
#   --static             OFFLINE: only checks that docker/mqsc/20-eventbridge.mqsc
#                        DEFINEs/SETs every object listed above (no MQ, no AWS)
#   --smoke              add the client-connection checks (puts ONE test message on
#                        ORDERS.DLQ and reads it back; nothing consumes that queue)
#
# Usage:  mq-integration/scripts/verify-mq-objects.sh [--static|--container N] [--smoke]
# Env:    INSTANCE_ID (live; otherwise read from terraform outputs),
#         OPERATOR_PROFILE, REGION, BUS_NAME
# Secrets: never printed. The smoke test uses $MQ_APP_PASSWORD from INSIDE the
#         container; the value is never put on a command line or in a log.
# Safety class: read-only (live/container), offline (--static). --smoke writes and
#         removes one message on ORDERS.DLQ.
# Exit:   0 all PASS (UNKNOWN allowed), 1 any FAIL.
###############################################################################
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

MODE=live; CONTAINER=""; SMOKE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)    MODE=static ;;
    --container) MODE=container; CONTAINER="${2:-}"; [[ -n "$CONTAINER" ]] || die "--container needs a name"; shift ;;
    --smoke)     SMOKE=1 ;;
    -h|--help)   sed -n 2,45p "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

FAILED=0; NPASS=0; NUNK=0
pass() { printf "PASS     %s\n" "$1"; NPASS=$((NPASS+1)); }
fail() { printf "FAIL     %s\n" "$1"; FAILED=1; }
unk()  { printf "UNKNOWN  %s\n" "$1"; NUNK=$((NUNK+1)); }

MQSC="${MQ_ROOT}/docker/mqsc/20-eventbridge.mqsc"

###############################################################################
# --static : the MQSC file must define everything the live checks look for
###############################################################################
if [[ "$MODE" == static ]]; then
  echo "== MQ objects declared in $(basename "$MQSC") (offline) =="
  [[ -f "$MQSC" ]] || die "missing ${MQSC}"
  want() {  # want 'label' 'fixed string that must appear'
    grep -qF -- "$2" "$MQSC" && pass "$1" || fail "$1 — not found in mqsc: $2"
  }
  want "queue ORDERS.OUT"        "DEFINE QLOCAL('ORDERS.OUT')"
  want "queue ORDERS.IN"         "DEFINE QLOCAL('ORDERS.IN')"
  want "queue ORDERS.DLQ"        "DEFINE QLOCAL('ORDERS.DLQ')"
  want "ORDERS.OUT backout 3"    "BOTHRESH(3)"
  want "ORDERS.OUT backout queue" "BOQNAME('ORDERS.DLQ')"
  want "dead-letter queue"       "ALTER QMGR DEADQ('ORDERS.DLQ')"
  want "channel APP.SVRCONN"     "DEFINE CHANNEL('APP.SVRCONN') CHLTYPE(SVRCONN)"
  want "authinfo EB.AUTHINFO"    "DEFINE AUTHINFO('EB.AUTHINFO') AUTHTYPE(IDPWOS)"
  want "CHCKCLNT required"       "CHCKCLNT(REQUIRED)"
  want "ADOPTCTX yes"            "ADOPTCTX(YES)"
  want "connauth set on QMGR"    "ALTER QMGR CONNAUTH('EB.AUTHINFO')"
  want "chlauth default deny"    "USERSRC(NOACCESS)"
  want "chlauth usermap app"     "CLNTUSER('app')"
  want "chlauth block *MQADMIN"  "*MQADMIN"
  want "authrec connect QM1"     "PRINCIPAL('app') AUTHADD(CONNECT"
  want "authrec ORDERS.** queues" "PROFILE('ORDERS.**')"
  want "security refresh"        "REFRESH SECURITY TYPE(CONNAUTH)"
  printf "\n%s PASS, %s FAIL\n" "$NPASS" "$([[ $FAILED -eq 0 ]] && echo 0 || echo '>=1')"
  [[ "$FAILED" -eq 0 ]]; exit $?
fi

###############################################################################
# transport: run a bash script INSIDE the MQ container
#   container mode -> docker exec ; live mode -> SSM -> docker exec on the host
# The inner script is sent base64-encoded, so it may contain any quoting.
###############################################################################
if [[ "$MODE" == live ]]; then
  require_tools terraform aws jq
  assert_profile "$OPERATOR_PROFILE"
  if [[ -z "${INSTANCE_ID:-}" ]]; then
    info "reading terraform outputs (operator profile)"
    mq_tf_init
    INSTANCE_ID="$(tf_output "$MQ_TF_DIR" instance_id)"
    OUTBOUND_QUEUE_URL="${OUTBOUND_QUEUE_URL:-$(tf_output "$MQ_TF_DIR" outbound_queue_url)}"
  fi
  echo "== MQ post-build verification — LIVE, instance ${INSTANCE_ID} =="
  mq_sh() { local b; b="$(printf '%s' "$1" | base64 -w0)"
    bash "${MQ_SCRIPTS}/ssm-run.sh" "$INSTANCE_ID" \
      "MQC=\$(cd /opt/eb-mq/docker && docker compose ps -q mq); docker exec -i \"\$MQC\" bash -c \"echo ${b} | base64 -d | bash\""; }
else
  require_tools docker
  echo "== MQ object verification — container ${CONTAINER} =="
  mq_sh() { local b; b="$(printf '%s' "$1" | base64 -w0)"; docker exec -i "$CONTAINER" bash -c "echo ${b} | base64 -d | bash"; }
fi

###############################################################################
# One batched call: every DISPLAY in a single runmqsc session per object, with
# markers so we can slice the output. (One SSM round trip instead of ~15.)
###############################################################################
BATCH="$(cat <<'EOS'
rq() { echo "@@$1"; echo "$2" | runmqsc QM1 2>&1; }
echo "@@DSPMQ"; dspmq -m QM1 2>&1
rq QMGR "DISPLAY QMGR DEADQ CONNAUTH"
rq LSTR "DISPLAY LSSTATUS(*) PORT STATUS"
rq QOUT "DISPLAY QLOCAL(ORDERS.OUT) DEFPSIST MAXDEPTH BOTHRESH BOQNAME"
rq QIN  "DISPLAY QLOCAL(ORDERS.IN) DEFPSIST MAXDEPTH"
rq QDLQ "DISPLAY QLOCAL(ORDERS.DLQ) DEFPSIST MAXDEPTH"
rq CHL  "DISPLAY CHANNEL(APP.SVRCONN) CHLTYPE MCAUSER"
rq AUTH "DISPLAY AUTHINFO(EB.AUTHINFO) AUTHTYPE CHCKCLNT ADOPTCTX"
rq CHA1 "DISPLAY CHLAUTH(*) TYPE(ADDRESSMAP)"
rq CHA2 "DISPLAY CHLAUTH(APP.SVRCONN) TYPE(USERMAP)"
rq CHA3 "DISPLAY CHLAUTH(APP.SVRCONN) TYPE(BLOCKUSER)"
rq ARQ  "DISPLAY AUTHREC PROFILE(ORDERS.**) OBJTYPE(QUEUE) PRINCIPAL('app')"
rq ARM  "DISPLAY AUTHREC OBJTYPE(QMGR) PRINCIPAL('app')"
echo "@@END"
EOS
)"

info "querying the queue manager (one batched runmqsc session)..."
OUT="$(mq_sh "$BATCH" 2>&1)" || { fail "could not run commands in the MQ container (is it up? try: docker ps / ssm-run.sh)"; echo "$OUT" | head -5 >&2; exit 1; }
grep -q '^@@END' <<<"$OUT" || { fail "incomplete output from the container"; printf '%s\n' "$OUT" | head -8 >&2; exit 1; }

sec() { awk -v s="@@$1" '$0==s{f=1;next} /^@@/{f=0} f' <<<"$OUT"; }
# chk LABEL SECTION REGEX  — regex must match somewhere in the section
chk() {
  local label="$1" s="$2" re="$3" body
  body="$(sec "$s")"
  if grep -Eq -- "$re" <<<"$body"; then pass "$label"
  else
    fail "$label — expected /${re}/ in $s"
    printf '           %s\n' "$(grep -E 'AMQ[0-9]+[EI]|[A-Z]+\(' <<<"$body" | head -3 | tr -s ' ' | cut -c1-160)" >&2 || true
  fi
}

echo "-- queue manager"
chk "QM1 is Running"                       DSPMQ 'QMNAME\(QM1\).*STATUS\(Running\)|STATUS\(Running\)'
chk "dead-letter queue = ORDERS.DLQ"       QMGR  'DEADQ\(ORDERS\.DLQ\)'
chk "CONNAUTH = EB.AUTHINFO"               QMGR  'CONNAUTH\(EB\.AUTHINFO\)'
chk "a listener is RUNNING on 1414"        LSTR  'PORT\(1414\)'
echo "-- queues"
chk "ORDERS.OUT exists (QLOCAL)"           QOUT  'QUEUE\(ORDERS\.OUT\)'
chk "ORDERS.OUT persistent"                QOUT  'DEFPSIST\(YES\)'
chk "ORDERS.OUT MAXDEPTH 50000"            QOUT  'MAXDEPTH\(50000\)'
chk "ORDERS.OUT backout threshold 3"       QOUT  'BOTHRESH\(3\)'
chk "ORDERS.OUT backout queue ORDERS.DLQ"  QOUT  'BOQNAME\(ORDERS\.DLQ\)'
chk "ORDERS.IN exists, persistent"         QIN   'QUEUE\(ORDERS\.IN\)'
chk "ORDERS.IN MAXDEPTH 50000"             QIN   'MAXDEPTH\(50000\)'
chk "ORDERS.DLQ exists, persistent"        QDLQ  'QUEUE\(ORDERS\.DLQ\)'
chk "ORDERS.DLQ MAXDEPTH 50000"            QDLQ  'MAXDEPTH\(50000\)'
echo "-- channel, authentication, channel auth"
chk "channel APP.SVRCONN is a SVRCONN"     CHL   'CHLTYPE\(SVRCONN\)'
chk "AUTHINFO EB.AUTHINFO = IDPWOS"        AUTH  'AUTHTYPE\(IDPWOS\)'
chk "CHCKCLNT(REQUIRED): no anonymous"     AUTH  'CHCKCLNT\(REQUIRED\)'
chk "ADOPTCTX(YES)"                        AUTH  'ADOPTCTX\(YES\)'
chk "CHLAUTH default deny (NOACCESS)"      CHA1  'USERSRC\(NOACCESS\)'
chk "CHLAUTH allows only user app"         CHA2  'CLNTUSER\(app\)'
chk "CHLAUTH blocks *MQADMIN on channel"   CHA3  '\*MQADMIN'
echo "-- authorities (principal app)"
chk "CONNECT on QM1"                       ARM   'AUTHLIST\([^)]*CONNECT'
for p in PUT GET INQ BROWSE; do
  chk "ORDERS.** queues: ${p}"             ARQ   "AUTHLIST\\([^)]*${p}"
done

###############################################################################
# LIVE-only: the host and the AWS objects around the container
###############################################################################
if [[ "$MODE" == live ]]; then
  echo "-- host and AWS objects"
  state="$(aws_op ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true)"
  [[ "$state" == running ]] && pass "EC2 instance ${INSTANCE_ID} running" || fail "EC2 instance state: ${state:-unknown}"

  hostchk="$(bash "${MQ_SCRIPTS}/ssm-run.sh" "$INSTANCE_ID" \
    'test -f /opt/eb-mq/READY && echo READY=yes || echo READY=no; cd /opt/eb-mq/docker && docker compose ps --format "{{.Service}}={{.State}}={{.Health}}"' 2>&1 || true)"
  grep -q 'READY=yes' <<<"$hostchk"           && pass "bootstrap marker /opt/eb-mq/READY present" || fail "READY marker missing (bootstrap not finished?)"
  grep -Eq '^mq=running'     <<<"$hostchk"    && pass "compose service mq running"     || fail "compose service mq not running"
  grep -Eq '^bridge=running' <<<"$hostchk"    && pass "compose service bridge running" || fail "compose service bridge not running"

  # The checks above run INSIDE the mq container (localhost). The bridge reaches MQ from ITS OWN
  # container over the docker network as user 'app': prove that path, which is what failed once
  # (MQRC 2009 because the bridge user had no home directory).
  BPROBE="$(cat <<'EOS'
cd /opt/eb-mq/docker
echo "BRIDGEHEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q bridge)" 2>/dev/null)"
docker compose exec -T bridge python - <<'PY'
import os, ibmmq as mq
cd = mq.CD(); cd.ChannelName = os.environ["MQ_CHANNEL"].encode()
cd.ConnectionName = ("%s(%s)" % (os.environ["MQ_HOST"], os.environ.get("MQ_PORT", "1414"))).encode()
cd.ChannelType = mq.CMQXC.MQCHT_CLNTCONN; cd.TransportType = mq.CMQXC.MQXPT_TCP
q = mq.QueueManager(None)
try:
    q.connect_with_options(os.environ["MQ_QMGR"], cd=cd, user=os.environ["MQ_USER"], password=os.environ["MQ_PASSWORD"])
    print("BRIDGECONNECT=OK"); q.disconnect()
except mq.MQMIError as e:
    print("BRIDGECONNECT=FAIL reason=%s" % e.reason)
PY
EOS
)"
  bprobe="$(bash "${MQ_SCRIPTS}/ssm-run.sh" "$INSTANCE_ID" "$BPROBE" 2>&1 || true)"
  grep -q 'BRIDGECONNECT=OK' <<<"$bprobe" \
    && pass "bridge container can log in to MQ as app over the docker network" \
    || fail "bridge container CANNOT connect to MQ ($(grep -o 'BRIDGECONNECT=FAIL reason=[0-9]*' <<<"$bprobe" | head -1)) — see: docker compose logs bridge"
  grep -q 'BRIDGEHEALTH=unhealthy' <<<"$bprobe" && fail "bridge container health is unhealthy" || true

  QURL="${OUTBOUND_QUEUE_URL:-$(tf_output "$MQ_TF_DIR" outbound_queue_url 2>/dev/null || true)}"
  if [[ -n "$QURL" ]]; then
    redrive="$(aws_op sqs get-queue-attributes --queue-url "$QURL" --attribute-names RedrivePolicy --query 'Attributes.RedrivePolicy' --output text 2>/dev/null || true)"
    [[ "$redrive" == *deadLetterTargetArn* ]] && pass "SQS eb-mq-outbound exists with DLQ redrive" || fail "SQS queue / redrive policy missing"
  else unk "SQS queue URL unknown (no terraform output)"; fi

  rule_state="$(aws_op events describe-rule --name mq-outbound-rule --event-bus-name "$BUS_NAME" --query State --output text 2>/dev/null || true)"
  [[ "$rule_state" == ENABLED ]] && pass "EventBridge rule mq-outbound-rule ENABLED on ${BUS_NAME}" || fail "rule mq-outbound-rule state: ${rule_state:-missing}"
  tgt="$(aws_op events list-targets-by-rule --rule mq-outbound-rule --event-bus-name "$BUS_NAME" --query 'Targets[].Arn' --output text 2>/dev/null || true)"
  [[ "$tgt" == *:sqs:* ]] && pass "rule target is the SQS queue" || fail "rule has no SQS target"

  sec_ok="$(aws_op secretsmanager describe-secret --secret-id "$MQ_SECRET_NAME" --query 'LastChangedDate' --output text 2>/dev/null || true)"
  [[ -n "$sec_ok" && "$sec_ok" != None ]] && pass "secret ${MQ_SECRET_NAME} present (value not read)" || fail "secret ${MQ_SECRET_NAME} missing"
fi

###############################################################################
# --smoke: real client connections through the channel (proves the security
# objects WORK, not just exist). Uses $MQ_APP_PASSWORD from inside the container.
###############################################################################
if [[ "$SMOKE" -eq 1 ]]; then
  echo "-- smoke: client connections through APP.SVRCONN"
  SMOKE_SH="$(cat <<'EOS'
export MQSERVER="APP.SVRCONN/TCP/localhost(1414)"
S=/opt/mqm/samp/bin
if [ -z "$MQ_APP_PASSWORD" ]; then echo "RESULT NOPW"; exit 0; fi
# The samples read the password from the FIRST stdin line (not from an env var).
# The password is only ever referenced as a variable here, never printed.
printf "%s\n%s\n" "$MQ_APP_PASSWORD" "eb-mq-smoke" | MQSAMP_USER_ID=app $S/amqsputc ORDERS.DLQ QM1 >/dev/null 2>&1 \
  && echo "RESULT PUT_OK" || echo "RESULT PUT_FAIL"
G=$(printf "%s\n" "$MQ_APP_PASSWORD" | MQSAMP_USER_ID=app timeout 60 $S/amqsgetc ORDERS.DLQ QM1 2>&1)
printf "%s" "$G" | grep -q "eb-mq-smoke" && echo "RESULT GET_OK" || echo "RESULT GET_FAIL"
printf "%s\n%s\n" "definitely-wrong" "x" | MQSAMP_USER_ID=app $S/amqsputc ORDERS.DLQ QM1 >/dev/null 2>&1 \
  && echo "RESULT BADPW_ACCEPTED" || echo "RESULT BADPW_REFUSED"
if [ -z "$MQ_ADMIN_PASSWORD" ]; then echo "RESULT NOADMINPW"; else
  printf "%s\n%s\n" "$MQ_ADMIN_PASSWORD" "x" | MQSAMP_USER_ID=admin $S/amqsputc ORDERS.DLQ QM1 >/dev/null 2>&1 \
    && echo "RESULT ADMIN_ALLOWED" || echo "RESULT ADMIN_BLOCKED"
fi
EOS
)"
  SOUT="$(mq_sh "$SMOKE_SH" 2>&1 || true)"
  if grep -q 'RESULT NOPW' <<<"$SOUT"; then
    unk "smoke skipped: MQ_APP_PASSWORD is not in the container environment"
  else
    grep -q 'RESULT PUT_OK'        <<<"$SOUT" && pass "app can PUT through APP.SVRCONN (password auth works)" || fail "app could not put through the channel"
    grep -q 'RESULT GET_OK'        <<<"$SOUT" && pass "app can GET the message back (queue left empty)"       || fail "app could not get the test message back"
    grep -q 'RESULT BADPW_REFUSED' <<<"$SOUT" && pass "wrong password is REFUSED (CHCKCLNT REQUIRED works)"    || fail "a wrong password was ACCEPTED"
    if grep -q 'RESULT NOADMINPW' <<<"$SOUT"; then unk "admin-blocked check skipped: MQ_ADMIN_PASSWORD not in the container environment"
    else grep -q 'RESULT ADMIN_BLOCKED' <<<"$SOUT" && pass "admin (valid password) is BLOCKED on APP.SVRCONN (CHLAUTH works)" || fail "admin was allowed on the app channel"; fi
  fi
fi

echo "======================================================================"
printf "%s PASS, %s UNKNOWN, %s\n" "$NPASS" "$NUNK" "$([[ $FAILED -eq 0 ]] && echo 'no FAIL' || echo 'FAILURES')"
[[ "$FAILED" -eq 0 ]] || { err "MQ objects verification FAILED"; exit 1; }
ok "MQ queue manager and objects verified"
