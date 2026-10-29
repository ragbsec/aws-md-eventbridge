# EventBridge Compliance Test Suite

Reusable, automated validation of the **EVB-xx** (EventBridge) and **HA-xx**
(high-availability) governance controls against a live EventBridge deployment.
Emits the **EVB-19 evidence model** — `PASS` / `FAIL` / `UNKNOWN` /
`NOT_APPLICABLE` per control, with a reason and a machine-readable manifest.

## Why

The control framework mixes two kinds of requirement:

1. **Runtime-testable** — things you can prove with an API call against the
   deployed bus/rules/targets/DLQ/alarms (encryption, patterns, retry, DLQ,
   monitoring, delivery). These scripts test them.
2. **Governance / process / design** — ARB approvals, exception registers, CI
   OIDC boundaries, signed RTO/RPO decisions, Well-Architected mappings. These
   are verified by repo/plan inspection or evidence review, **not** a command.
   The aggregator records them `NOT_APPLICABLE` *to runtime testing* with the
   verification method named, so the manifest is complete rather than silent.

## Layout

| File | Purpose |
|------|---------|
| `lib-compliance.sh`    | Shared assertion verbs (`pass_v`/`fail_v`/`unk_v`/`na_v`), evidence JSONL, and **discovery** (resolves coordinates from Terraform outputs or env). |
| `01-static-posture.sh` | **Read-only.** EVB-03/04/05/06/07/08/09/10/12. Describe-based; mutates nothing. CI-safe. |
| `02-functional.sh`     | **Live, non-destructive.** HA-01/02, EVB-07 (negative routing), EVB-15 (duplicate-key idempotency). Invokes the producer and publishes events. |
| `03-failure-drills.sh` | **Mutating, self-cleaning, gated by `--confirm`.** EVB-10/HA-14 DLQ fault injection; EVB-11/HA-12 archive replay. Adds one throwaway target + purges the DLQ, never touches Terraform state. |
| `run-compliance.sh`    | Orchestrates the families, folds per-resource verdicts into one per-control status (worst wins), and writes `manifest.json` + `manifest.md`. Exits non-zero on any `FAIL`. |

## Run it

```bash
cd eventbridge-lab

# Read-only posture scan, primary region (safe anywhere, incl. CI):
scripts/compliance/01-static-posture.sh primary

# Full gate: static + functional on the primary region:
scripts/compliance/run-compliance.sh

# Both regions:
scripts/compliance/run-compliance.sh --both-regions

# CI-safe (no event firing, no mutation):
scripts/compliance/run-compliance.sh --static-only

# Include the mutating failure drills (DLQ + replay):
scripts/compliance/run-compliance.sh --drills
```

Evidence lands in `.runtime/compliance/`:
`verdicts.jsonl` (raw), `manifest.json`, `manifest.md`.

For the controls the suite marks `NOT_APPLICABLE` to runtime testing
(governance / process / design), complete
[`HUMAN_VERIFICATION_CHECKLIST.md`](./HUMAN_VERIFICATION_CHECKLIST.md). The two
together satisfy EVB-19: the manifest proves what a machine can prove; the
checklist proves the rest, by a named reviewer with dated evidence.

## Control coverage

| Control | Script | What is asserted |
|---------|--------|------------------|
| EVB-03 | static | App bus is custom, not `default`. |
| EVB-04 | static | Bus has a CMK; key rotation + multi-region; archive inherits bus key. |
| EVB-05 | static | Explicit bus resource policy, no unconditioned `Principal "*"`. |
| EVB-06 | static | Producer `events:PutEvents` scoped to bus ARN; permissions boundary present. |
| EVB-07 | static + functional | Rule pattern constrains source+detail-type; 1–5 targets; a wrong-source event is NOT routed. |
| EVB-08 | static | Every Lambda target has a standard SQS DLQ (same acct/region). |
| EVB-09 | static | Every target declares retry in bounds (age 60–86400, attempts 0–185). |
| EVB-10 | static + drill | FailedInvocations alarm wired to SNS; DLQ-depth alarm at `period>=300`; fault injection lands a message in the DLQ. |
| EVB-11 | drill | Replayable archive exists; `start-replay` reaches COMPLETED. |
| EVB-12 | static | Audit log group present and KMS-encrypted. |
| EVB-15 | functional | Duplicate business key processed without error (idempotency; flags UNKNOWN if no dedup store observed). |
| HA-01  | functional | Producer publishes with 0 failed entries (durable accept). |
| HA-02  | functional | Routed event reaches the consumer end-to-end. |
| HA-12  | drill | Archive replay completes; consumer idempotency handles duplicates. |
| HA-14  | drill | DLQ fault injection proven; depth alarm breaches on next SQS datapoint. |
| EVB-01/02/13/14/16/17/18/19/20/21/22/23, HA-03/04/05/06/07/08/09/10/11/13 | aggregator | Recorded `NOT_APPLICABLE` to runtime testing with the named verification method (plan/evidence/decision-record). |

### AWS-recommended standards (`AWS-*` — from AWS docs & Security Hub)

These are prescribed by AWS itself and verified the same way (PASS/FAIL/etc.).
`AWS-*` ids distinguish them from the internal EVB/HA controls.

| Standard | Script | What is asserted | AWS source |
|----------|--------|------------------|-----------|
| AWS-KMS-CONFUSED-DEPUTY | static | CMK key policy scopes EventBridge's use by `aws:SourceArn`/`aws:SourceAccount`/`kms:EncryptionContext:aws:events:event-bus:arn`. | EventBridge "Authorizing EventBridge to use a customer managed key" |
| AWS-SECHUB-EB2 | static | Event bus carries non-system tags. | Security Hub `EventBridge.2` |
| AWS-SECHUB-EB3 | static | Custom bus has a resource-based policy. | Security Hub `EventBridge.3` (NIST 800-53 r5 AC-\*, PCI DSS v4.0.1 10.3.1) |
| AWS-SECHUB-EB4 / AWS-GE-REPLICATION | multiregion | Global endpoint has event replication ENABLED. | Security Hub `EventBridge.4` |
| AWS-GE-QUOTA-PARITY | multiregion | `PutEvents` throttle quota equal in both regions (failover headroom). | Global-endpoints best practices — "Preventing event throttling" |
| AWS-GE-HEALTHCHECK | multiregion | Route 53 health check excludes subscriber metrics (no false failover). | Global-endpoints best practices — health checks |
| AWS-BATCH-LIMITS | static (src) | Producer caps/chunks to 1–100 entries / ≤256 KB per `PutEvents`. | EventBridge quotas / PutEvents reference |
| AWS-PUTEVENTS-PARTIAL | static (src) | Producer reads `FailedEntryCount` AND retries failed entries. | PutEvents partial-failure handling |
| AWS-IMMUTABLE-ID | static (src) | Events carry an immutable business key for replay/cross-Region correlation. | Global-endpoints best practices — enabling replication |

Live findings on this lab: `AWS-KMS-CONFUSED-DEPUTY`, `AWS-SECHUB-EB3`, and
`AWS-PUTEVENTS-PARTIAL` currently **FAIL**; `AWS-GE-QUOTA-PARITY` and
`AWS-BATCH-LIMITS` are **UNKNOWN** (quota-read permission missing; producer has
no explicit ≤100 cap).

## Running against a NEW cluster

Discovery prefers Terraform outputs (`platform` + `application` roots). For a
deployment whose state is not local, override via env — the scripts need only
a reachable bus:

```bash
BUS_NAME=my-bus REGION_OVERRIDE=eu-west-1 \
  DEPLOYER_PROFILE=my-deployer \
  scripts/compliance/01-static-posture.sh primary
```

Static checks that depend on application outputs (producer role, consumer log
group, DLQ) degrade to `NOT_APPLICABLE`/`UNKNOWN` when those coordinates are
not resolvable, rather than failing hard — so the read-only scan still runs
against a platform-only stack.

## CI wiring

`run-compliance.sh --static-only` is the build-gate entry point: it is
read-only, deterministic, and exits non-zero on any `FAIL`. `UNKNOWN` does not
fail the build (EVB-19: missing evidence cannot PASS, but an implicit AWS
default is not itself a violation) — surface it in review. Wire the functional
and drill phases to a post-deploy stage against a non-prod environment.
