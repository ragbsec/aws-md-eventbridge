#!/usr/bin/env python3
"""LIVE check of bridge.mq_client.MQClient against a REAL IBM MQ queue manager.

Not a pytest module (the name does not start with test_): it needs the IBM MQ C
client libraries, the `ibmmq` package and a reachable queue manager that has the
objects from docker/mqsc/20-eventbridge.mqsc. Run it from a place that can reach
the listener (inside the container's network namespace, or on the EC2 host where
the compose project publishes 127.0.0.1:1414).

    MQ_HOST=localhost MQ_PORT=1414 MQ_QMGR=QM1 MQ_CHANNEL=APP.SVRCONN MQ_USER=app \
    MQ_PASSWORD=... LD_LIBRARY_PATH=<client>/lib64 python tests/live_mq_check.py

It proves the calls the unit tests can only fake:
  1. connect with user+password through APP.SVRCONN (CHCKCLNT REQUIRED satisfied)
  2. a WRONG password is refused (MQRC 2035)
  3. the backout settings are read from ORDERS.OUT (threshold 3, queue ORDERS.DLQ)
  4. put -> commit -> get -> commit round trip on ORDERS.IN (persistent, CCSID 1208)
  5. get under syncpoint + backout: the message returns and BackoutCount increments
  6. poison handling: move_to_backout_queue + commit lands it on ORDERS.DLQ

It leaves every queue empty. The password is read from the environment and is
never printed. Exit code 0 = all PASS.
"""
import os
import sys
import time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from bridge.mq_client import MQClient, MQClientError  # noqa: E402

FAILED = 0


def report(ok, label, extra=""):
    global FAILED
    print(f"{'PASS' if ok else 'FAIL'}  {label}{(' - ' + extra) if extra else ''}")
    if not ok:
        FAILED = 1


def cfg(password=None):
    return types.SimpleNamespace(
        mq_host=os.environ.get("MQ_HOST", "localhost"),
        mq_port=int(os.environ.get("MQ_PORT", "1414")),
        mq_qmgr=os.environ.get("MQ_QMGR", "QM1"),
        mq_channel=os.environ.get("MQ_CHANNEL", "APP.SVRCONN"),
        mq_user=os.environ.get("MQ_USER", "app"),
        mq_password=password if password is not None else os.environ["MQ_PASSWORD"],
    )


def client(queue, mode, password=None):
    c = MQClient(cfg(password), queue, mode)
    c.connect()
    return c


def drain(queue):
    """Remove leftovers so the check starts and ends with empty queues."""
    c = client(queue, "get")
    n = 0
    while c.get(500) is not None:
        n += 1
    c.commit()
    c.close()
    return n


def main():
    # 1. connect
    try:
        c = client("ORDERS.OUT", "get")
        report(True, "1 connect with user+password through APP.SVRCONN")
    except MQClientError as e:
        report(False, "1 connect with user+password", f"{e} (reason {e.reason})")
        return 1

    # 3. backout settings read from the queue itself
    report(c.backout_threshold == 3 and c.backout_queue == "ORDERS.DLQ",
           "3 backout settings read from ORDERS.OUT",
           f"threshold={c.backout_threshold} queue={c.backout_queue!r}")
    c.close()

    # 2. wrong password refused
    try:
        client("ORDERS.OUT", "get", password="definitely-wrong").close()
        report(False, "2 wrong password refused", "connection was ACCEPTED")
    except MQClientError as e:
        report(e.reason == 2035, "2 wrong password refused", f"reason {e.reason} (2035 = not authorized)")

    for q in ("ORDERS.IN", "ORDERS.OUT", "ORDERS.DLQ"):
        drain(q)

    # 4. put / commit / get / commit round trip on ORDERS.IN
    body = f'{{"live-check":"{int(time.time())}"}}'
    p = client("ORDERS.IN", "put")
    p.put_persistent(body)
    p.commit()
    p.close()
    g = client("ORDERS.IN", "get")
    m = g.get(5000)
    ok = m is not None and m.body.decode() == body and len(m.msg_id_hex) == 48
    g.commit()
    g.close()
    report(ok, "4 persistent put/commit then get/commit round trip (ORDERS.IN)")

    # 5. get under syncpoint, backout, and the backout count increments
    p = client("ORDERS.OUT", "put")
    p.put_persistent('{"poison":"yes"}')
    p.commit()
    p.close()
    counts = []
    for _ in range(3):
        g = client("ORDERS.OUT", "get")
        m = g.get(5000)
        if m is None:
            counts.append(None)
            g.close()
            break
        counts.append(m.backout_count)
        g.backout()
        g.close()
    report(counts == [0, 1, 2], "5 syncpoint get + backout returns the message; BackoutCount 0,1,2", f"seen {counts}")

    # 6. poison: 4th delivery has count 3 == threshold -> move to ORDERS.DLQ and commit
    g = client("ORDERS.OUT", "get")
    m = g.get(5000)
    moved = False
    if m is not None and m.backout_count >= g.backout_threshold:
        g.move_to_backout_queue(m)
        g.commit()
        moved = True
    g.close()
    d = client("ORDERS.DLQ", "get")
    dm = d.get(5000)
    d.commit()
    d.close()
    left = drain("ORDERS.OUT")
    report(moved and dm is not None and dm.body == b'{"poison":"yes"}' and left == 0,
           "6 poison message moved to ORDERS.DLQ; ORDERS.OUT left empty",
           f"moved={moved} dlq_has_msg={dm is not None} out_left={left}")

    leftovers = {q: drain(q) for q in ("ORDERS.IN", "ORDERS.OUT", "ORDERS.DLQ")}
    report(all(v == 0 for v in leftovers.values()), "queues left empty", str(leftovers))
    return FAILED


if __name__ == "__main__":
    sys.exit(main())
