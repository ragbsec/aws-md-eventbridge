"""Thin wrapper over the official `ibmmq` package.

ibmmq (and the IBM MQ C client it binds to) is imported lazily so the rest of
the package and the unit tests work without the native libraries.

NOTE: an MQ connection/handle must not be shared between threads; each loop
creates its own MQClient.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

CCSID_UTF8 = 1208


class MQClientError(Exception):
    def __init__(self, msg: str, reason: Optional[int] = None):
        super().__init__(msg)
        self.reason = reason


@dataclass
class MQMessage:
    body: bytes
    msg_id_hex: str
    correl_id_hex: str
    backout_count: int = 0


class MQClient:
    def __init__(self, cfg, queue: str, mode: str):
        assert mode in ("get", "put")
        self.cfg, self.queue_name, self.mode = cfg, queue, mode
        self._mq = self._qmgr = self._queue = self._boq = None
        self.backout_threshold = 0
        self.backout_queue = ""

    def connect(self) -> None:
        try:
            import ibmmq as mq
        except ImportError as e:  # pragma: no cover
            raise MQClientError(f"ibmmq not importable: {e}") from e
        self._mq = mq
        c = self.cfg
        try:
            cd = mq.CD()
            cd.ChannelName = c.mq_channel.encode()
            cd.ConnectionName = f"{c.mq_host}({c.mq_port})".encode()
            cd.ChannelType = mq.CMQXC.MQCHT_CLNTCONN   # channel constants live in CMQXC, not CMQC
            cd.TransportType = mq.CMQXC.MQXPT_TCP
            self._qmgr = mq.QueueManager(None)
            # user/password become an MQCSP (MQCSP_AUTH_USER_ID_AND_PWD), which
            # satisfies CHCKCLNT(REQUIRED). (ibmmq's CSP fields are CSPUserId /
            # CSPPassword; the user=/password= kwargs are the documented path.)
            self._qmgr.connect_with_options(c.mq_qmgr, cd=cd, user=c.mq_user, password=c.mq_password)
            if self.mode == "get":
                self._queue = mq.Queue(self._qmgr, self.queue_name,
                                       mq.CMQC.MQOO_INPUT_SHARED | mq.CMQC.MQOO_INQUIRE)
                self._load_backout_settings()
            else:
                self._queue = mq.Queue(self._qmgr, self.queue_name, mq.CMQC.MQOO_OUTPUT)
        except mq.MQMIError as e:
            self.close()
            raise MQClientError(f"MQ connect failed: {e}", getattr(e, "reason", None)) from e

    def _load_backout_settings(self) -> None:
        mq = self._mq
        try:
            self.backout_threshold = int(self._queue.inquire(mq.CMQC.MQIA_BACKOUT_THRESHOLD))
            name = self._queue.inquire(mq.CMQC.MQCA_BACKOUT_REQ_Q_NAME)
            self.backout_queue = (name.decode() if isinstance(name, bytes) else name).strip()
        except mq.MQMIError:
            self.backout_threshold, self.backout_queue = 0, ""

    def get(self, wait_ms: int) -> Optional[MQMessage]:
        """Get one message under syncpoint; None if the wait expired."""
        mq = self._mq
        md = mq.MD()
        gmo = mq.GMO()
        gmo.Options = (mq.CMQC.MQGMO_WAIT | mq.CMQC.MQGMO_SYNCPOINT
                       | mq.CMQC.MQGMO_FAIL_IF_QUIESCING | mq.CMQC.MQGMO_CONVERT)
        gmo.WaitInterval = wait_ms
        try:
            body = self._queue.get(None, md, gmo)
        except mq.MQMIError as e:
            if e.reason == mq.CMQC.MQRC_NO_MSG_AVAILABLE:
                return None
            raise MQClientError(f"MQ get failed: {e}", e.reason) from e
        return MQMessage(
            body=body,
            msg_id_hex=md.MsgId.hex(),
            correl_id_hex=md.CorrelId.hex(),
            backout_count=int(getattr(md, "BackoutCount", 0) or 0),
        )

    def put_persistent(self, text: str) -> None:
        """Put a persistent CCSID 1208 text message under syncpoint (call commit())."""
        mq = self._mq
        md = mq.MD()
        md.Format = mq.CMQC.MQFMT_STRING
        md.CodedCharSetId = CCSID_UTF8
        md.Persistence = mq.CMQC.MQPER_PERSISTENT
        pmo = mq.PMO()
        pmo.Options = mq.CMQC.MQPMO_SYNCPOINT | mq.CMQC.MQPMO_FAIL_IF_QUIESCING
        try:
            self._queue.put(text.encode("utf-8"), md, pmo)
        except mq.MQMIError as e:
            raise MQClientError(f"MQ put failed: {e}", e.reason) from e

    def move_to_backout_queue(self, msg: MQMessage) -> None:
        """Re-put a poison message on the backout queue inside the current unit
        of work (the caller commits). Needed because plain MQI applications must
        honour BOTHRESH/BOQNAME themselves; the queue manager does not move it."""
        mq = self._mq
        try:
            if self._boq is None:
                self._boq = mq.Queue(self._qmgr, self.backout_queue, mq.CMQC.MQOO_OUTPUT)
            md = mq.MD()
            md.Persistence = mq.CMQC.MQPER_PERSISTENT
            md.CorrelId = bytes.fromhex(msg.msg_id_hex)
            pmo = mq.PMO()
            pmo.Options = mq.CMQC.MQPMO_SYNCPOINT
            self._boq.put(msg.body, md, pmo)
        except mq.MQMIError as e:
            raise MQClientError(f"MQ backout-queue put failed: {e}", e.reason) from e

    def commit(self) -> None:
        try:
            self._qmgr.commit()
        except self._mq.MQMIError as e:
            raise MQClientError(f"MQ commit failed: {e}", e.reason) from e

    def backout(self) -> None:
        try:
            self._qmgr.backout()
        except self._mq.MQMIError as e:
            raise MQClientError(f"MQ backout failed: {e}", e.reason) from e

    def close(self) -> None:
        for obj, meth in ((self._queue, "close"), (self._boq, "close"), (self._qmgr, "disconnect")):
            try:
                if obj is not None:
                    getattr(obj, meth)()
            except Exception:
                pass
        self._queue = self._boq = self._qmgr = None
