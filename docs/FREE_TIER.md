# Free-Tier & Sandbox Safety Assessment

This lab is designed to run inside the **Pluralsight AWS cloud sandbox** and to
stay within the AWS Free Tier. Below is the service-by-service check against the
sandbox's published limits and the AWS Free Tier.

## Sandbox global rules (from the Pluralsight sandbox doc)

- **Regions:** only `us-east-1` and `us-west-2` are allowed.
  → Enforced by a `validation` block on the `region` variable (app layer).
- **User:** `cloud_user` is the provided identity.
  → Used **only** to bootstrap; the app runs as `eventbridge-lab-deployer`.
- **Billing:** no access to cost/budget APIs. This lab never calls them.

## Service-by-service

| Service | Sandbox support | Sandbox limit | This lab uses | Free-tier headroom |
| --- | --- | --- | --- | --- |
| Amazon EventBridge | Supported | — | 1 bus, 1 rule, 3 targets, 1 archive | Custom bus events are always free; well under any limit |
| AWS Lambda | Conditionally supported | **Max 10 functions**, **max 2048 MB/fn** | **2 functions, 128 MB each** | 1M free requests + 400k GB-s/mo; on-demand use is negligible |
| Amazon SQS | Supported | — | 1 DLQ | 1M free requests/mo |
| Amazon SNS | Supported | — | 1 topic (no subscriptions by default) | 1M free publishes/mo |
| Amazon CloudWatch | Supported | — | 2 log groups (7-day retention) | 5 GB logs ingest/mo free; tiny volume here |
| Amazon S3 | Supported | — | 1 state bucket (small text objects) | 5 GB free; state files are KB-sized |
| AWS IAM | Supported | — | 1 user, service roles | IAM is always free |
| EventBridge Scheduler | Supported (part of EventBridge) | — | **0 by default** (opt-in) | 14M free scheduler invocations/mo even if enabled |

## Why there is no unattended cost

The single biggest free-tier risk in an event lab is a **recurring schedule**
firing forever in an account nobody is watching. This lab defends against that:

- `enable_schedule` defaults to **`false`** — no EventBridge Scheduler schedule
  is created unless you explicitly opt in.
- The demo therefore produces events **only on demand** (via `scripts/test.sh`
  or a manual `lambda invoke`), so between runs the lab consumes nothing but
  idle storage (a few KB of state + logs).
- If you do enable the schedule, the default is a conservative `rate(1 hour)`
  (not minutes), and it still sits far inside the 14M/mo free scheduler tier and
  the 1M/mo free Lambda tier.

## Data-retention caps

- CloudWatch Logs retention: **7 days** (`log_retention_days`).
- EventBridge archive retention: **3 days**.

Both bound how much data can accumulate even under heavy manual testing.

## Bugs guarded against (lessons from building this lab)

These were hit and fixed during development, so the code ships clean:

1. **Provider version:** EventBridge module v4.3.2 requires AWS provider
   `>= 6.28`; both layers pin it. (A `~> 5.x` pin fails to resolve.)
2. **State locking:** AWS provider 6.x deprecates `dynamodb_table` on the S3
   backend → this lab uses S3-native `use_lockfile = true` (one fewer resource,
   cleaner destroy).
3. **Lambda `$LATEST` permission:** the Lambda module tried to add an
   EventBridge permission to `$LATEST`, which AWS rejects → fixed with
   `create_current_version_allowed_triggers = false`.
4. **Deployer IAM scope:** the EventBridge module tags its policies and updates
   role trust policies, so the deployer needs `iam:TagPolicy`,
   `iam:UpdateAssumeRolePolicy`, etc. The policy now lists the complete
   role/policy action set so repeated apply/destroy never hits a permission wall.
5. **Backend auth:** the S3 backend needs `profile` in its config (not just the
   provider block) to authenticate as the deployer.
6. **Sandbox temp dir:** Terraform's provider cache/temp is redirected to
   project-local paths (`.tf-plugin-cache`, `.tftmp`) because the default
   sandbox `$TMPDIR` is not writable by the provider installer.
