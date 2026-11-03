# Production verification checklist: proving the bridge against a separate MQ deployment

Legend: **[TESTED]** we ran it live (lab only: one IBM MQ developer container, image `icr.io/ibm-messaging/mq:10.0.0.5-r2`, one bridge on one EC2 host) · **[DESIGN]** reasoned from the repo, not run · **[VERIFY]** general IBM MQ / AWS knowledge; confirm for your MQ version and edition.

**Nothing in this checklist has been run against a production-style MQ (Native HA, uniform cluster, TLS, LDAP).** The expected outputs below are fragments to look for, written from the lab output and from general MQ knowledge; treat every one tagged [VERIFY] as "check against what your queue manager really prints". Paste real outputs into your evidence pack and correct this file.

Related: [`PRODUCTION_MQ_CLUSTER.md`](PRODUCTION_MQ_CLUSTER.md) (what to build), [`BRIDGE_PRODUCTION_ROADMAP.md`](BRIDGE_PRODUCTION_ROADMAP.md) (what the bridge still lacks; items R1-R18), [`RESILIENCE_AND_LIMITATIONS.md`](RESILIENCE_AND_LIMITATIONS.md) (lab failure scenarios), [`examples/20-eventbridge-cluster.mqsc.example`](examples/20-eventbridge-cluster.mqsc.example) (the objects being checked).

Placeholders: `<QMGR>` queue manager name, `<CLUSTER>` cluster name, `<BRIDGE_USER>`, `<BRIDGE_GROUP>`, `<BRIDGE_DN>`, `<BRIDGE_ADDRESS>` as in the template.

Safety markers: **RO** read-only · **LIVE** puts/gets messages or publishes events · **MUT** changes or stops something (drills).

---

## 1. MQ-side object checks (runmqsc)  RO

Run every command **on every queue manager of a uniform cluster** (configuration is per queue manager, see the template header) and **on the active instance of a Native HA queue manager**. Use whatever transport your platform gives you (`kubectl exec -i <pod> -- runmqsc <QMGR>`, `ssh host runmqsc <QMGR>`, an MQ Console, a REST admin client). `scripts/verify-mq-objects.sh` cannot do this today (section 2.3).

```bash
rq() { echo "$1" | runmqsc <QMGR>; }      # adapt to your transport
```

The lab's version of these checks (29 checks, all PASS against the lab container) is in `scripts/verify-mq-objects.sh` [TESTED]. The commands below extend it to HA, cluster, TLS and the production identity [DESIGN].

### 1.1 Queue manager running, Native HA role and replicas  [VERIFY]

```bash
dspmq -m <QMGR>
dspmq -m <QMGR> -o nativeha -x          # Native HA only
```

| Look for | Meaning |
|---|---|
| `QMNAME(<QMGR>)  STATUS(Running)` | the queue manager is up (lab: `STATUS(Running)` [TESTED]) |
| Native HA: `ROLE(Active)` on exactly one instance, the others `ROLE(Replica)` | one leader |
| Native HA: `INSYNC(yes)` for every replica and a quorum figure such as `QUORUM(3/3)` | replicas are caught up; a majority is available |
| Native HA: `BACKLOG(0)` or a small number on replicas | replication is not lagging |

The exact `dspmq` field names and layout differ by version; a Kubernetes Operator deployment also exposes this on the `QueueManager` resource (`kubectl get queuemanager <name>`). [VERIFY] Also `DISPLAY QMSTATUS ALL` for general status, [VERIFY] whether it carries HA fields in your version.

```bash
rq "DISPLAY QMGR QMNAME DEADQ CONNAUTH CHLAUTH SSLKEYR CERTLABL"
rq "DISPLAY LSSTATUS(*) PORT STATUS"
```

Expect `DEADQ(...)` equal to your dead-letter queue, `CONNAUTH(EB.AUTHINFO)` (or your AUTHINFO name), **`CHLAUTH(ENABLED)`** (if channel authentication is disabled every CHLAUTH rule below is ignored) [VERIFY], the key repository and certificate label you intended, and a listener `STATUS(RUNNING)` on the port the bridge uses (lab: `PORT(1414)` [TESTED]).

### 1.2 Cluster membership  [VERIFY]

```bash
rq "DISPLAY CLUSQMGR(*) CLUSTER QMTYPE STATUS CONNAME"
rq "DISPLAY QCLUSTER(ORDERS.*) CLUSTER CLUSQMGR DEFBIND CLWLUSEQ DEFPSIST"
```

| Look for | Meaning |
|---|---|
| one `CLUSQMGR(...)` record per queue manager, `CLUSTER(<CLUSTER>)`, `STATUS(RUNNING)` | everyone is a member and reachable. Full repositories show `QMTYPE(REPOS)`, the others `QMTYPE(NORMAL)` |
| `QCLUSTER(ORDERS.OUT)` and `QCLUSTER(ORDERS.IN)` each listed once **per queue manager that hosts an instance** | the queues are advertised where you expect. No record for `ORDERS.DLQ` (it is deliberately not clustered) |
| `DEFBIND(NOTFIXED)` on both | matches the template |

A queue manager that is missing, `STATUS(STOPPED)` or `STATUS(INACTIVE)` is a finding, not noise.

### 1.3 Queues and backout settings  [TESTED in the lab for the same attributes; DESIGN for the cluster]

```bash
rq "DISPLAY QLOCAL('ORDERS.OUT') CLUSTER DEFPSIST MAXDEPTH BOTHRESH BOQNAME CURDEPTH IPPROCS OPPROCS SHARE"
rq "DISPLAY QLOCAL('ORDERS.IN')  CLUSTER DEFPSIST MAXDEPTH CURDEPTH IPPROCS OPPROCS"
rq "DISPLAY QLOCAL('ORDERS.DLQ') CLUSTER DEFPSIST MAXDEPTH CURDEPTH"
```

Expect on `ORDERS.OUT`: `CLUSTER(<CLUSTER>)`, `DEFPSIST(YES)`, `MAXDEPTH(50000)`, **`BOTHRESH(3)`**, **`BOQNAME(ORDERS.DLQ)`** (the bridge reads these two from the queue and does the move itself [TESTED in the lab]). `ORDERS.DLQ`: **empty `CLUSTER()`**, `CURDEPTH(0)` in steady state.

**Coverage check for a clustered `ORDERS.OUT`** [DESIGN]: `IPPROCS(1)` or more on `ORDERS.OUT` **on every queue manager that hosts it**. `IPPROCS(0)` somewhere means orders put to that instance are not being read. Make this an alarm (roadmap R3).

### 1.4 Channel and TLS settings

```bash
rq "DISPLAY CHANNEL('APP.SVRCONN') CHLTYPE SSLCIPH SSLCAUTH SSLPEER CERTLABL MCAUSER MAXINST MAXINSTC SHARECNV HBINT"
rq "DISPLAY CHSTATUS('APP.SVRCONN') ALL"
rq "DISPLAY CONN(*) WHERE(CHANNEL EQ 'APP.SVRCONN') APPLTAG CONNAME USERID"
```

Expect `CHLTYPE(SVRCONN)`, **`SSLCIPH(<your CipherSpec>)`** (non-blank; blank means plaintext, which is exactly the lab's state [TESTED]), **`SSLCAUTH(REQUIRED)`**, `MCAUSER()` blank unless you chose to set it, `MAXINST`/`MAXINSTC` sized per the template. While the bridge is connected, `CHSTATUS` shows one running instance per bridge connection with the bridge's `CONNAME` and a TLS peer/issuer; `CONN` shows the `USERID`. [VERIFY] which TLS fields `CHSTATUS` prints in your version and the exact `WHERE` syntax. `APPLTAG` is only meaningful once the bridge sets one (roadmap R3).

### 1.5 Authentication information

```bash
rq "DISPLAY AUTHINFO('EB.AUTHINFO') ALL"
```

Lab (IDPWOS): `AUTHTYPE(IDPWOS)`, `CHCKCLNT(REQUIRED)`, `ADOPTCTX(YES)` [TESTED]. LDAP: `AUTHTYPE(IDPWLDAP)`, `CONNAME(...)`, `SECCOMM(YES)`, `CHCKCLNT(REQUIRED)`, `ADOPTCTX(YES)` and the base DNs you configured. [VERIFY] Do **not** expect the bind password in the output (`LDAPPWD` is write-only). A successful display proves the object exists, not that LDAP is reachable: prove that with a real login (section 2) and a deliberate wrong password. [DESIGN]

### 1.6 Channel authentication for the bridge identity  [VERIFY]

```bash
rq "DISPLAY CHLAUTH('APP.SVRCONN') ALL"
# Does the rule set actually admit the bridge? (RUNCHECK evaluates the rules; it does not connect.)
rq "DISPLAY CHLAUTH('APP.SVRCONN') MATCH(RUNCHECK) SSLPEER('<BRIDGE_DN>') SSLCERTI('<ISSUER_DN>') ADDRESS('<BRIDGE_ADDRESS>')"
rq "DISPLAY CHLAUTH('APP.SVRCONN') MATCH(RUNCHECK) CLNTUSER('<BRIDGE_USER>') ADDRESS('<BRIDGE_ADDRESS>')"
# Negative cases: each must come back NOACCESS
rq "DISPLAY CHLAUTH('APP.SVRCONN') MATCH(RUNCHECK) SSLPEER('CN=somebody-else,O=Other') ADDRESS('<BRIDGE_ADDRESS>')"
rq "DISPLAY CHLAUTH('APP.SVRCONN') MATCH(RUNCHECK) CLNTUSER('mqm') ADDRESS('<BRIDGE_ADDRESS>')"
rq "DISPLAY CHLAUTH('APP.SVRCONN') MATCH(RUNCHECK) SSLPEER('<BRIDGE_DN>') ADDRESS('203.0.113.9')"
```

| Case | Expected |
|---|---|
| Bridge certificate DN + issuer, from the bridge address | a record with `USERSRC(MAP)` and `MCAUSER(<BRIDGE_USER>)` (or `USERSRC(CHANNEL)` for a user-mapped variant) |
| Any other certificate DN | `USERSRC(NOACCESS)` (default deny) |
| An administrator such as `mqm` | `USERSRC(NOACCESS)` (the `BLOCKUSER('*MQADMIN')` rule; in the lab `admin` was blocked [TESTED]) |
| Bridge DN from an address outside `<BRIDGE_ADDRESS>` | `USERSRC(NOACCESS)` |

[VERIFY] the exact RUNCHECK parameters accepted together (`SSLPEER` with `SSLCERTI` and `ADDRESS`) and the output layout. Also review `DISPLAY CHLAUTH(*) ALL` for rules from other teams that overlap the bridge's channel. The `DISPLAY CHLAUTH` forms the lab script uses (`TYPE(ADDRESSMAP)`, `TYPE(USERMAP)`, `TYPE(BLOCKUSER)`) are [TESTED] in the lab only.

### 1.7 Authority records for the bridge identity  [VERIFY]

```bash
rq "DISPLAY AUTHREC OBJTYPE(QMGR) GROUP('<BRIDGE_GROUP>')"
rq "DISPLAY AUTHREC PROFILE('ORDERS.OUT') OBJTYPE(QUEUE)"       # lists EVERY entity with rights: review it
rq "DISPLAY AUTHREC PROFILE('ORDERS.IN')  OBJTYPE(QUEUE)"
rq "DISPLAY AUTHREC PROFILE('ORDERS.DLQ') OBJTYPE(QUEUE)"
# Effective rights after group membership (this is what the bridge really gets):
rq "DISPLAY ENTAUTH('ORDERS.OUT') OBJTYPE(QUEUE) PRINCIPAL('<BRIDGE_USER>')"
```

| Object | Authorities the bridge needs | Needed by |
|---|---|---|
| queue manager | `CONNECT` | `MQClient.connect` |
| `ORDERS.OUT` | `GET`, `INQ` | open for shared input + inquire; `get`; `_load_backout_settings` |
| `ORDERS.IN` | `PUT` | `put_persistent` |
| backout queue (`ORDERS.DLQ`) | `PUT` | `move_to_backout_queue` |

Expected: exactly these (the lab granted `PUT,GET,INQ,BROWSE` on `ORDERS.**` and `CONNECT,INQ` on the queue manager to the user `app` [TESTED]; production should be narrower, see the template section 6). Anything extra for the bridge identity, or `+all`/`+alladmin`/`+setall` for anyone unexpected, is a finding. `DISPLAY ENTAUTH` and `dspmqaut -m <QMGR> -n ORDERS.OUT -t queue -p <BRIDGE_USER>` are the two ways to see effective rights; [VERIFY] which your platform supports. The effective rights must be checked **per queue manager** in a uniform cluster.

### 1.8 Dead-letter queue

```bash
rq "DISPLAY QMGR DEADQ"
rq "DISPLAY QLOCAL('ORDERS.DLQ') CURDEPTH MAXDEPTH"
```

Expect the `DEADQ` you chose (lab: `ORDERS.DLQ` [TESTED]) and `CURDEPTH(0)`. A non-empty dead-letter queue before go-live means something already failed to deliver or was poisoned: find out why before signing off.

---

## 2. Client-side proof: the live checks against a separate queue manager

### 2.1 What they prove in the lab  [TESTED]

`bridge/tests/live_mq_check.py` (the `MQClient` wrapper) and `bridge/tests/live_loop_check.py` (both delivery loops with **fake AWS clients**) ran against the lab container: 17 checks, all PASS, and they found a real bug (channel constants live in `ibmmq.CMQXC`). Expect lines such as `PASS  1 connect with user+password through APP.SVRCONN` and `PASS  6 poison message moved to ORDERS.DLQ; ORDERS.OUT left empty`. Exit code 0 means all PASS.

### 2.2 Running them against a remote queue manager today  [DESIGN: not run against any remote queue manager]

> **WARNING (read before running).** Both scripts `drain()` `ORDERS.IN`, `ORDERS.OUT` and `ORDERS.DLQ` at the start **and** at the end: they **read and discard every message on those queues.** Never point them at a queue manager with real traffic on those queues. Use a dedicated non-production cluster, or stop the bridge and the applications and confirm the queues are empty first (`CURDEPTH(0)`). Check 2 also deliberately sends a **wrong password**, which can lock an LDAP account (roadmap R5, R18).

Requirements, from the scripts' docstrings: a host that can reach the listener; the IBM MQ C client libraries (`LD_LIBRARY_PATH=<client>/lib64`); the `ibmmq` package; for `live_loop_check.py` also the repository checkout (it reads `schemas/samples/prod.orders__OrderPlaced/valid-1.json`).

```bash
cd mq-integration/bridge
export MQ_HOST=<listener host or load balancer name>   # a single host name (see below)
export MQ_PORT=<port>
export MQ_QMGR=<QMGR> MQ_CHANNEL=APP.SVRCONN MQ_USER=<BRIDGE_USER>
read -rs MQ_PASSWORD && export MQ_PASSWORD             # never echo or log it
export LD_LIBRARY_PATH=<client>/lib64
python tests/live_mq_check.py
python tests/live_loop_check.py                        # also sets lab defaults for EVENT_BUS_NAME etc.; no AWS call is made
```

What does **not** work today, and what has to change:

| Obstacle | Today | Needed |
|---|---|---|
| **TLS** | The scripts go through `MQClient.connect`, which sets no cipher spec and no key repository. They cannot connect to a channel with `SSLCIPH` set. A blank-`SSLCIPH` test channel on a non-production cluster is the only option until then. | roadmap R4 |
| **Several hosts / CCDT** | `MQ_HOST` must be one name; the live checks build `host(port)`. Do not use the connection-name-list hack for evidence. | roadmap R1 |
| **Certificate-only identity** | `MQ_USER` and `MQ_PASSWORD` are required | roadmap R6 |
| **Lab constants** | check 3 expects `BOTHRESH(3)` and `ORDERS.DLQ`; a different production value is a false FAIL, not a defect | roadmap R8, R18 |
| **Clustered queues** | each queue manager has its own instance of `ORDERS.OUT`/`ORDERS.IN`; run the checks **once per queue manager** (pin `MQ_HOST`/`MQ_QMGR`). A put to a clustered `ORDERS.IN` may be routed to another queue manager's instance, so check 4's `get` on the connected queue manager can see nothing (a false FAIL). [DESIGN] | note result per queue manager |
| **Reconnect** | no live check exercises reconnect or failover | drills in section 4 |

### 2.3 How `verify-mq-objects.sh` relates  [DESIGN, from reading the script]

| Mode | Transport | Works against a separate MQ? |
|---|---|---|
| `--static` | none (greps `docker/mqsc/20-eventbridge.mqsc` for expected strings) | No: checks the **lab file**. It does not know the production template |
| `--container NAME` | `docker exec` into a local/other Docker container, runs `runmqsc QM1` and `dspmq -m QM1` | Only if MQ is a Docker container on a host where you can run `docker`; and the lab's names (`QM1`, `APP.SVRCONN`, `EB.AUTHINFO`, user `app`, `IDPWOS`, port 1414, `MAXDEPTH(50000)`) are hard-coded, so a production deployment FAILs by design |
| default (live) | SSM to the lab EC2 host, then `docker exec` in the compose project | No: needs the lab's Terraform outputs and instance |
| `--smoke` | `amqsputc` / `amqsgetc` inside the container | No |

**There is no mode for a remote queue manager.** Roadmap R15 proposes `--runmqsc-cmd '<command>'` (for example `'kubectl exec -i qm-0 -- runmqsc QM1'`), `--mqsc FILE` for `--static`, and parameters for the lab constants. Until it exists, run section 1 by hand and keep the outputs as evidence. The lab script's check list (29 checks) is the model for the pass/fail bar [TESTED in the lab].

---

## 3. AWS-side checks  (account and region of the production bus)

Set `AWS_PROFILE`, `REGION`, `BUS`, check the account ID first (`aws sts get-caller-identity`). These mirror `docs/AWS_CLI_AND_MQ_COMMANDS.md`, which is itself "not yet run on a live stack" for its own commands except where RESILIENCE section 6 records a live run. [DESIGN] unless noted.

**RO**

```bash
# Rule: enabled, right pattern (origin excluded), SQS target with a DLQ
aws events describe-rule --name mq-outbound-rule --event-bus-name $BUS --region $REGION --query '[State,EventPattern]' --output text
#  -> ENABLED  {"detail":{"origin":[{"exists":false},{"anything-but":"ibm-mq"}]},"detail-type":["OrderPlaced"],"source":["prod.orders"]}
aws events list-targets-by-rule --rule mq-outbound-rule --event-bus-name $BUS --region $REGION \
  --query 'Targets[].[Id,Arn,DeadLetterConfig.Arn]' --output text
# Pattern logic without sending anything (expect True without origin, False with origin ibm-mq)
aws events test-event-pattern --region $REGION --event-pattern "$(aws events describe-rule --name mq-outbound-rule --event-bus-name $BUS --region $REGION --query EventPattern --output text)" --event '<sample event json>' --query Result --output text

# SQS: redrive to the DLQ after 5 receives, encryption, visibility, depths
aws sqs get-queue-attributes --queue-url "$QURL" --region $REGION \
  --attribute-names RedrivePolicy VisibilityTimeout SqsManagedSseEnabled KmsMasterKeyId Policy
aws sqs get-queue-attributes --queue-url "$DLQURL" --region $REGION \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
#  expect: RedrivePolicy with deadLetterTargetArn and maxReceiveCount 5; DLQ depth 0

# IAM: what the bridge's task role may do (simulation does not call the services)
aws iam simulate-principal-policy --policy-source-arn <TASK_ROLE_ARN> \
  --action-names events:PutEvents --resource-arns <BUS_ARN> --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
aws iam simulate-principal-policy --policy-source-arn <TASK_ROLE_ARN> \
  --action-names sqs:ReceiveMessage sqs:DeleteMessage sqs:GetQueueAttributes sqs:ChangeMessageVisibility \
  --resource-arns <OUTBOUND_QUEUE_ARN> --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
#  expect allowed for these; implicitDeny for events:PutEvents on any OTHER bus and for any other queue

# Global endpoint (only if EB_ENDPOINT_ID is used)
aws events describe-endpoint --name <ENDPOINT_NAME> --home-region $REGION
#  expect State ACTIVE, the two buses in EventBuses, ReplicationConfig / RoutingConfig as designed   [VERIFY output fields]
aws events describe-event-bus --name $BUS --region $REGION
```

Also confirm: the failover bus ARN is in the task role's `PutEvents` resources (the lab role has this for `failover_bus_arns`); the bridge image contains `awscrt` when `EB_ENDPOINT_ID` is set (SigV4a); the queues are TLS-only and SSE-enabled (`SECURITY.md` section 5). [DESIGN]

**LIVE** (publishes one event; use a test `orderId`)

```bash
aws events put-events --region $REGION --entries '[{"Source":"prod.orders","DetailType":"OrderPlaced","EventBusName":"'$BUS'","Detail":"{\"orderId\":\"<uuid>\",\"product\":\"widget\",\"quantity\":1,\"amount\":9.99,\"placedAt\":\"<now>\"}"}]'
#  -> FailedEntryCount: 0, then the message appears on ORDERS.IN of a queue manager within ~20 s and SQS drains
```

Through the endpoint add `--endpoint-id <id>` (needs `awscrt`). In the lab, flow 1 through the endpoint and a failover drill were run and worked; **flow 2 through the endpoint and during failover were not tested** (RESILIENCE section 6). [TESTED / TESTED absence]

---

## 4. Failover drills on the real cluster  MUT

None of these has been run. Every "expected" is [DESIGN] or [VERIFY], and a drill that disagrees with it is a finding about the bridge, the cluster, or this document. Run them in a non-production environment first. For each drill record: start time, time to recovery, **orders put vs events seen vs orders delivered (count duplicates by `orderId`)**, depth of `ORDERS.OUT`/`ORDERS.IN`/`ORDERS.DLQ`, SQS and SQS-DLQ depth, bridge log lines, and `BackoutCount` on any message still on `ORDERS.OUT`.

Test traffic for all drills: a producer that puts N numbered orders per second on `ORDERS.OUT` (through the real client path, applications' own identity) and a subscriber that counts events by `orderId`; a publisher of N events per second on the bus for flow 2 and a consumer counting arrivals on `ORDERS.IN`.

| # | Drill | How | Expected behaviour | Observe |
|---|---|---|---|---|
| D1 | **Kill the active Native HA instance** | delete the active Pod / stop the active VM abruptly | A replica takes over after a leader election; the listener moves with it. [VERIFY] time. The bridge's connections break (2009/2059-class errors), the in-flight unit of work is backed out by the new active instance, the bridge reconnects (today: backoff 1-30 s, to whatever the connection name resolves to; needs R1/R2 for a clean multi-address reconnect). Persistent messages committed before the kill are not lost. The in-flight message may be published **twice** (at-least-once). [DESIGN] | failover duration; bridge `MQ error, reconnecting` lines; zero lost orders; duplicates counted; `INSYNC(yes)` returns for the old instance after it rejoins; `BackoutCount` after repeated kills |
| D2 | **Drain / stop one uniform-cluster queue manager** | `SUSPEND QMGR CLUSTER(<CLUSTER>)` first, then a normal stop of one queue manager ([VERIFY] the exact drain sequence and whether to also use `endmqm` with its reconnect option) | After suspend, producers' workload balancing sends new puts to the other queue managers; the suspended one still serves its local consumers. After the stop, **messages already sitting on that queue manager's `ORDERS.OUT` are not served** until it is back (they are not moved by the cluster) [DESIGN]. Bridge connections to it break and reconnect; if the bridge is pinned (R3 option 1) that consumer waits; if rebalancing is on it may move to another queue manager [VERIFY]. | per-queue-manager `CURDEPTH`; whether new orders still flow; time for the stuck backlog to drain after restart; `IPPROCS` per queue manager; whether the bridge task for that queue manager restarts needlessly (health threshold, R10) |
| D3 | **Rolling upgrade** | upgrade replicas one at a time, then force a switch of the active; or one uniform-cluster queue manager at a time | Equivalent to a series of D1/D2 events with quorum kept; never two instances down at once. [VERIFY] the vendor's rolling-update procedure for your version. | total failovers; duplicates; time with no consumer on any `ORDERS.OUT`; clients on mixed versions (client library compatibility [VERIFY]) |
| D4 | **MQ down while events arrive** | stop every MQ endpoint for 5, 15 and 60 minutes while publishing on the bus (flow 2) and while producers fail to put (flow 1) | Flow 2: SQS buffers events up to its retention (lab default 4 days [DESIGN]). Reading the code, the SQS loop only calls `receive_message` while it holds an MQ connection, so messages are **not** repeatedly received during a full outage and the receive count should not climb; this differs from RESILIENCE S5 (which assumes repeated receives) and should be confirmed here. A failure that lets the bridge connect but makes the put fail (queue full, authority error) *does* consume receives and moves events to the SQS DLQ after 5. [DESIGN] After recovery the backlog drains and `ORDERS.IN` receives each event; no event in the SQS DLQ. Flow 1: nothing to publish. **Side effect to check:** the container health file is only touched after a successful connect, so an outage longer than ~120 s may mark bridge tasks unhealthy and have the orchestrator replace them (roadmap R10). | SQS depth over time; SQS-DLQ depth stays 0; drain rate after recovery; task restarts; reconnect storm on the queue manager when many tasks return together |
| D5 | **AZ loss for the bridge tasks** | stop all tasks in one AZ (or break their subnet route) | The orchestrator starts replacements in the remaining AZs. SQS keeps buffering for flow 2. For flow 1, if consumers are pinned one per queue manager (R3), the queue manager whose consumer was in the lost AZ has no reader until the replacement is running. [DESIGN] | time to replacement; `ORDERS.OUT` growth on the affected queue manager; no duplicates beyond the in-flight messages |
| D6 | **Bridge task killed mid-unit-of-work** | SIGKILL a task while it processes a message | The queue manager backs out the open unit of work when the connection drops; the message is re-delivered to another/new consumer. For flow 2, an SQS message is re-delivered after the 60 s visibility timeout. Possible duplicate, no loss. [DESIGN] | duplicates; `BackoutCount` increments |
| D7 | **Certificate rotation / expiry** | replace the bridge's client certificate, then (separately) the server's | New connections use the new certificate; existing ones keep working until they break. An expired or untrusted certificate is refused at connect; the bridge retries (today with a 30 s cap, R5). [VERIFY] | refused-connection messages on the queue manager error log; whether the bridge recovers without a restart |
| D8 | **Identity provider (LDAP) unavailable** | block LDAP from the queue manager | New connections cannot authenticate; existing ones continue. [VERIFY] the configured failure behaviour. Watch for account lockout if the bridge hammers wrong credentials (R5). | connect failures vs lockouts |

---

## 5. Go-live gate

Same bar as the lab: both directions, loop guard, poison -> DLQ, global endpoint replication and failover, plus what only a production MQ adds. "Lab evidence" is what the lab already proved; **it does not count as production evidence** [TESTED in the lab only].

| # | Gate | Evidence required | Owner | Lab evidence |
|---|---|---|---|---|
| G1 | Roadmap items R1, R2, R4, R5, R7, R8, R18 implemented and unit/live tested | merged changes, green `pytest`, live-check output | Platform / bridge team | none (all NOT IMPLEMENTED) |
| G2 | MQ objects match the template on **every** queue manager (section 1) | saved outputs of 1.1 to 1.8 per queue manager | MQ team | 29 object checks on the lab container [TESTED] |
| G3 | TLS enforced: connection without certificate, with a wrong certificate, with a wrong cipher: all refused; correct one admitted | command output / log evidence of each | MQ team + Security | none (lab has no TLS) |
| G4 | Authentication: valid identity accepted, wrong password refused, administrator blocked on the channel; RUNCHECK cases (1.6) | outputs of 1.6 and live check 1-2 | Security | `app` accepted, wrong password refused, `admin` blocked [TESTED] |
| G5 | Least privilege: bridge identity has exactly the rights in 1.7 on each queue manager | `DISPLAY ENTAUTH` outputs | Security + MQ team | AUTHREC checks [TESTED] (broader than production) |
| G6 | **MQ -> EventBridge**: an order on `ORDERS.OUT` appears once on the bus (`origin=ibm-mq`, `correlationId`), reaches the consumer; the message is committed only after publish | live run and bus/consumer logs; `live_loop_check.py` A-C equivalents against the production-like cluster | Platform + app team | [TESTED] |
| G7 | **EventBridge -> MQ**: an event without `origin` lands on `ORDERS.IN` (persistent), SQS drained after the MQ commit | live run, SQS depth 0 | Platform + app team | [TESTED] on the regional bus |
| G8 | **Loop guard**: an event with `origin=ibm-mq` never reaches `ORDERS.IN` | live run, nothing on queue, nothing left in SQS | Platform | [TESTED] |
| G9 | **Poison -> DLQ**: non-JSON message rolled back 3 times, moved to the backout queue, neighbour not blocked; the backout queue is monitored | live run; DLQ depth alarm fires | Platform + MQ team | [TESTED] (DLQ alarm not created in the lab) |
| G10 | **Global endpoint** (if used): bridge publishes with `EndpointId`; replica appears in the secondary Region; failover and failback with no bridge restart | endpoint description, drill timings | Platform | flow 1 [TESTED]; flow 2 through the endpoint and during failover NOT tested |
| G11 | Secondary outbound path built and tested (roadmap R9), or the gap is formally accepted | drill evidence or signed risk acceptance | Platform + business owner | not built |
| G12 | Failover drills D1 to D6 executed, **zero lost orders**, duplicates counted and acceptable to consumers (idempotent on `orderId`), recovery times recorded | drill reports | SRE + MQ team | none |
| G13 | Consumer coverage: `IPPROCS >= 1` on every `ORDERS.OUT` instance, with an alarm | alarm test | MQ team + SRE | n/a (single queue manager) |
| G14 | Alarms exist and fire: `ORDERS.DLQ` depth, SQS DLQ depth, `ORDERS.OUT` depth/age, bridge not ready, reconnect rate | alarm test evidence | SRE | not created in the lab |
| G15 | Secrets: no password in task environment, logs or `docker inspect` equivalents; rotation tested | config review, rotation test | Security | lab uses env passwords (known gap) |
| G16 | Capacity: load test at expected peak plus headroom (throughput, latency, backlog drain, `MAXINSTC` under NAT) | load-test report | Platform + MQ team | none |
| G17 | Rollback / teardown proven: bridge can be removed without losing MQ messages; AWS resources removed leave nothing behind | teardown run plus a clean sweep (the lab's `leftover-check.sh` is the model) | Platform | lab destroy ends with a leftover sweep (repo rule; no run recorded in these docs) [DESIGN] |
| G18 | Evidence pack reviewed; this file's [VERIFY] items resolved or recorded | signed-off pack | all owners | n/a |

---

## 6. What the lab proved, and what remains unproven

**Proved in the lab [TESTED]** (single developer-image queue manager, plaintext on loopback/Docker, one bridge, one EC2 host; details in RESILIENCE section 6 and the README):

* the lab MQSC loads (38/38 commands); queue manager, queues, channel, authentication and authority objects exist with the expected attributes (29 checks);
* client login through the channel: right password accepted, wrong password refused, administrator blocked;
* the `MQClient` wrapper and both loops against real MQ (17 live checks): commit after publish, rollback on failure, SQS delete only after MQ commit, loop guard, poison rolled back 3 times then moved to `ORDERS.DLQ`, neighbouring messages not blocked;
* end to end through the real bus: MQ -> EventBridge -> consumer, EventBridge -> SQS -> MQ, loop guard, poison;
* publishing through the global endpoint (SigV4a), replication to the secondary Region, a failover and failback of flow 1 with no bridge restart.

**Not proved for production** (every one needs evidence from sections 1 to 5):

* anything on a Native HA queue manager or a uniform cluster: replicas, failover, rolling upgrade, workload balancing, consumer coverage per queue manager;
* TLS (any), certificate identity, LDAP authentication and lockout behaviour, the production CHLAUTH/AUTHREC set;
* client reconnect, connection-name lists, CCDT (the bridge does not support them yet: roadmap R1, R2);
* MQ down while events arrive (SQS retention and redrive live), and the code-reading claim in D4 that the SQS loop does not burn receives during a full outage;
* flow 2 through the global endpoint and during failover; the secondary outbound path;
* the bridge as an ECS/EKS service (image build in the target pipeline, task role, health under MQ outage, shutdown);
* load, latency and backlog behaviour; metrics and alarms.
