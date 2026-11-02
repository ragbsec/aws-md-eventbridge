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
  `scripts/contract_test.py` and `scripts/compliance/01-static-posture.sh` are
  safe. `create*.sh`, `test*.sh`, `destroy*.sh`, `rebuild.sh`,
  `compliance/02-04` and `03-failure-drills.sh --confirm` create, bill or mutate
  real AWS resources — ask the user first, and confirm the account ID shown by
  preflight.
- **Never print, log, or commit credentials.** `.runtime/` (deployer keys,
  backend config) and `*.tfstate` are gitignored and must stay that way.
- **Cloud containers are ephemeral.** Whatever `create*.sh` deploys must be torn
  down with `destroy*.sh` in the same session, or the user must keep
  `STATE_BUCKET_NAME` so a later session can run `scripts/cloud/restore-runtime.sh`.
- Apply order is fixed: bootstrap → platform-primary → platform-secondary →
  platform-global → application; destroy is the reverse. Use the scripts, not
  ad-hoc `terraform apply`.
- Before enabling the global endpoint read `docs/CICD_AND_OPERATIONS.md` §2
  (producer needs `awscrt` for SigV4a).
