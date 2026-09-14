#!/usr/bin/env bash
# Reproducible build of the aimragflow derived image.
#
# This environment's Docker daemon uses the `overlayfs` driver and cannot
# extract the upstream RAGFlow image (opaque whiteout error), so instead of a
# docker buildx build we assemble the image with `crane append`: one extra
# layer that shadows api/db/db_models.py with the patched copy.
#
# Requires: crane, ghcr.io credentials (docker login ghcr.io).
#
# Usage: ./build-image.sh [UPSTREAM_TAG] [TARGET_TAG]
set -euo pipefail

UPSTREAM_TAG="${1:-v0.27.2}"
TARGET_TAG="${2:-ghcr.io/bayerhazard/aimragflow:v0.27.2-1}"
BASE="docker.io/infiniflow/ragflow:${UPSTREAM_TAG}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo ">> fetching api/db/db_models.py from infiniflow/ragflow@${UPSTREAM_TAG}"
mkdir -p "$workdir/root/ragflow/api/db"
curl -fsSL "https://raw.githubusercontent.com/infiniflow/ragflow/${UPSTREAM_TAG}/api/db/db_models.py" \
  -o "$workdir/root/ragflow/api/db/db_models.py"

f="$workdir/root/ragflow/api/db/db_models.py"
grep -q 'close_stale(age=30)' "$f" || { echo "ERROR: expected pattern not found"; exit 1; }
sed -i 's/close_stale(age=30)/close_stale(age=3600)/' "$f"
grep -q 'close_stale(age=3600)' "$f"

tar -C "$workdir/root" -cf "$workdir/layer.tar" ragflow/api/db/db_models.py

echo ">> crane append -> ${TARGET_TAG}"
crane append --platform linux/amd64 -b "$BASE" -f "$workdir/layer.tar" -t "$TARGET_TAG"
echo ">> done: ${TARGET_TAG}"
