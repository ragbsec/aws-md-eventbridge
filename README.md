# AWS EventBridge Reference Lab (Terraform)

A complete, reproducible **Amazon EventBridge** reference lab built with the
official `terraform-aws-modules/eventbridge/aws` **v4.3.2** module (plus the
`lambda`, `sqs`, and `sns` modules from the same namespace). It proves every
critical EventBridge function end to end — custom bus, content-based routing,
multi-target fan-out, dead-letter handling, archive/replay, and scheduling — with
a real producer/consumer application, and it can **create, destroy, and rebuild
from scratch** on command.

## Highlights

- **Runs as a dedicated IAM user, not `cloud_user`.** A one-time bootstrap
  (run by `cloud_user`) mints a scoped `eventbridge-lab-deployer` user; all app
  create/destroy runs as that user.
- **Remote state on S3** with **S3-native locking** (no DynamoDB). Reuses an
  existing state bucket if you have one, otherwise creates a fresh, secured one.
- **Clean, ordered teardown** — app first, then bootstrap — so destroy leaves
  **zero orphans** (verified).
- **Lint + validate + functional tests as build output** at every step.
- **Free-tier / sandbox safe** — region-locked, 128 MB Lambdas, and nothing runs
  unattended (recurring schedule is opt-in).

## Layout

```
eventbridge-lab/
├── bootstrap/          # Layer 0: S3 state bucket + deployer IAM user (run by cloud_user)
├── app/                # Layer 1: EventBridge stack (run by the deployer user)
│   └── lambda/
│       ├── producer/   # publishes OrderPlaced events
│       └── consumer/   # processes routed events
├── scripts/
│   ├── create.sh       # verify -> bootstrap -> app apply
│   ├── test.sh         # end-to-end functional proof
│   ├── destroy.sh      # clean teardown (app -> bootstrap)
│   ├── rebuild.sh      # destroy + create
│   └── verify.sh       # fmt + validate + tflint (PASS/FAIL matrix)
└── docs/
    ├── ARCHITECT_GUIDE.md   # how it's built and why
    ├── ENDUSER_GUIDE.md     # how to run it
    └── FREE_TIER.md         # sandbox/free-tier assessment
```

## Quick start

```bash
cd eventbridge-lab
./scripts/create.sh     # build it
./scripts/test.sh       # prove it works
./scripts/destroy.sh    # tear it down clean
```

Reuse an existing state bucket instead of creating one:

```bash
STATE_BUCKET_NAME=my-existing-tfstate-bucket ./scripts/create.sh
```

## Requirements

- Terraform ≥ 1.5, AWS CLI (configured `default` profile), `jq`
- AWS provider **≥ 6.28** (required by the EventBridge module v4.3.2; pinned)
- Region: **us-east-1** or **us-west-2** only (sandbox rule)

## Production capabilities (multi-region)

Beyond the single-region `app/` lab above, the repo includes a **production-grade,
multi-region** build split into independently-applied layers:

```
platform-primary/    # primary-region bus, rules, archive, KMS primary key, monitoring, Access Analyzer
platform-secondary/  # secondary-region bus, rules, archive, KMS replica, monitoring
platform-global/     # global endpoint + Route 53 health check + replication role (reads both regions)
application/     # producer/consumer Lambdas, DLQ + consumer-failure queue, SNS, rule targets (reads platform state)
modules/
  eventbridge-platform/   # reusable platform building block
  event-application/      # reusable application building block
scripts/
  create-prod.sh / test-prod.sh / destroy-prod.sh / verify-prod.sh
```

Capabilities added for production use:
- **Multi-region** (primary + secondary) with a **global endpoint + Route 53 health
  check** for automatic regional failover (`enable_global_endpoint`).
- **Security**: multi-region KMS CMK (rotation on) encrypting bus/archive/SQS/SNS/logs;
  TLS-deny resource policies; least-privilege IAM.
- **Monitoring**: CloudWatch alarms (failed invocations, throttles, DLQ depth) → SNS,
  optional email subscription (`alert_email`), per-region dashboards.
- **Cross-account / org sharing** — publish-in (`trusted_account_ids`/`organization_id`)
  and consume-out (`forward_to_bus_arns`). Fully opt-in.
- **CI/CD**: GitLab pipeline with OIDC deploy identity (no static keys), manual-gated
  applies. Assumed-role deploy path also available.

```bash
# production multi-region deploy
SECONDARY_REGION=us-east-2 ENABLE_GLOBAL_ENDPOINT=true \
  HEALTH_CHECK_DOMAIN=health.example.com ./scripts/create-prod.sh
```

## Documentation (start here for handover)

| Audience / topic | Doc |
| --- | --- |
| **New to the repo — read first** | [`docs/FOLDER_STRUCTURE.md`](docs/FOLDER_STRUCTURE.md) |
| Architecture, security, monitoring (multi-region) | [`docs/PRODUCTION_ARCHITECTURE.md`](docs/PRODUCTION_ARCHITECTURE.md) |
| System architects (base lab) | [`docs/ARCHITECT_GUIDE.md`](docs/ARCHITECT_GUIDE.md) |
| End users / how to run | [`docs/ENDUSER_GUIDE.md`](docs/ENDUSER_GUIDE.md) |
| **Cross-account / org bus sharing** | [`docs/CROSS_ACCOUNT_SHARING.md`](docs/CROSS_ACCOUNT_SHARING.md) |
| **CI/CD, OIDC, global-endpoint gotchas, ops** | [`docs/CICD_AND_OPERATIONS.md`](docs/CICD_AND_OPERATIONS.md) |
| **Security model + per-app onboarding contract** | [`docs/SECURITY_AND_ONBOARDING.md`](docs/SECURITY_AND_ONBOARDING.md) |
| **Event schema onboarding (multi-team)** | [`docs/SCHEMA_ONBOARDING.md`](docs/SCHEMA_ONBOARDING.md) |
| Pre-deploy account preflight (AI prompt) | [`docs/PREDEPLOY_PREFLIGHT_PROMPT.md`](docs/PREDEPLOY_PREFLIGHT_PROMPT.md) |
| TLS / cipher posture | [`docs/TLS_POLICY.md`](docs/TLS_POLICY.md) |
| Free-tier / sandbox safety | [`docs/FREE_TIER.md`](docs/FREE_TIER.md) |

> **Before enabling the global endpoint**, read §2 of `docs/CICD_AND_OPERATIONS.md`
> — the producer requires the `awscrt` library (SigV4a) or it fails with
> `MissingDependencyException`. This is the most common handover trap.

## Modules

| Module | Version |
| --- | --- |
| `terraform-aws-modules/eventbridge/aws` | 4.3.2 |
| `terraform-aws-modules/lambda/aws` | ~> 7.20 |
| `terraform-aws-modules/sqs/aws` | ~> 4.2 |
| `terraform-aws-modules/sns/aws` | ~> 6.1 |
