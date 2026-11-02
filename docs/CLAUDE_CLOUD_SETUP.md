# Running the lab in a Claude Code cloud session

Step-by-step: create the cloud environment, start the session on the latest
release, let the automatic preflight ground the tools and credentials, then
start the project work.

What runs automatically on every new cloud session (`.claude/settings.json` →
SessionStart hook → `scripts/cloud/session-start.sh`):

| Step | Script | What it does |
|---|---|---|
| 1 | `scripts/cloud/install-tools.sh` | Installs **terraform 1.9.8**, **tflint 0.53.0**, **jq 1.7.1**, **AWS CLI** (v2, or v1 + `awscrt` from PyPI if the AWS download host is blocked). Skips anything already present. |
| 2 | `scripts/cloud/configure-aws.sh` | Writes the operator profile (`~/.aws/credentials`, mode 600) from the `OPERATOR_AWS_*` environment variables. Never prints secrets. |
| 3 | `scripts/cloud/preflight.sh` | PASS / WARN / FAIL matrix — runtime, tools, network allow-list, repo vs latest release, AWS identity + account guard, existing deployment — and a **VERDICT**. |

The output lands in Claude's context, so the session starts knowing exactly
what it can and cannot do. Nothing is deployed by the hook. Local (non-cloud)
sessions skip it.

---

## Step 1 — Prepare AWS credentials (on your machine)

Use credentials for the **operator** (admin-capable, it runs `bootstrap/` which
mints the least-privilege deployer). Prefer **temporary** credentials:

```bash
aws sts get-session-token --duration-seconds 43200     # or: aws sts assume-role ...
aws sts get-caller-identity --query Account --output text   # note the account ID
```

> The cloud environment's variables are visible to anyone who can use that
> environment. Use short-lived credentials, a sandbox account, and delete or
> rotate them after testing.

## Step 2 — Create the cloud environment (once)

At **claude.ai/code** → environment selector → **Add / edit environment**
(labels may vary slightly):

1. **Name:** `eventbridge-lab`
2. **Network access:** the default *Trusted* allow-list covers GitHub, PyPI and
   package registries, but deploying needs the AWS APIs. Choose **Custom** and
   allow at least:
   ```
   registry.terraform.io
   releases.hashicorp.com
   github.com
   api.github.com
   objects.githubusercontent.com
   pypi.org
   files.pythonhosted.org
   *.amazonaws.com
   ```
   (or **Full** access). Offline checks only need the first seven.
3. **Environment variables** (`.env` format):
   ```bash
   OPERATOR_AWS_ACCESS_KEY_ID=ASIA...
   OPERATOR_AWS_SECRET_ACCESS_KEY=...
   OPERATOR_AWS_SESSION_TOKEN=...          # omit for a long-lived key
   EXPECTED_AWS_ACCOUNT_ID=123456789012    # preflight FAILs on any other account
   REGION=us-east-1                        # primary region (lab + prod)
   PRIMARY_REGION=us-east-1
   SECONDARY_REGION=us-west-2
   # STATE_BUCKET_NAME=eventbridge-lab-tfstate-...   # reuse an existing state bucket (recommended for later sessions)
   # ENABLE_GLOBAL_ENDPOINT=false                    # true only with a HEALTH_CHECK_DOMAIN
   ```
   Use the `OPERATOR_AWS_*` names, **not** `AWS_ACCESS_KEY_ID`: raw AWS_* vars
   override the profile switching the scripts do (operator → deployer).
4. **Setup script** (optional, speeds up session start; runs as root before
   Claude starts):
   ```bash
   bash scripts/cloud/install-tools.sh
   ```
   If your environment runs the setup script before the repo is cloned, leave
   this empty — the SessionStart hook installs the tools anyway.

## Step 3 — Start the session on the latest release

**Option A — browser:** claude.ai/code → repo **ragbsec/aws-md-eventbridge** →
branch **first-release** → environment **eventbridge-lab** → send the first
prompt below.

**Option B — terminal** (from a local checkout on `first-release`):

```bash
claude --cloud "$(cat <<'EOF'
Start EventBridge lab work. 1) Show me the preflight output from session start
and explain any FAIL/WARN. 2) Run scripts/cloud/clone-latest.sh --here so we
work on the latest release. 3) Run scripts/verify-prod.sh and the contract test
for schemas/prod.orders__OrderPlaced.json against its valid and invalid samples.
Report results. Do NOT run create/test/destroy or anything that changes AWS until
I confirm the account ID and say go.
EOF
)"
```

Reattach later with `claude --cloud <session-id-or-url>`.

**Option C — any Linux box / existing session without the hook:**

```bash
curl -fsSL https://raw.githubusercontent.com/ragbsec/aws-md-eventbridge/first-release/scripts/cloud/clone-latest.sh | bash
cd aws-md-eventbridge
CLOUD_SETUP_FORCE=1 bash scripts/cloud/session-start.sh
```

## Step 4 — Read the preflight verdict

| Verdict | Meaning | What you can run |
|---|---|---|
| `READY (deploy)` | Tools, network, AWS identity in the expected account | Everything (with explicit approval) |
| `READY (offline)` | Tools + network OK; no/invalid AWS creds or wrong account | `verify-prod.sh`, contract tests, docs work |
| `NOT READY` | Tool missing or a required host blocked | Fix the FAIL lines, then `bash scripts/cloud/preflight.sh` |

Common fixes:
- `FAIL sts.us-east-1 … BLOCKED` → add `*.amazonaws.com` to the network allow-list.
- `WARN credentials … not configured` → add the `OPERATOR_AWS_*` vars, start a new session (or run `bash scripts/cloud/configure-aws.sh`).
- `FAIL account … WRONG ACCOUNT` → fix the credentials / `EXPECTED_AWS_ACCOUNT_ID` before anything else.
- `WARN credential-type … temporary` → refresh the vars if you see `ExpiredToken`.

## Step 5 — Start the project work

```bash
# offline (safe)
scripts/verify-prod.sh
python3 scripts/contract_test.py validate schemas/prod.orders__OrderPlaced.json \
  schemas/samples/prod.orders__OrderPlaced/valid-1.json
scripts/compliance/01-static-posture.sh primary      # read-only, needs a deployment

# deploy → prove → tear down (bills; approve explicitly)
scripts/create-prod.sh
scripts/test-prod.sh
scripts/compliance/run-compliance.sh
scripts/destroy-prod.sh
```

## Step 6 — Before the session ends

Cloud containers are discarded. `.runtime/` (deployer keys) and the local
bootstrap state go with them.

- **Preferred:** `scripts/destroy-prod.sh` in the same session.
- **Keeping it running:** note the state bucket name printed by `create-prod.sh`
  and set `STATE_BUCKET_NAME` in the environment. A later session then runs:
  ```bash
  STATE_BUCKET_NAME=<bucket> scripts/cloud/restore-runtime.sh prod   # or: lab
  scripts/test-prod.sh          # or destroy-prod.sh
  ```
- Commit and push code changes from the session (`git push`) — uncommitted work
  is lost with the container.
- Delete or rotate the credentials you put in the environment.

## Files

| File | Role |
|---|---|
| `.claude/settings.json` | Registers the SessionStart hook |
| `CLAUDE.md` | Rules Claude follows in this repo (offline-first, approval before deploy) |
| `scripts/cloud/session-start.sh` | Hook entry point (no-op outside cloud unless `CLOUD_SETUP_FORCE=1`) |
| `scripts/cloud/install-tools.sh` | Tool installer (also usable as the environment setup script) |
| `scripts/cloud/configure-aws.sh` | Env vars → operator AWS profile |
| `scripts/cloud/preflight.sh` | Readiness matrix (`--strict` exits 1 on FAIL) |
| `scripts/cloud/clone-latest.sh` | Clone latest `v*` release (`DEST`) or switch to it in place (`--here`) |
| `scripts/cloud/restore-runtime.sh` | Rebuild `.runtime/` from the S3-mirrored bootstrap state |
