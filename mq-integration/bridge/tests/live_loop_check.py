#!/usr/bin/env python3
"""LIVE check of the bridge's two delivery loops against a REAL IBM MQ queue manager.

Uses the real ToEventBridge / FromEventBridge / MQClient classes and a REAL queue
manager, but FAKE AWS clients (no AWS access, nothing is sent anywhere). It proves
the delivery semantics the unit tests can only simulate:

  MQ -> EventBridge (ToEventBridge)
    A  a valid order on ORDERS.OUT becomes ONE PutEvents entry (source prod.orders,
       OrderPlaced, bus, detail.origin=ibm-mq, correlationId) and the queue empties
    B  FailedEntryCount>0 is retried, and the message is committed only afterwards
    C  PutEvents that keeps failing rolls the message BACK (it stays on ORDERS.OUT)
    D  a poison (non-JSON) message is rolled back 3 times, then moved to ORDERS.DLQ,
       and never reaches EventBridge
  EventBridge -> MQ (FromEventBridge)
    E  an event without origin lands on ORDERS.IN (persistent) and is deleted from
       SQS only after the MQ commit
    F  an event with origin=ibm-mq is DROPPED (deleted, not put on MQ): loop guard
    G  a non-JSON SQS message is neither put on MQ nor deleted (SQS redrive parks it)

Same environment as live_mq_check.py (MQ_HOST, MQ_PORT, MQ_QMGR, MQ_CHANNEL, MQ_USER,
MQ_PASSWORD) plus nothing else; the AWS-ish settings get lab defaults. Leaves every
queue empty. The password is never printed. Exit 0 = all PASS.
"""
import json
import os
import sys
import threading
from pathlib import Path

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[1] / "src"))
os.environ.setdefault("EVENT_BUS_NAME", "eb-prod-orders")
os.environ.setdefault("EVENT_SOURCE", "prod.orders")
os.environ.setdefault("OUTBOUND_QUEUE_URL", "https://sqs.us-east-1.amazonaws.com/000000000000/eb-mq-outbound")
os.environ.setdefault("MQ_QUEUE_TO_EB", "ORDERS.OUT")
os.environ.setdefault("MQ_QUEUE_FROM_EB", "ORDERS.IN")
os.environ.setdefault("POLL_INTERVAL", "0")

from bridge.config import Config  # noqa: E402
from bridge.from_eventbridge import FromEventBridge  # noqa: E402
from bridge.mq_client import MQClient  # noqa: E402
from bridge.to_eventbridge import ToEventBridge  # noqa: E402

CFG = Config.from_env()
SAMPLE = HERE.parents[3] / "schemas" / "samples" / "prod.orders__OrderPlaced" / "valid-1.json"
FAILED = 0


def report(ok, label, extra=""):
    global FAILED
    print(f"{'PASS' if ok else 'FAIL'}  {label}{(' - ' + extra) if extra else ''}")
    if not ok:
        FAILED = 1


def mqc(queue, mode):
    c = MQClient(CFG, queue, mode)
    c.connect()
    return c


def put_raw(queue, text):
    p = mqc(queue, "put")
    p.put_persistent(text)
    p.commit()
    p.close()


def drain(queue):
    c = mqc(queue, "get")
    out = []
    while True:
        m = c.get(500)
        if m is None:
            break
        out.append(m.body)
    c.commit()
    c.close()
    return out


class FakeEvents:
    def __init__(self, fail_first=0, always_fail=False):
        self.calls, self.fail_first, self.always_fail = [], fail_first, always_fail

    def put_events(self, **kw):
        self.calls.append(kw)
        if self.always_fail or len(self.calls) <= self.fail_first:
            return {"FailedEntryCount": 1, "Entries": [{"ErrorCode": "ThrottlingException", "ErrorMessage": "fake"}]}
        return {"FailedEntryCount": 0, "Entries": [{"EventId": "fake"}]}


class FakeSQS:
    def __init__(self, bodies):
        self.bodies, self.deleted = list(bodies), []

    def receive_message(self, **kw):
        msgs = [{"MessageId": f"m{i}", "ReceiptHandle": f"r{i}", "Body": b} for i, b in enumerate(self.bodies)]
        self.bodies = []
        return {"Messages": msgs}

    def delete_message(self, **kw):
        self.deleted.append(kw["ReceiptHandle"])


def to_eb(events):
    t = ToEventBridge(CFG, events, lambda: MQClient(CFG, CFG.mq_queue_to_eb, "get"),
                      threading.Event(), health=lambda: None, wait_ms=2000, base_delay=0.01)
    t.mq = t.mq_factory()
    t.mq.connect()
    return t


def main():
    for q in ("ORDERS.OUT", "ORDERS.IN", "ORDERS.DLQ"):
        drain(q)
    order = json.loads(SAMPLE.read_text())

    # A ------------------------------------------------------------------------
    ev = FakeEvents()
    put_raw("ORDERS.OUT", json.dumps(order))
    t = to_eb(ev)
    handled = t.step()
    ent = ev.calls[0]["Entries"][0] if ev.calls else {}
    det = json.loads(ent.get("Detail", "{}")) if ent else {}
    ok = (handled and len(ev.calls) == 1 and ent.get("Source") == "prod.orders"
          and ent.get("DetailType") == "OrderPlaced" and ent.get("EventBusName") == "eb-prod-orders"
          and det.get("origin") == "ibm-mq" and det.get("orderId") == order["orderId"]
          and bool(det.get("correlationId")))
    report(ok, "A valid MQ order -> one PutEvents entry with origin=ibm-mq and correlationId")
    report(t.step() is False and drain("ORDERS.OUT") == [], "A  ... and ORDERS.OUT is empty (committed)")
    t.mq.close()

    # B ------------------------------------------------------------------------
    ev = FakeEvents(fail_first=2)
    put_raw("ORDERS.OUT", json.dumps(order))
    t = to_eb(ev)
    t.step()
    report(len(ev.calls) == 3 and drain("ORDERS.OUT") == [], "B FailedEntryCount>0 retried (3 calls) then committed",
           f"calls={len(ev.calls)}")
    t.mq.close()

    # C ------------------------------------------------------------------------
    ev = FakeEvents(always_fail=True)
    put_raw("ORDERS.OUT", json.dumps(order))
    t = to_eb(ev)
    t.step()
    t.mq.close()
    back = mqc("ORDERS.OUT", "get")
    m = back.get(3000)
    still = m is not None and m.backout_count >= 1
    back.backout()
    back.close()
    report(still, "C PutEvents keeps failing -> message rolled BACK and still on ORDERS.OUT",
           f"backout_count={getattr(m, 'backout_count', None)}")
    t = to_eb(FakeEvents())          # EventBridge recovers: the same message goes through
    t.step()
    report(drain("ORDERS.OUT") == [], "C  ... then it is delivered once EventBridge recovers")
    t.mq.close()

    # D ------------------------------------------------------------------------
    ev = FakeEvents()
    put_raw("ORDERS.OUT", "this is not json")
    for _ in range(4):               # 3 rollbacks, then the 4th delivery is moved to the DLQ
        t = to_eb(ev)
        t.step()
        t.mq.close()
    dlq = drain("ORDERS.DLQ")
    report(dlq == [b"this is not json"] and drain("ORDERS.OUT") == [] and not ev.calls,
           "D poison message -> rolled back 3x, moved to ORDERS.DLQ, never sent to EventBridge",
           f"dlq={len(dlq)} eb_calls={len(ev.calls)}")

    # E / F / G ------------------------------------------------------------------
    good = {"id": "evt-good", "source": "prod.orders", "detail-type": "OrderPlaced", "detail": dict(order)}
    looped = {"id": "evt-loop", "source": "prod.orders", "detail-type": "OrderPlaced",
              "detail": dict(order, origin="ibm-mq")}
    sqs = FakeSQS([json.dumps(good), json.dumps(looped), "not json at all"])
    f = FromEventBridge(CFG, sqs, lambda: MQClient(CFG, CFG.mq_queue_from_eb, "put"),
                        threading.Event(), health=lambda: None, wait_seconds=0)
    f.mq = f.mq_factory()
    f.mq.connect()
    f.step()
    f.mq.close()
    in_msgs = drain("ORDERS.IN")
    report(len(in_msgs) == 1 and b"evt-good" in in_msgs[0] and "r0" in sqs.deleted,
           "E event without origin -> ORDERS.IN, SQS message deleted after the MQ commit",
           f"on_queue={len(in_msgs)} deleted={sqs.deleted}")
    report("r1" in sqs.deleted and not any(b"evt-loop" in x for x in in_msgs),
           "F event with origin=ibm-mq dropped (deleted, NOT put on MQ): loop guard")
    report("r2" not in sqs.deleted,
           "G non-JSON SQS message not deleted (left for the SQS redrive policy)")

    left = {q: len(drain(q)) for q in ("ORDERS.OUT", "ORDERS.IN", "ORDERS.DLQ")}
    report(all(v == 0 for v in left.values()), "queues left empty", str(left))
    return FAILED


if __name__ == "__main__":
    sys.exit(main())
