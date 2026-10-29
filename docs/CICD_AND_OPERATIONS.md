# CI/CD, Deploy Identity & Operational Gotchas

Team handover reference for everything added beyond the base multi-region build.
Read this before enabling the global endpoint or wiring the pipeline.

---

## 1. CI/CD pipeline (GitLab) + OIDC deploy identity

### Files
- `.gitlab-ci.yml` — the pipeline (root of repo).
- `bootstrap/gitlab_oidc.tf` — the OIDC provider + federated deploy role (flag-gated).

### How auth works (no static keys in CI)
The pipeline authenticates to AWS via **GitLab OIDC → STS AssumeRoleWithWebIdentity**:
GitLab issues a signed `id_token`, AWS trusts it because of the OIDC provider, and
only for the project/branch named in the role's trust `sub` condition. No long-lived
access key lives in CI.

### Enable it (production account)
```bash
terraform -chdir=bootstrap apply \
  -var enable_gitlab_oidc=true \
  -var gitlab_project_path=yourgroup/eventbridge-lab
```
Then set two protected+masked CI/CD variables from the bootstrap outputs:
- `TF_DEPLOYER_ROLE_ARN` = output `gitlab_deployer_role_arn`
- `TF_STATE_BUCKET`      = output `state_bucket_name`

### Pipeline stages
`validate` (fmt+validate+tflint, no creds) → `plan:platform` → **`apply:platform` (manual)**
→ `plan:application` → **`apply:application` (manual)**. The two manual apply jobs are
the human approval gate (your PR/MR review). Regions and feature flags are `TF_VAR_*`
CI/CD variables, so sandbox vs prod differ only by variables, not code.

### Local vs CI credentials
The provider `profile` is parameterized: locally it uses the deployer profile; in CI
it is empty, so the providers and the S3 backend fall back to the OIDC env-var session.
One STS session serves BOTH regions.

### Assumed-role alternative (not CI)
`bootstrap/deployer_role.tf` (flag `enable_deployer_role`, list `deployer_trust_principals`)
creates a human/CI assumable role as the production alternative to the static IAM-user key.
Verified that `sts:AssumeRole` works in the sandbox account — see `scripts/who-can-assume.sh`
to enumerate who may assume any role.

---

## 2. Global endpoint: the awscrt / SigV4a requirement (CRITICAL)

**If you enable the global endpoint, the producer MUST include `awscrt`.** `PutEvents`
with an `EndpointId` signs with **SigV4a** (multi-region signatures), which botocore
only does when the AWS Common Runtime is present. Lambda's bundled botocore lacks it.

Symptom if missing: `MissingDependencyException: Use pip install botocore[crt]`.

How it's solved in this repo:
- `src/lambda/producer/requirements.txt` pins `awscrt`.
- `scripts/build-producer.sh` vendors the **manylinux x86_64 abi3** wheel into the
  package via `pip --platform manylinux2014_x86_64 --only-binary --abi abi3` (no Docker,
  no compile). The `event-application` module runs this build before zipping.
- Result: producer package is ~4.7 MB (with CRT) instead of ~1 KB.

Clients other than Lambda: AWS CLI v2 bundles CRT, so `aws events put-events --endpoint-id <id>`
works directly — useful for testing failover from a cold client.

---

## 3. Global endpoint: the IAM/KMS chain (why the apply failed 4 times before working)

Enabling `replication_config` on the endpoint pulls in requirements `terraform validate`
cannot see. All are now in `platform-global/main.tf` (the global glue root);
documented here so nobody re-discovers them:
1. Replication needs an IAM **`role_arn`** on the endpoint.
2. That role needs `events:PutRule`, `events:PutTargets`, and **`iam:PassRole`** (on itself).
3. Because the buses are KMS-encrypted, the role needs **KMS grants** on BOTH regional
   CMKs (`aws_kms_grant`) — the key policy's service principal is not enough for
   role-based replication.
4. Endpoint creation must **retry after IAM propagation** (a fresh role isn't instantly usable).

And the producer, under failover, needs `events:PutEvents` + KMS on BOTH regional buses
(failover redirects PutEvents to the other region) — see `failover_bus_arns` /
`failover_kms_key_arns` in the `event-application` module.

### Failover timing (set expectations)
RTO is **360–420s** (AWS docs), measured from failure including Route 53 health-check
detection. Failover routing away from primary is observable; the event's arrival in the
secondary is asynchronous (the RPO) and can lag minutes. Test with a COLD client and
patient (120s) log sweeps — a warm Lambda caches DNS and hides failover.

---

## 4. Monitoring wiring (added this round)

- **DLQ alarm → SNS**: the DLQ-depth alarm now publishes to the platform alerts topic
  (`alerts_topic_arn` passed from platform to the app module). Previously it had no action.
- **DLQ alarm period = 300**, not 60: SQS `ApproximateNumberOfMessagesVisible` publishes
  on a ~5-min cadence, so a 60s-period alarm misses short spikes. Use 300.
- **Alert subscription**: set `-var alert_email=you@example.com` on the platform to create
  a (confirmation-pending) email subscription on the alerts topic. Without a subscriber,
  alarms fire into a topic nobody hears.

---

## 5. Account gotchas found during this build

- **SCP governance**: the test account is org-governed (`o-yu55c2titn`); some IAM reads
  (e.g. `iam:GetRole` on `admin`) are SCP-denied even though identity policies allow them.
  When a call is denied despite an apparent grant, suspect an SCP.
- **Cross-account KMS principals must be REAL**: `trusted_account_ids` with a non-existent
  account ID fails `PutKeyPolicy` with `MalformedPolicyDocumentException` and rolls back.
- **Sandbox vs prod regions**: us-east-2 is unavailable in the Pluralsight sandbox; the
  code is region-parameterized (`SECONDARY_REGION`) so prod uses us-east-2 unchanged.

---

## 6. Where to look

| Topic | File |
|---|---|
| Multi-region architecture, security, monitoring | `docs/PRODUCTION_ARCHITECTURE.md` |
| Cross-account / org bus sharing (publish + consume) | `docs/CROSS_ACCOUNT_SHARING.md` |
| Pre-deploy account preflight (AI prompt) | `docs/PREDEPLOY_PREFLIGHT_PROMPT.md` |
| CI/CD, OIDC, global-endpoint gotchas (this doc) | `docs/CICD_AND_OPERATIONS.md` |
| TLS / cipher posture | `docs/TLS_POLICY.md` |
| Free-tier / sandbox limits | `docs/FREE_TIER.md` |
| Architect deep-dive / end-user guide | `docs/ARCHITECT_GUIDE.md`, `docs/ENDUSER_GUIDE.md` |
