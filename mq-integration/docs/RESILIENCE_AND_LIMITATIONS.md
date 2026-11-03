# Resilience and limitations

Legend: **[TESTED]** we ran it live and have evidence (section 6); **[DESIGN]** reasoned from how this repo is built, not run; **[VERIFY]** from general IBM MQ / AWS knowledge, confirm against your own versions.

## 1. Summary

This is a single-host lab: one IBM MQ developer-image queue manager (`QM1`) and one bridge in Docker on one EC2 `t3.medium`, in one AZ of `us-east-1`. [TESTED] on the live stack: both flows work, the loop guard and the poison-message path work, and flow 1 through the EventBridge global endpoint survives a simulated primary-region impairment, including failback, without restarting the bridge. [TESTED] The gaps are equally important. Flow 2 (EventBridge to MQ) is not region-resilient, because the rule and queue exist only in the primary region. [TESTED absence] A whole-region outage of `us-east-1` takes the MQ host, the bridge and the SQS queue with it, so neither flow runs. [DESIGN] That is deliberately **not covered** here (section 3). Queued MQ messages live on one EBS volume and are lost whenever Terraform replaces the instance. [TESTED, it happened 3 times] Do not read the endpoint failover result as "the integration is highly available": only flow 1 was shown to fail over.

## 2. Failure scenarios

| Scenario | Flow 1 MQ -> EventBridge | Flow 2 EventBridge -> MQ | Data | Evidence |
|---|---|---|---|---|
| **S1** EventBridge primary-region impairment, MQ host still up (endpoint failover) | **Survives.** With `EB_ENDPOINT_ID` set, the bridge's `PutEvents` is routed to `us-west-2` after Route 53 marks the primary unhealthy; no bridge restart. Failback worked. [TESTED] | **Does not survive.** `mq-outbound-rule` and an SQS queue do not exist in `us-west-2`, so events processed by the secondary bus never reach MQ. [TESTED absence] Events already in the primary SQS queue stay there until the primary recovers. [DESIGN] | Flow 1: no loss seen; the order was received natively in `us-west-2` 104 s after Route 53 reported Unhealthy. Duplicates are possible, so consumers must be idempotent on `orderId`. [DESIGN] Flow 2: events published to the secondary bus during the window are not delivered to MQ at all. [DESIGN] | Failover drill, section 6 |
| **S2** Whole `us-east-1` region outage | **Does not run.** MQ host, bridge and SQS are all in `us-east-1`; there is no bridge anywhere else. [DESIGN] | **Does not run**, same reason. Nothing to fail over to. [DESIGN] | MQ messages on the EBS volume are unreachable for the duration and survive only if the region and volume recover. [VERIFY] Events published while down are not buffered for MQ (secondary has no rule). [TESTED absence] | **NOT covered and deferred.** Section 3 records why |
| **S3** AZ outage (the instance's AZ) | Stops: the instance and its EBS volume are in one AZ. [DESIGN] | Stops consuming. SQS is a regional service, so events keep landing in the queue and wait up to the retention period (default 4 days, `sqs_retention_seconds`). [DESIGN] | Messages on `ORDERS.OUT`/`ORDERS.IN` sit on an EBS volume that is bound to the failed AZ. A replacement instance (new AZ) does **not** have them. [DESIGN] [VERIFY] EBS behaviour in an AZ event | Not tested |
| **S4** MQ host or instance failure / replacement | Stops until a new host is up. Producers' `MQPUT` fail meanwhile. [DESIGN] | Stops consuming; SQS buffers. [DESIGN] | **Queued MQ messages are lost on replacement.** Queue data is in Docker volume `qm1data` on the root EBS; `user_data_replace_on_change = true` replaces the instance when the bundle or user_data changes. [TESTED, happened 3 times today] A plain reboot or container restart keeps the volume. [DESIGN] [VERIFY] | Observed during development |
| **S5** MQ down while EventBridge is up | `ORDERS.OUT` is not being read; nothing reaches EventBridge. Producers cannot `MQPUT` either. [DESIGN] | While the bridge cannot connect to MQ it does **not poll SQS at all** (the SQS loop only runs while the MQ connection is up: `from_eventbridge.py` `run()`), so events simply wait in `eb-mq-outbound` and nothing is redriven. A message already received when the connection drops is not deleted and becomes visible again after the 60 s visibility timeout. [DESIGN, read from the code] | Events are kept for the retention period (4 days, `sqs_retention_seconds`) and then **expire silently: they do NOT go to the DLQ**, so an MQ outage longer than that loses them. Only messages that are received but not deleted (a failed MQ put after connecting, or non-JSON) count towards the 5 receives and the DLQ. [DESIGN] | **Not tested live** (SQS retention and redrive with MQ down) |
| **S6** Poison (non-JSON / contract-invalid) message on `ORDERS.OUT` | Rolled back 3 times, then the bridge moves it to `ORDERS.DLQ`; the valid message behind it was not blocked. [TESTED] | n/a for MQ-origin poison. A non-JSON SQS body is left alone and parks in the SQS DLQ after 5 receives. [DESIGN] | Poison message preserved on `ORDERS.DLQ` for manual inspection and replay (lost if the instance is replaced, as S4). [TESTED] DLQ move; [DESIGN] loss on replacement | Poison test, section 6 |

Other things the table does not cover: a bridge-only crash between commit and delete gives duplicates, not loss. [DESIGN] A prolonged AWS outage raises backout counts and can send valid messages to `ORDERS.DLQ` (documented in `bridge/README.md`). [DESIGN]

## 3. Why a whole-region outage is not covered, and the decision

Everything stateful sits in one place: one queue manager in `us-east-1`. To survive loss of that region you need a queue manager in `us-west-2` **with the messages replicated or the queue manager made highly available across sites**, plus a bridge there. The free IBM MQ Advanced for Developers image used here does not provide that. [VERIFY] MQ Native HA, replicated data queue managers and uniform clusters are separate, licensed deployment patterns; check the exact entitlements for your version and licence. Building a pretend version on one developer image would give a false sense of safety and would be untested. [DESIGN]

**Decision (recorded):** in production, MQ is expected to be a separate, natively highly available / uniform-cluster deployment owned by the MQ team. The bridge plugs into it as a client. This lab will **not** try to solve whole-region MQ resilience. What the repo tracks instead is what the bridge needs to connect to such a cluster; see [`PRODUCTION_MQ_CLUSTER.md`](PRODUCTION_MQ_CLUSTER.md) and [`BRIDGE_PRODUCTION_ROADMAP.md`](BRIDGE_PRODUCTION_ROADMAP.md). The checks to run before trusting a production setup are in [`PRODUCTION_VERIFICATION_CHECKLIST.md`](PRODUCTION_VERIFICATION_CHECKLIST.md). Anyone reading S2 as "to be fixed in this lab" is mistaken: it is out of scope by decision.

## 4. Deferred design: make flow 2 survive an EventBridge regional failover

**Status: [DESIGN], not built, not tested.** This closes S1 for flow 2 only. It does not address S2-S4.

**Changes**

1. Terraform: in `us-west-2`, create on the secondary bus the same rule as `mq-outbound-rule` (same pattern, including the `origin` exclusion), an SQS queue and DLQ with the same redrive (5 receives), and the queue policies (SendMessage restricted by `aws:SourceArn`, TLS-only).
2. Bridge: replace the single `OUTBOUND_QUEUE_URL` with a list (new env var, for example `OUTBOUND_QUEUE_URLS`, comma-separated) and run one poll loop per queue, each with its own SQS client in that queue's region. The loops share the same put-commit-then-delete logic. The bridge on the `us-east-1` host would read the `us-west-2` queue cross-region over HTTPS.
3. IAM: extend the instance role's `ConsumeOutboundQueue` statement with the second queue's ARN (Receive, Delete, GetQueueAttributes, ChangeMessageVisibility). If the secondary bus uses a CMK, check the queue and rule delivery permissions there. [VERIFY]
4. Duplicate avoidance: with a rule on each bus, an event replicated by the endpoint could match both rules and be delivered twice. Give each rule an envelope `region` filter: primary rule `region = ["us-east-1"]`, secondary rule `region = ["us-west-2"]`, so exactly one rule matches a given event. This rests on a [TESTED] observation: a replica of an event published in `us-east-1` keeps envelope `region = us-east-1` in `us-west-2`, while an event received natively after failover has `region = us-west-2`.
5. **Untested assumption:** an event received in `us-west-2` during failover and then replicated back to the primary keeps `region = us-west-2`. If instead the region is rewritten, the primary rule would pick it up, or neither rule would, and the filter logic must change. Test this before building. [DESIGN]

**Effort and cost (rough estimate, not measured):** about M in size: roughly one Terraform change in a second region, one small bridge change (list of URLs, one loop per queue, tests) and an IAM edit, plus the live test below. Running cost is pennies (an extra SQS queue and rule); the cross-region SQS reads add small data-transfer charges. [VERIFY] current pricing.

**Test plan**

| Phase | Action | Pass condition |
|---|---|---|
| Healthy | Publish one event through the endpoint and one on the regional bus | Each appears exactly once on `ORDERS.IN` (no double delivery from the two rules) |
| Failover | Run the health-Lambda failover drill, publish via the endpoint | The event still reaches `ORDERS.IN` (via the `us-west-2` queue) |
| Failback | Restore health, publish again | Exactly once on `ORDERS.IN`; both queues drain; both DLQs empty |
| Replica-back | Check envelope `region` of failed-over events after replication to the primary | Confirms or refutes the untested assumption in point 5 |
| Bonus | Stop MQ, publish during failover, restart MQ | Events wait in the `us-west-2` queue while MQ is down and are delivered after (subject to the 4-day retention in S5; nothing is redriven while MQ is down) |

## 5. Prioritised backlog of deferred items

| Priority | Item | Why | Size |
|---|---|---|---|
| 1 | Flow-2-via-endpoint test (events published with `--endpoint-id`, healthy and during failover) | Only the regional-bus path is tested; this decides what the real failover behaviour of flow 2 is | S |
| 2 | SQS-down-MQ-up / MQ-down-SQS-up live test (retention, redrive to DLQ, manual redrive) | S5 is [DESIGN] only | S |
| 3 | Production MQ cluster connection support (see [`BRIDGE_PRODUCTION_ROADMAP.md`](BRIDGE_PRODUCTION_ROADMAP.md)) | The decision in section 3 depends on the bridge connecting to HA / uniform-cluster MQ (reconnect, CCDT, multiple endpoints) | L |
| 4 | Secondary outbound path (section 4) | Closes S1 for flow 2 | M |
| 5 | TLS on the MQ channel (see [`SECURITY.md`](SECURITY.md) section 4) | Channel is plaintext, acceptable only because the listener is bound to 127.0.0.1 | M |
| 6 | Docker secrets or Secrets Manager injection instead of deprecated `MQ_*_PASSWORD` env vars | The image flags the env vars as deprecated; they work in 10.0.0.5-r2 but may not forever; visible via `docker inspect` | S |
| 7 | Load test (throughput, latency, backlog drain) | No performance data at all | M |
| 8 | Persist MQ data across instance replacement (separate EBS data volume or backup/restore) | Replacement currently destroys queued messages (S4); not needed if production MQ is separate | M |

## 6. Evidence behind the [TESTED] tags

Run on 2026-11-03 in account 968220652414 (`us-east-1` primary, `us-west-2` secondary), image `icr.io/ibm-messaging/mq:10.0.0.5-r2`, one `t3.medium`, `QM1`.

- Flow 1: an order on `ORDERS.OUT` reached the existing consumer Lambda via EventBridge; `ORDERS.OUT` drained; commit only after `PutEvents` succeeded.
- Flow 2: an event with no `detail.origin`, published on the **regional** bus (no `--endpoint-id`), matched `mq-outbound-rule`, landed in `eb-mq-outbound`, reached `ORDERS.IN`; SQS drained after the MQ commit.
- Loop guard: an event with `origin=ibm-mq` did not come back to `ORDERS.IN`. Poison (non-JSON) message: 3 rollbacks, then moved to `ORDERS.DLQ`; a valid message behind it was not blocked.
- Global endpoint `hfzmrj3sp9.veo`: the bridge published with `EndpointId` (SigV4a); an MQ order replicated to `us-west-2` and was processed there (replica envelope `region = us-east-1`, `detail.origin = ibm-mq`).
- Failover drill (health Lambda `HEALTHY=false`): Route 53 reported the primary Unhealthy after 97 s; an MQ order was received natively in `us-west-2` (envelope `region = us-west-2`) 104 s later with no bridge restart. Failback to `us-east-1` worked. This is faster than the documented 360-420 s RTO in [`../../docs/CICD_AND_OPERATIONS.md`](../../docs/CICD_AND_OPERATIONS.md) section 3; treat the single run as one data point, not a guarantee. [DESIGN]
- Confirmed absent: `mq-outbound-rule` and any SQS queue in `us-west-2`.
- Instance replacement destroyed queued MQ messages three times (Terraform `user_data_replace_on_change`).

**Not tested:** flow 2 for events published through the endpoint; flow 2 during or after failover; MQ down while events arrive (SQS retention and redrive live); TLS; load; any multi-queue-manager, Native HA or uniform-cluster setup.

See also: [`ARCHITECTURE.md`](ARCHITECTURE.md) section 8, [`SECURITY.md`](SECURITY.md).
