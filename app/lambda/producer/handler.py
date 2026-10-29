"""
EventBridge lab — PRODUCER Lambda.

Publishes one or more synthetic `OrderPlaced` events onto the custom event bus.
Invoked two ways in this lab:
  1. On a recurring EventBridge Scheduler schedule (proves "scheduled producer").
  2. Manually / by the test harness (proves "on-demand producer").

Environment:
  EVENT_BUS_NAME  - name of the custom bus to publish to
  EVENT_SOURCE    - the `source` field stamped on every event
"""

import json
import os
import random
import uuid
from datetime import datetime, timezone

import boto3

events = boto3.client("events")

BUS = os.environ["EVENT_BUS_NAME"]
SOURCE = os.environ.get("EVENT_SOURCE", "lab.orders")

_PRODUCTS = ["widget", "gadget", "gizmo", "doohickey", "sprocket"]


def _make_order() -> dict:
    return {
        "orderId": str(uuid.uuid4()),
        "product": random.choice(_PRODUCTS),
        "quantity": random.randint(1, 5),
        "amount": round(random.uniform(9.99, 499.99), 2),
        "placedAt": datetime.now(timezone.utc).isoformat(),
    }


def handler(event, context):
    # Allow the caller to request a batch size; default to 1.
    count = 1
    if isinstance(event, dict):
        count = int(event.get("count", 1))

    entries = []
    for _ in range(count):
        order = _make_order()
        entries.append(
            {
                "Source": SOURCE,
                "DetailType": "OrderPlaced",
                "Detail": json.dumps(order),
                "EventBusName": BUS,
            }
        )

    resp = events.put_events(Entries=entries)
    failed = resp.get("FailedEntryCount", 0)

    result = {
        "published": len(entries) - failed,
        "failed": failed,
        "bus": BUS,
        "source": SOURCE,
        "sampleOrderIds": [json.loads(e["Detail"])["orderId"] for e in entries],
    }
    print(json.dumps({"level": "INFO", "msg": "produced events", **result}))
    return result
