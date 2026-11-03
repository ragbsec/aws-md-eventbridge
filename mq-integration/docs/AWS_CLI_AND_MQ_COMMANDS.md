# AWS CLI and MQ Commands Cookbook — testing the MQ bridge by hand

Plain-CLI version of `mq-integration/scripts/test.sh`, in the style of
[`../../docs/AWS_CLI_TEST_COOKBOOK.md`](../../docs/AWS_CLI_TEST_COOKBOOK.md).
Use it to **see each step** or when a script check fails. Every section says
what it proves, the command, what good looks like, and whether it changes
anything.

> **Safety markers**
> - 🟢 **READ-ONLY** — only describes/lists/browses.
> - 🟡 **LIVE** — publishes events or puts/gets messages. No new infrastructure; tiny cost.
> - 🔴 **MUTATING** — changes or deletes something. Each has a cleanup/rollback note.

> **Status of every command in this file: not yet run on a live stack.**
> They are written from the Terraform, MQSC and compose files and the AWS/IBM
> CLI syntax. Treat all as unverified until you have run them once, and fix
> this file with what you learn. Never print or paste passwords: the commands
> read them into a variable and `unset` it.

---

## 0. Setup (once per shell)

```bash
cd /path/to/aws-md-eventbridge
export AWS_PROFILE=<operator-profile>          # same profile the scripts use (OPERATOR_PROFILE)
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN   # env keys override the profile
export AWS_PAGER=""
export REGION=us-east-1 BUS=eb-prod-orders
TF="terraform -chdir=mq-integration/terraform"
export IID=$($TF output -raw instance_id)
export QURL=$($TF output -raw outbound_queue_url)
export DLQARN=$($TF output -raw outbound_dlq_arn)
export DLQURL=$(aws sqs get-queue-url --queue-name eb-mq-outbound-dlq --region $REGION --query QueueUrl --output text)
aws sts get-caller-identity --query Arn --output text
now_ms() { echo $(( $(date +%s) * 1000 )); }
```

Check the account ID is the one you approved before running anything 🟡/🔴.

---

## 1. SSM session and one-off commands 🟢

**Proves:** the host is registered with Systems Manager and reachable without SSH.

```bash
aws ssm describe-instance-information --region $REGION \
  --filters Key=InstanceIds,Values=$IID \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text
#  -> i-0123...  Online

aws ssm start-session --target $IID --region $REGION           # interactive shell
bash mq-integration/scripts/ssm-run.sh $IID 'cat /opt/eb-mq/READY'   # one-off via the repo helper
```

**Good:** `Online`, and READY prints a timestamp. `ConnectionLost`/empty = see
TROUBLESHOOTING "instance never READY".

Raw one-off without the helper (🟢 for read-only commands):

```bash
CMD=$(aws ssm send-command --region $REGION --instance-ids $IID \
  --document-name AWS-RunShellScript --parameters 'commands=["docker ps --format {{.Names}}"]' \
  --query Command.CommandId --output text)
sleep 3
aws ssm get-command-invocation --region $REGION --command-id $CMD --instance-id $IID \
  --query '[Status,StandardOutputContent]' --output text
#  -> Success  eb-mq-mq-1 / eb-mq-bridge-1
```

---

## 2. runmqsc DISPLAY commands 🟢

**Proves:** the MQSC in `docker/mqsc/20-eventbridge.mqsc` was applied.
Run on the host (inside an SSM session).

```bash
docker exec eb-mq-mq-1 dspmq
#  -> QMNAME(QM1)  STATUS(Running)

docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY QLOCAL('ORDERS.*') CURDEPTH BOTHRESH BOQNAME DEFPSIST"
#  -> ORDERS.OUT  BOTHRESH(3) BOQNAME(ORDERS.DLQ) ; ORDERS.IN ; ORDERS.DLQ

docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY CHANNEL('APP.SVRCONN') ALL"
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY CHSTATUS('APP.SVRCONN') CONNAME USERID MCAUSER"   # bridge connection
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY CHLAUTH('APP.SVRCONN') ALL"
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY AUTHINFO('EB.AUTHINFO') CHCKCLNT ADOPTCTX"
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY AUTHREC PROFILE('ORDERS.**') OBJTYPE(QUEUE) PRINCIPAL('app')"
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY QMGR CONNAUTH DEADQ"
```

**Good:** `CHCKCLNT(REQUIRED)`, a `CHLAUTH` `USERMAP` for `app`, `BLOCKUSER` for
`*MQADMIN`, `AUTHREC` with `put get inq browse`, `DEADQ(ORDERS.DLQ)`.

---

## 3. Put and get with amqsputc / amqsgetc 🟡

**Proves:** the real client channel and authentication path work. The `c`
variants connect as a client over `APP.SVRCONN` (the non-`c` variants bind
locally and bypass the channel).
Run on the host. With the bridge running it **consumes `ORDERS.OUT` within
seconds**, which is what you want for flow 1.

```bash
APP_PW=$(grep '^MQ_APP_PASSWORD=' /opt/eb-mq/docker/.env | cut -d= -f2-)
# The bridge validates against schemas/prod.orders__OrderPlaced.json: orderId MUST be a UUID,
# all five fields required, NO extra fields (anything else is treated as poison -> ORDERS.DLQ).
OID=$(python3 -c 'import uuid;print(uuid.uuid4())')
ORDER="{\"orderId\":\"$OID\",\"product\":\"widget\",\"quantity\":1,\"amount\":9.99,\"placedAt\":\"$(date -u +%FT%TZ)\"}"

# Flow 1: put an order for the bridge to publish   (single line = one message)
echo "$ORDER" | docker exec -i -e MQSAMP_USER_ID=app -e MQSAMP_PASSWORD="$APP_PW" eb-mq-mq-1 \
  bash -c 'MQSERVER="APP.SVRCONN/TCP/localhost(1414)" /opt/mqm/samp/bin/amqsputc ORDERS.OUT QM1'

# Flow 2: read what EventBridge delivered (waits ~15 s for a message, then exits)
docker exec -i -e MQSAMP_USER_ID=app -e MQSAMP_PASSWORD="$APP_PW" eb-mq-mq-1 \
  bash -c 'MQSERVER="APP.SVRCONN/TCP/localhost(1414)" /opt/mqm/samp/bin/amqsgetc ORDERS.IN QM1'
unset APP_PW
```

**Good:** put prints `Sample AMQSPUT0 start` / `end`; get prints the JSON order.
`MQRC 2035` = auth/permission problem, `2538` = host/port, `2059` = QM down
(see TROUBLESHOOTING). Undo: a message you got is gone; discard test data with
🔴 `runmqsc ... "CLEAR QLOCAL('ORDERS.IN')"`.

Browse without removing: `/opt/mqm/samp/bin/amqsbcgc ORDERS.DLQ QM1` (same env).
`docker/mq-test-order.json` is a schema-valid sample payload.

---

## 4. Publish an event onto the bus (put-events) 🟡

**Proves:** `mq-outbound-rule` matches and the event reaches `ORDERS.IN`
(flow 2). Script check 3.

```bash
OID=$(python3 -c 'import uuid;print(uuid.uuid4())')
aws events put-events --region $REGION --entries "[{
  \"Source\":\"prod.orders\",\"DetailType\":\"OrderPlaced\",\"EventBusName\":\"$BUS\",
  \"Detail\":\"{\\\"orderId\\\":\\\"$OID\\\",\\\"product\\\":\\\"widget\\\",\\\"quantity\\\":1,\\\"amount\\\":9.99,\\\"placedAt\\\":\\\"$(date -u +%FT%TZ)\\\",\\\"origin\\\":\\\"cli\\\"}\"}]"
#  -> FailedEntryCount: 0
```

> **Note.** `mq-outbound-rule` matches `detail.origin` of
> `[{"exists":false},{"anything-but":"ibm-mq"}]` (values in one array are
> OR'ed): events with **no** `origin` (the lab producer, `test.sh`) and events
> with any origin other than `ibm-mq` reach MQ. `anything-but` alone would not
> match a missing field, hence the `exists:false` branch.

Validate the pattern offline against a sample event (🟢):

```bash
aws events test-event-pattern --region $REGION \
  --event-pattern "$(aws events describe-rule --name mq-outbound-rule --event-bus-name $BUS --region $REGION --query EventPattern --output text)" \
  --event '{"id":"1","account":"111122223333","time":"2026-01-01T00:00:00Z","region":"us-east-1","resources":[],"version":"0","source":"prod.orders","detail-type":"OrderPlaced","detail":{"orderId":"x"}}' \
  --query Result --output text
#  -> True (no origin) — repeat with "origin":"ibm-mq" in detail: False
```

Then, after ~15 s, read it on the MQ side with `amqsgetc ORDERS.IN` (§3).

---

## 5. SQS queue and DLQ 🟢 / 🔴

**Proves:** where an event is in the EventBridge -> bridge hop.

```bash
# 🟢 depths (visible, in-flight, delayed) — both queues
for U in "$QURL" "$DLQURL"; do
  aws sqs get-queue-attributes --queue-url "$U" --region $REGION \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query Attributes --output json
done
#  steady state: outbound ~0/0, DLQ 0

aws sqs get-queue-attributes --queue-url "$QURL" --region $REGION --attribute-names RedrivePolicy VisibilityTimeout --query Attributes
#  -> maxReceiveCount 5, VisibilityTimeout 60
```

Peek at the DLQ without consuming it (a receive makes the message invisible
for 30 s and counts as a receive, so this is 🟡 on a live queue, harmless on
the DLQ):

```bash
aws sqs receive-message --queue-url "$DLQURL" --region $REGION --max-number-of-messages 5 \
  --visibility-timeout 5 --attribute-names All --query 'Messages[].[MessageId,Body]' --output text
```

**Good:** an empty DLQ. A body is the full EventBridge envelope (`detail-type`,
`detail.orderId`, ...). Replay: 🔴 `aws sqs start-message-move-task --source-arn $DLQARN --destination-arn <queue-arn>`
(see RUNBOOK §5). Purge (🔴, irreversible): `aws sqs purge-queue --queue-url "$DLQURL"`.

---

## 6. The rule and its targets 🟢

**Proves:** `mq-outbound-rule` exists, is enabled and targets SQS with a DLQ.

```bash
aws events describe-rule --name mq-outbound-rule --event-bus-name $BUS --region $REGION \
  --query '[State,EventPattern]' --output text
#  -> ENABLED  {"detail":{"origin":[{"exists":false},{"anything-but":"ibm-mq"}]},"detail-type":["OrderPlaced"],"source":["prod.orders"]}

aws events list-targets-by-rule --rule mq-outbound-rule --event-bus-name $BUS --region $REGION \
  --query 'Targets[].[Id,Arn,DeadLetterConfig.Arn]' --output text
#  -> mq-outbound-sqs  arn:aws:sqs:...:eb-mq-outbound  arn:aws:sqs:...:eb-mq-outbound-dlq
```

The existing lab rule must be unchanged (`order-placed-rule`, 3 targets; see
the main cookbook §1).

---

## 7. Consumer logs and the bridge's origin stamp 🟢

**Proves:** a flow-1 event reached the existing consumer, with `origin=ibm-mq`.

```bash
T=$(now_ms)   # take BEFORE putting the MQ message in §3
# ... put the order, wait ~20 s ...
aws logs filter-log-events --region $REGION --log-group-name /aws/lambda/eb-prod-pri-consumer \
  --start-time $T --filter-pattern "\"$OID\"" --query 'events[].message' --output text | head
aws logs filter-log-events --region $REGION --log-group-name /aws/events/eb-prod-pri/audit \
  --start-time $T --filter-pattern '"ibm-mq"' --query 'events[0].message' --output text
```

Keep the `$OID` you used in §3 in the same shell. **Good:** consumer line "processed order" with your `orderId`; audit entry
containing `"origin":"ibm-mq"`. The sample fan-out also reaches SNS.

---

## 8. Anti-loop check 🟡

**Proves:** the bridge's own events never come back to MQ (check 4).

```bash
aws events put-events --region $REGION --entries "[{\"Source\":\"prod.orders\",\"DetailType\":\"OrderPlaced\",\"EventBusName\":\"$BUS\",
  \"Detail\":\"{\\\"orderId\\\":\\\"$(python3 -c 'import uuid;print(uuid.uuid4())')\\\",\\\"quantity\\\":1,\\\"amount\\\":1,\\\"origin\\\":\\\"ibm-mq\\\"}\"}]"
sleep 20
aws sqs get-queue-attributes --queue-url "$QURL" --region $REGION --attribute-names ApproximateNumberOfMessages --query Attributes
# and amqsgetc ORDERS.IN (§3) must find nothing
```

**Good:** nothing arrives in SQS or on `ORDERS.IN`. Clean up: nothing was written to MQ.

---

## 9. Poison message 🟡

**Proves:** a bad message backs out 3 times and lands on `ORDERS.DLQ` (check 5).

```bash
# on host: put non-JSON
echo "this is not json" | docker exec -i -e MQSAMP_USER_ID=app -e MQSAMP_PASSWORD="$APP_PW" eb-mq-mq-1 \
  bash -c 'MQSERVER="APP.SVRCONN/TCP/localhost(1414)" /opt/mqm/samp/bin/amqsputc ORDERS.OUT QM1'
sleep 30
docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY QLOCAL('ORDERS.DLQ') CURDEPTH"
```

**Good:** `CURDEPTH(1)` and `ORDERS.OUT` depth back to 0. Cleanup: 🔴
`CLEAR QLOCAL('ORDERS.DLQ')` or replay per RUNBOOK §5.

---

## 10. Secret exists (value never printed) 🟢

```bash
aws secretsmanager describe-secret --secret-id eb-mq/credentials --region $REGION \
  --query '[Name,LastChangedDate]' --output text
# NEVER run get-secret-value to the terminal. To check shape only:
aws secretsmanager get-secret-value --secret-id eb-mq/credentials --region $REGION \
  --query SecretString --output text | jq 'keys'      # -> ["admin_password","app_password"]
```
