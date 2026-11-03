import json
from unittest.mock import MagicMock
import pytest
from bridge.from_eventbridge import FromEventBridge
from bridge.mq_client import MQClientError
from conftest import FakeMQ, ORDER


def make(cfg, mq, stop, msgs):
    sqs = MagicMock()
    sqs.receive_message.return_value = {"Messages": msgs}
    f = FromEventBridge(cfg, sqs, lambda: mq, stop, health=lambda: None, wait_seconds=20)
    f.mq = mq
    return f, sqs


def sqsmsg(detail=None, body=None):
    ev = {"id": "ev-1", "source": "prod.orders", "detail-type": "OrderPlaced", "detail": detail or dict(ORDER)}
    return {"MessageId": "m1", "ReceiptHandle": "rh1", "Body": body if body is not None else json.dumps(ev)}


def test_deletes_only_after_commit(cfg, stop):
    mq = FakeMQ()
    order = []
    mq.commit = lambda: order.append("commit")
    f, sqs = make(cfg, mq, stop, [sqsmsg()])
    sqs.delete_message.side_effect = lambda **k: order.append("delete")
    assert f.step() == 1
    assert order == ["commit", "delete"]
    assert json.loads(mq.puts[0])["detail"]["orderId"] == ORDER["orderId"]
    kw = sqs.receive_message.call_args.kwargs
    assert kw["WaitTimeSeconds"] == 20 and kw["QueueUrl"] == cfg.outbound_queue_url


def test_no_delete_when_commit_fails(cfg, stop):
    mq = FakeMQ()
    mq.fail_commit = True
    f, sqs = make(cfg, mq, stop, [sqsmsg()])
    with pytest.raises(MQClientError):
        f.step()
    sqs.delete_message.assert_not_called()
    assert "backout" in mq.calls


def test_no_delete_when_put_fails(cfg, stop):
    mq = FakeMQ()
    def bad(text): raise MQClientError("put failed")
    mq.put_persistent = bad
    f, sqs = make(cfg, mq, stop, [sqsmsg()])
    with pytest.raises(MQClientError):
        f.step()
    sqs.delete_message.assert_not_called()


def test_origin_ibm_mq_dropped_and_deleted(cfg, stop):
    mq = FakeMQ()
    f, sqs = make(cfg, mq, stop, [sqsmsg(detail=dict(ORDER, origin="ibm-mq"))])
    f.step()
    assert mq.puts == []
    sqs.delete_message.assert_called_once_with(QueueUrl=cfg.outbound_queue_url, ReceiptHandle="rh1")


def test_non_json_not_put_not_deleted(cfg, stop):
    mq = FakeMQ()
    f, sqs = make(cfg, mq, stop, [sqsmsg(body="not json")])
    f.step()
    assert mq.puts == [] and mq.calls == []
    sqs.delete_message.assert_not_called()
