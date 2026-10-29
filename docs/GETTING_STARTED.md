# Getting Started — Onboarding Sequence for a Fresh User

The single ordered path for someone new to this repo. It has two phases:
**understand** (read the docs in order), then **do** (run the lifecycle). Every
other doc is indexed from `README.md`; this page is the sequence through them.

> New here? Read this page first, then follow the order below. You do **not**
> need to read every doc up front — items 6–7 and the reference docs are
> read-on-demand.

---

## Phase 1 — Understand (read in this order)

| # | Read | Why / what you get |
|---|---|---|
| 1 | [`../README.md`](../README.md) | The map: highlights, the two tiers (single-region `app/` lab vs multi-region production), quick-start commands, module versions, and the doc index. |
| 2 | [`FOLDER_STRUCTURE.md`](FOLDER_STRUCTURE.md) | **The mental model** (marked "read first"): the three-root Option C split, each root's own state, and the cross-root `terraform_remote_state` wiring. Everything else assumes this. |
| 3 | [`PRODUCTION_ARCHITECTURE.md`](PRODUCTION_ARCHITECTURE.md) | The real design: regions, global-endpoint active/standby failover, layer separation, and the Security section (encryption + the IAM trust map). |
| 4 | [`SECURITY_AND_ONBOARDING.md`](SECURITY_AND_ONBOARDING.md) | The security contract + the full **IAM trust / assume-role model** and the per-app onboarding checklist. Read before touching IAM or onboarding a team. |
| 5 | [`CICD_AND_OPERATIONS.md`](CICD_AND_OPERATIONS.md) | **Critical before any global-endpoint deploy** — §2 is the `awscrt`/SigV4a `MissingDependencyException` trap, the most common handover failure. Also OIDC CI/CD and ops. |
| 6 | [`SCHEMA_ONBOARDING.md`](SCHEMA_ONBOARDING.md) | How event contracts work and how CI validates events. Read when you add/change an event type. |
| 7 | [`CROSS_ACCOUNT_SHARING.md`](CROSS_ACCOUNT_SHARING.md) | Only if another account must publish to / consume from the bus. Skippable for single-account. |

**Reference, read on demand:**
[`PREDEPLOY_PREFLIGHT_PROMPT.md`](PREDEPLOY_PREFLIGHT_PROMPT.md) (account
preflight), [`TLS_POLICY.md`](TLS_POLICY.md), [`FREE_TIER.md`](FREE_TIER.md).
[`ARCHITECT_GUIDE.md`](ARCHITECT_GUIDE.md) and
[`ENDUSER_GUIDE.md`](ENDUSER_GUIDE.md) describe the **legacy single-region
`app/` lab** — read only if you deploy that, not the Option C production stack.

---

## Phase 2 — Do (prerequisites → deploy → prove → tear down)

### 0. Prerequisites

> For the complete, copy-paste checklist (tooling, both profiles, SCP gotchas,
> cost, and the final GO/NO-GO gate) see **[`PREFLIGHT_CHECKLIST.md`](PREFLIGHT_CHECKLIST.md)** —
> run through it before your first deploy into any new account. The essentials:

- Terraform ≥ 1.5, AWS CLI with a configured `default` profile, `jq`.
- AWS provider ≥ 6.28 (pinned).
- Region **us-east-1 or us-west-2 only** (sandbox rule).
- **Confirm your identity/account first:**
  ```bash
  aws sts get-caller-identity
  ```
  Deploying into the wrong account is a recurring gotcha — check this before anything else.

### 1. Decide which stack you are deploying

- **Production multi-region (Option C)** → the `platform-*` + `application/`
  roots via `scripts/*-prod.sh`. **This is the supported stack.**
- **Legacy single-region demo** → `app/` via `scripts/create.sh`. Older and
  simpler; only if you specifically want it.

### 2. Deploy the production stack

Bootstrap runs as the operator (admin); everything after runs as the minted
least-privilege `eventbridge-lab-deployer`.

```bash
cd eventbridge-lab
./scripts/verify-prod.sh                       # fmt + validate + tflint gate (fast pre-check)
SECONDARY_REGION=us-west-2 ENABLE_GLOBAL_ENDPOINT=true \
  ./scripts/create-prod.sh                     # bootstrap → platform-primary → secondary → global → application
./scripts/test-prod.sh                         # end-to-end functional proof, both regions
./scripts/destroy-prod.sh                      # clean reverse-order teardown (stops billing)
```

Apply order is fixed: **bootstrap → platform-primary → platform-secondary →
platform-global → application**; destroy is the exact reverse. `create-prod.sh`
runs `verify-prod` as its own step 0, so the standalone verify above is just a
fast pre-check.

### 3. Key truths to internalize before applying

- **`bootstrap/` runs first, once, as the admin/operator.** It mints the S3
  state bucket + the least-privilege deployer. Every later root uses that remote
  backend and that identity, so nothing else can run until bootstrap exists.
- **Enabling the global endpoint** requires reading `CICD_AND_OPERATIONS.md` §2
  first (the `awscrt` SigV4a trap).
- **It bills.** The Route 53 health check (global endpoint) is the one
  meaningfully-billed item; `destroy-prod.sh` stops it.

---

## One-line summary

**Read:** README → FOLDER_STRUCTURE → PRODUCTION_ARCHITECTURE →
SECURITY_AND_ONBOARDING → CICD_AND_OPERATIONS.
**Run:** `verify-prod.sh` → `create-prod.sh` → `test-prod.sh` →
`destroy-prod.sh`.
The remaining docs are consulted on demand.
