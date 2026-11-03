"""Entrypoint: python -m bridge.main"""
from __future__ import annotations

import logging
import signal
import sys
import threading

from .config import Config, ConfigError
from .util import log, setup_logging

logger = logging.getLogger("bridge.main")


def main() -> int:
    try:
        cfg = Config.from_env()
    except ConfigError as e:
        print(f"FATAL: {e}", file=sys.stderr)
        return 2
    setup_logging(cfg.log_level)

    import boto3
    from .from_eventbridge import FromEventBridge
    from .mq_client import MQClient
    from .to_eventbridge import ToEventBridge

    # Credentials: default chain -> EC2 instance role via IMDSv2. No keys set here.
    events = boto3.client("events", region_name=cfg.aws_region)
    sqs = boto3.client("sqs", region_name=cfg.aws_region)

    stop = threading.Event()

    def _sig(signum, _frame):
        log(logger, logging.INFO, "shutdown requested", signal=signum)
        stop.set()

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)

    to_eb = ToEventBridge(cfg, events, lambda: MQClient(cfg, cfg.mq_queue_to_eb, "get"), stop)
    from_eb = FromEventBridge(cfg, sqs, lambda: MQClient(cfg, cfg.mq_queue_from_eb, "put"), stop)
    threads = [threading.Thread(target=t.run, name=n, daemon=True)
               for n, t in (("mq-to-eb", to_eb), ("eb-to-mq", from_eb))]
    log(logger, logging.INFO, "bridge starting", bus=cfg.event_bus_name,
        endpoint_id=cfg.eb_endpoint_id, region=cfg.aws_region)
    for t in threads:
        t.start()
    while not stop.is_set():
        if not all(t.is_alive() for t in threads):
            logger.error("a worker thread died; exiting")
            stop.set()
            return 1
        stop.wait(2)
    for t in threads:
        t.join(timeout=30)  # in-flight unit of work finishes or is backed out
    log(logger, logging.INFO, "bridge stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
