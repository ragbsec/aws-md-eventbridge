# EventBridge Human-Verification Checklist

Controls the automated suite records as `NOT_APPLICABLE` to runtime testing.
Each is verified by **inspecting a plan/repo**, **reviewing an evidence
artifact**, or **confirming a signed decision record** — never by a command
against the running cluster.

This checklist is the companion to the automated manifest
(`.runtime/compliance/manifest.json`). Together they satisfy **EVB-19**:
machine-proven controls come from the suite; the controls below are proven
here, by a named human with dated evidence. Missing evidence **cannot** pass.

**Method key:** `plan` = Terraform plan / repo inspection · `evidence` =
review of a produced artifact (report, diagram, mapping) · `decision-record` =
a signed architectural/business decision.

**Status values:** `PASS` · `FAIL` · `UNKNOWN` (evidence not yet produced) ·
`NOT_APPLICABLE` (precondition absent in this deployment — say why).

---

## EVB — EventBridge governance

### EVB-01 · Approved supply chain — method: `plan`
- [ ] Module source is `platform-eventbridge` at an approved version (1.1.0, or 1.0.0 until 2027-01-21), pinning `terraform-aws-modules/eventbridge/aws` `4.3.2`.
- [ ] No raw `aws_cloudwatch_event_*` resources bypassing the wrapper (except the documented application-layer targets).
- [ ] `.terraform.lock.hcl` is committed (locks providers).
- [ ] Pipeline policy MSG-GOV-01..04 result attached.
- Evidence (path/link): ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-02 · Ownership & inventory — method: `plan` + `evidence`
- [ ] Bus and rules carry mandatory + provenance tags (`tags_all` in plan).
- [ ] Targets/archives/schedules (untaggable) have ownership recorded in the workload manifest and inferred from the bus.
- [ ] Inventory classification record present.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-13 · Cross-account & cross-Region routing — method: `evidence`
- [ ] Bus-to-bus target role limited to `events:PutEvents` on named buses.
- [ ] Receiving bus policy names the source account.
- [ ] Patterns are narrow; routing loops prevented and documented.
- [ ] Topology diagram attached.
- _N/A if single-account, single-bus (state why): _______________________
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-14 · Features outside the wrapper — method: `evidence`
- [ ] Pipes, Scheduler, API destinations/connections, schema discovery are disabled in `platform-eventbridge` v1.
- [ ] Any use of them has its own approved pattern + architecture-review record.
- [ ] Connection credentials (if any) live in Secrets Manager, never in tfvars/state outputs.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-16 · Regional resilience decision — method: `decision-record`
- [ ] Signed single-Region vs multi-Region decision (ties to HA-13).
- [ ] If multi-Region: global-endpoint + health-check config documented, independent keys/data/replay source confirmed.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-17 · Change safety & drift — method: `plan` + `evidence`
- [ ] Bus/archive deletion, rule disable/delete, target removal are gated changes (policy MSG-GOV-07).
- [ ] Scheduled drift + inventory detection for unmanaged rules/buses is active.
- [ ] No automatic deletion anywhere in the pipeline.
- [ ] Plan diff reviewed for destructive changes.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-18 · Capacity & cost — method: `evidence`
- [ ] PutEvents + invocation quotas modelled per Region.
- [ ] Target concurrency/throughput, archive storage, replay, cross-Region transfer costed.
- [ ] Load test at peak **and** impaired scenario recorded.
- [ ] Classic vs enhanced-bus pricing compared with real event sizes + subscriber counts.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-19 · Evidence & exceptions — method: `evidence`
- [ ] This checklist + the automated `manifest.json` together give PASS/FAIL/UNKNOWN/NOT_APPLICABLE per resource.
- [ ] Every exception is independently approved, scoped, and ≤ 90 days.
- [ ] No control passes on missing evidence.
- Exception register (path/link): ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-20 · Trusted CI & AI boundaries — method: `plan` + `evidence`
- [ ] Protected pipelines; OIDC short-lived roles (no static keys).
- [ ] Apply runs only the reviewed plan digest.
- [ ] Untrusted MRs get no credentials.
- [ ] AI review is advisory and read-only.
- [ ] CI config + approval records attached.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-21 · Enhanced Custom Event Bus adoption gate — method: `decision-record`
- [ ] ARB-approved pilot (while no Terraform resources exist; deployed via CloudFormation `AWS::EventsV2::*`).
- [ ] `approved_patterns` entry present; tagged `platform:pattern=eventbridge-v2-pilot`.
- [ ] Limited to the 14 launch Regions; reviewed before pattern expiry.
- [ ] Inventory status = `APPROVED_PATTERN`.
- _N/A if enhanced bus not adopted (state so): _______________________
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-22 · Subscriber design (enhanced bus) — method: `evidence`
- [ ] One target per Subscriber.
- [ ] `RetryPolicy` set explicitly (Subscriber default 300 s / 5 attempts, unlike classic 24 h / 185).
- [ ] Ordered subscribers use short retry windows (a failing event blocks its group).
- [ ] Dead-letter destination configured; starting position chosen deliberately; filters match the publishing API (PutEvents vs PutRawEvents).
- [ ] Subscriber create/delete serialised in IaC (one at a time per bus).
- [ ] Ordering test with a poison event recorded.
- _N/A if enhanced bus not adopted: _______________________
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### EVB-23 · Sharing, retention & encryption (enhanced bus) — method: `evidence` + `plan`
- [ ] Shared via AWS RAM within the org only, narrowest managed permission (PublishOnly / SubscribeOnly).
- [ ] Retention set from replay/RPO need with per-GB cost noted.
- [ ] CMK for confidential/restricted data; consumers remain idempotent (dedup protects only against producer retries).
- [ ] Org SCP covers `events:*Subscriber` / `*EventSource` / `*ResourcePolicy` actions.
- _N/A if enhanced bus not adopted: _______________________
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

---

## HA — High availability / resilience

### HA-03 · Network access resilience — method: `evidence`
- [ ] Endpoint ENIs, DNS, routing, security rules, NAT/proxy paths traced.
- [ ] Healthy-AZ clients can reach the regional API after one AZ/network path is unavailable.
- [ ] Only relevant network dependencies demanded (don't require NAT for an interface-endpoint path).
- _For serverless producers (no VPC): trace the SDK→public-endpoint path instead._
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-04 · Downstream systems — method: `evidence`
- [ ] Dependency fault-domain map + recovery contract.
- [ ] DB/API failover, connection refresh, timeouts, bounded backpressure.
- [ ] Dependency-failover simulation shows safe pause/recovery or continued completion within SLO.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-05 · Scaling under failure — method: `evidence`
- [ ] Measured surviving capacity, subnet IPs, quotas, scale-out delay, downstream limits.
- [ ] Peak-load test with a fault domain unavailable, including startup/scale-out delay.
- [ ] No assumption that emergency provisioning succeeds.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-06 · Operations detect & restore — method: `evidence` (overlaps automated HA-14)
- [ ] Detection, paging, acknowledgement, recovery, replay timestamps captured.
- [ ] Accountable responder named; runbook executed.
- [ ] Approved synthetic failure triggered; alert receipt + restoration proven against declared targets.
- Cross-ref: automated `03-failure-drills.sh` proves the DLQ alarm fires; this control adds the human paging/ack/runbook timing.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-07 · Well-Architected traceability — method: `evidence`
- [ ] Control → AWS question/best-practice-ID mapping maintained (not just pillar names).
- [ ] Applicability, source URL, review date, evidence per row.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-08 · Availability objective — method: `decision-record`
- [ ] Numeric target + SLI numerator/denominator + measurement window + latency deadline.
- [ ] Excluded events, required subscriber paths, owner, business approval.
- [ ] Not resting on "a healthy API / successful Publish" alone.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-09 · Recovery objectives (RTO/RPO) — method: `decision-record`
- [ ] Approved RTO + RPO per AZ, dependency, and regional-failure scenario.
- [ ] Timer boundaries, acknowledged-message durability, replay source stated.
- [ ] Acceptable irrecoverable records/time window stated; no inferring zero RPO from a queue/DLQ.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-10 · AZ-failure design — method: `evidence`
- [ ] As-built topology, placement, dependency map, failover behaviour, SPOF review.
- [ ] For managed services: service-responsibility documented (don't invent a topic/queue multi-AZ switch).
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-11 · Failure-capacity test — method: `evidence`
- [ ] Workload profile + largest fault domain lost + measured sustainable throughput.
- [ ] Backlog growth/age, scale latency, downstream impact, recovery/drain duration vs approved limits.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### HA-13 · Regional-outage decision — method: `decision-record`
- [ ] Justification covers business impact, RTO/RPO, cost/complexity, residency, recovery dependencies.
- [ ] If multi-Region: independent usable infrastructure, keys, data/replay source, tested routing.
- [ ] Single-Region is a documented choice, not a default.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

---

## AWS — AWS-recommended standards (`AWS-*`)

These are prescribed by AWS (Security Hub CSPM controls + EventBridge
best-practice docs) and are **machine-tested** by the suite. The automated
verdict is authoritative; the human step here is to **review the finding and
confirm the remediation or a scoped exception** — a code/policy contract a
scanner can flag but only a person can accept. Each row names the automated
control whose verdict feeds it.

Method key as before. Cross-ref column = the `AWS-*` control in
`manifest.json`.

### AWS-KMS-CONFUSED-DEPUTY · method: `plan` (confirms a FAIL) — cross-ref `AWS-KMS-CONFUSED-DEPUTY`
AWS: the CMK key policy **must** scope EventBridge's use to a specific bus/account via `aws:SourceArn`, `aws:SourceAccount`, or `kms:EncryptionContext:aws:events:event-bus:arn`.
- [ ] Every `events.amazonaws.com` grant in the CMK key policy carries one of those condition keys.
- [ ] Remediation applied (add the condition to `platform/main.tf` key_statements) **or** scoped exception filed.
- Source: EventBridge "Authorizing EventBridge to use a customer managed key".
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### AWS-SECHUB-EB2 · method: `evidence` — cross-ref `AWS-SECHUB-EB2`
Security Hub `EventBridge.2`: event buses should be tagged.
- [ ] Bus carries the organisation's required non-system tag keys (ties to EVB-02).
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### AWS-SECHUB-EB3 · method: `plan`/`evidence` (confirms a FAIL) — cross-ref `AWS-SECHUB-EB3`
Security Hub `EventBridge.3`: custom buses must have a resource-based policy. Mapped to **NIST 800-53 r5 AC-\*** and **PCI DSS v4.0.1 10.3.1** — a FAIL is an external compliance finding, not just an internal one.
- [ ] Bus has a resource-based policy listing producer accounts / an org condition (ties to EVB-05).
- [ ] Remediation applied **or** scoped exception filed with the compliance mapping noted.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### AWS-SECHUB-EB4 / AWS-GE-REPLICATION · method: `evidence` — cross-ref `AWS-GE-REPLICATION`
Security Hub `EventBridge.4`: global endpoints must have event replication enabled.
- [ ] Replication `ENABLED` on the global endpoint (auto-PASS when the endpoint is deployed; N/A otherwise).
- [ ] Secondary-Region consumer confirmed actually processing replicated events (AWS best practice: don't just enable, verify the secondary path works).
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### AWS-GE-QUOTA-PARITY · method: `evidence` — cross-ref `AWS-GE-QUOTA-PARITY`
Global-endpoint best practice: `PutEvents` throttle quota + target limits must match across Regions so the secondary absorbs the primary's full rate on failover.
- [ ] `PutEvents` quota (`L-7B264GC8`) equal in both Regions.
- [ ] Target/rule limits raised consistently across Regions.
- [ ] If the suite reports UNKNOWN, grant the deployer `servicequotas:GetServiceQuota` (read-only) so this can be auto-verified, then re-run.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### AWS-GE-HEALTHCHECK · method: `evidence` — cross-ref `AWS-GE-HEALTHCHECK`
Global-endpoint best practice: the Route 53 health check must **exclude subscriber (SQS/Lambda) metrics** — a single unhealthy subscriber must not trigger a Region failover.
- [ ] Health check tracks the Region/publish path, not subscriber processing metrics.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### AWS-BATCH-LIMITS · method: `plan` (code contract) — cross-ref `AWS-BATCH-LIMITS`
`PutEvents`/`PutRawEvents` accept **1–100 entries and ≤256 KB per request** (distinct from the 1 MB-per-event limit in EVB-15).
- [ ] Producer caps/chunks batches to ≤100 entries and ≤256 KB per request (confirm no caller can exceed it).
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### AWS-PUTEVENTS-PARTIAL · method: `plan` (code contract, confirms a FAIL) — cross-ref `AWS-PUTEVENTS-PARTIAL`
A `PutEvents` 200 response can still carry `FailedEntryCount > 0` per entry. Producers must **detect and retry** failed entries, or events are silently lost.
- [ ] Producer inspects `FailedEntryCount`/`ErrorCode` and retries failed entries with backoff.
- [ ] Remediation applied **or** exception filed (e.g. at-most-once is acceptable for this flow — justify).
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

### AWS-IMMUTABLE-ID · method: `plan` (code contract) — cross-ref `AWS-IMMUTABLE-ID`
Event IDs change across API calls / replay, so correlation needs an **immutable business key** in the payload and idempotent consumers (ties to EVB-15).
- [ ] Every event carries an immutable business key (e.g. `orderId`/UUID).
- [ ] Consumers key idempotency off that business key, not the EventBridge event id.
- Evidence: ______________________  Status: ____  Verifier: __________  Date: ________

---

## Sign-off

| Field | Value |
|-------|-------|
| Deployment / account | ______________________ |
| Reviewer | ______________________ |
| Review date | ______________________ |
| Automated manifest ref | `.runtime/compliance/manifest.json` @ ________ |
| Overall result | PASS / FAIL / CONDITIONAL (with open items) |
| Next review due | ______________________ |

> A control left `UNKNOWN` here is **not** a pass. Produce the named evidence or
> file a scoped, time-boxed exception (EVB-19, ≤ 90 days) before release.
