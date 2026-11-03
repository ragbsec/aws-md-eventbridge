# Troubleshooting — IBM MQ <-> EventBridge bridge

> **Not yet run on a live stack.** Causes are the likely ones from the design
> and the files written; add what you actually see on a first deploy.
> Commands marked "on host" run inside an SSM session (see
> [`RUNBOOK.md`](RUNBOOK.md) §1). Other commands are in
> [`AWS_CLI_AND_MQ_COMMANDS.md`](AWS_CLI_AND_MQ_COMMANDS.md).

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| Instance never reaches READY (`/opt/eb-mq/READY` missing, test check 1 fails) | No outbound internet (no public IP / NAT) so `dnf`, the Compose download from GitHub or the `icr.io` pull fails; `docker compose` build of the bridge failed (pip); MQ did not become healthy within 10 min; instance role lacks S3 read of the bundle | on host: `tail -n 80 /var/log/eb-mq-bootstrap.log`; `docker compose -f /opt/eb-mq/docker/docker-compose.yml ps`; `docker compose logs mq`; `aws ssm describe-instance-information` shows `Online`? | Fix the egress (`associate_public_ip`, NAT, VPC endpoints); re-run the bootstrap steps by hand or `deploy.sh --yes` (user_data change replaces the instance). If MQ is slow on small hardware, wait and re-check `docker compose ps` |
| SSM `TargetNotConnected` / no session | Instance has no route to SSM endpoints, profile/role missing, agent not up yet | `describe-instance-information`; instance profile attached? | Add NAT or `ssm`, `ssmmessages`, `ec2messages` VPC endpoints; wait 2-3 minutes after boot |
| Bridge log: `MQRC 2538` (`MQRC_HOST_NOT_AVAILABLE`) / `MQRC_Q_MGR_NOT_AVAILABLE` | Bridge cannot reach `mq:1414`: `mq` container down/unhealthy, wrong `MQ_HOST` in `bridge.env` (must be `mq`), listener not up yet | on host: `docker compose ps`; `cat /opt/eb-mq/docker/bridge.env \| grep MQ_`; `docker compose logs mq` | Start `mq`, wait for `healthy`, `docker compose restart bridge`. The bridge `depends_on` a healthy MQ at start only |
| Bridge log: `MQRC 2059` (`MQRC_Q_MGR_NOT_AVAILABLE`) | Queue manager `QM1` stopped/starting, or wrong `MQ_QMGR` | `docker exec eb-mq-mq-1 dspmq` | `docker compose restart mq`; correct `MQ_QMGR=QM1` |
| Bridge log: `MQRC 2035` (`MQRC_NOT_AUTHORIZED`) / `MQRC 2538` right after connect with reason `CHLAUTH` | Wrong `app` password (secret and container out of sync), CHLAUTH blocking (not user `app`, not `APP.SVRCONN`), AUTHREC missing for `mqclient` on `ORDERS.**`, `ADOPTCTX` / CONNAUTH not refreshed | `runmqsc`: `DISPLAY CHLAUTH('APP.SVRCONN') ALL`, `DISPLAY AUTHREC PROFILE('ORDERS.**') GROUP('mqclient')`; `DISPLAY CHSTATUS`; MQ error log `docker exec eb-mq-mq-1 bash -c 'tail -n 30 /var/mqm/qmgrs/QM1/errors/AMQERR01.LOG'` (look for `AMQ5541`/`AMQ9557`/`AMQ8135`) | Re-sync passwords (RUNBOOK §6) and recreate; re-run MQSC `REFRESH SECURITY TYPE(CONNAUTH)`; confirm the channel name is `APP.SVRCONN` and user is `app`. Do not weaken CHLAUTH to "fix" it |
| `AccessDenied` on `events:PutEvents` in bridge log | Instance role cannot PutEvents on the bus ARN (wrong `bus_name`, wrong region), or a global endpoint is used and the resource does not cover it | `aws iam get-role-policy` for role `eb-mq-host-*`; bridge `bridge.env` `EVENT_BUS_NAME`/`AWS_REGION`; check IMDS credentials from the container (below) | Correct variables and re-apply; policy resource must be the bus ARN. With `EB_ENDPOINT_ID`, install `awscrt` (SigV4a) |
| `Unable to locate credentials` / `NoCredentialsError` in bridge | IMDS hop limit is 1 (container can't reach IMDS) or IMDSv2 token handling broken | `aws ec2 describe-instances --instance-ids $IID --query 'Reservations[].Instances[].MetadataOptions'` (expect `HttpPutResponseHopLimit: 2`, `required`) | Set `http_put_response_hop_limit = 2` and re-apply; then `docker compose restart bridge` |
| `AccessDenied`/`KMS` error on PutEvents (`kms:GenerateDataKey`) | The bus uses a CMK and the role's `BusCmkUse` statement or the **key policy** does not allow the instance role; condition `kms:ViaService` mismatched region | Bus: `aws events describe-event-bus --name eb-prod-orders` (KmsKeyIdentifier); key policy; role policy | Add the role to the key policy / grant; make sure the policy statement is present (it is only generated when the bus has a CMK at plan time: re-plan if the bus changed) |
| Events published but nothing on `ORDERS.IN` | (1) Event carries `origin=ibm-mq` (excluded by design; the rule matches absent `origin` or any other value); (2) rule disabled / pattern mismatch (source/detail-type); (3) rule cannot write to SQS (queue policy `aws:SourceArn`); (4) bridge not polling or MQ put failing; (5) message sits in-flight (visibility 60 s); (6) the event carries `origin=ibm-mq`, which the bridge deliberately deletes (log: "dropped event with origin=ibm-mq") | `aws events test-event-pattern` with your event; `describe-rule mq-outbound-rule`; SQS depth + DLQ depth; `docker compose logs bridge`; CloudWatch metric `FailedInvocations` for the rule | Fix the queue policy / re-enable the rule. Restart bridge |
| Event published, SQS empty, DLQ has messages | Bridge put to MQ failed 5 times (MQ down, `ORDERS.IN` full or not authorised) | DLQ message body; bridge logs; `DISPLAY QLOCAL('ORDERS.IN') CURDEPTH MAXDEPTH` | Fix MQ, redrive the DLQ (RUNBOOK §5) |
| Loop suspected (same `orderId` ping-pongs, rising event counts, `ORDERS.OUT` and SQS both busy) | `detail.origin` not stamped by the bridge, a different producer sets `origin=ibm-mq`, or an app on MQ re-puts every `ORDERS.IN` message onto `ORDERS.OUT` | Audit log: filter `"orderId"` and count; look at `origin` of repeated events; `describe-rule` pattern; whether an app forwards `ORDERS.IN` -> `ORDERS.OUT` | Stop the bridge (`docker compose stop bridge`) to break the loop, `aws events disable-rule --name mq-outbound-rule --event-bus-name eb-prod-orders`, purge queues if needed; fix the stamping/forwarding app; re-enable. An app that forwards received events back to `ORDERS.OUT` must preserve or set `origin` |
| `eb-mq-outbound-dlq` filling | Persistent MQ put failure, malformed payload that the bridge always rejects, or EventBridge cannot deliver to SQS (target DLQ also lands here) | Receive and read a DLQ message (cookbook §5): does it have the EventBridge envelope (bridge/MQ problem) or an `ERROR_CODE` attribute (delivery problem)? | Delivery problem: fix the queue policy / KMS. MQ problem: fix MQ and redrive. Bad payload: discard and fix the producer's schema |
| `ORDERS.DLQ` filling | Poison messages from apps (non-JSON, missing `orderId`), or EventBridge rejects every event (e.g. wrong IAM) so all messages back out 3 times | Browse the DLQ (RUNBOOK §5); bridge logs for the exception per message | Fix the producing app; if it is an AWS error fix that and replay. DLQ is also `DEADQ` for the queue manager, so it can contain MQ system-undeliverable messages |
| `ORDERS.OUT` depth keeps growing | Bridge down or rolling back every message; EventBridge throttling | `docker compose ps`; bridge logs; `DISPLAY QLOCAL('ORDERS.OUT') CURDEPTH IPPROCS` | Restart the bridge; fix the underlying error |
| Duplicates at the consumer | Expected: at-least-once (crash between publish and commit, SQS redelivery) | Same `orderId` twice in consumer logs | Make the consumer idempotent on `orderId`; not a fault |
| Console unreachable | Ports bound to 127.0.0.1; no SG rule | n/a | SSM port-forward to 9443 (RUNBOOK §1), or open `console_cidrs` with a narrow CIDR (and read SECURITY.md §4 first) |
| `terraform` precondition "No VPC available" | No default VPC in the region | n/a | Set `vpc_id` and `subnet_id` |

## Reading MQ return codes quickly

| MQRC | Name | First thing to check |
|---|---|---|
| 2035 | NOT_AUTHORIZED | Password, CHLAUTH, AUTHREC, CONNAUTH |
| 2059 | Q_MGR_NOT_AVAILABLE | `dspmq`, container health, QM name |
| 2538 | HOST_NOT_AVAILABLE | Host/port/listener, container network |
| 2085 | UNKNOWN_OBJECT_NAME | Queue name typo; MQSC not applied |
| 2053 | Q_FULL | `MAXDEPTH` reached; bridge stalled |
| 2009 | CONNECTION_BROKEN | Channel dropped (queue manager restart) |

If a symptom is not here, capture `docker compose logs --tail 200`, the
`AMQERR01.LOG`, and the SQS/rule state before restarting, then add the row.
