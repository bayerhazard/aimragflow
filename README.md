# aimragflow

Custom Olares app for the AImighty market (`market.AImighty`): **RAGFlow 0.27.2**,
repackaged from the official Olares chart (`beclab/apps/ragflow` 1.0.30) with the
Olares/Hermes tuning baked in.

- App / K8s name: `aimragflow`
- Chart version: `26.9.1`, `spec.versionName: 0.27.2`
- Image: `ghcr.io/bayerhazard/aimragflow:v0.27.2-1`
- Category: `AI`

## What differs from the upstream Olares chart

| Area | Change |
|---|---|
| Upstream RAGFlow | `v0.26.4` → `v0.27.2` (Agentic RAG, Knowledge Compilation) |
| Image | thin derivative adding the `close_stale(age=3600)` patch |
| `MAX_CONCURRENT_CHUNK_BUILDERS` | `4` (env) |
| `DOC_BULK_SIZE` | `50` (env, respected by 0.27.2) |
| `EMBEDDING_BATCH_SIZE` | `16` (env, respected by 0.27.2) |
| ragflow resources | CPU `10` / RAM `12Gi` |
| Infinity companion | removed (`DOC_ENGINE=elasticsearch`) |
| MySQL middleware DB | `aimragflow` (own DB/user, no clash with `ragflow`) |

Elasticsearch stays at **8.11.3** because RAGFlow 0.27.2 pins
`elasticsearch-dsl==8.12.0`; the v8 client cannot serve ES 9.x.

## Layout

```
Dockerfile            derived image (close_stale patch)
build-image.sh        reproducible image build (crane append)
patches/              (reserved)
OlaresManifest.yaml   root manifest (identical to the chart's)
aimragflow/           Helm chart
releases/             packaged chart (helm package)
RUNBOOK.md            post-install + Hermes wiring
```

## Build

Image (this host's Docker cannot extract the upstream image; use crane):

```bash
export PATH=$PATH:~/go/bin
./build-image.sh                 # -> ghcr.io/bayerhazard/aimragflow:v0.27.2-1
# keep the package PUBLIC (private packages break Olares install)
```

Chart:

```bash
helm lint aimragflow
helm package aimragflow -d releases
```

Market publish: add the `_apps.ts` entry and the base64 of
`releases/aimragflow-26.9.1.tgz` to `_lib.ts` in `bayerhazard/aimighty-market`,
commit, then deploy with wrangler. See `RUNBOOK.md` for install and Hermes wiring.
