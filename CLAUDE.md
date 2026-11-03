# EventBridge lab — notes for Claude

Terraform reference lab for Amazon EventBridge. Read `README.md` and
`docs/GETTING_STARTED.md` for the layout; `docs/CLAUDE_CLOUD_SETUP.md` for
running in a Claude Code cloud session.

## Cloud sessions

- A SessionStart hook (`.claude/settings.json` → `scripts/cloud/session-start.sh`)
  installs tools, writes the operator AWS profile from `OPERATOR_AWS_*` env vars,
  and prints a preflight matrix. Re-run it any time with
  `bash scripts/cloud/preflight.sh`.
- Trust the preflight VERDICT: `READY (offline)` means only verify/contract
  checks; `READY (deploy)` is required before anything touches AWS.

## Rules

- **Offline first, deploy only on explicit approval.** `scripts/verify*.sh`,
  `scripts/contract_test.py`, `scripts/leftover-check.sh` (read-only sweep of
  both regions) and `scripts/compliance/01-static-posture.sh` are safe. `create*.sh`, `test*.sh`, `destroy*.sh`, `rebuild.sh`,
  `compliance/02-04` and `03-failure-drills.sh --confirm` create, bill or mutate
  real AWS resources — ask the user first, and confirm the account ID shown by
  preflight.
- **Never print, log, or commit credentials.** `.runtime/` (deployer keys,
  backend config) and `*.tfstate` are gitignored and must stay that way.
- **Destroy must be proven clean.** `destroy-prod.sh` stops before deleting the
  state bucket if any layer failed (re-run; `FORCE_UNLOCK=1` clears a stale lock
  from an interrupted run) and ends with `leftover-check.sh`. Never trust a
  "destroyed" banner on its own. Terraform >= 1.10 is required (`use_lockfile`).
- **Cloud containers are ephemeral.** Whatever `create*.sh` deploys must be torn
  down with `destroy*.sh` in the same session, or the user must keep
  `STATE_BUCKET_NAME` so a later session can run `scripts/cloud/restore-runtime.sh`.
- Apply order is fixed: bootstrap → platform-primary → platform-secondary →
  platform-global → application; destroy is the reverse. Use the scripts, not
  ad-hoc `terraform apply`.
- Before enabling the global endpoint read `docs/CICD_AND_OPERATIONS.md` §2
  (producer needs `awscrt` for SigV4a).

## IBM MQ integration + compliance additions (branch `compliance-and-mq-integration`)

Start with `mq-integration/README.md` (its status table says what is proven), then
`mq-integration/docs/RESILIENCE_AND_LIMITATIONS.md`. Plugging a separate production MQ cluster in:
`mq-integration/docs/PRODUCTION_MQ_CLUSTER.md`. Hand-run AWS CLI tests: `docs/AWS_CLI_TEST_COOKBOOK.md`.

- **Safety classes (same approval rule as above, and confirm the account ID):**
  - Offline/local, safe: `mq-integration/scripts/verify.sh`, `verify-mq-objects.sh --static`,
    `local-mq-check.sh` (Docker, no AWS; pulls ~1 GB; `LICENSE=accept` is the USER's acceptance of the IBM licence).
  - Read-only: `mq-integration/scripts/leftover-check.sh` (fails closed: exit 2 = cleanliness unproven),
    `scripts/compliance/01` and `04`.
  - Create/bill/mutate, ask first: `mq-integration/scripts/deploy.sh --yes [--global-endpoint]`, `test.sh`,
    `test-global-endpoint.sh` (`--failover --confirm` flips the health Lambda and restores it), `destroy.sh --yes`,
    `scripts/compliance/05-global-endpoint.sh`.
- **Order:** build the main lab first (`ENABLE_GLOBAL_ENDPOINT=true` for endpoint tests), then
  `EXPECTED_AWS_ACCOUNT_ID=<id> mq-integration/scripts/deploy.sh --yes --global-endpoint`. Destroy MQ **before** the
  main lab (the MQ Terraform state lives in the main lab's state bucket).
- **Account limits enforced by the MQ stack:** instance types t2/t3/t3a in micro-medium only (t4g is rejected: the
  stack is x86_64), root volume 20-100 GiB, at most 9 concurrent instances (`deploy.sh` counts them).
- **Lessons that cost time (do not rediscover):** the committed `.terraform.lock.hcl` files now carry hashes for all
  platforms, so `terraform init` no longer rewrites them (if the stop hook flags them, something changed them: do not
  just `git checkout` them while a stack is deployed); the MQ 10.0.x developer image has no OS users/groups, rights go to
  `PRINCIPAL('app')`; the bridge user needs a home directory or every MQ connect fails with MQRC 2009; a raw
  `AWS_ACCESS_KEY_ID` in the environment overrides profiles; checks run inside the MQ container cannot catch
  bridge-to-MQ network problems (`verify-mq-objects.sh` also logs in from the bridge container).
- **State at the end of the last session (2026-11-03):** everything destroyed and verified clean, nothing deployed.
  KMS keys in pending deletion are expected (7-30 days). The state bucket is gone, so rebuild from scratch.
- **Open items:** `EXPECTED_AWS_ACCOUNT_ID` in the cloud environment is stale (the lab account is 968220652414: confirm
  with the user); rotate the long-lived operator key; compliance suite still FAILs on the bus resource policy,
  producer permissions boundary, KMS confused-deputy condition and `PutEvents` retry; EventBridge-to-MQ is not
  region-resilient and a whole-`us-east-1` outage is not covered (deferred by design); no TLS on the MQ channel; no load
  test; no PR opened for this branch.
