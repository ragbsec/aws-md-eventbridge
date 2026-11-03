# syntax=docker/dockerfile:1
#
# IBM MQ <-> EventBridge bridge image.
#
# The IBM MQ C client comes from IBM's public "Redistributable Clients" directory:
# https://public.dhe.ibm.com/ibmdl/export/pub/software/websphere/messaging/mqdev/redist/
# (file <version>-IBM-MQC-Redist-LinuxX64.tar.gz). The default version below matches
# the server image (icr.io/ibm-messaging/mq:10.0.0.5-r2) and was confirmed to exist in
# that directory listing; an older default (9.4.2.0) returned HTTP 404 there.
# Override with:  docker build --build-arg MQ_CLIENT_VERSION=<x.y.z.w> .
# Review IBM's licence terms for the redistributable client before use.

ARG PYTHON_IMAGE=python:3.12-slim

# ---- stage 1: fetch the IBM MQ C client -----------------------------------
FROM ${PYTHON_IMAGE} AS mqclient
ARG MQ_CLIENT_VERSION=10.0.0.5
ARG MQ_CLIENT_URL=https://public.dhe.ibm.com/ibmdl/export/pub/software/websphere/messaging/mqdev/redist/${MQ_CLIENT_VERSION}-IBM-MQC-Redist-LinuxX64.tar.gz
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/mqm \
    && curl -fsSL "${MQ_CLIENT_URL}" -o /tmp/mqc.tar.gz \
    && tar -xzf /tmp/mqc.tar.gz -C /opt/mqm \
    && rm /tmp/mqc.tar.gz

# ---- stage 2: build python deps (ibmmq compiles against /opt/mqm) ----------
FROM ${PYTHON_IMAGE} AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
COPY --from=mqclient /opt/mqm /opt/mqm
ENV MQ_FILE_PATH=/opt/mqm
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# ---- stage 3: runtime -------------------------------------------------------
FROM ${PYTHON_IMAGE}
COPY --from=mqclient /opt/mqm /opt/mqm
COPY --from=build /opt/venv /opt/venv
ENV LD_LIBRARY_PATH=/opt/mqm/lib64:/opt/mqm/lib \
    PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app/src \
    PYTHONUNBUFFERED=1 \
    HEALTH_FILE=/tmp/healthy
# The IBM MQ client needs a WRITABLE HOME for its working files. Without one the client
# fails every connection with MQRC 2009 (AMQ6235E: Directory '/home/bridge' missing).
# (Found on EC2: the old --no-create-home user could not connect to MQ.)
RUN useradd --system --uid 10001 --create-home --home-dir /home/bridge bridge
WORKDIR /app
COPY src/ /app/src/
USER 10001
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "import os,sys,time; sys.exit(0 if time.time()-os.path.getmtime('/tmp/healthy')<120 else 1)"
ENTRYPOINT ["python", "-m", "bridge.main"]
