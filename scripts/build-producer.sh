#!/usr/bin/env bash
###############################################################################
# build-producer.sh — stage the producer Lambda package WITH awscrt.
#
# PutEvents with an EndpointId (EventBridge global endpoint) signs with SigV4a,
# which botocore only does when the AWS Common Runtime (awscrt) is present. The
# Lambda runtime's bundled botocore lacks it, so we vendor a manylinux x86_64
# awscrt wheel into the package. pip fetches the PREBUILT wheel for the Lambda
# platform (no compile, no Docker) via --platform/--only-binary.
#
# Args: $1 = producer source dir (contains handler.py [+ requirements.txt])
#       $2 = output staging dir (zipped by Terraform's archive_file)
###############################################################################
set -Eeuo pipefail

SRC="${1:?producer source dir required}"
OUT="${2:?output staging dir required}"

PY_VERSION="3.12"
PLATFORM="manylinux2014_x86_64"

rm -rf "$OUT"
mkdir -p "$OUT"

# Application code.
cp "$SRC"/*.py "$OUT"/

# Vendored, platform-correct dependencies (awscrt for SigV4a).
if [[ -f "$SRC/requirements.txt" ]]; then
  python3 -m pip install \
    --no-deps --only-binary=:all: \
    --platform "$PLATFORM" --python-version "$PY_VERSION" \
    --implementation cp --abi abi3 \
    --target "$OUT" \
    -r "$SRC/requirements.txt" >&2
fi

echo "$OUT"
