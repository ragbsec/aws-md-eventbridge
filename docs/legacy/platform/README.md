# RETIRED — legacy single-root platform

This directory is an **archive**, not a live Terraform root. It holds the
previous `platform/` layout: **one root deploying BOTH regions in a single
state**. It was retired on 2026-10-28 when the project standardized on the
**Option C** per-region layout.

## Why it was retired

The platform is now three independent per-region roots, each with its own state:

```
platform-primary/     primary-region bus + KMS primary key
platform-secondary/   secondary-region bus + KMS replica  (reads primary's key ARN)
platform-global/      global endpoint + health check + replication (reads both)
```

Option C deploys the **same multi-region architecture** but with full
blast-radius isolation (a region deploys / fails / rolls back on its own). It
was built, deployed, and exercised end to end (failover + DLQ drills), so there
is no capability the single-root layout adds. Carrying two selectable layouts
was a maintenance tax and a source of "which one do I use?" confusion for
onboarding teams — so the project standardized on one.

See `docs/FOLDER_STRUCTURE.md` for the current layout and the reasoning.

## What is here

The four source files (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`)
exactly as they were when retired. The S3 **backend block in `versions.tf` is
commented out** so this copy cannot be accidentally `terraform init`/`apply`ed.
The stale `.terraform/` backend pointer and lock file were NOT archived.

## How to restore it (if you ever genuinely need the single-root layout)

1. Copy this directory back to the repo root as `platform/`.
2. Un-comment the `backend "s3"` block in `versions.tf`.
3. Repoint `scripts/*-prod.sh` at the single `platform/` root (or add a
   `PLATFORM_LAYOUT` switch), and restore the single `platform/terraform.tfstate`
   key.

Because the repo is under version control once committed, the cleaner restore is
`git revert` / checking out the retiring commit — this archive is the safety net
for the pre-git window.
