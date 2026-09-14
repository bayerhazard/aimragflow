# RAGFlow „Privat" — Parsing- & Embedding-Optimierung

Verifiziert am 2026-09-14 an einer Test-KB (`aimragflow-parse-test`, 10 repräsentative
Dokumente) plus Direkttests von Embedder und Reranker. RAGFlow `0.27.2`.

## Vorgehen
- Test-KB mit naive-Parser, `layout_recognize: DeepDOC`, `chunk_token_num 512`,
  `delimiter \n`, `overlapped_percent 0.1` — identisch zum Ist-Zustand der KB „Privat".
- Repräsentative Dateien: Scan (`Personalausweis`), gemischter Scan (`Impfpass`),
  Text-PDF (`Aethiopien`, `Renteninfo`, `Tag Heuer`), DOCX, XLSX, TXT (UTF-16),
  Legacy `.doc`, PNG.
- Prüfung per `POST /api/v1/retrieval` (mit/ohne Rerank) und Direktaufruf der
  AIM-Modelle.

## Ist-Zustand KB „Privat"
- 36 Dokumente, davon **nur 1 geparst** (`Tag Heuer Service 2025.pdf`, 6 Chunks);
  35 stehen auf `UNSTART`.
- `chunk_method: naive`, `layout_recognize: DeepDOC`, `chunk_token_num: 512`,
  `delimiter: "\n"`, `overlapped_percent: 0.1`, `language: English`, kein Image2Text
  (`img2txt_id: ""`).

## Was DeepDOC tatsächlich leistet (Testergebnis)
| Klasse | Beispiel | Ergebnis | Bewertung |
|---|---|---|---|
| Text-PDF | Äthiopien, Tag Heuer | sauber; Tabellen als HTML | gut, keine Pipeline |
| Scan (0 Textlayer) | Personalausweis | OCR gut genug für Retrieval (Name/Datum/Augenfarbe gefunden), aber OCR-Rauschen (»人人人«) | ok; für Fidelity VLM/OCR |
| Scan gemischt | Impfpass | 9 Chunks/3523 Token, **274 s** Parsezeit | ok, aber langsam |
| Textlayer defekt | Renteninformation | Wörter verschmolzen (»Abt.VersicherungundRente«) — **Quell-PDF**, nicht Parser | nur OCR/VLM besser |
| DOCX | Reifenwechsel Tesla | Text ohne Trenner (»TeslaLüftung…«) | brauchbar |
| XLSX | Rotwild Ausstattung | strukturiert (Original/Custom/Gewicht/Preis) | sehr gut |
| TXT (UTF-16) | Best of Friends | korrekt gelesen | gut |
| Legacy .doc | Italien Toskana | **erfolgreich** geparst | gut |
| Bild (PNG) | Weltreise Flightmap | nur OCR-Fragmente (Airport-Codes) | **Image2Text nötig** |

Retrieval-Gegenprobe: Die richtige Stelle wurde je Frage gefunden (Personalausweis
Augenfarbe/Geburtsdatum; Impfpass; Renten-Betrag; Flightmap-Codes). Translation der
Scans/Images in den Index ist also **gegeben**.

## Modell-Fakten (direkt gemessen)
| | Modell | Limit | Dim | Ort | Messwert |
|---|---|---|---|---|---|
| Embedder | Qwen3-Embedding-4B (`aimighty-embedding-4b`) | `MAX_LENGTH 8192` | 2560 | CPU, cluster (2×8 Threads) | 2 Texte → 0.33 s |
| Reranker | Qwen3-Reranker-0.6B | `max-model-len 8192`, `max-num-seqs 4` | — | GPU (vLLM) | `/v1/rerank` trennt 0.965 vs 0.646 |
| LLM | LiteLLM Analyst/Experte (Qwen3.8-27B) | 200k | — | GPU | — |

**Konsequenz:** Chunks ≤ ~1024 Token halten → weder Embedder noch Reranker
truncieren (beide 8192). Reranker-`max-num-seqs 4` → Kandidatenzahl moderat halten.

## Empfehlung (KB „Privat")

### Dataset-Ebene
- **`language: German`** (statt English) — Tokenizer/Stemmer und ggf. OCR-Sprache.
- Chunk-Methode: `naive` + `layout_recognize: DeepDOC` beibehalten.

### `parser_config`
```
chunk_token_num: 512          # bei kurzen Faktendokumenten ggf. 256–384
delimiter: "\n\n"             # Absätze statt jeder Zeile (Prosa), sonst \n lassen
overlapped_percent: 0.15
enable_children: false        # parent_child für dieses Korpus nicht nötig
layout_recognize: "DeepDOC"
table_context_size: 512       # Umgebungstext für Tabellen-Chunks
image_table_context_window: 512
auto_keywords: 0
auto_questions: 0
mineru_lang: German           # nur relevant, falls später MinerU/PaddleOCR genutzt
```

### Mandant/Modelle
- **Image2Text (VLM) konfigurieren** (lokales Vision-Modell: AIM Qwen3.8-27B bzw.
  Gemma 4 über LiteLLM) → Scans/Fotos/embedded images werden beschrieben statt nur
  OCR-Fragmente. Behebt v. a. das PNG (`Weltreise Flightmap`).
- **Reranker im Chat-Assistenten aktivieren** (Dropdown — RAGFlow speichert dann die
  TenantModel-UUID; die Retrieval-API akzeptiert nur die UUID, keinen Modellnamen).
  Kandidaten: `top_k` ~256 holen, ~30–50 reranken.
- Embedder unverändert (2560 dim, 8192). `EMBED_DIM` nicht reduzieren (kein Bedarf).

### Pipeline?
**Für v1 nein.** Der General-Parser (naive+DeepDOC) deckt alle vorkommenden Typen
ab — inkl. Scan-OCR, Tabellen→HTML, Legacy-.doc, XLSX, UTF-16-TXT, Bild-OCR.
Eine Ingestion-Pipeline ist nur gerechtfertigt, wenn:
1. Bilder/Scans per VLM semantisch beschrieben werden sollen (geht auch ohne
   Pipeline über Image2Text am Mandanten), **oder**
2. pro Dateityp unterschiedliche Parser/OCR-Modelle geroutet werden sollen, **oder**
3. Metadaten (Dokumenttyp, Datum, Person) automatisch extrahiert werden sollen,
   **oder**
4. das 247-Seiten-`Tesla Model 3 Handbuch` in Seitenbereichen/kontrolliert
   verarbeitet werden soll.

## Bekannte Problemfälle & Gegenmaßnahme
- `Renteninformation 2025.pdf`: defekter Textlayer (Quelle). Nur echtes OCR oder
  ein VLM rekonstruiert Leerzeichen → Image2Text/OCR-Pipeline.
- `Personalausweis`/`Reisepass`/`Führerschein`/`Impfpass`: DeepDOC-OCR ausreichend
  für Retrieval; bei Bedarf VLM-Transkription.
- `Weltreise Flightmap.png`: ohne VLM nur Airport-Codes → Image2Text.
- `Tesla Model 3 Handbuch.pdf` (11,7 MB/247 S.): Parsezeit und Chunkmenge hoch;
  ggf. per Page-Range aufteilen (Dataflow) oder bewusst roh lassen.

## Umgesetzt & gemessen (2026-09-14)

Chart `26.9.2`: ragflow CPU 10 → **20**, RAM 12 → **16 GiB**, Env
`TABLE_AUTO_ROTATE=false` (Default), `limitedCpu 24`. Delimiter-Bug (`'"\n\n"'`)
korrigiert. 13 narrative Text-PDFs auf `layout_recognize: Plain Text`
(Dokument-Level via PATCH); Formulare/Scans/Tabellen bleiben DeepDOC.

Messung während des Re-Ingests:

| Metrik | vorher | nachher |
|---|---|---|
| ragflow CPU | konstant 10,0 (=Limit) | bis 20,0 (=neues Limit), dann Einbrüche |
| Table analysis | 104–188 s/Seite | ~1 s (Tag Heuer Task: ~150 s → **33 s**) |
| Chunks / ~5 min | 86 | 256–341 |
| Fehler | 0 | 0 |

**Neuer Engpass: der CPU-Embedder** (`aimembqwen3vino`) — 12–15 Cores, während
ragflow zeitweise bei 0,16 Cores idle wartet (Backpressure durch Embedding).
CPU gesamt 17/48, RAM 75/187 GiB, GPU 11/48 GiB (weiter idle).

Restlich langsam (DeepDOC, komplexe Tabellen/Scans): `Bad Bikes Rotwild` 346 s,
`Fielmann` 367 s; OCR-Scans weiterhin teuer.

### iGPU-Test Embedder (2026-09-14) — negativ

`OV_DEVICE=GPU` (per `settings apps env set`):

```
Device: GPU
[WARNING] GPU compile failed, falling back to CPU:
  Cannot load library "…/libopenvino_intel_gpu_plugin.so":
  libOpenCL.so.1: cannot open shared object file
Model loaded and compiled on CPU (fallback) successfully.
```

Benchmark (idle, 8×batch16 = 128 Texte à ~250 Token):

| Setting | texts/s | ms/Text | 16er-Batch |
|---|---|---|---|
| CPU (Baseline) | **0,77** | 1306 | 20,9 s |
| `OV_DEVICE=GPU` (CPU-Fallback) | **0,77** | 1304 | 20,9 s |

Ursachen: (1) das Image bringt die Intel-OpenCL-/oneAPI-Runtime nicht mit,
(2) dem Pod fehlt `/dev/dri`. `OV_DEVICE` wieder auf **CPU** zurückgestellt.

Für echten iGPU-Betrieb nötig:
1. Embedder-Image neu bauen **mit** `intel-opencl-icd`/`libOpenCL.so.1` (+ Level-Zero/oneAPI).
2. `/dev/dri` in den Pod mounten (Chart) + ggf. Olares-Intel-Compute-Binding.
3. Danach neu benchmarken (Vergleichswerte oben).

Praktikablerer Hebel ohne iGPU: Embedder-Pod-CPU-Limit (derzeit **8 Cores/Pod**,
2 Replicas = 16) anheben + `INFERENCE_THREADS`/`NUM_STREAMS` erhöhen.

### Weitere Optimierungen
1. **Embedder auf Intel-iGPU** (`OV_DEVICE=GPU`, Olares One hat Arc-iGPU) oder
   mehr Threads/Replicas → entlastet CPU und beschleunigt Embedding.
2. `MAX_CONCURRENT_CHUNK_BUILDERS` 4 → 8–12 (nutzt die 20 Cores besser).
3. Restliche langsame Text-PDFs (Bad Bikes, Fielmann, HUK24, CosmosDirekt,
   neue leben) ebenfalls auf PlainText, wenn Tabellenstruktur entbehrlich ist.
4. Scans/Bilder per VLM/OCR-Parser auf die GPU verlagern.

## Embedder-Skalierung (Variant 1) & iGPU — Messung 2026-09-14

Referenz (idle): 8 Threads / 1 Stream / CPU-Limit 8 / cluster = **0,77 Texte/s**.

Getestet per Re-Deploy aus der lokalen Upload-Source (kein öffentlicher Release):

| Config | threads/s | ms/Text | Fazit |
|---|---|---|---|
| Baseline (Limit 8, thr 8, stream 1) | **0,77** | 1306 | Referenz |
| Limit 12, thr 12, **streams 2** | 0,43 | 2321 | viel schlechter |
| Limit 12, thr 12, streams 1 | 0,58 | 1734 | schlechter |
| Limit 12, **thr 8**, streams 1 | 0,76 | ~ | = Baseline |

**Ergebnis: Variante 1 bringt nichts.** Der Embedder ist bei 8 Threads/1 Stream
bereits optimal; mehr Threads (→ E-Core-Überbuchung) und mehr Streams schaden.
**Kein Release.** Produktions-Embedder auf 26.8.31 zurückgestellt.

**iGPU:** `OV_DEVICE=GPU` scheitert (`libOpenCL.so.1` fehlt) → CPU-Fallback, Benchmark
identisch. Ein Thin-Layer-Fix ist hier nicht möglich: der Docker-Daemon dieser
Sandbox kann keine RUN-Schritte bauen (overlayfs), und die Debian-bookworm-Basis
bringt keinen Arrow-Lake-tauglichen Intel-Treiber mit. Nötig wäre ein **neu
gebautes Basis-Image (Ubuntu 24.04 + Intel-Compute-Runtime)** plus Device-Plugin-
Request `gpu.intel.com/i915` (der `olares`-Node exponiert die iGPU) → Aufwand hoch,
Erfolg unsicher, Nutzen bei nur 4 Xe-Kernen begrenzt.

**Konsequenz:** Für Ingest-Speed ist der CPU-Embedder ausgereizt. Echter Sprung nur
über einen **GPU-Embedder (CUDA/vLLM auf der RTX 5090)** — neues App-Chart, ~2–4 GB
VRAM neben Reranker/TTS. Für den 36-Dokumente-Bestand nicht nötig.

## Nächste Schritte
1. KB „Privat": `language=German` + optimierte `parser_config` setzen.
2. VLM als Image2Text hinterlegen.
3. Alle 36 Dokumente neu parsen (Idle-Zeit einplanen: Scan ≈ 4–5 min/Dokument).
4. Chat-Assistenten: Thinking=Medium, Rerank = AIM Reranker, Top-N ~8–16.
5. Retrieval-Stichproben je Dokumentklasse; erst dann ggf. Pipeline ergänzen.
