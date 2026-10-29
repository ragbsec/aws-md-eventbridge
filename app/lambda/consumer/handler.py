"""
EventBridge lab — CONSUMER Lambda.

Invoked by an EventBridge RULE whose event pattern matches `OrderPlaced` events
on the custom bus. Demonstrates the "consume + process" half of the flow:
  - parses the event envelope EventBridge delivers,
  - performs trivial "business logic" (totals, validation),
  - raises on a poison record so the rule's DLQ / retry path is exercised.

A record with quantity <= 0 is treated as poison to demonstrate failure
handling; the synthetic producer never emits those, so the happy path is clean.

Environment:
  RESULT_LOG_GROUP - (informational) where processed results are logged
"""

import json


class PoisonEventError(Exception):
    """Raised for events that must go to the DLQ / retry path."""


def handler(event, context):
    # EventBridge delivers the event as the top-level object; the payload we
    # published lives under "detail".
    detail = event.get("detail", {})
    detail_type = event.get("detail-type", "<unknown>")
    source = event.get("source", "<unknown>")

    order_id = detail.get("orderId", "<none>")
    quantity = int(detail.get("quantity", 0))
    amount = float(detail.get("amount", 0.0))

    if quantity <= 0:
        # Poison record — surface it so EventBridge retries then DLQs it.
        print(
            json.dumps(
                {"level": "ERROR", "msg": "poison event", "orderId": order_id}
            )
        )
        raise PoisonEventError(f"invalid quantity for order {order_id}")

    line_total = round(quantity * amount, 2)

    print(
        json.dumps(
            {
                "level": "INFO",
                "msg": "processed order",
                "source": source,
                "detailType": detail_type,
                "orderId": order_id,
                "quantity": quantity,
                "unitAmount": amount,
                "lineTotal": line_total,
            }
        )
    )

    return {"orderId": order_id, "lineTotal": line_total, "status": "PROCESSED"}
