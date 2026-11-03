"""Loop 1: IBM MQ (ORDERS.OUT) -> EventBridge PutEvents."""
from __future__ import annotations

import logging
import threading
from typing import Callable

from . import transform
from .mq_client import MQClientError
from .util import log, next_delay, touch_health

logger = logging.getLogger("bridge.to_eventbridge")

MAX_PUT_ATTEMPTS = 5
WAIT_MS = 5000


class PublishError(Exception):
    pass


class ToEventBridge:
    def __init__(self, cfg, events_client, mq_factory: Callable, stop: threading.Event,
                 health: Callable = touch_health, wait_ms: int = WAIT_MS,
                 base_delay: float = 0.5):
        self.cfg, self.events, self.mq_factory = cfg, events_client, mq_factory
        self.stop, self.health, self.wait_ms, self.base_delay = stop, health, wait_ms, base_delay
        self.mq = None

    # -- PutEvents with retry --------------------------------------------
    def publish(self, entry: dict) -> None:
        kwargs = {"Entries": [entry]}
        if self.cfg.eb_endpoint_id:
            kwargs["EndpointId"] = self.cfg.eb_endpoint_id
        delay, err = 0.0, "unknown"
        for attempt in range(1, MAX_PUT_ATTEMPTS + 1):
            try:
                resp = self.events.put_events(**kwargs)
                if resp.get("FailedEntryCount", 0) == 0:
                    return
                e0 = (resp.get("Entries") or [{}])[0]
                err = f"{e0.get('ErrorCode')}: {e0.get('ErrorMessage')}"
            except Exception as e:  # network / throttling / auth
                err = f"{type(e).__name__}: {e}"
            log(logger, logging.WARNING, "PutEvents failed", attempt=attempt, error=err)
            if attempt < MAX_PUT_ATTEMPTS:
                delay = next_delay(delay, self.base_delay)
                if self.stop.wait(delay):
                    break
        raise PublishError(err)

    # -- one unit of work ---------------------------------------------------
    def step(self) -> bool:
        """Process at most one message. Returns True if a message was handled."""
        mq = self.mq
        msg = mq.get(self.wait_ms)
        if msg is None:
            return False
        mid = msg.msg_id_hex
        # Honour BOTHRESH/BOQNAME: plain MQI apps must requeue poison messages.
        if mq.backout_threshold and mq.backout_queue and msg.backout_count >= mq.backout_threshold:
            try:
                mq.move_to_backout_queue(msg)
                mq.commit()
            except MQClientError:
                mq.backout()
                raise
            log(logger, logging.ERROR, "message moved to backout queue",
                msg_id=mid, backout_count=msg.backout_count, queue=mq.backout_queue)
            return True
        try:
            entry, order_id = transform.mq_to_entry(
                msg.body, mid, msg.correl_id_hex, self.cfg.event_bus_name, self.cfg.event_source)
            self.publish(entry)
        except transform.TransformError as e:
            mq.backout()  # poison: MQ backout threshold will route it to the DLQ
            log(logger, logging.ERROR, "invalid message rolled back",
                msg_id=mid, backout_count=msg.backout_count, reason=str(e))
            return True
        except PublishError as e:
            mq.backout()
            log(logger, logging.ERROR, "publish failed, message rolled back",
                msg_id=mid, backout_count=msg.backout_count, error=str(e))
            self.stop.wait(self.base_delay)
            return True
        except BaseException:
            mq.backout()
            raise
        mq.commit()
        log(logger, logging.INFO, "published", msg_id=mid, order_id=order_id)
        return True

    def run(self) -> None:
        delay = 0.0
        while not self.stop.is_set():
            try:
                self.mq = self.mq_factory()
                self.mq.connect()
                delay = 0.0
                log(logger, logging.INFO, "connected to MQ", queue=self.cfg.mq_queue_to_eb)
                while not self.stop.is_set():
                    self.health()
                    if not self.step() and self.cfg.poll_interval:
                        self.stop.wait(self.cfg.poll_interval)
            except MQClientError as e:
                delay = next_delay(delay)
                log(logger, logging.ERROR, "MQ error, reconnecting",
                    error=str(e), reason=e.reason, retry_in=delay)
                self.stop.wait(delay)
            except Exception:
                delay = next_delay(delay)
                logger.exception("unexpected error, reconnecting")
                self.stop.wait(delay)
            finally:
                if self.mq is not None:
                    self.mq.close()
                    self.mq = None
