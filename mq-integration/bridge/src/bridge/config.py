"""Environment parsing and fail-fast validation."""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping, Optional


class ConfigError(Exception):
    pass


REQUIRED = (
    "EVENT_BUS_NAME", "EVENT_SOURCE", "OUTBOUND_QUEUE_URL",
    "MQ_HOST", "MQ_QMGR", "MQ_CHANNEL", "MQ_USER", "MQ_PASSWORD",
    "MQ_QUEUE_TO_EB", "MQ_QUEUE_FROM_EB",
)


@dataclass(frozen=True)
class Config:
    aws_region: str
    event_bus_name: str
    event_source: str
    outbound_queue_url: str
    mq_host: str
    mq_port: int
    mq_qmgr: str
    mq_channel: str
    mq_user: str
    mq_password: str = ""  # never printed; excluded from repr
    mq_queue_to_eb: str = ""
    mq_queue_from_eb: str = ""
    eb_endpoint_id: Optional[str] = None
    secret_id: Optional[str] = None
    log_level: str = "INFO"
    poll_interval: float = 1.0

    def __repr__(self) -> str:  # keep the password out of logs/tracebacks
        d = {k: ("***" if k == "mq_password" else v) for k, v in self.__dict__.items()}
        return f"Config({d})"

    @classmethod
    def from_env(cls, env: Optional[Mapping[str, str]] = None) -> "Config":
        env = os.environ if env is None else env
        get = lambda k: (env.get(k) or "").strip()  # noqa: E731
        missing = [k for k in REQUIRED if not get(k)]
        problems = []
        if missing:
            problems.append("missing required env vars: " + ", ".join(missing))

        port_s = get("MQ_PORT") or "1414"
        poll_s = get("POLL_INTERVAL") or "1.0"
        port = 1414
        poll = 1.0
        try:
            port = int(port_s)
            if not 1 <= port <= 65535:
                raise ValueError
        except ValueError:
            problems.append(f"MQ_PORT must be an integer 1-65535, got {port_s!r}")
        try:
            poll = float(poll_s)
            if poll < 0:
                raise ValueError
        except ValueError:
            problems.append(f"POLL_INTERVAL must be a number >= 0, got {poll_s!r}")
        level = (get("LOG_LEVEL") or "INFO").upper()
        if level not in ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"):
            problems.append(f"LOG_LEVEL invalid: {level!r}")
        if get("OUTBOUND_QUEUE_URL") and not get("OUTBOUND_QUEUE_URL").startswith("https://"):
            problems.append("OUTBOUND_QUEUE_URL must be an https:// SQS queue URL")
        if get("MQ_QUEUE_TO_EB") and get("MQ_QUEUE_TO_EB") == get("MQ_QUEUE_FROM_EB"):
            problems.append("MQ_QUEUE_TO_EB and MQ_QUEUE_FROM_EB must differ (feedback loop)")
        if problems:
            raise ConfigError("invalid configuration: " + "; ".join(problems))

        return cls(
            aws_region=get("AWS_REGION") or "us-east-1",
            event_bus_name=get("EVENT_BUS_NAME"),
            event_source=get("EVENT_SOURCE"),
            outbound_queue_url=get("OUTBOUND_QUEUE_URL"),
            mq_host=get("MQ_HOST"),
            mq_port=port,
            mq_qmgr=get("MQ_QMGR"),
            mq_channel=get("MQ_CHANNEL"),
            mq_user=get("MQ_USER"),
            mq_password=env.get("MQ_PASSWORD", ""),
            mq_queue_to_eb=get("MQ_QUEUE_TO_EB"),
            mq_queue_from_eb=get("MQ_QUEUE_FROM_EB"),
            eb_endpoint_id=get("EB_ENDPOINT_ID") or None,
            secret_id=get("SECRET_ID") or None,
            log_level=level,
            poll_interval=poll,
        )
