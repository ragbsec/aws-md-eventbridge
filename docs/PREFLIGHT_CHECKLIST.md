# Pre-Flight — Deploying into a New AWS Account

Everything you must have, check, and decide **before** running
`scripts/create-prod.sh` in a fresh (or changed) AWS account. Work top to
bottom; do not start the deploy until every **REQUIRED** item passes.

> Two preflight docs, two jobs:
> - **This file** = a human do-this checklist with copy-paste commands.
> - [`PREDEPLOY_PREFLIGHT_PROMPT.md`](PREDEPLOY_PREFLIGHT_PROMPT.md) = an AI
>   agent prompt that inspects the live account read-only and returns a
>   GO/NO-GO. Run that for a production account; this file is the fast path.

---

## 1. Local tooling (REQUIRED)

The scripts call `require_tools terraform aws jq` and will hard-fail if any is
missing.

| Tool | Minimum | Check |
|---|---|---|
| Terraform | ≥ 1.5 | `terraform version` |
| AWS CLI v2 | current | `aws --version` |
| jq | any | `jq --version` |
| AWS provider | ≥ 6.28 (pinned) | resolved on `init`; needed by EventBridge module v4.3.2 |

`tflint` ships in the repo (`.bin/tflint`) and is used by `verify-prod.sh`; no
separate install needed.

---

## 2. AWS identity & profiles (REQUIRED)

The scripts use **two** profiles (overridable by env var):

| Role | Env var | Default | Who it is |
|---|---|---|---|
| Operator | `OPERATOR_PROFILE` | `default` | Privileged identity that runs **bootstrap only** (mints state bucket + deployer). |
| Deployer | `DEPLOYER_PROFILE` | `eventbridge-lab-deployer` | Least-privilege identity bootstrap creates; runs every other layer. **You do NOT create this — bootstrap does.** |

**Confirm the operator profile resolves to the RIGHT account before anything:**

```bash
aws sts get-caller-identity --profile "${OPERATOR_PROFILE:-default}"
```

- ✅ Verify the `Account` is the account you intend. *(Deploying into the wrong
  account is the single most common mistake — check every time.)*
- The operator needs permission to create: an S3 bucket + bucket policy, an IAM
  user + access key + inline policy, and (optionally) an IAM role / OIDC
  provider. Account-admin or equivalent is sufficient for bootstrap.
- For a **production** account the operator should be an assumed role or SSO
  identity, not a long-lived root/user key.

---

## 3. Region rules (REQUIRED)

- Sandbox rule: **us-east-1 or us-west-2 only.** Defaults are
  `PRIMARY_REGION=us-east-1`, `SECONDARY_REGION=us-west-2`.
- The **state bucket lives in `PRIMARY_REGION`**; both regional roots read it
  from there.
- For real production, AWS recommends `SECONDARY_REGION=us-east-2`. Confirm
  EventBridge, Lambda, SQS, SNS, KMS, CloudWatch, Route 53 and S3 are all
  available and not SCP-denied in **both** regions.

---

## 4. Decisions to make before you run (REQUIRED)

Set these as environment variables (all have defaults):

| Variable | Default | Decide |
|---|---|---|
| `PRIMARY_REGION` | `us-east-1` | primary region |
| `SECONDARY_REGION` | `us-west-2` | failover region |
| `NAME_PREFIX` | `eb-prod` | resource name prefix |
| `BUS_NAME` | `eb-prod-orders` | custom bus name (same in both regions) |
| `ENABLE_GLOBAL_ENDPOINT` | `false` | **off** = no global endpoint / Route 53 health check (cheapest, proves regional stacks). **on** = full failover path. |
| `STATE_BUCKET_NAME` | *(empty → auto-create)* | set to **reuse** an existing state bucket; leave empty to create a new secured one |

### If `ENABLE_GLOBAL_ENDPOINT=true` — extra REQUIRED reading & inputs
- **Read [`CICD_AND_OPERATIONS.md`](CICD_AND_OPERATIONS.md) §2 first** — the
  producer needs the `awscrt` (SigV4a) library or it fails with
  `MissingDependencyException`. **This is the most common handover trap.**
- A public Route 53 hosted zone / reachable HTTPS health endpoint is needed to
  exercise failover end-to-end. Without one the endpoint deploys but failover
  cannot be truly validated.
- The Route 53 health check is the one **meaningfully-billed** item — be sure
  you want it, and run `destroy-prod.sh` after to stop it.

---

## 5. SCP / permission boundary gotchas (CHECK)

Sandbox and org accounts often deny things an identity policy appears to allow:

- Some sandboxes **deny `sts:AssumeRole` for `cloud_user`** → the minted static
  IAM-user key is then the only deploy path (leave `enable_deployer_role=false`).
  Others allow it. Verify per account; don't assume.
- SCPs can deny specific IAM reads/writes even with `iam:*` granted. If a call
  is denied despite an apparent grant, suspect an SCP.
- `servicequotas:GetServiceQuota` may be denied on the deployer — a known gap
  that leaves quota-parity checks UNKNOWN (not fatal).

---

## 6. Cost & quota posture (CHECK)

- Sandbox/free-tier safe by design: 128 MB Lambdas, short retention, no
  unattended schedule unless opted in.
- The only meaningfully-billed resources: **2 KMS CMKs** (~pennies prorated) and
  the **Route 53 health check** (only when `ENABLE_GLOBAL_ENDPOINT=true`).
- KMS keys enter a mandatory **7-day pending-deletion** window on destroy
  (disabled, no cost) — expected, not an orphan.
- Glance at quotas near a limit: Lambda concurrency/function count, KMS CMKs,
  EventBridge buses/rules, CloudWatch alarms, SNS topics.

---

## 7. State backend expectations (INFORMATIONAL)

`bootstrap/` creates (or reuses) the S3 state bucket with: versioning ON,
SSE, public-access-block all-true, a TLS-deny policy, and **S3-native locking**
(`use_lockfile=true`, no DynamoDB). For production, consider cross-region
replication of the state bucket and MFA-delete / object-lock.

---

## 8. Final pre-flight gate

Run these, in order, and confirm each is clean before `create-prod.sh`:

```bash
cd eventbridge-lab

# 8a. identity is the intended account
aws sts get-caller-identity --profile "${OPERATOR_PROFILE:-default}"

# 8b. static gate: fmt + validate + tflint across all roots (exit 0 required)
./scripts/verify-prod.sh

# 8c. THEN deploy (example: full failover path)
SECONDARY_REGION=us-west-2 ENABLE_GLOBAL_ENDPOINT=true ./scripts/create-prod.sh
```

Apply order is fixed and automatic: **bootstrap → platform-primary →
platform-secondary → platform-global *(if enabled)* → application**. Destroy is
the exact reverse via `scripts/destroy-prod.sh`.

---

## Quick GO / NO-GO summary

| Gate | Must be true |
|---|---|
| Tools | `terraform ≥1.5`, `aws` v2, `jq` on PATH |
| Identity | `get-caller-identity` shows the **intended** account; operator can create S3/IAM |
| Region | primary + secondary both in-policy and service-available |
| Global endpoint | if `true`: read CICD §2 (`awscrt`), have a public health domain, accept the Route 53 cost |
| Static gate | `./scripts/verify-prod.sh` exits 0 |

All green → run `create-prod.sh`. Any red → fix first.
