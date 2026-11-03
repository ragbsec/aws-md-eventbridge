import pytest
from bridge.config import Config, ConfigError
from conftest import ENV


def test_ok_defaults():
    env = {k: v for k, v in ENV.items() if k not in ("MQ_PORT", "AWS_REGION")}
    c = Config.from_env(env)
    assert c.mq_port == 1414 and c.aws_region == "us-east-1" and c.eb_endpoint_id is None
    assert c.poll_interval == 1.0 and c.log_level == "INFO"


def test_missing_lists_all():
    with pytest.raises(ConfigError) as e:
        Config.from_env({"MQ_HOST": "mq"})
    msg = str(e.value)
    for k in ("EVENT_BUS_NAME", "OUTBOUND_QUEUE_URL", "MQ_PASSWORD", "MQ_QMGR"):
        assert k in msg
    assert "MQ_HOST," not in msg


def test_bad_values():
    with pytest.raises(ConfigError) as e:
        Config.from_env({**ENV, "MQ_PORT": "abc", "POLL_INTERVAL": "-1", "LOG_LEVEL": "LOUD"})
    assert "MQ_PORT" in str(e.value) and "POLL_INTERVAL" in str(e.value) and "LOG_LEVEL" in str(e.value)


def test_same_queue_rejected():
    with pytest.raises(ConfigError):
        Config.from_env({**ENV, "MQ_QUEUE_FROM_EB": "ORDERS.OUT"})


def test_password_not_in_repr(cfg):
    assert "not-a-real-password" not in repr(cfg)
