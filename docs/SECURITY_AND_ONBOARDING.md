# EventBridge Security & Per-App Onboarding Contract

How the shared EventBridge platform stays secure, and the **security checklist
every app team must pass to onboard**. Grounded in AWS's EventBridge
data-protection, IAM, and KMS best-practice guidance (see Sources).

Security here is two layers: what the **platform enforces for everyone**
(automatic), and the **app-team responsibility** (shared-responsibility model).

---

## 1. Platform-enforced controls (automatic, every app)

| Control | Mechanism | Where |
|---|---|---|
| Encryption at rest | Multi-region customer-managed KMS CMK encrypts bus, archive, SQS, SNS, logs | `platform-primary`/`platform-secondary` KMS + module |
| Encryption in transit | TLS-deny resource policies (`aws:SecureTransport`, `s3:TlsVersion>=1.2`); EventBridge API is AWS-managed TLS>=1.2 | module + bootstrap |
| No static deploy creds | GitLab OIDC / assumed-role deploy identity | `bootstrap/gitlab_oidc.tf`, `deployer_role.tf` |
| Least-privilege deployer | Scoped to needed services; no account-admin | `bootstrap/main.tf` |
| Blast-radius isolation | Dedicated custom bus (not the default bus) | module |
| Contract enforcement | CI rejects events violating the registered schema | `.gitlab-ci.yml` contract-test |
| **Dual dead-letter (delivery + processing)** | EventBridge target DLQ catches undeliverable events; a separate per-consumer failure queue + Lambda `on_failure` catches events whose handler THROWS — neither class is silently dropped | `modules/event-application` |
| **Cross-account KMS scoping** | Trusted accounts/org may use the CMK ONLY via EventBridge (`kms:ViaService` condition), not arbitrary KMS ops | `platform-primary`/`platform-secondary` main.tf |

---

## 2. Per-app onboarding security checklist (the contract)

Each team's PR must satisfy ALL of these before it merges:

### a. Least-privilege producer IAM
- `events:PutEvents` scoped to the **specific bus ARN**, never `events:*` or `Resource:"*"`.
- KMS only if the producer builds the payload client-side; scoped to the bus CMK.
- ✅ The reference producer (`modules/event-application`) models this exactly — copy it.

### b. Least-privilege consumer / target IAM
- A rule-target role may invoke only that team's function/queue — no other app's target.
- No wildcard target ARNs.

### c. Rule pattern scoping (tenant isolation)
- A team's rule matches ONLY its own `source` + `detail-type`. This prevents one
  team's rule from siphoning another team's events off the shared bus.

### d. Schema contract registered
- A JSON Schema in `schemas/<source>__<DetailType>.json` + samples (see
  `docs/SCHEMA_ONBOARDING.md`). CI validates events against it.

### e. No sensitive data in events, tags, or free-form fields
- AWS WARNS: data in tags/free-form fields can surface in billing & diagnostic logs.
- Events carry **references/IDs**, never secrets, tokens, PII, or card data.
- If a payload field is sensitive, pass a reference and resolve it in the consumer
  against a secured store — do not put the value on the bus.

### f. Dead-letter + retry on every target — BOTH failure classes

There are two distinct failure points on the `rule → consumer` path, with two
different safety nets. A consumer must have BOTH, or events are lost silently:

| Failure | What failed | Caught by | Config |
|---|---|---|---|
| **Delivery** | EventBridge could not hand the event to the target (throttle, target gone, permission) | EventBridge **target DLQ** | `dead_letter_config` + `retry_policy` on the rule target |
| **Processing** | The target WAS invoked but the handler **threw** (bug, bad data, downstream outage) | the consumer's **own Lambda `on_failure` destination** (a separate failure queue) | `aws_lambda_function_event_invoke_config` |

- The target DLQ does **NOT** catch a handler that throws — that is a Lambda
  async-invocation failure. Without an `on_failure` destination the Lambda retries
  on its defaults and then **drops the event silently** (verified live).
- The reference `modules/event-application` wires BOTH by default
  (`enable_consumer_on_failure = true`): a dedicated `<prefix>-consumer-failures`
  queue (KMS-encrypted, TLS-enforced) receives the failed event **with its error
  metadata** (`condition: RetriesExhausted`, `errorType`, the original payload),
  and a CloudWatch alarm on that queue publishes to the alerting topic.
- Turn `enable_consumer_on_failure` off ONLY for a genuinely fire-and-forget
  consumer where a dropped event is acceptable — and say so in the PR.
- Both queues retain 14 days, so a failed event is **replayable** once the bug is fixed.

### g. Cross-account teams
- The team's AWS account is allow-listed (`trusted_account_ids` / `organization_id`),
  and their KMS use is auto-restricted to EventBridge via `kms:ViaService`.
- The remote side grants only `events:PutEvents` to the shared bus ARN.

---

## 3. Enforcement — how these are actually checked

- **CI gates (automatic):** `terraform validate` + `tflint` (IAM shape), and the
  `contract-test` stage (schema). A PR that violates the schema fails.
- **PR review (human):** the reviewer checks a-c and e-f against this checklist —
  these are judgement calls tflint cannot fully make (e.g. "is this field sensitive?",
  or "is this consumer genuinely fire-and-forget, or did the team disable the
  processing-failure queue by mistake?").
- **Preflight (pre-deploy):** `docs/PREDEPLOY_PREFLIGHT_PROMPT.md` audits the target
  account's IAM/KMS/SCP posture before any apply.
- **Detective (recommended, not yet built):** enable CloudTrail on `events:PutEvents`
  and `kms:Decrypt`, and an AWS Config / IAM Access Analyzer rule to flag any bus
  policy or producer role that grants `*`. See "Future hardening" below.

### Detective control: IAM Access Analyzer (built, flag-gated)

The platform owner can turn on IAM Access Analyzer from the `platform-primary`
root. It
is account/region-scoped so it is created ONCE in the primary region. Two
independent toggles:

| Flag | Analyzer | Catches |
|---|---|---|
| `enable_access_analyzer_external` | External access | Any resource policy (EventBridge bus, SQS, SNS, KMS, IAM roles) granting access OUTSIDE the account/org — e.g. an over-broad cross-account bus policy |
| `enable_access_analyzer_unused` | Unused access | IAM roles/permissions unused for `access_analyzer_unused_age_days` (default 90) — e.g. a producer/consumer role granted more than it uses |

```bash
terraform -chdir=platform-primary apply \
  -var enable_access_analyzer_external=true \
  -var enable_access_analyzer_unused=true \
  -var access_analyzer_org_scope=false        # true needs Org mgmt/delegated-admin account
```

Findings are emitted as EventBridge events (`detail-type` "... Finding ..."), so
they can be routed to the alerting topic or a dedicated security bus for triage.
This is the automated backstop for checklist items (a)–(c): if a reviewer misses
an over-broad policy or role, the analyzer flags it after deploy.

---

## 4. Known gaps / future hardening (honest)

- **No automated least-privilege linter** for producer/consumer IAM yet — reviewer
  enforces it. A custom `tflint` ruleset or OPA/Conftest policy could gate it in CI.
  (IAM Access Analyzer, now wired, is the detective backstop that catches what the
  linter would — after deploy rather than in CI.)
- **Attribute-based access** (per-team tags + `aws:ResourceTag` conditions) not used;
  viable for finer isolation as team count grows.
- **Event-level encryption** (field-level) is not provided — the CMK encrypts the
  whole event at rest; sensitive fields should not be on the bus at all (see 2e).

---

## Sources (AWS docs)

- Data protection in Amazon EventBridge — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-data-protection.html
- Infrastructure security in EventBridge — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-infrastructure.html
- KMS key policy for EventBridge (ViaService condition) — https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-encryption-key-policy.html
- KMS key policy condition keys for connections — https://docs.aws.amazon.com/eventbridge/latest/userguide/encryption-connections.html
- IAM least-privilege policy best practices — https://docs.aws.amazon.com/scheduler/latest/UserGuide/security_iam_id-based-policy-examples.html
