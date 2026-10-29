# Decision Brief — Multi-Region Deployment Model for the EventBridge Platform

**To:** Pipeline team, Cloud/Platform team
**From:** <your name>
**Re:** Input needed — should our EventBridge platform deploy region-by-region, and how?

## Background (one paragraph)

We have a production-grade, multi-region Amazon EventBridge platform built in
Terraform (GitLab CI/CD, OIDC deploy identity, primary + secondary region with a
global endpoint for failover). **Today it deploys both regions in a single
`terraform apply`** — one plan, one apply, both regions in the same state, which
suits the global endpoint (the endpoint resource must reference both regional
buses in one state to wire failover + the KMS multi-region replica).

We are evaluating whether to move to a **region-by-region** deployment model. Two
options are on the table (Option B and Option C below). Before we commit, we want
your input on operational fit, pipeline mechanics, and state/ownership.

We are NOT asking about Option A (`-target` sequencing) — it's a break-glass hack
we've already ruled out.

---

## Current model (baseline — what we'd be changing)

- **One Terraform root** (`platform/`) with two provider aliases (`primary`,
  `secondary`); the platform module is instantiated once per region in the same
  config.
- **One state file**, one apply, one OIDC STS session covering both regions.
- Global endpoint + KMS multi-region replica live in this same root (they
  inherently span both regions).
- **Pros:** simplest state, matches AWS's global-endpoint design, cross-region
  wiring is trivial.
- **Cons:** a single apply touches two regions (no per-region isolation); a
  failure in the secondary can roll back / block the whole apply; can't deploy
  regions on different schedules.

---

## Option B — Region as a pipeline matrix (one region per apply, shared root)

Refactor the root so **one region deploys per apply**, driven by a `region`
variable, and run the pipeline once per region (GitLab `parallel: matrix`, which
can run parallel or be forced sequential).

```yaml
apply:platform:
  parallel:
    matrix:
      - REGION: [us-east-1, us-east-2]
  script: terraform apply -var "region=$REGION" ...
```

**Key structural change:** the **global endpoint + KMS multi-region replica**
(which span both regions) can no longer live in a per-region root. They move to a
small **third "glue" root** (`platform-global/`) that runs AFTER both regional
applies complete.

- **State:** one state per region + one for the glue root (≈3 total).
- **Pros:** per-region isolation (a us-east-2 failure doesn't block us-east-1);
  can gate secondary behind primary; can stagger schedules; clearer per-region
  blast radius.
- **Cons:** more moving parts; the global/failover wiring is now a separate
  apply with a cross-root dependency (glue root reads both regional states); more
  pipeline orchestration (ordering: primary + secondary → glue).
- **Effort:** medium refactor (parameterize the root to single-region, extract
  the global/KMS-replica resources, add the glue root + pipeline ordering).

---

## Option C — Separate root + separate state per region (full isolation)

Distinct Terraform roots and state per region, plus a global root:

```
platform-us-east-1/     # own state
platform-us-east-2/     # own state
platform-global/        # global endpoint + KMS replica; own state
```

- **State:** fully independent per region (≈3+ states), independent lifecycles.
- **Pros:** maximum blast-radius isolation; each region deploys, rolls back, and
  is audited completely independently; fits a strict compliance boundary where
  one apply must never touch two regions; largest orgs use this.
- **Cons:** heaviest refactor; 3× the state to manage and keep in sync; the most
  duplication (or a shared module consumed by each root); more complex
  cross-root data passing for the global endpoint.
- **Effort:** large refactor.

---

## Comparison at a glance

| Dimension | Baseline (today) | Option B (matrix) | Option C (separate roots) |
|---|---|---|---|
| Regions per apply | both | one | one |
| State files | 1 | ~3 | 3+ |
| Per-region failure isolation | no | yes | yes (strongest) |
| Staggered schedules per region | no | yes | yes |
| Global-endpoint wiring | trivial (same root) | separate glue root | separate global root |
| Pipeline complexity | low | medium | high |
| Refactor effort | — | medium | large |
| Best when | default / simplicity | staged rollout, some isolation | compliance boundary, large org |

---

## Questions we need your input on

**For the Pipeline team:**
1. Do you prefer GitLab `parallel: matrix` (Option B) or fully separate pipelines
   per region (Option C) for how you run and observe deploys?
2. How should we order the global/failover apply relative to the regional
   applies — manual gate, automatic-on-success, or a separate pipeline?
3. Any existing convention for cross-root/state dependencies (how one root reads
   another's outputs) we should follow?
4. OIDC role scoping: one deploy role for all regions, or a role per region?

**For the Cloud/Platform team:**
5. Is there a **compliance/isolation requirement** that a single apply must not
   span two regions? (If yes → Option C.)
6. Do regions need **independent deploy schedules or change windows**? (If yes →
   B or C; if no → baseline may be fine.)
7. State-bucket strategy: one state bucket with per-region keys, or a state
   bucket per region (DR consideration)?
8. For the global endpoint specifically: are you comfortable with it living in a
   separate "glue" root that depends on both regional states?

---

## Our recommendation (for discussion)

For the current scope, the **baseline single-apply model is adequate and
simplest**, and matches AWS's global-endpoint design. We'd move to **Option B**
only if there is a concrete driver (staged-rollout safety, independent schedules,
or a soft isolation goal), and to **Option C** only if a **hard compliance
boundary** requires fully independent per-region state. We'd like your read on
whether such a driver exists on your side before we invest in the refactor.

Please reply with your answers to the questions above, or flag a call.

Thanks,
<your name>
