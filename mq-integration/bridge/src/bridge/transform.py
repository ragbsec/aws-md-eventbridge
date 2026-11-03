"""Pure transformation functions (no I/O)."""
from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any, Dict, Tuple

ORIGIN = "ibm-mq"
DETAIL_TYPE = "OrderPlaced"

# Order contract: schemas/prod.orders__OrderPlaced.json (components.schemas.OrderPlaced)
ORDER_FIELDS = ("orderId", "product", "quantity", "amount", "placedAt")
# PutEvents limit is 256 KB per entry (incl. envelope overhead); keep headroom.
MAX_ENTRY_BYTES = 256 * 1024 - 2048

_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


class TransformError(ValueError):
    """Permanent (poison) failure: retrying will not help."""


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def validate_order(order: Any) -> Dict[str, Any]:
    if not isinstance(order, dict):
        raise TransformError("message must be a JSON object")
    errs = [f"missing required field: {k}" for k in ORDER_FIELDS if k not in order]
    extra = sorted(set(order) - set(ORDER_FIELDS))
    if extra:  # schema has additionalProperties=false
        errs.append(f"unexpected fields: {extra}")
    if not errs:
        if not (isinstance(order["orderId"], str) and _UUID.match(order["orderId"])):
            errs.append("orderId must be a UUID string")
        if not (isinstance(order["product"], str) and order["product"]):
            errs.append("product must be a non-empty string")
        if not (_is_int(order["quantity"]) and order["quantity"] >= 1):
            errs.append("quantity must be an integer >= 1")
        if not (_is_num(order["amount"]) and order["amount"] >= 0):
            errs.append("amount must be a number >= 0")
        pa = order["placedAt"]
        try:
            if not isinstance(pa, str):
                raise ValueError
            datetime.fromisoformat(pa.replace("Z", "+00:00"))
        except ValueError:
            errs.append("placedAt must be an RFC3339 date-time string")
    if errs:
        raise TransformError("; ".join(errs))
    return order


def correlation_id(msg_id_hex: str, correl_id_hex: str = "") -> str:
    """CorrelId if the producer set one (non-zero), else MsgId."""
    c = (correl_id_hex or "").lower()
    if c and set(c) != {"0"}:
        return c
    return (msg_id_hex or "").lower()


def mq_to_entry(body: bytes, msg_id_hex: str, correl_id_hex: str,
                bus: str, source: str) -> Tuple[Dict[str, str], str]:
    """MQ message bytes -> (PutEvents entry, orderId). Raises TransformError."""
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as e:
        raise TransformError(f"message is not valid UTF-8: {e.reason}") from None
    try:
        order = json.loads(text)
    except json.JSONDecodeError as e:
        raise TransformError(f"message is not valid JSON: {e.msg}") from None
    validate_order(order)
    detail = dict(order)
    detail["origin"] = ORIGIN
    detail["correlationId"] = correlation_id(msg_id_hex, correl_id_hex)
    entry = {
        "Source": source,
        "DetailType": DETAIL_TYPE,
        "EventBusName": bus,
        "Detail": json.dumps(detail, separators=(",", ":")),
    }
    size = sum(len(entry[k].encode("utf-8")) for k in ("Source", "DetailType", "Detail"))
    if size > MAX_ENTRY_BYTES:
        raise TransformError(f"entry too large for PutEvents ({size} bytes)")
    return entry, order["orderId"]


def parse_sqs_event(body: str) -> Dict[str, Any]:
    """SQS body (EventBridge event JSON) -> dict. Raises TransformError on non-JSON."""
    try:
        ev = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        raise TransformError("SQS body is not valid JSON") from None
    if not isinstance(ev, dict):
        raise TransformError("SQS body must be a JSON object")
    return ev


def is_bridge_origin(event: Dict[str, Any]) -> bool:
    detail = event.get("detail")
    return isinstance(detail, dict) and detail.get("origin") == ORIGIN


def sqs_to_mq_text(body: str) -> Tuple[str, Dict[str, Any]]:
    """Return (text for ORDERS.IN, parsed event). The full EventBridge event
    envelope is forwarded unchanged (compact JSON)."""
    ev = parse_sqs_event(body)
    return json.dumps(ev, separators=(",", ":"), ensure_ascii=False), ev
