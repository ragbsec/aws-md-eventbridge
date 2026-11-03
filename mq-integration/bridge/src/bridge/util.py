"""Shared helpers: JSON logging, health file, backoff."""
from __future__ import annotations

import json
import logging
import os
import time

HEALTH_FILE = os.environ.get("HEALTH_FILE", "/tmp/healthy")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        out = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)) + "Z",
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        out.update(getattr(record, "fields", {}) or {})
        if record.exc_info:
            out["exc"] = self.formatException(record.exc_info)
        return json.dumps(out, default=str)


def setup_logging(level: str = "INFO") -> None:
    h = logging.StreamHandler()
    h.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [h]
    root.setLevel(level)
    logging.getLogger("botocore").setLevel(logging.WARNING)


def log(logger: logging.Logger, level: int, msg: str, **fields) -> None:
    logger.log(level, msg, extra={"fields": fields})


def touch_health(path: str = None) -> None:
    path = path or HEALTH_FILE
    try:
        with open(path, "a"):
            os.utime(path, None)
    except OSError:
        pass


def next_delay(current: float, base: float = 1.0, cap: float = 30.0) -> float:
    return base if current <= 0 else min(current * 2, cap)
