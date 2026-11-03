# Runbook — operating the IBM MQ <-> EventBridge bridge

> **Not yet run on a live stack.** Every procedure is written from the design
> and the files in this folder. Safety markers: 🟢 READ-ONLY, 🟡 LIVE (sends
> messages/events, adds no infrastructure), 🔴 MUTATING (changes or restarts
> things).

Host facts: Docker Compose project `eb-mq` in `/opt/eb-mq/docker`; containers
`eb-mq-mq-1` and `eb-mq-bridge-1`; queue manager `QM1`; readiness marker
`/opt/eb-mq/READY`; first-boot log `/var/log/eb-mq-bootstrap.log`.
Commands marked `# on host` run inside an SSM session, as root (`sudo -i`
if your session user is `ssm-user`).

## 1. Connect (SSM only, no SSH) 🟢

```bash
terraform -chdir=mq-integration/terraform output -raw ssm_session_command   # prints the command
aws ssm start-session --target <instance-id> --region us-east-1
# one-off command without an interactive shell:
bash mq-integration/scripts/ssm-run.sh <instance-id> 'docker compose -f /opt/eb-mq/docker/docker-compose.yml ps'
# web console via port forward (https://localhost:9443/ibmmq/console, user admin):
aws ssm start-session --target <instance-id> --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9443"],"localPortNumber":["9443"]}'
```

Needs the Session Manager plugin locally. "TargetNotConnected" means the SSM
agent has not registered (no outbound internet, or the instance profile is missing).

## 2. Read logs 🟢

```bash
# on host
cd /opt/eb-mq/docker
docker compose ps
docker compose logs --tail 100 bridge
docker compose logs --tail 100 mq
docker compose logs -f --since 5m bridge          # Ctrl-C to stop
sudo tail -n 100 /var/log/eb-mq-bootstrap.log     # first-boot problems
cat /opt/eb-mq/READY                              # exists only when MQ became healthy
```

Logs use the `json-file` driver, 10 MB x 5 files, and vanish with the
instance. Consumer-side logs are in CloudWatch: `/aws/lambda/eb-prod-pri-consumer`,
audit `/aws/events/eb-prod-pri/audit`.

## 3. Queue depths with runmqsc 🟢

```bash
# on host
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY QLOCAL('ORDERS.*') CURDEPTH MAXDEPTH OPPROCS IPPROCS"
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY CHSTATUS('APP.SVRCONN') ALL"
docker exec eb-mq-mq-1 dspmq
```

Healthy steady state: `ORDERS.OUT` depth ~0 with the bridge holding one
input handle (`IPPROCS(1)`), `ORDERS.DLQ` depth 0. A growing `ORDERS.OUT` means the bridge is
down, cannot reach EventBridge, or is rolling messages back.

SQS side (from your workstation):

```bash
Q=$(terraform -chdir=mq-integration/terraform output -raw outbound_queue_url)
aws sqs get-queue-attributes --queue-url "$Q" --region us-east-1 \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

## 4. Restart the bridge 🔴

Safe: in-flight messages are rolled back / left visible and retried
(possible duplicate, consumers are idempotent).

```bash
# on host
cd /opt/eb-mq/docker && docker compose restart bridge
docker compose logs --tail 30 bridge
```

Rebuild after changing `bridge/` code: re-run `deploy.sh --yes` (the bundle in
S3 changes, and the instance user_data is replaced, which **replaces the
instance**; unprocessed MQ messages are lost with the volume. Drain first).

## 5. Drain and replay the DLQs

**MQ `ORDERS.DLQ`** (poison messages that backed out more than 3 times).

```bash
# 🟢 look at them without removing (browse), as user app over the real channel
# on host (password from the secret, never typed in plain text)
APP_PW=$(grep '^MQ_APP_PASSWORD=' /opt/eb-mq/docker/.env | cut -d= -f2-)
docker exec -i -e MQSAMP_USER_ID=app -e MQSAMP_PASSWORD="$APP_PW" eb-mq-mq-1 \
  bash -c 'MQSERVER="APP.SVRCONN/TCP/localhost(1414)" /opt/mqm/samp/bin/amqsbcgc ORDERS.DLQ QM1'
unset APP_PW
```

Decide per message: fix the cause (bad JSON, missing `orderId`) then replay, or
discard.

```bash
# 🔴 replay: move DLQ -> ORDERS.OUT. get destructively, then re-put the corrected payload
docker exec -i -e MQSAMP_USER_ID=app -e MQSAMP_PASSWORD="$APP_PW" eb-mq-mq-1 \
  bash -c 'MQSERVER="APP.SVRCONN/TCP/localhost(1414)" /opt/mqm/samp/bin/amqsgetc ORDERS.DLQ QM1'
#   ...then put the corrected JSON back with amqsputc ORDERS.OUT QM1 (see cookbook)
# 🔴 discard everything (irreversible):
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "CLEAR QLOCAL('ORDERS.DLQ')"
```

Messages that were already published to EventBridge are not in the DLQ; do
not replay those blindly: the same `orderId` will reach consumers twice.

**SQS `eb-mq-outbound-dlq`** (events the bridge could not put to MQ after 5
tries, or EventBridge could not deliver):

```bash
# 🔴 redrive DLQ -> source queue after fixing the cause (MQ down, bad payload)
aws sqs start-message-move-task --region us-east-1 \
  --source-arn "$(terraform -chdir=mq-integration/terraform output -raw outbound_dlq_arn)" \
  --destination-arn "$(terraform -chdir=mq-integration/terraform output -raw outbound_queue_arn)"
aws sqs list-message-move-tasks --region us-east-1 --source-arn "<dlq-arn>"
```

## 6. Rotate secrets 🔴

Target: new `admin_password` / `app_password` in `eb-mq/credentials`, compose
`.env` and MQ.

1. Write a new value. Do **not** echo it:
   ```bash
   jq -n --arg a "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)" \
         --arg p "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)" \
         '{admin_password:$a,app_password:$p}' > "$TMPDIR/s.json"
   aws secretsmanager put-secret-value --secret-id eb-mq/credentials --region us-east-1 \
     --secret-string "file://$TMPDIR/s.json" >/dev/null; shred -u "$TMPDIR/s.json"
   ```
2. On the host, rewrite `/opt/eb-mq/docker/.env` (mode 0600) from the secret
   (the keys `MQ_ADMIN_PASSWORD`, `MQ_APP_PASSWORD`) and recreate:
   `docker compose up -d --force-recreate`.
3. Run `scripts/test.sh` (health + MQ -> EB proves the bridge authenticates).

Expect a short outage; messages queue in SQS and (for apps) on their side.
Whether the image applies the new passwords on a plain container recreate
(versus needing a fresh data volume) is **unverified**: confirm with the test.
Update any other application that uses the `app` credentials.

## 7. Upgrade the MQ image 🔴

1. Read the IBM release notes and license for the new tag. **You** accept the license.
2. Drain: wait for `ORDERS.OUT` and `ORDERS.IN` depth 0 (§3) or accept loss.
3. Change `mq_image` (Terraform variable) to a pinned tag, e.g.
   `icr.io/ibm-messaging/mq:<tag>`, then `deploy.sh --yes`. (That replaces
   the instance because `user_data` changes; the volume does not survive.)
   In-place alternative: on host, edit `MQ_IMAGE=` in `.env`, then
   `docker compose pull mq && docker compose up -d mq`. The `qm1data` volume is
   kept; check the IBM docs for supported queue manager version upgrades.
4. `scripts/test.sh`.

## 8. What each `test.sh` check proves and what to look at on failure

Run: `bash mq-integration/scripts/test.sh` (🟡 LIVE).

| # | Check | Proves | If it fails, look at |
|---|---|---|---|
| 1 | **Health** (a) | Instance reachable via SSM, `/opt/eb-mq/READY` present, `mq` healthy, `bridge` running, queues defined | `/var/log/eb-mq-bootstrap.log`, `docker compose ps`, `docker compose logs mq`; TROUBLESHOOTING "instance never READY" |
| 2 | **MQ -> EventBridge** (b) | A valid order put on `ORDERS.OUT` is consumed, published with `origin=ibm-mq`, accepted by the bus, reaches the consumer ("processed order" with the orderId), and `ORDERS.OUT` drains to 0 | `docker compose logs bridge` (MQRC codes, `AccessDenied`), `ORDERS.OUT` depth, `/aws/lambda/eb-prod-pri-consumer`, rule `order-placed-rule` state |
| 3 | **EventBridge -> MQ** (c) | A PutEvents (source `prod.orders`, `OrderPlaced`, **no** `detail.origin` in `test.sh` as written) matches `mq-outbound-rule`, lands in SQS, is put on `ORDERS.IN` by the bridge, and the SQS queue drains | `describe-rule mq-outbound-rule` (state, pattern), queue attributes and DLQ, bridge logs, `ORDERS.IN` depth. The rule pattern accepts an absent `origin` (`exists:false` OR `anything-but ibm-mq`) |
| 4 | **Anti-loop** (d) | The `origin=ibm-mq` event produced by check 2 did **not** reappear on `ORDERS.IN` (rule exclusion; the bridge also drops such events as a second guard) | Pattern of `mq-outbound-rule`; check the bridge actually stamps `detail.origin`; bridge log line "dropped event with origin=ibm-mq" means the rule let one through |
| 5 | **Poison -> DLQ** (e) | A non-JSON message is backed out 3 times and ends up in `ORDERS.DLQ`, a valid order queued behind it is still processed, and `ORDERS.OUT` ends at 0 | `ORDERS.DLQ` depth, `BACKCOUNT` handling in bridge logs; `ORDERS.OUT` not stuck; `BOTHRESH`/`BOQNAME` on the queue (`DISPLAY QLOCAL('ORDERS.OUT') BOTHRESH BOQNAME`) |

`test.sh` prints PASS/FAIL per sub-step (a1.. e5), does not print message bodies, and drains the DLQ at the end. After a failure, clean up leftover test messages: browse and clear queues as in §5.

## 9. Teardown 🔴

```bash
bash mq-integration/scripts/destroy.sh --yes      # ends with leftover-check.sh
bash mq-integration/scripts/leftover-check.sh     # 🟢 re-run; must report clean
```

Messages in MQ and the `qm1data` volume are deleted with the instance. A
"destroyed" banner alone is not proof; the clean sweep is. Per CLAUDE.md,
destroy in the same cloud session, or keep `STATE_BUCKET_NAME`.
