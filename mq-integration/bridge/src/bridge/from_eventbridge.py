"""Loop 2: SQS (fed by rule mq-outbound-rule) -> IBM MQ (ORDERS.IN)."""
from __future__ import annotations

import logging
import threading
from typing import Callable

from . import transform
from .mq_client import MQClientError
from .util import log, next_delay, touch_health

logger = logging.getLogger("bridge.from_eventbridge")


class FromEventBridge:
    def __init__(self, cfg, sqs_client, mq_factory: Callable, stop: threading.Event,
                 health: Callable = touch_health, wait_seconds: int = 20):
        self.cfg, self.sqs, self.mq_factory = cfg, sqs_client, mq_factory
        self.stop, self.health, self.wait_seconds = stop, health, wait_seconds
        self.mq = None

    def _delete(self, m) -> None:
        self.sqs.delete_message(QueueUrl=self.cfg.outbound_queue_url,
                                ReceiptHandle=m["ReceiptHandle"])

    def handle(self, m) -> None:
        sid = m.get("MessageId")
        try:
            text, ev = transform.sqs_to_mq_text(m["Body"])
        except transform.TransformError as e:
            # Not deleted: the queue's redrive policy parks it in the SQS DLQ.
            log(logger, logging.ERROR, "non-JSON SQS message left for redrive",
                sqs_id=sid, reason=str(e))
            return
        if transform.is_bridge_origin(ev):
            self._delete(m)
            log(logger, logging.WARNING, "dropped event with origin=ibm-mq (loop guard)",
                sqs_id=sid, event_id=ev.get("id"))
            return
        try:
            self.mq.put_persistent(text)
            self.mq.commit()
        except MQClientError:
            try:
                self.mq.backout()
            except MQClientError:
                pass
            raise  # message stays in SQS and is redelivered after visibility timeout
        self._delete(m)  # only after the MQ put is committed
        log(logger, logging.INFO, "delivered to MQ", sqs_id=sid, event_id=ev.get("id"))

    def step(self) -> int:
        resp = self.sqs.receive_message(
            QueueUrl=self.cfg.outbound_queue_url, MaxNumberOfMessages=10,
            WaitTimeSeconds=self.wait_seconds)
        msgs = resp.get("Messages") or []
        for m in msgs:
            self.handle(m)
        return len(msgs)

    def run(self) -> None:
        delay = 0.0
        while not self.stop.is_set():
            try:
                self.mq = self.mq_factory()
                self.mq.connect()
                delay = 0.0
                log(logger, logging.INFO, "connected to MQ", queue=self.cfg.mq_queue_from_eb)
                while not self.stop.is_set():
                    self.health()
                    self.step()
            except MQClientError as e:
                delay = next_delay(delay)
                log(logger, logging.ERROR, "MQ error, reconnecting",
                    error=str(e), reason=e.reason, retry_in=delay)
                self.stop.wait(delay)
            except Exception:
                delay = next_delay(delay)
                logger.exception("unexpected error, retrying")
                self.stop.wait(delay)
            finally:
                if self.mq is not None:
                    self.mq.close()
                    self.mq = None
