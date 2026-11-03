import json
from unittest.mock import MagicMock
import pytest
from bridge.mq_client import MQClientError
from bridge.to_eventbridge import ToEventBridge
from conftest import FakeMQ, mqmsg


def make(cfg, events, mq, stop):
    b = ToEventBridge(cfg, events, lambda: mq, stop, health=lambda: None, wait_ms=1, base_delay=0)
    b.mq = mq
    return b


def test_commit_only_after_success(cfg, events, stop):
    mq = FakeMQ([mqmsg()])
    assert make(cfg, events, mq, stop).step() is True
    assert mq.calls == ["commit"]
    kw = events.put_events.call_args.kwargs
    assert "EndpointId" not in kw
    assert json.loads(kw["Entries"][0]["Detail"])["origin"] == "ibm-mq"


def test_empty_queue(cfg, events, stop):
    mq = FakeMQ()
    assert make(cfg, events, mq, stop).step() is False
    events.put_events.assert_not_called()


def test_endpoint_id_used(cfg_endpoint, events, stop):
    mq = FakeMQ([mqmsg()])
    make(cfg_endpoint, events, mq, stop).step()
    assert events.put_events.call_args.kwargs["EndpointId"] == "abc123.xyz"


def test_failed_entry_then_success_retries(cfg, events, stop):
    events.put_events.side_effect = [
        {"FailedEntryCount": 1, "Entries": [{"ErrorCode": "ThrottlingException", "ErrorMessage": "x"}]},
        {"FailedEntryCount": 0, "Entries": [{"EventId": "e"}]},
    ]
    mq = FakeMQ([mqmsg()])
    make(cfg, events, mq, stop).step()
    assert events.put_events.call_count == 2 and mq.calls == ["commit"]


def test_persistent_failure_rolls_back(cfg, events, stop):
    events.put_events.return_value = {"FailedEntryCount": 1, "Entries": [{"ErrorCode": "Internal", "ErrorMessage": "x"}]}
    mq = FakeMQ([mqmsg()])
    make(cfg, events, mq, stop).step()
    assert events.put_events.call_count == 5
    assert mq.calls == ["backout"]


def test_exception_from_boto_rolls_back(cfg, events, stop):
    events.put_events.side_effect = RuntimeError("boom")
    mq = FakeMQ([mqmsg()])
    make(cfg, events, mq, stop).step()
    assert mq.calls == ["backout"]


def test_poison_rolls_back_without_put(cfg, events, stop):
    mq = FakeMQ([mqmsg(body="garbage")])
    make(cfg, events, mq, stop).step()
    assert mq.calls == ["backout"]
    events.put_events.assert_not_called()


def test_backout_threshold_moves_to_dlq(cfg, events, stop):
    mq = FakeMQ([mqmsg(body="garbage", backout=3)])
    make(cfg, events, mq, stop).step()
    assert mq.calls == ["move", "commit"] and len(mq.moved) == 1
    events.put_events.assert_not_called()


def test_commit_failure_propagates(cfg, events, stop):
    mq = FakeMQ([mqmsg()])
    mq.fail_commit = True
    with pytest.raises(MQClientError):
        make(cfg, events, mq, stop).step()


def test_run_reconnects_then_stops(cfg, events, stop):
    seq = []
    class Flaky(FakeMQ):
        def connect(self):
            seq.append("c")
            if len(seq) == 1:
                raise MQClientError("down", 2059)
            stop.set()
    b = ToEventBridge(cfg, events, lambda: Flaky(), stop, health=lambda: None, base_delay=0)
    b.run()
    assert seq == ["c", "c"]
