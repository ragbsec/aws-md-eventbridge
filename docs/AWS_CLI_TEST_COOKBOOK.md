# AWS CLI Test Cookbook — testing the EventBridge platform by hand

This is the plain-AWS-CLI version of the platform tests. Use it when you want to
**see and understand each step** instead of running a script, or when a script
fails and you need to look at the raw API behaviour.

Every section says **what it proves**, **the command**, **what a good result
looks like**, and whether it **changes anything**. The matching script is named
where one exists.

> **Safety markers**
> - 🟢 **READ-ONLY** — only describes/lists. Safe at any time.
> - 🟡 **LIVE** — publishes test events / invokes Lambdas. Adds no infrastructure; tiny cost.
> - 🔴 **MUTATING** — changes a resource (and restores it). Do it deliberately; each one has a cleanup step.

> **Status of these commands.** Run against the live `v1.0.3` stack while writing this:
> every 🟢 read-only command (sections 1, 5a, 6a, 6b, 7 archive listing, 8, 9), plus the
> global-endpoint send and replication check (6c/6d, via `05-global-endpoint.sh`).
> **Not run by hand** (written from the matching scripts and the AWS API): the 🟡 commands in
> sections 2, 3, 4 and 10 (sections 2–4 mirror `test-prod.sh` / `02-functional.sh`, which
> `test-prod.sh` has exercised), and all 🔴 drills (5b DLQ, 7 replay, 6e/6f failover). Treat
> the 🔴 commands as unverified until you have run them once and note any fix here.

---

## 0. Setup (once per shell)

The lab creates a dedicated **deployer** IAM user. Its keys live in
`.runtime/deployer.aws-credentials` (gitignored — never print, paste or commit this file).

```bash
cd /path/to/aws-md-eventbridge

# Use the deployer identity (NOT your operator/admin keys) for tests.
export AWS_SHARED_CREDENTIALS_FILE="$PWD/.runtime/deployer.aws-credentials"
export AWS_PROFILE=eventbridge-lab-deployer
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN   # env keys override the profile
export AWS_PAGER=""                                              # no interactive pager

# Names the lab created (defaults; see `terraform -chdir=<root> output`).
export PRI=us-east-1  SEC=us-west-2
export BUS=eb-prod-orders
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export GE_ID=$(terraform -chdir=platform-global output -raw global_endpoint_id)   # e.g. hfzmrj3sp9.veo
export HC_ID=$(terraform -chdir=platform-global output -raw health_check_id)
export EVENT_SOURCE=prod.orders
```

Check you are who you think you are:

```bash
aws sts get-caller-identity --query Arn --output text
# arn:aws:iam::<account>:user/eventbridge-lab-deployer
```

Helper used throughout — "did this text show up in a log group after time T?":

```bash
# usage: seen <region> <log-group> <start-ms> <text>
seen() { aws logs filter-log-events --region "$1" --log-group-name "$2" \
           --start-time "$3" --filter-pattern "\"$4\"" \
           --query 'events[].message' --output text | grep -q "$4"; }
now_ms() { echo $(( $(date +%s) * 1000 )); }
```

---

## 1. Baseline — what is deployed? 🟢

**Proves:** the stack exists in both regions and has the expected shape.

```bash
# Custom bus (the lab's bus is distinct from "default")
aws events list-event-buses --region $PRI --query 'EventBuses[].Name' --output text
#  -> default   eb-prod-orders

# Rules on the bus. Besides order-placed-rule you will see two MANAGED rules
# (the archive and the global endpoint). Do not edit them.
aws events list-rules --event-bus-name $BUS --region $PRI \
  --query 'Rules[].[Name,State]' --output text

# Targets of the business rule = the fan-out
aws events list-targets-by-rule --rule order-placed-rule --event-bus-name $BUS --region $PRI \
  --query 'Targets[].[Id,Arn]' --output text
#  -> audit-to-cloudwatch-logs   (log group)
#     fan-out-to-sns             (SNS topic)
#     send-to-consumer-lambda    (the consumer)

# The routing pattern itself
aws events describe-rule --name order-placed-rule --event-bus-name $BUS --region $PRI \
  --query EventPattern --output text
#  -> {"detail-type":["OrderPlaced"],"source":["prod.orders"]}
```

Repeat with `--region $SEC` for the second region. Whole-account sweep:
`scripts/leftover-check.sh` (it reports "leftovers" while the stack is up — that is expected).

---

## 2. Pattern: content-based routing and fan-out 🟡

**Proves:** a matching event goes to **all three** targets; the producer works.
Script: `scripts/test-prod.sh`.

```bash
T=$(now_ms)

# Invoke the producer Lambda: it publishes 5 OrderPlaced events on the bus.
aws lambda invoke --region $PRI --function-name eb-prod-pri-producer \
  --payload '{"count":5}' --cli-binary-format raw-in-base64-out /tmp/producer-out.json >/dev/null
cat /tmp/producer-out.json          # {"published": 5, "failed": 0, ...}

sleep 15

# (a) consumer Lambda processed them
aws logs filter-log-events --region $PRI --log-group-name /aws/lambda/eb-prod-pri-consumer \
  --start-time $T --filter-pattern '"processed order"' --query 'events[].message' --output text | head

# (b) audit trail got the full event JSON
aws logs filter-log-events --region $PRI --log-group-name /aws/events/eb-prod-pri/audit \
  --start-time $T --query 'events[0].message' --output text
```

**Good:** `published: 5`, `failed: 0`, "processed order" lines, and an audit entry
containing `"detail-type":"OrderPlaced"`. Repeat with `$SEC` and the `-sec-` names.

---

## 3. Negative routing — a wrong-source event must NOT be delivered 🟡

**Proves:** the rule pattern is specific, not "match everything" (control EVB-07).
Script: `compliance/02-functional.sh`.

```bash
T=$(now_ms); OID="neg-$T"
aws events put-events --region $PRI --entries "[{
  \"Source\":\"evb.compliance.negative\",\"DetailType\":\"OrderPlaced\",\"EventBusName\":\"$BUS\",
  \"Detail\":\"{\\\"orderId\\\":\\\"$OID\\\",\\\"quantity\\\":1,\\\"amount\\\":1}\"}]"
sleep 20
seen $PRI /aws/lambda/eb-prod-pri-consumer $T "$OID" && echo "FAIL: routed" || echo "PASS: not routed"
```

**Good:** `PASS: not routed`. (The bus accepts the event — `FailedEntryCount: 0` — it just
matches no rule.)

---

## 4. Idempotency — the same business key twice 🟡

**Proves:** a duplicate delivery does not crash the consumer. Note the lab consumer has
**no dedup store**, so this shows "no error", not true exactly-once. Control EVB-15.

```bash
T=$(now_ms); OID="dup-$T"
E="[{\"Source\":\"$EVENT_SOURCE\",\"DetailType\":\"OrderPlaced\",\"EventBusName\":\"$BUS\",
     \"Detail\":\"{\\\"orderId\\\":\\\"$OID\\\",\\\"quantity\\\":1,\\\"amount\\\":5}\"}]"
aws events put-events --region $PRI --entries "$E"; sleep 3
aws events put-events --region $PRI --entries "$E"
sleep 20
aws logs filter-log-events --region $PRI --log-group-name /aws/lambda/eb-prod-pri-consumer \
  --start-time $T --filter-pattern "\"$OID\"" --query 'events[].message' --output text
# two "processed order" lines for the same orderId, no ERROR
```

A real production consumer should store processed IDs (for example in DynamoDB) and skip repeats.

---

## 5. Reliable delivery — retry, DLQ, alarms

### 5a. Inspect the configuration 🟢

```bash
# Retry policy + dead-letter queue on the Lambda target
aws events list-targets-by-rule --rule order-placed-rule --event-bus-name $BUS --region $PRI \
  --query "Targets[?Id=='send-to-consumer-lambda'].{retry:RetryPolicy,dlq:DeadLetterConfig}"
#  retry: MaximumRetryAttempts 2, MaximumEventAgeInSeconds 3600;  dlq: eb-prod-pri-dlq

# DLQ is empty
aws sqs get-queue-attributes --region $PRI \
  --queue-url https://sqs.$PRI.amazonaws.com/$ACCOUNT/eb-prod-pri-dlq \
  --attribute-names ApproximateNumberOfMessages --query Attributes --output text      # 0

# Alarms exist and are OK
aws cloudwatch describe-alarms --region $PRI --alarm-name-prefix eb-prod-pri \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
```

Known gap (reported by `compliance/01`): the SNS and CloudWatch Logs targets have **no explicit
retry policy**, so AWS defaults apply (24 h, 185 attempts).

### 5b. DLQ drill 🔴 MUTATING (adds a temporary target, then removes it)

**Proves:** an undeliverable event lands in the DLQ. Script: `compliance/03-failure-drills.sh --confirm`.

```bash
DLQ_URL=https://sqs.$PRI.amazonaws.com/$ACCOUNT/eb-prod-pri-dlq
DLQ_ARN=$(aws sqs get-queue-attributes --region $PRI --queue-url $DLQ_URL \
          --attribute-names QueueArn --query Attributes.QueueArn --output text)

# 1. Add a target that points at a Lambda that does not exist, with the DLQ set.
aws events put-targets --region $PRI --rule order-placed-rule --event-bus-name $BUS --targets "[{
  \"Id\":\"manual-dlq-drill\",
  \"Arn\":\"arn:aws:lambda:$PRI:$ACCOUNT:function:does-not-exist\",
  \"DeadLetterConfig\":{\"Arn\":\"$DLQ_ARN\"},
  \"RetryPolicy\":{\"MaximumEventAgeInSeconds\":60,\"MaximumRetryAttempts\":0}}]"

# 2. Fire a matching event.
aws lambda invoke --region $PRI --function-name eb-prod-pri-producer \
  --payload '{"count":1}' --cli-binary-format raw-in-base64-out /tmp/o.json >/dev/null

# 3. Wait, then look for a message in the DLQ (can take a minute or two).
sleep 60
aws sqs receive-message --region $PRI --queue-url $DLQ_URL --max-number-of-messages 1 \
  --attribute-names All --message-attribute-names All --query 'Messages[0].MessageAttributes' 

# 4. CLEAN UP — always.
aws events remove-targets --region $PRI --rule order-placed-rule --event-bus-name $BUS --ids manual-dlq-drill
aws sqs purge-queue --region $PRI --queue-url $DLQ_URL
```

**Good:** a message with `ERROR_MESSAGE` / `RULE_ARN` attributes appears. If you skip step 4,
the DLQ alarm will go to ALARM and a broken target stays on the rule.

---

## 6. Global endpoint — multi-region send, replication, failover

Needs the stack built with `ENABLE_GLOBAL_ENDPOINT=true`. Script:
`scripts/compliance/05-global-endpoint.sh` (sections 6a–6d; 6e–6f with `--failover --confirm`).

**Background in one paragraph.** The endpoint `eb-prod-endpoint` fronts the bus in both
regions. Producers send to it with an **`EndpointId`**; it routes to the **primary** region while a
Route 53 **health check** says the primary is healthy, and to the **secondary** when it is not.
**Replication** also copies events to the other region. Because the call uses **SigV4a**
(multi-region signing), the client needs the AWS Common Runtime — the AWS CLI v2 has it; a Lambda
producer must bundle `awscrt` (`docs/CICD_AND_OPERATIONS.md` §2).

### 6a. Endpoint configuration 🟢

```bash
aws events describe-endpoint --name eb-prod-endpoint --region $PRI \
  --query '{state:State,replication:ReplicationConfig.State,secondary:RoutingConfig.FailoverConfig.Secondary.Route,buses:EventBuses[].EventBusArn}'
```
**Good:** `state ACTIVE`, `replication ENABLED`, `secondary us-west-2`, two bus ARNs.

### 6b. Health check status 🟢

```bash
aws route53 get-health-check-status --health-check-id $HC_ID \
  --query 'HealthCheckObservations[].StatusReport.Status' --output text | tr '\t' '\n' | sort | uniq -c
#  16 Success: HTTP Status Code 200, OK. ...
```
**Good:** only `Success` lines. Any `Failure` means the primary is considered down — do not start
a failover drill until it is clean.

### 6c. Send through the endpoint 🟡

```bash
T=$(now_ms); OID="ge-$T"
aws events put-events --region $PRI --endpoint-id "$GE_ID" --entries "[{
  \"Source\":\"$EVENT_SOURCE\",\"DetailType\":\"OrderPlaced\",\"EventBusName\":\"$BUS\",
  \"Detail\":\"{\\\"orderId\\\":\\\"$OID\\\",\\\"quantity\\\":1,\\\"amount\\\":9.99}\"}]"
#  -> {"FailedEntryCount": 0, "Entries":[{"EventId":"..."}]}
```
Notes: `EventBusName` is the bus **name** (identical in both regions) — not the ARN. If you see
`MissingDependencyException: ... botocore[crt]` your client lacks CRT.

### 6d. Processed in the primary and replicated to the secondary 🟡

```bash
sleep 20
echo "primary:";   seen $PRI /aws/lambda/eb-prod-pri-consumer $T "$OID" && echo found
# Replication is asynchronous — be patient (up to ~2 minutes).
for i in $(seq 1 24); do sleep 5
  seen $SEC /aws/lambda/eb-prod-sec-consumer $T "$OID" && { echo "secondary: found after $((i*5))s"; break; }
done

# The replica keeps the ORIGINAL region in its envelope. Remember this value for 6e:
aws logs filter-log-events --region $SEC --log-group-name /aws/events/eb-prod-sec/audit \
  --start-time $T --filter-pattern "\"$OID\"" --query 'events[0].message' --output text | jq -r .region
#  -> us-east-1
```
**Good:** found in both regions, replica `region` = `us-east-1`. That last fact is how the script
tells a *replica* (region = primary) from an event *received natively* in the secondary during a
failover (region = `us-west-2`).

### 6e. Failover drill 🔴 MUTATING (changes the health Lambda; restore is mandatory)

**Proves:** when the primary is "down", events sent to the endpoint are received in the secondary.
We simulate the outage by making the health Lambda answer HTTP 503 (`HEALTHY=false`).
Expect **10–20 minutes** (health-check detection + AWS's documented 360–420 s RTO).

```bash
# 1. Record the current value (should be "true").
aws lambda get-function-configuration --region $PRI --function-name eb-prod-health \
  --query 'Environment.Variables' --output json

# 2. Simulate the outage.
aws lambda update-function-configuration --region $PRI --function-name eb-prod-health \
  --environment 'Variables={HEALTHY=false}'
aws lambda wait function-updated --region $PRI --function-name eb-prod-health

# 3. Wait for Route 53 to notice (poll every 30 s until you see Failure lines).
watch -n 30 "aws route53 get-health-check-status --health-check-id $HC_ID \
  --query 'HealthCheckObservations[].StatusReport.Status' --output text | tr '\t' '\n' | cut -c1-12 | sort | uniq -c"

# 4. Keep sending through the endpoint (each call is a fresh CLI process = a COLD client;
#    a long-running warm client caches DNS and hides the failover).
T=$(now_ms); OID="ge-fo-$T"
aws events put-events --region $PRI --endpoint-id "$GE_ID" --entries "[{\"Source\":\"$EVENT_SOURCE\",
  \"DetailType\":\"OrderPlaced\",\"EventBusName\":\"$BUS\",
  \"Detail\":\"{\\\"orderId\\\":\\\"$OID\\\",\\\"quantity\\\":1,\\\"amount\\\":1}\"}]"
sleep 30
aws logs filter-log-events --region $SEC --log-group-name /aws/events/eb-prod-sec/audit \
  --start-time $T --filter-pattern "\"$OID\"" --query 'events[0].message' --output text | jq -r .region
#  -> us-west-2   means it was RECEIVED in the secondary (failover worked)
#  -> us-east-1   means it is only a replica (not failed over yet): wait and repeat step 4
```

### 6f. Fail back (MANDATORY after 6e) 🔴

```bash
aws lambda update-function-configuration --region $PRI --function-name eb-prod-health \
  --environment 'Variables={HEALTHY=true}'
aws lambda wait function-updated --region $PRI --function-name eb-prod-health
# Wait until every observation says "Success" again (a few minutes), then re-run 6b.
```
If you forget, the primary stays "unhealthy" and **all endpoint traffic goes to the secondary**.

---

## 7. Archive and replay 🟢 / 🔴

**Proves:** past events can be re-injected (recovery, audit, bug-fix reprocessing). Controls EVB-11/HA-12.

```bash
# 🟢 The archive exists (7-day retention in this lab)
aws events list-archives --region $PRI \
  --event-source-arn arn:aws:events:$PRI:$ACCOUNT:event-bus/$BUS \
  --query 'Archives[].[ArchiveName,State,RetentionDays,EventCount]' --output text

# 🔴 Replay the last 15 minutes back onto the bus. This RE-DELIVERS those events to the
#    consumer (duplicates!) — safe only because the consumer tolerates repeats (section 4).
ARC=arn:aws:events:$PRI:$ACCOUNT:archive/eb-prod-pri-archive
aws events start-replay --region $PRI --replay-name manual-replay-$(date +%s) \
  --event-source-arn "$ARC" \
  --event-start-time "$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --event-end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --destination "{\"Arn\":\"arn:aws:events:$PRI:$ACCOUNT:event-bus/$BUS\"}"

aws events list-replays --region $PRI --query 'Replays[].[ReplayName,State]' --output text   # → COMPLETED
```
An empty window is normal (state `COMPLETED` with 0 events) — run section 2 first so there is
something to replay. Archived events are only those matching the archive pattern (`source = prod.orders`).

---

## 8. Security posture 🟢

```bash
# 8a. Bus resource policy. "None" = no policy: only this account can publish.
aws events describe-event-bus --name $BUS --region $PRI --query Policy --output text
#     Lab finding: None  → AWS Security Hub EventBridge.3 / control EVB-05 FAIL until
#     trusted_account_ids / organization_id are set (docs/CROSS_ACCOUNT_SHARING.md).

# 8b. Bus is encrypted with the customer-managed key, and rotation is on
KEY=$(aws events describe-event-bus --name $BUS --region $PRI --query KmsKeyIdentifier --output text)
aws kms get-key-rotation-status --region $PRI --key-id "$KEY" --query KeyRotationEnabled   # true

# 8c. Key policy: look for a confused-deputy condition (aws:SourceArn / SourceAccount)
aws kms get-key-policy --region $PRI --key-id "$KEY" --policy-name default --output text | jq .
#     Lab finding: the EventBridge statement lacks it (AWS-KMS-CONFUSED-DEPUTY FAIL).

# 8d. Least privilege: what can the producer role do?
aws iam list-role-policies --role-name eb-prod-pri-producer --query PolicyNames --output text
aws iam get-role-policy --role-name eb-prod-pri-producer --policy-name <name-from-above> \
  --query PolicyDocument --output json
#     PutEvents should be limited to the bus ARN (the lab does this), not "*".
```

Full automated scan with verdicts: `scripts/compliance/01-static-posture.sh primary|secondary`.

---

## 9. Observability 🟢

```bash
# CloudWatch alarms for this region (all should be OK on a healthy stack)
aws cloudwatch describe-alarms --region $PRI --alarm-name-prefix eb-prod-pri \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output text

# Rule metrics: how many events matched / were delivered / failed in the last hour
aws cloudwatch get-metric-statistics --region $PRI --namespace AWS/Events \
  --metric-name MatchedEvents --dimensions Name=RuleName,Value=order-placed-rule Name=EventBusName,Value=$BUS \
  --start-time "$(date -u -d '1 hour ago' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 3600 --statistics Sum --query 'Datapoints[0].Sum'

# Dashboard
aws cloudwatch get-dashboard --region $PRI --dashboard-name eb-prod-pri-us-east-1-platform --query DashboardName
```

---

## 10. Producer limits (batching and partial failure) 🟡

**Proves/finds:** how the producer behaves above the 100-entries-per-`PutEvents` limit.
`compliance/01` currently reports `AWS-BATCH-LIMITS UNKNOWN` and `AWS-PUTEVENTS-PARTIAL FAIL`
(the producer detects failed entries but does not retry them).

```bash
aws lambda invoke --region $PRI --function-name eb-prod-pri-producer \
  --payload '{"count":150}' --cli-binary-format raw-in-base64-out /tmp/big.json >/dev/null
cat /tmp/big.json     # look at published vs failed; an error here confirms there is no chunking
```

---

## 11. Reading the results

| Observation | Meaning |
|---|---|
| `FailedEntryCount: 0` from `put-events` | The bus **accepted** the event. It does not mean any target succeeded — check the logs. |
| Event accepted but nothing in logs | No rule matched (wrong `Source`/`DetailType`) or the target failed — check the DLQ. |
| `AccessDeniedException` on `put-events` | Missing `events:PutEvents` on the bus (or, with a CMK, missing KMS rights). |
| `MissingDependencyException ... crt` | Using `--endpoint-id` from a client without the AWS Common Runtime. |
| Replica visible in the secondary but not "native" | Replication works; failover has not happened (see 6e step 4). |

## 12. Cleanup checklist

- 5b: `manual-dlq-drill` target removed, DLQ purged.
- 6e/6f: `eb-prod-health` has `HEALTHY=true` (`aws lambda get-function-configuration ... --query Environment.Variables`).
- 7: replays finished.
- Finally tear the stack down with `scripts/destroy-prod.sh` — it ends with `scripts/leftover-check.sh`, which must report clean (KMS keys in *pending deletion* are expected for 7–30 days).
