"""Transformed Detail must satisfy the OrderPlaced contract, using the same
validation code path as scripts/contract_test.py."""
import importlib.util
import json
from pathlib import Path

import pytest
from bridge import transform as t
from conftest import ORDER

REPO = Path(__file__).resolve().parents[3]
SCHEMA = REPO / "schemas" / "prod.orders__OrderPlaced.json"
SAMPLES = REPO / "schemas" / "samples" / "prod.orders__OrderPlaced"

if not SCHEMA.exists():
    pytest.skip("repo schemas not found", allow_module_level=True)

spec = importlib.util.spec_from_file_location("contract_test", REPO / "scripts" / "contract_test.py")
ct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ct)
SCHEMA_NODE = ct._schema_node(ct._load(str(SCHEMA)))
BRIDGE_FIELDS = {"origin", "correlationId"}


def detail_of(order):
    e, _ = t.mq_to_entry(json.dumps(order).encode(), "ab" * 24, "00" * 24, "b", "prod.orders")
    return json.loads(e["Detail"])


def test_order_fields_match_schema():
    assert tuple(sorted(t.ORDER_FIELDS)) == tuple(sorted(SCHEMA_NODE["required"]))


def test_full_detail_validates_including_bridge_metadata():
    """schemas/prod.orders__OrderPlaced.json (v1.1.0) declares origin and
    correlationId as OPTIONAL properties, so the FULL Detail the bridge publishes
    validates strictly (additionalProperties stays false)."""
    d = detail_of(ORDER)
    assert d["origin"] == "ibm-mq" and d["correlationId"]
    assert ct._validate(SCHEMA_NODE, d) == []


def test_metadata_fields_are_optional_in_schema():
    assert BRIDGE_FIELDS.isdisjoint(SCHEMA_NODE["required"])
    assert BRIDGE_FIELDS <= set(SCHEMA_NODE["properties"])


def test_unknown_extra_field_still_rejected():
    d = detail_of(ORDER)
    d["surprise"] = 1
    assert ct._validate(SCHEMA_NODE, d) != []


@pytest.mark.parametrize("p", sorted(SAMPLES.glob("valid-*.json")))
def test_valid_samples_accepted_by_bridge(p):
    """Inbound MQ messages carry ONLY the order fields. Bridge-owned metadata
    (origin, correlationId) is stripped from the sample first: valid-2.json shows
    the PUBLISHED event shape, which must validate against the schema (below)."""
    sample = json.loads(p.read_text())
    order = {k: v for k, v in sample.items() if k not in BRIDGE_FIELDS}
    assert detail_of(order)["orderId"] == sample["orderId"]


@pytest.mark.parametrize("p", sorted(SAMPLES.glob("valid-*.json")))
def test_valid_samples_validate_against_schema(p):
    assert ct._validate(SCHEMA_NODE, json.loads(p.read_text())) == []


def test_apps_cannot_set_bridge_metadata_on_inbound_messages():
    """Security: an app must not be able to pre-set origin (it would defeat the
    anti-loop guard or spoof the source). The bridge rejects such messages."""
    bad = dict(ORDER, origin="not-ibm-mq")
    with pytest.raises(t.TransformError):
        detail_of(bad)


@pytest.mark.parametrize("p", sorted(SAMPLES.glob("invalid-*.json")))
def test_invalid_samples_rejected_by_bridge(p):
    with pytest.raises(t.TransformError):
        detail_of(json.loads(p.read_text()))
