# IBM MQ <-> EventBridge bridge

Two loops in one container (threads, one MQ connection each):

| Direction | Source | Target |
|---|---|---|
| MQ -> AWS | queue `MQ_QUEUE_TO_EB` (`ORDERS.OUT`) | `PutEvents` on `EVENT_BUS_NAME` (`eb-prod-orders`) |
| AWS -> MQ | SQS `OUTBOUND_QUEUE_URL` (fed by rule `mq-outbound-rule`) | queue `MQ_QUEUE_FROM_EB` (`ORDERS.IN`) |

AWS credentials come from the default chain (EC2 instance role via IMDSv2); no keys are configured.

## Configuration

| Variable | Required | Default | Notes |
|---|---|---|---|
| `AWS_REGION` | no | `us-east-1` | |
| `EVENT_BUS_NAME` | yes | | `eb-prod-orders` |
| `EVENT_SOURCE` | yes | | `prod.orders` |
| `OUTBOUND_QUEUE_URL` | yes | | https SQS URL |
| `MQ_HOST` / `MQ_PORT` | host yes | port `1414` | |
| `MQ_QMGR` | yes | | `QM1` |
| `MQ_CHANNEL` | yes | | `APP.SVRCONN` |
| `MQ_USER` / `MQ_PASSWORD` | yes | | password never logged (redacted in repr) |
| `MQ_QUEUE_TO_EB` / `MQ_QUEUE_FROM_EB` | yes | | must differ |
| `EB_ENDPOINT_ID` | no | unset | if set, `PutEvents(EndpointId=...)`; needs `awscrt` (SigV4a), installed via `boto3[crt]` |
| `LOG_LEVEL` | no | `INFO` | |
| `POLL_INTERVAL` | no | `1.0` | seconds to sleep after an empty MQ wait |
| `SECRET_ID` | no | | informational only; not read by the code |
| `HEALTH_FILE` | no | `/tmp/healthy` | touched every loop iteration |

Missing/invalid variables abort startup (exit 2) with one message listing all of them.

## Message formats

**MQ -> EventBridge.** The MQ message body is UTF-8 JSON, exactly the `OrderPlaced` contract
(`schemas/prod.orders__OrderPlaced.json`): `orderId` (UUID), `product`, `quantity` (int >= 1),
`amount` (number >= 0), `placedAt` (date-time); no other fields. Resulting entry:
`Source=EVENT_SOURCE`, `DetailType=OrderPlaced`, `EventBusName=EVENT_BUS_NAME`,
`Detail = {<order fields>, "origin": "ibm-mq", "correlationId": "<hex>"}`.
`correlationId` is the MQ CorrelId hex if non-zero, else the MsgId hex.

**EventBridge -> MQ.** The SQS body (the full EventBridge event JSON, as delivered by the rule) is put
unchanged (compact) as a persistent text message, CCSID 1208, format `MQSTR`. Non-JSON bodies are
rejected; events with `detail.origin == "ibm-mq"` are dropped and deleted (anti-loop guard).

## Delivery semantics

At-least-once in both directions. Consumers must be idempotent, keyed on `orderId`
(duplicates arise after a crash between `PutEvents` and MQ commit, or between MQ commit and SQS delete).

MQ -> EB: one message per unit of work. Get under syncpoint; `PutEvents` (up to 5 attempts with
exponential backoff, retrying `FailedEntryCount > 0` and client errors); **commit only when
`FailedEntryCount == 0`**, otherwise roll back. Batching was deliberately not used: one bad message
would otherwise roll back its good neighbours and inflate their backout counts.

Poison messages (invalid JSON/contract, >~254 KB) are rolled back. A plain MQI application is
responsible for honouring `BOTHRESH`/`BOQNAME` (the queue manager does not move messages for it), so the
bridge reads both from the queue and, when a message's backout count reaches the threshold, re-puts it
on the backout queue and commits (same unit of work). Caveat: a prolonged AWS outage also raises
backout counts of valid messages and can send them to the DLQ; monitor `ORDERS.DLQ` and replay.

AWS -> MQ: long-poll (20 s, up to 10 messages). Put + commit to MQ, **then** delete from SQS. Any MQ
failure leaves the message in SQS (redelivered after visibility timeout). Non-JSON messages are neither
delivered nor deleted; configure a redrive policy/DLQ on the SQS queue.

## Failure behaviour

* MQ down: loop closes the connection and reconnects with exponential backoff (1 s .. 30 s); uncommitted work is backed out by MQ.
* SIGTERM: stops taking new work; the in-flight unit finishes (or is backed out), threads joined (30 s).
* A dead worker thread makes the process exit non-zero (container restart policy applies); the Docker
  HEALTHCHECK fails if the health file is older than 120 s.
* Logs are JSON on stdout; INFO logs contain ids only (MQ MsgId, orderId, SQS ids), never bodies.

## Tests / build

    python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/python -m pytest

Unit tests are offline (fake MQ, mocked boto3 clients, stubbed `ibmmq`).

**Live checks against a real queue manager** (not pytest modules; no AWS needed) prove what mocks
cannot: `tests/live_mq_check.py` (the `MQClient` wrapper: login, wrong password, backout settings,
syncpoint, dead-letter move) and `tests/live_loop_check.py` (both delivery loops with fake AWS
clients). They need the IBM MQ C client (`LD_LIBRARY_PATH=<client>/lib64`), the `ibmmq` package and
a reachable queue manager with the objects from `docker/mqsc/20-eventbridge.mqsc`, e.g. started by
`scripts/local-mq-check.sh` with `KEEP=1`. Both were run against `icr.io/ibm-messaging/mq:10.0.0.5-r2`
(17 checks, all PASS) and caught a real bug the unit tests could not (channel constants live in
`ibmmq.CMQXC`, not `CMQC`).

The Dockerfile downloads IBM's redistributable client for `MQ_CLIENT_VERSION` (default `10.0.0.5`,
confirmed to exist at the URL in the file; the previous default `9.4.2.0` returned HTTP 404). Review
IBM's licence terms for the redistributable client before use.
