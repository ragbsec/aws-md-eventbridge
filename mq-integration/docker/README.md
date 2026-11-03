# docker/ - IBM MQ + bridge

| File | Purpose |
|------|---------|
| `docker-compose.yml` | `mq` (IBM MQ, QM1) and `bridge` (built from `../bridge`) |
| `mqsc/20-eventbridge.mqsc` | Queues ORDERS.OUT/IN/DLQ, channel APP.SVRCONN, auth rules (idempotent) |
| `.env.example` | Template for `.env` (passwords, optional image/bind address) |
| `mq-test-order.json` | Sample order valid against `schemas/prod.orders__OrderPlaced.json` |

Users: the image creates `admin` (MQ_ADMIN_PASSWORD, group mqm, web console) and `app`
(MQ_APP_PASSWORD, group mqclient). The MQSC grants mqclient only ORDERS.* access.

`LICENSE=accept` in the compose file is your acceptance of the IBM MQ developer
license; read it (link in the compose comment) before running.

## Run locally (MQ only)

    cp .env.example .env      # then edit the passwords
    docker compose up -d mq
    docker compose ps         # wait for "healthy"

`bridge` also needs `bridge.env` and AWS credentials; skip it locally.
Web console: https://127.0.0.1:9443/ibmmq/console (user `admin`).

## Verify

    docker exec eb-mq-mq-1 dspmq
    docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY QLOCAL(ORDERS.*)"
    docker exec -i eb-mq-mq-1 runmqsc QM1 <<< "DISPLAY CHLAUTH(*)"

Put and get with the sample programs (run as the `app` user via client connection):

    docker exec -i -e MQSAMP_USER_ID=app -e MQSAMP_PASSWORD="$MQ_APP_PASSWORD" eb-mq-mq-1 \
      bash -c 'MQSERVER="APP.SVRCONN/TCP/localhost(1414)" /opt/mqm/samp/bin/amqsputc ORDERS.OUT QM1' < <(tr -d '\n' < mq-test-order.json; echo)
    docker exec -i -e MQSAMP_USER_ID=app -e MQSAMP_PASSWORD="$MQ_APP_PASSWORD" eb-mq-mq-1 \
      bash -c 'MQSERVER="APP.SVRCONN/TCP/localhost(1414)" /opt/mqm/samp/bin/amqsgetc ORDERS.IN QM1'

The local `amqsput`/`amqsget`
(no `c`) bind directly and run as the container user, not `app`; the `c` variants exercise
the real channel and auth path. Note: with the bridge running it consumes ORDERS.OUT.

## Teardown

    docker compose down        # keeps queue data
    docker compose down -v     # also deletes the qm1data volume
