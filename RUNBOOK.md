# AIM RAGFlow — Post-Install & Hermes Runbook

App: **aimragflow** · chart `26.9.1` · upstream RAGFlow `0.27.2`
Default entrance: `https://0112315c.<user>.olares.de` (appID `0112315c`)
Custom route: `https://kb.<user>.olares.de` (third-level `kb`, set after install)
Namespace: `aimragflow-aimighty`
Image: `ghcr.io/bayerhazard/aimragflow:v0.27.2-1` (must stay **public** in ghcr)

Deployed state (2026-09-14): app `running`; pods aimragflow/es/minio/redis Running;
MySQL middleware DB `aimragflow-aimighty_aimragflow` (separate from the old
`ragflow` app); ES 8.11.3 healthy; `/api/v1/system/healthz` = 200.

After `olares-cli market install aimragflow -s market.AImighty --watch`, work through
this list top to bottom.

---

## 0. Verify the app came up

```bash
kubectl -n aimragflow-aimighty get pods
# expect: aimragflow, elasticsearch, minio, redis all Running
olares-cli settings apps domain set aimragflow aimragflow --third-level kb
# -> https://kb.<user>.olares.de  (UI)
```

Check the pod image is the patched build and env is correct:

```bash
kubectl -n aimragflow-aimighty get deploy aimragflow \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n aimragflow-aimighty exec deploy/aimragflow -- \
  sh -c 'grep -n "close_stale(age=" /ragflow/api/db/db_models.py'
# expect: 1050: DB.close_stale(age=3600)
```

## 1. Get a RAGFlow API key

UI → **Settings → API** (or the user avatar → API) → create a key. Store it as
`RAGFLOW_API_KEY`. All API calls below use `Authorization: Bearer $RAGFLOW_API_KEY`.

Quick smoke test:

```bash
curl -s "https://kb.<user>.olares.de/api/v1/datasets" \
  -H "Authorization: Bearer $RAGFLOW_API_KEY" | head -c 400
```

## 2. Wire the local AIM models into RAGFlow

RAGFlow must be told which LLM / embedding / rerank to use. Point them at the
already-installed AIM apps (all OpenAI-compatible):

| Role | Endpoint | Model |
|---|---|---|
| Chat LLM (Agentic RAG brain) | `https://llm.aimighty.olares.de/v1` (LiteLLM) | `Analyst` (fallback `Experte`) |
| Embedding | `https://<aimembqwen3vino-appid>.aimighty.olares.de/v1` | `aimighty-embedding-4b` |
| Rerank | `https://<aimrerqwen3vllm-appid>.aimighty.olares.de/v1` | reranker model id from `/v1/models` |

UI → **Settings → Model providers → Add** an *OpenAI-API-Compatible* provider for
each. Use the API key of the respective app (LiteLLM key for `llm.*`).

> RAGFlow sends many calls in Agentic RAG modes. Keep the LLM at
> `reasoning_effort: medium` (LiteLLM already does) and use **Medium** thinking.

Then set the tenant defaults: **Settings → Model** → *Chat model* = `Analyst`,
*Embedding model* = `aimighty-embedding-4b`, *Rerank model* = the local reranker.

## 3. Create the knowledge base and ingest

1. **Knowledge Base → Create**. Recommended chunking (AGENTS.md tuning):
   - Method: *General* (naive), `chunk_token_num = 256`, `delimiter = \n\n`
     (literal newline, no backticks), **parent-child OFF**, RAPTOR off.
2. Upload files. Parsing uses DeepDoc. Ingestion limits are already raised
   (`MAX_CONCURRENT_CHUNK_BUILDERS=4`, `DOC_BULK_SIZE=50`, `EMBEDDING_BATCH_SIZE=16`).
3. Optional quality: enable **Knowledge Compilation** (Graph / Tree / Wiki /
   PageIndex) per dataset. This replaces the deprecated GraphRAG/RAPTOR and feeds
   Agentic RAG more evidence.

## 4. Create the Chat assistant (this is what Hermes calls)

UI → **Chat → Create**:

- Datasets: the KB(s) from step 3.
- Model: `Analyst`.
- **Thinking: Medium** (Sweetspot). High/Ultra only for hard multi-hop questions
  (several LLM round-trips; on one RTX 5090 High/Ultra can take minutes).
- Retrieval: **Rerank ON**, Top N ~8-16, similarity per taste; Citations ON.
- Retrieval augmentation: Keyword analysis ON, Multi-turn optimization ON,
  Cross-language ON if documents are not English.
- System prompt: keep the `{knowledge}` placeholder; instruct to answer only from
  the knowledge base and to say when evidence is missing.

Note the `chat_id` from the URL (`.../chat/<chat_id>`).

Test the OpenAI-compatible endpoint:

```bash
curl -s "https://kb.<user>.olares.de/api/v1/chats_openai/<chat_id>/chat/completions" \
  -H "Authorization: Bearer $RAGFLOW_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"model","messages":[{"role":"user","content":"<question>"}],"stream":false}'
```

## 5. Wire Hermes Agent

Hermes config: `~/.hermes/config.yaml` inside the `hermesagent` pod
(`drive/Data/hermesagent/home/config.yaml` from the Files view).

**Option A — RAGFlow as an OpenAI-compatible custom provider (fastest to set up).**
Add under `custom_providers:` (mirror the existing `Analyst` entry):

```yaml
custom_providers:
  - name: RagflowKB
    base_url: https://kb.<user>.olares.de/api/v1/chats_openai/<chat_id>
    key_env: RAGFLOW_API_KEY
    model: ragflow
    models:
      ragflow:
        context_length: 32000
```

Set `RAGFLOW_API_KEY` in the pod env (or `.env`). Then `RagflowKB` is selectable
as a model — use it for knowledge sessions.

**Option B — a tool so Hermes keeps its own loop/tools (recommended long-term).**
Add a small Hermes plugin under `~/.hermes/plugins/ragflow/` that POSTs to the
chat endpoint and returns answer + citations. Verify the plugin contract in
`~/.hermes/plugins/` and `known_plugin_toolsets` before shipping.

**Option C — MCP `retrieve` for chunk-level access.**
Run the RAGFlow MCP server (separate process) and register it under
`mcp_servers:` alongside `cua-driver`. Note: MCP exposes only the raw `retrieve`
tool — **no Agentic RAG**, so it is a complement, not a replacement for A/B.

## 6. Remove the 300s route cap (required for High/Ultra)

Olares `l4-bfl-proxy` defaults to a 5-minute route timeout and will cut long
Agentic RAG answers. Apply the live patch (re-apply after os-framework updates):

```bash
kubectl patch -n os-network deploy l4-bfl-proxy --type=json -p='[
 {"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"-xds-route-timeout"},
 {"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"0s"}]'
```

Hermes already has `agent.gateway_timeout: 1800`; leave it.

## 7. End-to-end verification

- UI answers a KB question with citations.
- `chats_openai` curl returns an answer (step 4).
- Hermes (Option A/B) answers the same question and cites the same sources.
- Pod `aimragflow` image = `ghcr.io/bayerhazard/aimragflow:v0.27.2-1`.

---

## Decommissioning the old market.olares RAGFlow

Only after aimragflow is verified:

```bash
olares-cli market uninstall ragflow --watch
```

Existing data in the old app is **not** migrated (separate appData/appCache paths,
separate MySQL DB). Export/re-ingest first if needed.
