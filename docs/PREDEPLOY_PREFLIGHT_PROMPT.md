# Pre-Deploy Account Preflight & Production-Readiness Prompt

Paste the prompt below into your AI agent **before every deploy into a new or
changed AWS account**. It inspects the *actual* target account (not assumptions),
runs an account-specific preflight, and reports every production gap — including
the known deviations this repo carries from a true production deployment — as a
**GO / NO-GO** decision with concrete fixes.

It is **read-only by default**: it must not create, modify, or destroy anything
until you explicitly approve the remediation plan it produces.

Repo roots it targets (apply order): `bootstrap/` → `platform-primary/` →
`platform-secondary/` → `platform-global/` → `application/`.
Deploy scripts: `scripts/create-prod.sh`, `scripts/verify-prod.sh`,
`scripts/test-prod.sh`, `scripts/destroy-prod.sh`.

---

## THE PROMPT (copy everything in this block)

```
ROLE
You are a senior AWS platform SRE doing a pre-deploy readiness review of the
EventBridge multi-region platform in this repo (roots: bootstrap/,
platform-primary/, platform-secondary/, platform-global/, application/). Do NOT
deploy, apply, or mutate anything. Produce a GO / NO-GO
report. Only after I approve your remediation plan may you make changes.

INPUTS I WILL GIVE YOU
- TARGET_PROFILE      = <aws profile / role to inspect the account with>
- PRIMARY_REGION      = <e.g. us-east-1>
- SECONDARY_REGION    = <e.g. us-east-2>
- ENV                 = <sandbox | staging | production>
- PUBLIC_HEALTH_DOMAIN= <public Route53 hosted-zone/domain for the global
                         endpoint health check, or "none">
- DEPLOY_IDENTITY     = <iam-user-access-key | assumed-role | github-oidc>
- ALERT_TARGETS       = <emails / PagerDuty / Opsgenie integration keys, or "none">

STEP 1 — IDENTITY & ACCOUNT INSPECTION (read-only)
  aws sts get-caller-identity --profile $TARGET_PROFILE
  Confirm: account id, that the principal is NOT a root/shared sandbox user
  (e.g. cloud_user) for a production deploy, and that it can assume the intended
  deploy identity. Record account id + region(s).

STEP 2 — REGION & SERVICE AVAILABILITY
  For PRIMARY_REGION and SECONDARY_REGION, confirm EventBridge, Lambda, SQS, SNS,
  KMS, CloudWatch, Route53, and S3 are all available and not SCP/boundary-denied.
  If ENV=sandbox, warn that EventBridge Global Endpoints need public Route53
  health checks and that some regions (e.g. us-east-2) may be unavailable.

STEP 3 — QUOTAS & COST GUARDRAILS
  Check service quotas that this stack consumes against current usage:
  Lambda concurrent executions & function count, KMS CMKs, EventBridge buses/rules,
  CloudWatch alarms, SNS topics. Flag anything near a limit. For ENV=sandbox,
  assert free-tier posture (128MB Lambdas, no unattended schedule, short retention).

STEP 4 — DEPLOY IDENTITY POSTURE  (gap #2 & #3)
  Inspect how deploys authenticate.
    - iam-user-access-key: FLAG as NON-PRODUCTION. Long-lived static key. Require
      rotation evidence and a migration path.
    - assumed-role: verify trust policy, max session duration, external id.
    - github-oidc: verify the OIDC provider thumbprint, the role's trust policy
      (repo:ref conditions, no wildcard sub), and least-privilege permissions.
  For ENV=production, deploy identity MUST be assumed-role or github-oidc.
  Note: Pluralsight/sandbox accounts deny sts:AssumeRole for cloud_user, so a
  minted IAM user key is the only sandbox path — call this out explicitly.

STEP 5 — STATE BACKEND HARDENING  (gap #6)
  Inspect the Terraform state S3 bucket (from bootstrap/):
    - Versioning ENABLED (required — recover a clobbered state).
    - SSE with a CMK, not just SSE-S3.
    - Public access block = all true.
    - TLS-deny bucket policy present (aws:SecureTransport=false denied,
      s3:TlsVersion >= 1.2).
    - use_lockfile = true (S3-native locking; no DynamoDB on AWS provider 6.x).
    - For production: recommend Cross-Region Replication of the state bucket to
      SECONDARY_REGION, and MFA-delete / object-lock consideration.
  Report each as PRESENT / MISSING with the exact fix.

STEP 6 — SECURITY & TLS 1.2 + MODERN CIPHERS
  Verify (read-only, against live resources if deployed, else against the .tf):
    - KMS CMK is multi-region, rotation enabled; encrypts bus, archive, SQS, SNS,
      and all CloudWatch log groups.
    - TLS-deny resource policies on SQS, SNS, and the state bucket.
    - Any EventBridge API Destination / Connection uses HTTPS only (TLS >= 1.2).
    - No IAM wildcards on application roles; deployer policy scoped to needed
      iam:*Role*/*Policy*, kms, route53, events, lambda, sqs, sns, logs, s3.
  Note: EventBridge's own control/data-plane API is AWS-managed TLS >= 1.2 — the
  TLS policy levers that YOU own are API Destinations + any ALB/CloudFront front.

STEP 7 — GLOBAL ENDPOINT / FAILOVER READINESS  (gap #1)
  If ENABLE_GLOBAL_ENDPOINT would be true:
    - PUBLIC_HEALTH_DOMAIN must be a real public Route53 hosted zone with a
      reachable HTTPS /health endpoint. If "none", mark the global endpoint
      NO-GO and explain it can only be validated end-to-end with a real domain.
    - Same-named custom bus must exist in BOTH regions, event replication ON.
    - Producers must send EndpointId on PutEvents.
  Report whether live failover can actually be exercised in this account.

STEP 8 — OBSERVABILITY & ON-CALL WIRING  (gap #5)
  Verify alarms exist (FailedInvocations, throttles, DLQ depth) AND that the
  alerting SNS topic has a REAL subscription (email confirmed / PagerDuty /
  Opsgenie). An alarm with an unsubscribed topic = NO-GO for production.
  Confirm per-region CloudWatch dashboards exist.

STEP 9 — MATURITY GAPS (report, don't block)  (gap #4)
  Note absence of: EventBridge Schema Registry, cross-account event bus sharing,
  input transformers / enrichment (API destinations, Pipes enrichment). Flag as
  "add if your use case needs it" rather than a hard blocker.

STEP 10 — CI/CD GATING  (gap #2)
  Confirm whether plan/apply is gated behind PR review + pipeline (OIDC role),
  or run ad-hoc from a laptop. For production, ad-hoc apply = FLAG.

OUTPUT FORMAT
  1) Account snapshot: account id, regions, deploy identity, ENV.
  2) A table: Check | Status (PASS/WARN/FAIL) | Evidence | Fix.
  3) The gap list below, each marked ADDRESSED / OPEN / N-A-FOR-THIS-ENV:
       - Global endpoint exercised end-to-end
       - CI/CD pipeline with PR gating
       - Short-lived deploy identity (assumed-role / OIDC) vs static key
       - Schema registry / cross-account / input transformers
       - Alarm subscriptions / on-call wiring
       - State bucket versioning + cross-region replication
  4) Verdict: GO or NO-GO, with the minimum set of fixes required to reach GO.
  5) A proposed remediation plan (ordered, idempotent). STOP and wait for my
     approval before executing any of it.

RULES
  - Read-only until I approve. Use describe/list/get/sts only.
  - Never read raw credential files; reference identities by ARN/name.
  - Ground every claim in a command you ran or a file you read; say what you
    could not verify.
  - If a required input is missing, ask once, then proceed with stated assumptions.
```

---

## How the gaps map to the prompt steps

| Your gap | Covered by |
|---|---|
| Global endpoint OFF / not exercised | Step 7 |
| No CI/CD pipeline (PR + OIDC gating) | Steps 4, 10 |
| Static IAM user key vs assumed-role/OIDC | Steps 1, 4 |
| No schema registry / cross-account / transformers | Step 9 |
| Alarms route to SNS but no subscription | Step 8 |
| No state versioning / cross-region replication | Step 5 |

## Usage

1. Fill in the `INPUTS` block (profile, regions, env, domain, deploy identity, alert targets).
2. Run the prompt against the agent **before** `scripts/create-prod.sh`.
3. Act only on a **GO** verdict; for **NO-GO**, apply the remediation plan it returns, then re-run.
