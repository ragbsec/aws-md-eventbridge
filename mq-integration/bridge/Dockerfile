# syntax=docker/dockerfile:1
#
# IBM MQ <-> EventBridge bridge image.
#
# UNVERIFIED: the author had no network access to IBM when writing this file,
# so the redistributable-client tarball URL pattern and default version below
# are from memory. CONFIRM both against IBM's current download page
# ("IBM MQ Redistributable Clients", file IBM-MQC-Redist-LinuxX64.tar.gz,
# https://public.dhe.ibm.com/ibmdl/export/pub/software/websphere/messaging/mqdev/redist/)
# and override with:  docker build --build-arg MQ_CLIENT_VERSION=<x.y.z.w> .
# Review IBM's licence terms for the redistributable client before use.

ARG PYTHON_IMAGE=python:3.12-slim

# ---- stage 1: fetch the IBM MQ C client -----------------------------------
FROM ${PYTHON_IMAGE} AS mqclient
ARG MQ_CLIENT_VERSION=9.4.2.0
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
RUN useradd --system --uid 10001 --no-create-home bridge
WORKDIR /app
COPY src/ /app/src/
USER 10001
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "import os,sys,time; sys.exit(0 if time.time()-os.path.getmtime('/tmp/healthy')<120 else 1)"
ENTRYPOINT ["python", "-m", "bridge.main"]
