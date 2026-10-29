# EventBridge Reference Lab — End-User Guide

Audience: anyone who wants to **stand up, try, and tear down** the EventBridge
lab without needing to understand the Terraform internals.

You will end up with a working Amazon EventBridge setup where a "producer"
publishes `OrderPlaced` events and a "consumer" processes them — and you can
watch it happen in CloudWatch Logs.

---

## Before you start

You need, on your machine:

- **Terraform** ≥ 1.5 (`terraform version`)
- **AWS CLI** configured with your sandbox's `default` profile
  (`aws sts get-caller-identity` should show your account)
- **jq** (`jq --version`)
- Internet access (Terraform downloads modules/providers the first time)

`tflint` is optional — the scripts install it automatically into `.bin/` if it
is missing.

> This lab is region-locked to **us-east-1** or **us-west-2** (sandbox rule).

---

## The three commands you need

All commands are run from the lab root (`eventbridge-lab/`).

### 1. Build everything

```bash
./scripts/create.sh
```

This will, in order:

1. Check the Terraform code (format, validate, lint) and print a PASS/FAIL table.
2. Create the state storage (an S3 bucket) and a **dedicated deployer user** —
   so your everyday `cloud_user` is not the one building the app.
3. Build the EventBridge bus, the producer and consumer functions, and the
   supporting queue, topic, logs and archive.
4. Print the names/ARNs of everything it created.

Takes ~1–2 minutes. Safe to re-run (it only applies differences).

### 2. Prove it works

```bash
./scripts/test.sh
```

This invokes the producer to publish 5 events, then checks CloudWatch Logs to
confirm the consumer actually received and processed them. You should see:

```
PASS  custom event bus exists: eb-lab-orders
PASS  rule exists on bus
PASS  producer lambda exists: eb-lab-producer
PASS  consumer lambda exists: eb-lab-consumer
PASS  DLQ exists
PASS  SNS topic exists
PASS  producer published 5 events
PASS  consumer processed a routed event (rule -> lambda works)
PASS  audit CloudWatch Logs target received the event
[ OK ] ALL FUNCTIONAL TESTS PASSED
```

### 3. Tear everything down

```bash
./scripts/destroy.sh
```

Removes **all** lab resources in the correct order and leaves your account
clean — including the state bucket and the deployer user. Local secrets are
scrubbed.

### Bonus: rebuild from scratch

```bash
./scripts/rebuild.sh   # = destroy, then create
```

---

## Trying it yourself (manual poke)

After `create.sh`, publish events by hand and watch them flow:

```bash
# Point the CLI at the deployer profile the lab created:
export AWS_SHARED_CREDENTIALS_FILE="$PWD/.runtime/deployer.aws-credentials"
P=(--profile eventbridge-lab-deployer --region us-east-1)

# 1. Produce 3 events:
aws lambda invoke --function-name eb-lab-producer \
  --payload '{"count":3}' "${P[@]}" /tmp/out.json && cat /tmp/out.json

# 2. Watch the consumer process them:
aws logs tail /aws/lambda/eb-lab-consumer --since 2m --follow "${P[@]}"

# 3. See the audit trail of matched events:
aws logs tail /aws/events/eb-lab/audit --since 5m "${P[@]}"
```

You will see the consumer log lines like
`{"level":"INFO","msg":"processed order","orderId":"...","lineTotal":123.45}`.

---

## What each piece is (in plain terms)

| Thing | Plain-English role |
| --- | --- |
| **Event bus** (`eb-lab-orders`) | The "post office" that receives events |
| **Rule** (`order_placed`) | The sorting rule: "send OrderPlaced events to these boxes" |
| **Producer** (`eb-lab-producer`) | Writes the letters (events) and drops them in |
| **Consumer** (`eb-lab-consumer`) | Opens each letter and acts on it |
| **SNS topic** | A mailing list — anyone subscribed gets a copy |
| **CloudWatch Logs (audit)** | A photocopy of every letter, kept for the record |
| **SQS DLQ** | The "returned mail" bin for anything that couldn't be delivered |
| **Archive** | A filing cabinet you can replay letters from later |

---

## Turning on the timer (optional)

By default nothing runs on a schedule — so a lab account stays quiet and free.
If you want EventBridge to invoke the producer automatically:

```bash
export AWS_SHARED_CREDENTIALS_FILE="$PWD/.runtime/deployer.aws-credentials"
terraform -chdir=app apply \
  -var enable_schedule=true \
  -var 'schedule_expression=rate(1 hour)' \
  -var deployer_profile=eventbridge-lab-deployer
```

Turn it back off by re-applying with `-var enable_schedule=false` (or just run
`./scripts/destroy.sh`).

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `AWS profile 'default' is not configured` | Run `aws configure` / `aws sso login`, confirm `aws sts get-caller-identity` works |
| A `403 AccessDenied` during create | Your sandbox may restrict a service; check `docs/FREE_TIER.md`. Re-run `create.sh` (it resumes) |
| `test.sh` says "no 'processed order' log" | Wait a few seconds and re-run — first-run cold starts can exceed the poll window |
| Want to reuse an existing state bucket | `STATE_BUCKET_NAME=my-bucket ./scripts/create.sh` |
