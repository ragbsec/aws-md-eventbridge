import json
import sys
import threading
import types
from unittest.mock import MagicMock

import pytest

# Stub the native-backed `ibmmq` package so no MQ C libraries are needed.
sys.modules.setdefault("ibmmq", types.ModuleType("ibmmq"))

from bridge.config import Config  # noqa: E402
from bridge.mq_client import MQMessage  # noqa: E402

ORDER = {
    "orderId": "0b11194d-4631-4867-8a44-b01f4ca96d61",
    "product": "widget", "quantity": 3, "amount": 38.82,
    "placedAt": "2026-10-27T23:05:29Z",
}

ENV = {
    "AWS_REGION": "us-east-1", "EVENT_BUS_NAME": "eb-prod-orders", "EVENT_SOURCE": "prod.orders",
    "OUTBOUND_QUEUE_URL": "https://sqs.us-east-1.amazonaws.com/123456789012/q",
    "MQ_HOST": "mq", "MQ_PORT": "1414", "MQ_QMGR": "QM1", "MQ_CHANNEL": "APP.SVRCONN",
    "MQ_USER": "app", "MQ_PASSWORD": "not-a-real-password",
    "MQ_QUEUE_TO_EB": "ORDERS.OUT", "MQ_QUEUE_FROM_EB": "ORDERS.IN",
}


@pytest.fixture
def cfg():
    return Config.from_env(dict(ENV))


@pytest.fixture
def cfg_endpoint():
    return Config.from_env({**ENV, "EB_ENDPOINT_ID": "abc123.xyz"})


@pytest.fixture
def stop():
    ev = threading.Event()
    return ev


class FakeMQ:
    """Fake bridge.mq_client.MQClient."""
    def __init__(self, messages=(), threshold=3, boq="ORDERS.DLQ"):
        self.messages = list(messages)
        self.backout_threshold, self.backout_queue = threshold, boq
        self.calls, self.puts, self.moved = [], [], []
        self.fail_commit = False

    def connect(self): self.calls.append("connect")
    def close(self): self.calls.append("close")

    def get(self, wait_ms):
        return self.messages.pop(0) if self.messages else None

    def put_persistent(self, text): self.calls.append("put"); self.puts.append(text)

    def move_to_backout_queue(self, msg): self.calls.append("move"); self.moved.append(msg)

    def commit(self):
        from bridge.mq_client import MQClientError
        if self.fail_commit:
            raise MQClientError("commit failed")
        self.calls.append("commit")

    def backout(self): self.calls.append("backout")


def mqmsg(body=None, msg_id="aa" * 24, correl="00" * 24, backout=0):
    if body is None:
        body = json.dumps(ORDER)
    if isinstance(body, str):
        body = body.encode()
    return MQMessage(body=body, msg_id_hex=msg_id, correl_id_hex=correl, backout_count=backout)


@pytest.fixture
def events():
    m = MagicMock()
    m.put_events.return_value = {"FailedEntryCount": 0, "Entries": [{"EventId": "e1"}]}
    return m
