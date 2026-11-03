# Bridge production roadmap: running against a separate HA / uniform-cluster MQ

Legend: **[TESTED]** we ran it live (lab: one IBM MQ developer container, image `icr.io/ibm-messaging/mq:10.0.0.5-r2`, one bridge, one EC2 host) · **[DESIGN]** reasoned from the code and repo, not run · **[VERIFY]** general IBM MQ / AWS knowledge; confirm for your MQ version and edition.

**Status of every item below: NOT IMPLEMENTED.** This is an engineering backlog, not a description of what the bridge does today. What the bridge does today is in [`../bridge/README.md`](../bridge/README.md).

Related documents (this file does not repeat their prose): topologies, networking and MQ-side security are in [`PRODUCTION_MQ_CLUSTER.md`](PRODUCTION_MQ_CLUSTER.md); failure scenarios S1-S6 and the deferred secondary outbound path are in [`RESILIENCE_AND_LIMITATIONS.md`](RESILIENCE_AND_LIMITATIONS.md); how to prove a production MQ is configured correctly is in [`PRODUCTION_VERIFICATION_CHECKLIST.md`](PRODUCTION_VERIFICATION_CHECKLIST.md); the MQSC template is [`examples/20-eventbridge-cluster.mqsc.example`](examples/20-eventbridge-cluster.mqsc.example).

## 1. Context

In production the MQ team runs MQ as a separate, natively highly available deployment (Native HA and/or a uniform cluster). The bridge becomes a **client** of it. Today the bridge assumes exactly one queue manager at one `host:port`, plaintext, with a password in an environment variable. [DESIGN, from reading `config.py` and `mq_client.py`]

### 1.1 Behaviours proven in the lab that every item must preserve

| Behaviour [TESTED in the lab] | Unit tests that cover it (`bridge/tests/`) | Live checks that cover it |
|---|---|---|
| MQ -> EventBridge: **commit only after `PutEvents` succeeds** (`FailedEntryCount == 0`); retry up to 5 times; otherwise roll back | `test_to_eventbridge.py`: `test_commit_only_after_success`, `test_failed_entry_then_success_retries`, `test_persistent_failure_rolls_back`, `test_exception_from_boto_rolls_back`, `test_commit_failure_propagates` | `live_loop_check.py` A, B, C |
| EventBridge -> MQ: **delete the SQS message only after the MQ commit**; any MQ failure leaves it in SQS | `test_from_eventbridge.py`: `test_deletes_only_after_commit`, `test_no_delete_when_commit_fails`, `test_no_delete_when_put_fails` | `live_loop_check.py` E |
| **Loop guard**: events with `detail.origin == "ibm-mq"` are deleted and never put on MQ; apps cannot set `origin` on inbound messages | `test_from_eventbridge.py::test_origin_ibm_mq_dropped_and_deleted`, `test_transform.py::test_origin_detection`, `test_contract.py::test_apps_cannot_set_bridge_metadata_on_inbound_messages` | `live_loop_check.py` F; end-to-end on the lab stack (RESILIENCE section 6) |
| **Poison -> DLQ**: invalid message rolled back 3 times, then re-put on the backout queue in the same unit of work; valid neighbours are not blocked | `test_to_eventbridge.py`: `test_poison_rolls_back_without_put`, `test_backout_threshold_moves_to_dlq` | `live_mq_check.py` 3, 5, 6; `live_loop_check.py` D, G |
| Reconnect with backoff after an MQ error | `test_to_eventbridge.py::test_run_reconnects_then_stops` (loop 1 only; loop 2 has no unit test for it) | none (not exercised live) |
| Password never logged | `test_config.py::test_password_not_in_repr` | n/a |
| Login: right password accepted, wrong password refused (2035) | n/a | `live_mq_check.py` 1, 2 |

Every change below must keep these tests green and add its own. A change that needs one of these tests to be edited is a behaviour change and needs its own review. [DESIGN]

### 1.2 Interim ways to connect today, with no code change (all [DESIGN], none run)

* **Single address.** If the MQ team exposes the queue manager (Native HA active instance) behind one stable DNS name or load balancer address, `MQ_HOST=<that name>`, `MQ_PORT=<port>` works as is, over plaintext only. TLS is not possible (R4).
* **Connection-name list hack.** `connect()` builds `f"{mq_host}({mq_port})"`, and `Config` does not validate `MQ_HOST`, so `MQ_HOST='hostA(1414),hostB'` with `MQ_PORT=1414` produces `hostA(1414),hostB(1414)`. This is an accident of string formatting, not a supported feature; it needs the same port on every host. Use it only to try a failover, and replace it with R1.
* **One bridge deployment per queue manager** (each with its own `MQ_HOST`/`MQ_QMGR`) gives "one consumer per queue manager" for a clustered `ORDERS.OUT` without code changes (see R3), at the cost of N deployments to operate.

## 2. Backlog

Sizes: S = under a day, M = a few days, L = a week or more including live testing. Estimates are rough and not measured.

### R1. Connection-name list or CCDT instead of single `MQ_HOST` / `MQ_PORT`  (size M)

* **What.** Accept an ordered list of `host(port)` entries, or a client channel definition table (JSON CCDT file or URL).
* **Why.** A Native HA queue manager has several instance addresses (only the active one accepts connections) and a uniform cluster has several queue managers. A single host cannot express either. [DESIGN]
* **Where.** `config.py`: `REQUIRED` contains `MQ_HOST`; `Config.mq_host`/`mq_port`. `mq_client.py::MQClient.connect`: `cd.ConnectionName = f"{c.mq_host}({c.mq_port})"`, `cd.ChannelName`, `mq.QueueManager(None)`, `connect_with_options(c.mq_qmgr, cd=cd, user=..., password=...)`.
* **Proposed config.** `MQ_CONNAME_LIST` (`hostA(1414),hostB(1414)`; keep `MQ_HOST`/`MQ_PORT` working when it is unset), and `MQ_CCDT_URL` or `MQ_CCDT_PATH`. With a CCDT the code would not build a `CD` at all and would connect with the queue manager name (or a `*GROUP` name) and rely on the CCDT (`MQCHLLIB`/`MQCHLTAB`, or `MQCCDTURL`). [VERIFY] JSON CCDT and URL-based CCDT need a recent enough client (introduced in the 9.1.x line, confirm for the client version in the Dockerfile), and `ibmmq`'s handling of `cd=None`. Mutually exclusive validation in `Config.from_env` (fail fast, exit 2, like today).
* **Tests.** Offline: extend `test_config.py` (list parsing, precedence, mutual exclusion, bad entries); a `mq_client` unit test with a stubbed `ibmmq` asserting the `ConnectionName` string. Live: `live_mq_check.py` against two addresses where the first is dead.
* **Open question.** `MQ_QMGR` today is the real queue manager name. With a Native HA group or a CCDT group it can be `*GROUPNAME`; the `backout`/`BOQNAME` logic must then not assume a fixed name. [VERIFY]

### R2. Automatic client reconnect and what the loops do after it  (size L)

* **What.** Ask the MQ client library to reconnect by itself (reconnect to the same queue manager, or to any queue manager in the group), and make both loops correct when it happens.
* **Why.** Today every MQ error ends in `run()`: close everything, sleep with exponential backoff (1 s up to 30 s), build a new `MQClient`, connect again. That works (unit-tested only, `test_run_reconnects_then_stops`; never exercised live). With a failover it is correct but slow and noisy, and the new connection can land on a different queue manager. [DESIGN]
* **Where.** `mq_client.py::MQClient.connect` (connect options), `get`, `commit`, `backout`, `put_persistent`, `_load_backout_settings` (cached at connect, see below), `to_eventbridge.py::ToEventBridge.step` / `run`, `from_eventbridge.py::FromEventBridge.handle` / `run`.
* **Proposed config.** `MQ_RECONNECT` = `off` (default, today's behaviour) | `qmgr` (same queue manager) | `any`; `MQ_RECONNECT_TIMEOUT` seconds. In `ibmmq` this would be the `opts` argument of `connect_with_options` with `MQCNO_RECONNECT` / `MQCNO_RECONNECT_Q_MGR`; the timeout normally comes from `mqclient.ini` (`Channels:` stanza, `MQReconnectTimeout`). [VERIFY] exact constant names, `ibmmq` signature, and that the timeout can be set per process.
* **What the loops must do on reconnect** (all [VERIFY] against IBM's reconnection documentation, then test live):
  * **Unit of work.** A local (non-XA) unit of work in flight when the connection breaks is backed out by the queue manager; the next call on the reconnected handle returns a backed-out reason (2003) instead of succeeding. `commit()` already turns any MQ error into `MQClientError`, so `step()` propagates and `run()` reconnects. The message is redelivered. That is the correct outcome and it preserves "commit only after publish": at worst the event was already published, giving a **duplicate**, never a loss. [DESIGN]
  * **Commit in doubt.** If the connection breaks *during* `MQCMIT` the application cannot know whether the commit happened. Loop 1: the message may be redelivered after it was published (duplicate event; consumers must be idempotent on `orderId`, as documented). Loop 2: commit happened but the SQS delete did not, so the SQS message comes back (duplicate on `ORDERS.IN`). Both are the documented at-least-once behaviour. [DESIGN]
  * **Re-open the queue.** With reconnect, the client library restores object handles, but `MQClient` also caches `backout_threshold`, `backout_queue` and the open `_boq` handle. After a move to a *different* queue manager these may be stale. Safest: after any reconnect event, re-run `_load_backout_settings()` and drop `_boq`. [DESIGN]
  * **Backout count.** `BackoutCount` is stored with the message. [VERIFY] whether a queue-manager-initiated backout (connection loss) increments it, and whether it survives a Native HA failover. If it does, several failovers during one publish can push a healthy message toward `BOTHRESH` (3); this is the same exposure the README already describes for a prolonged AWS outage.
  * **Blocked calls.** While the library is reconnecting, MQ calls block. The loops only check `stop` between calls, so SIGTERM during a reconnect waits for the reconnect timeout. Keep the timeout well below the orchestrator's stop timeout (R13).
* **Tests.** Offline: fake `MQClient` raising `MQClientError(reason=2003)` from `commit`, assert no SQS delete (loop 2) and no lost message (loop 1); a test that `_load_backout_settings` is re-run. Live: stop and start the queue manager (and, on the real cluster, kill the active Native HA instance) while `live_loop_check.py`-style traffic runs; assert zero loss, record duplicates. See drills in [`PRODUCTION_VERIFICATION_CHECKLIST.md`](PRODUCTION_VERIFICATION_CHECKLIST.md) section 4.

### R3. Uniform cluster: application tag, several bridge instances, one consumer per queue manager  (size L)

* **What.** Make the bridge behave correctly when `ORDERS.OUT` and `ORDERS.IN` are clustered queues with an instance on several queue managers.
* **Why.** A clustered queue has a separate set of messages on each queue manager that hosts it. A producer's `MQPUT` is workload-balanced to one instance. A message on queue manager QM2's `ORDERS.OUT` is only read by a consumer connected to QM2. If the bridge reads only from QM1, orders on QM2 wait forever. [DESIGN]
* **Where.** `mq_client.py::MQClient.connect`: `mq.Queue(self._qmgr, self.queue_name, MQOO_INPUT_SHARED | MQOO_INQUIRE)` for loop 1; `mq.Queue(..., MQOO_OUTPUT)` for loop 2 (no `MQOO_BIND_NOT_FIXED`; with the default bind-on-open, one connection keeps putting to the same instance until it reconnects). `main.py::main` starts exactly one `ToEventBridge` and one `FromEventBridge`.
* **Design options.**
  1. *Pinned consumers (recommended for `ORDERS.OUT`).* One bridge task per queue manager, each with a connection list containing only that queue manager (or only its Native HA group). No rebalancing. Needs `BRIDGE_ROLES` below so loop 2 is not duplicated N times for no reason. [DESIGN]
  2. *Rebalanced consumers.* Uniform clusters can move reconnectable applications between queue managers to even out connection counts; the application is identified by its application tag. This conflicts with "exactly one consumer on each queue manager" for `ORDERS.OUT`: the cluster balances *counts*, not coverage. If used, add a check that every queue manager has `IPPROCS >= 1` on `ORDERS.OUT` (checklist section 1) and alarm on it. [VERIFY] how rebalancing decides, and which reconnect options make an application eligible.
* **Proposed config.** `MQ_APPLTAG` (sets the application name seen by `DISPLAY CONN`/`DISPLAY QSTATUS ... TYPE(HANDLE)`; [VERIFY] whether this is the `MQAPPLNAME` environment variable or a connect-option field in your client version); `BRIDGE_ROLES` = `to-eb,from-eb` (default both; allows a deployment that only runs loop 2, which can be a plain competing consumer of SQS and can run on any queue manager). For loop 2 use `MQOO_BIND_NOT_FIXED` so each put can pick an instance, or define `ORDERS.IN` with `DEFBIND(NOTFIXED)` ([VERIFY], template section 1). Decide where `ORDERS.IN` instances live, because the applications that read it need a consumer on each of those queue managers too.
* **Ordering.** More than one consumer on one queue, or a workload-balanced cluster, gives up strict global ordering. The lab never promised ordering across orders; confirm with the owners of the consuming systems. [DESIGN]
* **Tests.** Offline: `Config` tests for the new vars; a `main.py` test (none exists today) that `BRIDGE_ROLES` starts the right threads. Live: on a two-queue-manager cluster put 100 orders from an application connected to each queue manager, and assert all arrive on the bus exactly once (duplicates counted separately), and that after stopping one bridge task its queue manager's `ORDERS.OUT` depth grows (proving the coverage requirement, and that the alarm fires).

### R4. TLS from the bridge to MQ  (size M)

* **What.** Cipher spec, key repository, optional client certificate, optional peer-name check, certificate rotation in a container.
* **Why.** The lab channel has no `SSLCIPH`; the lab is plaintext on loopback/Docker only (`SECURITY.md` section 4). Production traffic crosses a network and must be encrypted. The template makes `SSLCAUTH(REQUIRED)`, so the bridge must present a certificate. [DESIGN]
* **Where.** `mq_client.py::MQClient.connect`: nothing sets `cd.SSLCipherSpec`, `cd.SSLPeerName`, or an `SCO` with a key repository. `config.py`: no TLS settings. `bridge/Dockerfile`: the redistributable client includes the TLS libraries [VERIFY]; the key repository itself must be mounted, not baked in.
* **Proposed config.** `MQ_SSL_CIPHER_SPEC`, `MQ_SSL_KEY_REPOSITORY` (path without extension), `MQ_SSL_PEER_NAME` (optional DN filter), `MQ_SSL_KEY_REPO_PASSWORD_FILE` or the secret mechanism of R7, `MQ_SSL_CERT_LABEL`. In `ibmmq`: `cd.SSLCipherSpec`, `cd.SSLPeerName`, `sco = mq.SCO(); sco.KeyRepository = ...` passed to `connect_with_options(..., sco=sco)`. [VERIFY] attribute names and whether PKCS12 key repositories are accepted by the client version in use. Validate in `Config.from_env`: cipher and key repository must be set together.
* **Certificate rotation in a container.** The key repository is read when a connection is made, so a rotated certificate is picked up at the next (re)connect; established connections keep the old one until they drop. Options: (a) rolling-restart the tasks on rotation (simplest, [DESIGN]); (b) the bridge watches the key repository mtime and closes/reopens its connections at a quiet moment. Prefer (a) first. The server side needs `REFRESH SECURITY TYPE(SSL)` after it rotates its own certificate. [VERIFY]
* **Tests.** Offline: `Config` validation, stubbed-`ibmmq` test asserting the `CD`/`SCO` fields. Live: **`live_mq_check.py` and `live_loop_check.py` cannot run against a TLS channel today** because they go through `MQClient.connect`; they will once R4 lands. Add negative checks: wrong cipher refused, no client certificate refused, certificate not matching `SSLPEERMAP` refused, expired certificate refused.

### R5. Classify MQ errors: transient vs permanent  (size S)  [not in the original list]

* **What.** Treat reasons such as "not authorized" (2035), "unknown object" (2085) and TLS failures differently from "connection broken" (2009), "queue manager not available" (2059), "queue manager stopping/quiescing" (2162/2161), "host not available" (2538). [VERIFY] numbers against IBM's reason-code list.
* **Why.** `run()` in both loops treats every `MQClientError` the same: log, back off at most 30 s, reconnect, forever. A permanent error (wrong password after a rotation, missing `AUTHREC`, wrong cipher) then retries every 30 s indefinitely. With an LDAP lockout policy that can **lock the bridge's own account** (and then every other client of that account). [DESIGN]
* **Where.** `to_eventbridge.py::run`, `from_eventbridge.py::run` (`except MQClientError as e`), `util.py::next_delay` (cap 30 s, base 1 s).
* **Proposed.** A small classifier in `mq_client.py` returning `transient|permanent`; permanent errors use a long, capped backoff (for example 5 min), log at ERROR with the reason, and increment a metric (R11). Keep `MQClientError.reason`, which already exists.
* **Tests.** Offline: parametrised test over reason codes asserting the chosen delay. Live: wrong password for one attempt, assert the second attempt is not made within the long delay.

### R6. Identity by certificate, not password  (size M)

* **What.** Allow a bridge that authenticates to MQ with its client certificate only (no `MQ_USER`/`MQ_PASSWORD`).
* **Why.** `config.py::REQUIRED` demands `MQ_USER` and `MQ_PASSWORD`, and `MQClient.connect` always passes `user=` and `password=` (which sends an MQCSP; that is what satisfies `CHCKCLNT(REQUIRED)` [TESTED in the lab]). A queue manager with `CHCKCLNT(REQUIRED)` refuses a client that sends no credentials, so a certificate-only design needs `CHCKCLNT(OPTIONAL)` on the MQ side, which is an MQ-team security decision. [VERIFY]
* **Proposed config.** `MQ_AUTH_MODE` = `password` (default, today) | `certificate`. In `certificate` mode `MQ_USER`/`MQ_PASSWORD` are not required and `connect_with_options` is called without `user`/`password`. Requires R4.
* **Tests.** Offline: `Config` tests for both modes. Live: connect with certificate only against a channel with `SSLCAUTH(REQUIRED)` and a matching `SSLPEERMAP`; a certificate with a different DN is refused; a password-less connection with no certificate is refused.

### R7. Credentials from a secret store, not env passwords  (size S)

* **What.** Get the MQ password (and key repository passphrase) from AWS Secrets Manager, ECS task secrets, or Kubernetes secrets.
* **Why.** Lab: the password is in a Compose environment variable, visible with `docker inspect` (`SECURITY.md` section 1). `Config.secret_id` (`SECRET_ID`) exists but is **informational only; no code reads it** (`bridge/README.md`). [DESIGN, read from the code]
* **Where.** `config.py` (`mq_password`, `secret_id`), `mq_client.py::connect` (uses `c.mq_password`), `main.py`.
* **Options.**
  1. *Inject at start* (ECS `secrets` / `valueFrom`, Kubernetes secret as env or file). No code change beyond optional `MQ_PASSWORD_FILE`. A rotation needs a task restart. [DESIGN]
  2. *Fetch at every (re)connect* using the task role (`secretsmanager:GetSecretValue` on one secret). The new password is picked up by the next reconnect with no restart, which fits R5 and R2. Do not store it in the frozen `Config` or its `__repr__`; keep the existing redaction and test. [DESIGN]
* **Proposed config.** `MQ_PASSWORD_FILE`, `MQ_PASSWORD_SECRET_ID` (+ `MQ_PASSWORD_SECRET_KEY` if the secret is JSON).
* **Tests.** Offline: mocked `secretsmanager` client; password never in logs/`repr`/exception text (extend `test_password_not_in_repr`). Live: rotate the password during a run and see the next reconnect succeed.

### R8. Backout queue handling for a cluster  (size M)

* **What.** Make backout / poison handling explicit and safe when the queue manager is shared and clustered.
* **Why and where.** From `mq_client.py` and `to_eventbridge.py::step`:
  * `_load_backout_settings` swallows `MQMIError` and sets `backout_threshold = 0`, `backout_queue = ""`. If the bridge identity lacks `INQ` on `ORDERS.OUT`, poison handling is **silently disabled**. [DESIGN]
  * When the threshold is 0 or the queue name is empty, `step()` skips the move and a poison message is rolled back forever. `TransformError` handling returns `True` immediately (no delay), so the loop re-gets the same message at once: a hot loop, and head-of-line blocking on that queue manager. [DESIGN]
  * `move_to_backout_queue` re-puts with a new `MD` (persistence, `CorrelId` = original MsgId only). The original format, CCSID and encoding are not copied, and there is no dead-letter header. Replay tooling that expects the original `MD` or an `MQDLH` will not find them. [DESIGN, from reading the code; the move itself is [TESTED]]
  * The backout queue is resolved on the connected queue manager. In a cluster it must be a **local, non-clustered** queue defined on every queue manager (template section 1).
* **Proposed config.** `MQ_BACKOUT_QUEUE` (override), `MQ_BACKOUT_THRESHOLD_DEFAULT` (used when the queue reports 0), `MQ_REQUIRE_BACKOUT_CONFIG=true` (refuse to start consuming when the queue has no usable BOTHRESH/BOQNAME, or the INQ fails; log which). Copy `Format`, `CodedCharSetId`, `Encoding` of the original message on the move, and add a small delay after a `TransformError` rollback. Log the decision.
* **Tests.** Offline: extend `test_backout_threshold_moves_to_dlq`; new tests for the INQ failure, the missing-config refusal, and the copied `MD`. Live: extend `live_mq_check.py` 3 and 6 (they hard-code `threshold == 3` and `ORDERS.DLQ`; parametrise by env, R18).

### R9. List of SQS queue URLs, one per region  (size M)

* **What.** Replace the single `OUTBOUND_QUEUE_URL` by a list, with one poll loop per queue and one SQS client per queue region. This is the bridge half of the deferred secondary outbound path designed in [`RESILIENCE_AND_LIMITATIONS.md`](RESILIENCE_AND_LIMITATIONS.md) section 4 (its Terraform half is not repeated here).
* **Where.** `config.py` (`outbound_queue_url`, the `https://` check), `main.py` (one `boto3.client("sqs", region_name=cfg.aws_region)`), `from_eventbridge.py::FromEventBridge` (uses `cfg.outbound_queue_url` in `_delete` and `step`).
* **Proposed config.** `OUTBOUND_QUEUE_URLS` (comma separated; `OUTBOUND_QUEUE_URL` still accepted); region derived from each URL host. Each loop needs its **own MQ connection**, because an MQ handle must not be shared between threads (stated in `mq_client.py`).
* **Tests.** Offline: loop-per-URL test with two fake SQS clients. Live: `live_loop_check.py` E/F/G for two fake SQS queues. IAM: the role needs the second queue's receive/delete/attributes/visibility actions.

### R10. Health reporting beyond the touch-file  (size S)

* **What.** Separate "process is alive" from "ready to do useful work", expose it where the orchestrator can read it.
* **Why.** Today `touch_health()` writes `/tmp/healthy` at the top of each inner loop iteration and the Dockerfile `HEALTHCHECK` fails when the file is older than 120 s. The touch is only reached **after a successful connect**, so while the bridge is retrying a broken MQ connection it does not touch the file. An MQ outage longer than about two minutes therefore makes the container unhealthy, and under ECS/Kubernetes the task is killed and replaced for a failure it cannot fix by restarting, losing its backoff state. [DESIGN, from reading `to_eventbridge.py::run` and the Dockerfile]
* **Proposed.** A tiny HTTP endpoint (`HEALTH_PORT`): `/livez` = both worker threads alive; `/readyz` = each loop connected to MQ and last successful step or idle-poll within N seconds. Use `/livez` as the container health check (so an MQ outage does not restart the task) and `/readyz` for load balancer / rollout gating. Keep the file for the Docker lab.
* **Tests.** Offline: a thread-state test. Live: stop MQ for five minutes; the task stays alive and `/readyz` flips to not ready and back.

### R11. Metrics  (size M)

* **What.** Counters and gauges, exported without parsing logs. There are none today. [DESIGN, read from the code]
* **Proposed signals.** Messages in (MQ got), published, publish failures (by error code), backout moves, poison rollbacks, loop-guard drops, SQS received/delivered/left for redrive, MQ reconnects (by reason class from R5), connected gauge per loop, last-success timestamp, current queue manager name. Also, from outside the bridge: `ORDERS.OUT`/`ORDERS.DLQ` depth and oldest message age (MQ-side monitoring), SQS DLQ depth (CloudWatch).
* **How.** Either CloudWatch Embedded Metric Format JSON written to stdout (works with the `awslogs` driver, no agent, no extra IAM) or a Prometheus endpoint (`MQ_ENABLE_METRICS`-style, scraped on EKS). [VERIFY] EMF format and limits.
* **Tests.** Offline: counters change in the existing loop unit tests. Live: provoke each event once and see the metric.

### R12. Structured logs  (size S)

* **What.** JSON logs already exist (`util.py::JsonFormatter`; ids only, never bodies [DESIGN, read from the code]). Add context that matters on a cluster.
* **Gap.** `connected to MQ` logs the queue name only; it does not say **which queue manager and address** the bridge connected to, so a failover is invisible in the logs. Add `qmgr`, `conname` (not credentials), task/host id, loop name, `reason` on every MQ error (exists), and the backout count on moves (exists).
* **Tests.** Offline: log-field assertions; a test that no password or message body appears in captured logs.

### R13. Graceful shutdown with units of work in flight  (size S)

* **What.** Verify and tighten what `main.py` already does.
* **Current behaviour.** SIGTERM sets `stop`; each loop finishes its current iteration; `main` joins the threads for 30 s. Loop 1's `get` waits at most 5 s (`WAIT_MS`), PutEvents retries abort on `stop`, so the unit of work ends (commit or backout). Loop 2's SQS long poll is 20 s and not interruptible, and `step()` processes all (up to 10) received messages even after `stop` is set. After the 30 s join the process exits with daemon threads still running; the queue manager then backs out any open unit of work when the connection drops. [DESIGN, from reading the code; not tested live]
* **Gaps.** The 30 s join is close to a default orchestrator stop timeout (ECS default 30 s). Unprocessed SQS messages of a half-handled batch stay invisible until the visibility timeout (60 s). During an MQ client reconnect, shutdown waits (R2).
* **Proposed.** `SHUTDOWN_GRACE_SECONDS`; set ECS `stopTimeout` / Kubernetes `terminationGracePeriodSeconds` above it; on shutdown stop processing the rest of a batch and call `ChangeMessageVisibility(0)` for the unprocessed ones (the lab role already allows `sqs:ChangeMessageVisibility`).
* **Tests.** Offline: stop set mid-batch. Live: SIGTERM during traffic on a real queue manager, then confirm no message lost and no stuck unit of work (`DISPLAY QSTATUS ... TYPE(HANDLE)` shows no leftover handles).

### R14. Packaging as an ECS or EKS service  (size L)

* **What.** Run the bridge image as a service in the customer's account/VPC, next to (not on) the MQ hosts.
* **Image.** `bridge/Dockerfile` is already a multi-stage build on `python:3.12-slim`, runs as UID 10001 with a **writable home** (without it every connection failed with MQRC 2009; found and fixed on the lab EC2 host [TESTED]). Production: pull the IBM redistributable client from an internal artifact store pinned by checksum instead of the public URL at build time, scan, push to ECR. If the root filesystem is read-only (common on EKS), keep `HOME` and `/tmp` writable. [VERIFY] where the MQ client writes at run time.
* **Runtime.** Min 2 tasks across 2 AZs (a bridge task is stateless, so this is for availability; competing consumers on one queue give up strict ordering, R3). Task role: `events:PutEvents` on the bus ARN(s) including the failover bus; `sqs:ReceiveMessage/DeleteMessage/GetQueueAttributes/ChangeMessageVisibility` on the queue(s); `secretsmanager:GetSecretValue` on the MQ secret (R7). Execution role: image pull, logs, secret injection. Network: egress to every queue manager listener port (or the NLB), HTTPS to EventBridge, SQS, Secrets Manager (VPC endpoints are optional; [VERIFY] support for the EventBridge global endpoint / SigV4a through a VPC endpoint before relying on it). If tasks reach MQ through a NAT gateway, `MAXINSTC` on the channel must be sized for one shared source address (template section 3).
* **How the existing Terraform (`mq-integration/terraform/main.tf`) splits** [DESIGN, from reading it]:

| Existing resource | Production |
|---|---|
| `aws_sqs_queue.outbound`, `aws_sqs_queue.dlq`, `aws_sqs_queue_policy.*` | **Reuse** unchanged (redrive after 5 receives, TLS-only, SSE) |
| `aws_cloudwatch_event_rule.outbound`, `aws_cloudwatch_event_target.outbound` (`mq-outbound-rule`, with the `origin` exclusion) | **Reuse** unchanged |
| `aws_secretsmanager_secret.mq` | Reuse the container only if the MQ team does not already own the credential; the lab populates it from the instance at first boot, which no longer exists |
| `aws_iam_role.host` + policy `eb-mq-host` | **Rework** into a task role: keep `PutEventsOnBus`, optional `BusCmkUse`, `ConsumeOutboundQueue`; **drop** `ReadBundle` (S3) and `PutSecretValue`; drop the SSM managed-policy attachment |
| `aws_instance.mq`, instance profile, `templates/user-data.sh.tftpl`, `aws_s3_*` bundle, `network_check` | **Drop** (no EC2, no Docker host, no zipped bundle) |
| `aws_security_group.mq` and its ingress rules | **Replace** with a task security group: egress to MQ and HTTPS only, no ingress |
| (none) | **New**: ECR repository, ECS cluster/service/task definition (or Kubernetes manifests), log group, autoscaling or fixed count, alarms (R11), the secret wiring (R7) |

  Put the new Terraform in its **own root module**, not inside the lab `terraform/` directory, because that directory (and `docker/`) is zipped into the lab EC2 bundle.
* **Tests.** Offline: `terraform fmt/validate`, task-definition lint, `verify.sh`-style static checks. Live: deploy to a non-production account, run the checklist.

### R15. Remote-queue-manager mode for `verify-mq-objects.sh`  (size M)

* **What.** The script has three modes today: `--static` (greps the lab MQSC file), `--container NAME` (`docker exec` into a local container), and the default live mode (SSM to the lab EC2 host, then `docker exec`). **A mode for a queue manager you can only reach with `runmqsc` over some other transport does not exist.** [TESTED by reading the script]
* **Proposed.** `--runmqsc-cmd '<command that reads MQSC on stdin and runs runmqsc for the queue manager>'`, for example `'kubectl exec -i qm-0 -- runmqsc QM1'` or `'ssh mqhost runmqsc QM1'`, replacing the `mq_sh` function (which today wraps a bash script in `docker exec`). Make the hard-coded lab values parameters: queue manager name (`QM1`), `APP.SVRCONN`, `EB.AUTHINFO`, principal `app`, `IDPWOS`, port 1414, `MAXDEPTH(50000)`; accept `--mqsc FILE` so `--static` can check the production template instead of the lab file. The `--smoke` part uses `amqsputc` inside the container and will not work remotely without a client; leave it out of the remote mode.
* **Tests.** Offline: run `--static` against the template with the new `--mqsc`. Live: run against the real cluster and compare with the manual commands in the checklist.

### R16. Loop 2 error handling: SQS errors should not drop the MQ connection  (size S)  [not in the original list]

* **What.** In `from_eventbridge.py::run`, anything that is not an `MQClientError` (for example a botocore throttling or credentials error from `receive_message`, or from `_delete` after a successful MQ commit) falls into `except Exception`, which closes the MQ connection and reconnects with backoff.
* **Why.** With TLS and LDAP authentication every needless reconnect is a new TLS handshake and a new LDAP bind, and it adds noise during exactly the incidents where noise hurts. A failed `_delete` after the commit also guarantees a duplicate on `ORDERS.IN` after the visibility timeout (documented at-least-once). [DESIGN]
* **Proposed.** Catch SQS/boto errors around `receive_message` and `_delete` inside the inner loop with their own backoff; keep the MQ connection open.
* **Tests.** Offline: fake SQS raising on receive, assert `mq.connect` is not called again. Live: `live_loop_check.py` with an SQS fake that fails once.

### R17. Hard-coded tuning constants  (size S)  [not in the original list]

* **What.** `MAX_PUT_ATTEMPTS = 5` and `WAIT_MS = 5000` in `to_eventbridge.py`; `MaxNumberOfMessages=10`, `wait_seconds=20` in `from_eventbridge.py`; the 1 s / 30 s backoff in `util.next_delay`; the 120 s health threshold in the Dockerfile; the 30 s join in `main.py`. Move to env with the current values as defaults (`PUT_MAX_ATTEMPTS`, `MQ_GET_WAIT_MS`, `SQS_BATCH_SIZE`, `BACKOFF_MAX_SECONDS`, `SHUTDOWN_GRACE_SECONDS`).
* **Related.** Throughput is bounded by one message per unit of work (batching was a deliberate choice, see the README); there is no load-test data (RESILIENCE backlog item 7).
* **Tests.** `test_config.py` extension.

### R18. Make the live checks safe and parameterisable  (size S)  [not in the original list]

* **What.** `live_mq_check.py` and `live_loop_check.py` call `drain()` on `ORDERS.IN`, `ORDERS.OUT` and `ORDERS.DLQ` at the start and the end: **they consume and discard every message on those queues.** `live_mq_check.py` also hard-codes `threshold == 3`, `ORDERS.DLQ` and a deliberate wrong-password attempt. `live_loop_check.py` reads `schemas/samples/...` from the repository checkout.
* **Why.** Pointed at a production queue manager they would destroy live orders (and the wrong-password attempt can feed an LDAP lockout, R5).
* **Proposed.** Env-driven queue names (`CHECK_QUEUE_*`) with a refusal to run on queues that are not named for tests, a `--no-drain` mode that fails if the queue is not empty, an opt-out for the wrong-password check, expected threshold/backout queue from env.
* **Tests.** Offline: a unit test of the guard logic. Until this lands, run them only against a dedicated non-production cluster or a test copy of the queues, with the bridge and applications stopped. See [`PRODUCTION_VERIFICATION_CHECKLIST.md`](PRODUCTION_VERIFICATION_CHECKLIST.md) section 2.

## 3. Environment variables: today versus planned

**Implemented** means the variable is read by the code on this branch (`config.py`, `util.py`). **Planned** means it does not exist; the name is a proposal.

| Variable | State | Where read / purpose |
|---|---|---|
| `AWS_REGION` | implemented (default `us-east-1`) | `config.py`; boto3 clients in `main.py` |
| `EVENT_BUS_NAME`, `EVENT_SOURCE` | implemented, required | `config.py` |
| `OUTBOUND_QUEUE_URL` | implemented, required (https URL) | `config.py`; SQS loop |
| `MQ_HOST`, `MQ_PORT` (default 1414) | implemented; `MQ_HOST` required | `config.py`; `mq_client.py` builds `host(port)` |
| `MQ_QMGR`, `MQ_CHANNEL` | implemented, required | `config.py` |
| `MQ_USER`, `MQ_PASSWORD` | implemented, required; password redacted in `repr` | `config.py`; MQCSP in `connect` |
| `MQ_QUEUE_TO_EB`, `MQ_QUEUE_FROM_EB` | implemented, required, must differ | `config.py` |
| `EB_ENDPOINT_ID` | implemented, optional | `PutEvents(EndpointId=...)`; needs `awscrt` |
| `SECRET_ID` | implemented but **unused** (informational) | `config.py` stores it; nothing reads it |
| `LOG_LEVEL`, `POLL_INTERVAL` | implemented | `config.py` |
| `HEALTH_FILE` (default `/tmp/healthy`) | implemented | `util.py` |
| `MQ_CONNAME_LIST`, `MQ_CCDT_URL` / `MQ_CCDT_PATH` | **planned** (R1) | multiple endpoints |
| `MQ_RECONNECT`, `MQ_RECONNECT_TIMEOUT` | **planned** (R2) | client reconnect |
| `MQ_APPLTAG`, `BRIDGE_ROLES` | **planned** (R3) | uniform-cluster behaviour |
| `MQ_SSL_CIPHER_SPEC`, `MQ_SSL_KEY_REPOSITORY`, `MQ_SSL_PEER_NAME`, `MQ_SSL_CERT_LABEL` | **planned** (R4) | TLS |
| `MQ_AUTH_MODE` | **planned** (R6) | `password` or `certificate` |
| `MQ_PASSWORD_FILE`, `MQ_PASSWORD_SECRET_ID` (+ `_KEY`) | **planned** (R7) | secret sources |
| `MQ_BACKOUT_QUEUE`, `MQ_BACKOUT_THRESHOLD_DEFAULT`, `MQ_REQUIRE_BACKOUT_CONFIG` | **planned** (R8) | backout handling |
| `OUTBOUND_QUEUE_URLS` | **planned** (R9) | several SQS queues / regions |
| `HEALTH_PORT` | **planned** (R10) | `/livez`, `/readyz` |
| `METRICS_MODE` (`emf`/`prometheus`/`off`), `METRICS_PORT` | **planned** (R11) | metrics |
| `SHUTDOWN_GRACE_SECONDS`, `PUT_MAX_ATTEMPTS`, `MQ_GET_WAIT_MS`, `SQS_BATCH_SIZE`, `BACKOFF_MAX_SECONDS` | **planned** (R13, R17) | now constants |

AWS credentials are not an application variable: the default boto3 chain is used (instance role in the lab; task role in production).

## 4. Suggested order

1. **Before any production connection:** R18 (safe checks), R1, R4, R5, R7, R8. Without these the bridge cannot connect securely, can lock an account, and can hot-loop on poison.
2. **Before go-live:** R2, R3, R14, R10, R13, R16 (they decide how failovers actually behave), then R11/R12 so the failover drills can be observed.
3. **After go-live or when needed:** R6 (if the security team requires certificate-only), R9, R15, R17.

Each item needs its drill in [`PRODUCTION_VERIFICATION_CHECKLIST.md`](PRODUCTION_VERIFICATION_CHECKLIST.md) section 4 before it is marked done. Nothing here is done until it has run against a real HA / uniform-cluster queue manager.
