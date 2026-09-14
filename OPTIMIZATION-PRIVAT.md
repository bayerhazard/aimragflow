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

## Nächste Schritte
1. KB „Privat": `language=German` + optimierte `parser_config` setzen.
2. VLM als Image2Text hinterlegen.
3. Alle 36 Dokumente neu parsen (Idle-Zeit einplanen: Scan ≈ 4–5 min/Dokument).
4. Chat-Assistenten: Thinking=Medium, Rerank = AIM Reranker, Top-N ~8–16.
5. Retrieval-Stichproben je Dokumentklasse; erst dann ggf. Pipeline ergänzen.
