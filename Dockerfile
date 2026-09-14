# AIM RAGFlow — thin derivative of upstream RAGFlow 0.27.2
#
# Goal: bake only the Olares runtime tuning that upstream hardcodes, so the
# chart stays a pure configuration layer.
#
#   api/db/db_models.py : close_stale(age=30) -> close_stale(age=3600)
#     Olares' healthz thread drops idle MySQL pool connections; the 30s
#     reaper causes pymysql InterfaceError(0, '') log spam. 1h is harmless.
#
# The remaining AGENTS.md tunings are environment-driven in 0.27.2 and need
# no code change (set in the chart):
#   MAX_CONCURRENT_CHUNK_BUILDERS=4
#   DOC_BULK_SIZE=50               (common/settings.py: os.environ)
#   EMBEDDING_BATCH_SIZE=16        (common/settings.py: os.environ; already default)
#
# Build (amd64 only; Olares supportArch: amd64):
#   docker buildx build --platform linux/amd64 \
#     -t ghcr.io/bayerhazard/aimragflow:v0.27.2-1 --push .

FROM docker.io/infiniflow/ragflow:v0.27.2

RUN set -eux; \
    f=/ragflow/api/db/db_models.py; \
    test -f "$f"; \
    grep -q 'close_stale(age=30)' "$f"; \
    sed -i 's/close_stale(age=30)/close_stale(age=3600)/' "$f"; \
    grep -q 'close_stale(age=3600)' "$f"
