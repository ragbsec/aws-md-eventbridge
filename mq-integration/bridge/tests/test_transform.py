import json
import pytest
from bridge import transform as t
from conftest import ORDER


def entry(body=None, mid="ab" * 24, cid="00" * 24):
    body = json.dumps(ORDER).encode() if body is None else body
    return t.mq_to_entry(body, mid, cid, "eb-prod-orders", "prod.orders")


def test_happy_path():
    e, oid = entry()
    assert oid == ORDER["orderId"]
    assert (e["Source"], e["DetailType"], e["EventBusName"]) == ("prod.orders", "OrderPlaced", "eb-prod-orders")
    d = json.loads(e["Detail"])
    assert d["origin"] == "ibm-mq" and d["correlationId"] == "ab" * 24
    assert {k: d[k] for k in ORDER} == ORDER


def test_correlid_preferred_when_set():
    d = json.loads(entry(cid="cd" * 24)[0]["Detail"])
    assert d["correlationId"] == "cd" * 24


@pytest.mark.parametrize("mut", [
    lambda o: o.pop("orderId"), lambda o: o.pop("placedAt"),
    lambda o: o.update(orderId="nope"), lambda o: o.update(quantity=0),
    lambda o: o.update(quantity=1.5), lambda o: o.update(quantity=True),
    lambda o: o.update(amount=-1), lambda o: o.update(amount="3"),
    lambda o: o.update(product=""), lambda o: o.update(placedAt="yesterday"),
    lambda o: o.update(extra=1), lambda o: o.update(origin="ibm-mq"),
])
def test_validation_failures(mut):
    o = dict(ORDER)
    mut(o)
    with pytest.raises(t.TransformError):
        entry(json.dumps(o).encode())


@pytest.mark.parametrize("body", [b"not json", b"[1,2]", b"\xff\xfe", b'"s"', b""])
def test_rejects_non_json_object(body):
    with pytest.raises(t.TransformError):
        entry(body)


def test_size_guard():
    o = dict(ORDER, product="x" * 300_000)
    with pytest.raises(t.TransformError, match="too large"):
        entry(json.dumps(o).encode())


def test_origin_detection():
    assert t.is_bridge_origin({"detail": {"origin": "ibm-mq"}})
    assert not t.is_bridge_origin({"detail": {"origin": "other"}})
    assert not t.is_bridge_origin({"detail": "x"})
    assert not t.is_bridge_origin({})


def test_sqs_to_mq_text_roundtrip_and_reject():
    ev = {"id": "1", "detail": dict(ORDER)}
    text, parsed = t.sqs_to_mq_text(json.dumps(ev, indent=2))
    assert json.loads(text) == ev and parsed == ev
    for bad in ("nope", "[1]", ""):
        with pytest.raises(t.TransformError):
            t.sqs_to_mq_text(bad)
