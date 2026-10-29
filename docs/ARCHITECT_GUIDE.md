# EventBridge Reference Lab — System Architect Guide

Audience: engineers who need to understand **how this lab is built**, why each
piece exists, and how to extend or operate it safely.

---

## 1. What this lab proves

Amazon EventBridge is a **serverless event bus**: producers publish events, and
EventBridge routes them to targets using **content-based rules** — no
point-to-point coupling between producer and consumer. This lab stands up a
minimal-but-complete slice that exercises every critical EventBridge capability:

| EventBridge capability | How the lab proves it |
| --- | --- |
| Custom event bus | `eb-lab-orders` bus, created by the module |
| Content-based routing | A rule matches `source=lab.orders` + `detail-type=OrderPlaced` |
| Multiple target types (fan-out) | One rule → **3 targets**: Lambda, SNS, CloudWatch Logs |
| Reliable delivery / failure handling | Target has a **retry policy** + **SQS dead-letter queue** |
| Event archive & replay | An **archive** captures all bus events for replay |
| Scheduled event production | An **EventBridge Scheduler** schedule (opt-in) invokes the producer |
| Producer / consumer app | Two **Lambda** functions publish and process events |

---

## 2. Architecture

```
                         (opt-in: enable_schedule=true)
   [EventBridge Scheduler] --rate/cron--> invokes
            |
            v
   +--------------------+     put_events      +----------------------+
   |  Producer Lambda   | ------------------> |  Custom Event Bus    |
   |  eb-lab-producer   |                     |  eb-lab-orders       |
   +--------------------+                     +----------+-----------+
        ^  (also invoked on demand                       |
         by scripts/test.sh)                             | rule: order_placed
                                                         | pattern:
                                                         |  source=lab.orders
                                                         |  detail-type=OrderPlaced
                          +------------------------------+------------------------------+
                          |                              |                              |
                          v                              v                              v
              +----------------------+       +----------------------+       +----------------------+
              |  Consumer Lambda     |       |  SNS Topic           |       |  CloudWatch Logs     |
              |  eb-lab-consumer     |       |  eb-lab-notifications|       |  /aws/events/eb-lab  |
              |  (business logic)    |       |  (fan-out/notify)    |       |  (audit trail)       |
              +----------+-----------+       +----------------------+       +----------------------+
                         | on failure/retry-exhausted
                         v
              +----------------------+          +----------------------+
              |  SQS DLQ             |          |  EventBridge Archive |
              |  eb-lab-dlq          |          |  eb-lab-archive      |
              +----------------------+          |  (replayable store)  |
                                                +----------------------+
```

Every arrow is a real EventBridge feature. The rule fans a single event out to
three target types simultaneously; the Lambda target additionally has a retry
policy and a DLQ so failed invocations are not lost.

---

## 3. Terraform layering — why two layers

The code is split into two independently-applied layers with a clear trust
boundary.

### Layer 0 — `bootstrap/` (run ONCE by the privileged operator, `cloud_user`)

Creates the things the app layer *depends on* but should not manage itself:

- **S3 state bucket** (`eventbridge-lab-tfstate-<account>-<region>`), versioned +
  encrypted + public-access-blocked. Detects an existing bucket
  (`state_bucket_name`) to **reuse**, or creates a new one.
- **S3-native state locking** (`use_lockfile = true`). Requires AWS provider
  `>= 6.28` — which the EventBridge module v4.3.2 already mandates — so **no
  DynamoDB lock table is needed**.
- A **dedicated least-privilege IAM user**, `eventbridge-lab-deployer`, with an
  access key and a policy scoped to exactly the services the app touches.

Its own state is kept **locally** and mirrored to S3 (you cannot store a
backend's state inside the very bucket the same apply is creating).

### Layer 1 — `app/` (run by `eventbridge-lab-deployer`, NEVER `cloud_user`)

The EventBridge stack itself, using an **S3 remote backend** whose config is
rendered from the bootstrap outputs at `init` time (`-backend-config`).

**Why the separation matters**

- `cloud_user` is only ever used to mint the deployer and the state backend. All
  application create/destroy runs as the scoped deployer user — the explicit
  requirement of this lab.
- Clean teardown is deterministic: destroy **app first** (deployer), then
  **bootstrap** (operator). Because app state lives in the bootstrap-owned
  bucket, this ordering never orphans a resource.

### The deployer's permissions (least privilege)

`bootstrap/main.tf` → `data.aws_iam_policy_document.deployer` grants:

- S3 read/write to the **state bucket + objects** (incl. the native lock object).
- `events:*`, `scheduler:*`, `schemas:*` — EventBridge itself.
- `lambda:*`, `sqs:*`, `sns:*`, `logs:*`, `cloudwatch:*` — the demo targets.
- IAM **role** and **policy** actions only (create/tag/attach/pass service roles
  the modules build). No IAM user/group/account-admin rights.

---

## 4. Modules used (all from `terraform-aws-modules`)

| Module | Version | Purpose |
| --- | --- | --- |
| `eventbridge/aws` | **4.3.2** (pinned per requirement) | bus, rule, targets, archive, scheduler, target IAM |
| `lambda/aws` | `~> 7.20` | producer + consumer functions and their exec roles/log groups |
| `sqs/aws` | `~> 4.2` | dead-letter queue |
| `sns/aws` | `~> 6.1` | fan-out topic |

The EventBridge module v4.3.2 requires **AWS provider `>= 6.28`**; both layers
pin `hashicorp/aws >= 6.28` (resolves to 6.x) accordingly.

---

## 5. State & backend flow

```
bootstrap apply (local state)
  └─ outputs: state_bucket_name, deployer creds, app_backend_config
       │
       ├─ create.sh writes .runtime/deployer.aws-credentials  (mode 600, gitignored)
       └─ create.sh renders .runtime/backend.hcl:
              bucket=<state bucket>  key=eventbridge-lab/app/terraform.tfstate
              region=<region>  profile=eventbridge-lab-deployer  use_lockfile=true

app init -backend-config=.runtime/backend.hcl   → state in S3, locked natively
app apply (as deployer)                         → EventBridge stack
```

**Reusing an existing state bucket:** set `STATE_BUCKET_NAME=<your-bucket>` before
`create.sh`. The bootstrap treats it as data (never creates/destroys it), and the
app backend points at it.

---

## 6. Verification (linting + tests as build output)

`scripts/verify.sh` runs, per layer, in sequence and prints a PASS/FAIL matrix:

1. `terraform fmt -check` — style
2. `terraform init -backend=false` — module + provider resolution
3. `terraform validate` — configuration correctness
4. `tflint` — lint rules (auto-installed to `.bin/` if absent)

`create.sh` runs `verify.sh` as **step 0**, then `plan` before `apply` (the plan
is saved to `.runtime/app.plan`). `test.sh` is the **functional** proof: it
invokes the producer and confirms — via CloudWatch Logs — that the rule routed
the event to the consumer and the audit target. Both scripts emit PASS/FAIL to
stdout with diagnostics on stderr, so `$(...)` capture stays clean.

---

## 7. Free-tier / sandbox safety

This lab targets the **Pluralsight AWS sandbox** and stays inside its rules:

- **Region-locked** to `us-east-1` / `us-west-2` (a Terraform variable
  `validation` block rejects anything else).
- **Lambda:** 2 functions (sandbox cap 10), **128 MB** each (cap 2048 MB), so
  invocations sit firmly in the always-free tier.
- **EventBridge, SQS, SNS, CloudWatch, S3, IAM:** all "Supported" in the sandbox
  and used at 1–2 objects each — far under any free-tier threshold.
- **No unattended cost:** the recurring Scheduler is **OFF by default**
  (`enable_schedule = false`). Nothing runs on a timer unless you opt in; the
  demo produces events on demand via `test.sh`.
- **Short log retention** (7 days) and **short archive retention** (3 days) cap
  stored-data growth.

See `docs/FREE_TIER.md` for the full service-by-service assessment.

---

## 8. Extending the lab

- **Add a target type** (e.g. Step Functions, Kinesis): add it to the `targets`
  map in `app/main.tf` and flip the matching `attach_*_policy` / `*_target_arns`
  input on the EventBridge module.
- **Add a second rule / pattern:** add a key to `rules` and a matching key to
  `targets`.
- **API destinations / connections / pipes:** the v4.3.2 module supports
  `create_connections`, `create_api_destinations`, and `pipes` — wire them the
  same way. Grant the deployer any extra actions in `bootstrap/main.tf`.
- **Replay from the archive:** `aws events start-replay` against
  `eb-lab-archive` re-drives archived events through the bus.
