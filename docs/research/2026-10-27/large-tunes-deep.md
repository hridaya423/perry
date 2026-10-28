# Large tunes, deep pass: is anything better than plain Qwen3.8-27B for Perry?

Date: 2026-10-27. Author: research sub-agent. Status: final. Research only. I downloaded no weights, built nothing, and ran no model. Every speed here comes from a cited source. Scratch files lived in /tmp, not in the repo.

This extends `local-model-lineup.md` ("lineup") and `finetunes-and-cua.md` ("tunes") from today and `r8-local-models-best.md` ("r8") from 2026-10-25. I do not repeat their tables. Where they already cover a model I give a pointer and add what is new.

Licence rule applied: Perry is free and non-commercial, so CC BY-NC and research-only licences are allowed. I excluded only weights with no licence and terms that bar this use. Holo4-27B, Hemmingway and Frontis are back in and judged on merit.

## Summary (15 lines)

1. Owner question: "nothing better really?" Answer: correct. I found no model, tune, merge or compression of Qwen3.8-27B with independent evidence that it beats plain Qwen3.8-27B on screen actions, tool calls or short answers. Every claim of a win is VENDOR.
2. Independent evidence is thin. Artificial Analysis (AA) has no row for Ornith, Occamy, Holo, Flint, Bonsai, Mirai, UI-Mate, Hemmingway, Frontis or any tune (VERIFIED, I parsed 286 AA records on 2026-10-27). The best independent rows in range are all below Qwen3.8-27B (section 2).
3. Why the tunes tie or lose: they were tuned from older bases (Qwen3.5, Qwen3.6) and compared with those bases. Qwen3.8-27B is a newer base. On the vendors' own charts, Ornith-1.5-35B-A3B scores 67.8 on Terminal-Bench 2.1 (VENDOR) and Qwen3.8-27B scores 73.0 (VENDOR, from the Nanbeige card). AA's own run gives Qwen3.8-27B 79.7 at xhigh, 65.1 at medium, 49.0 with thinking off (INDEPENDENT).
4. Mirai is Mirai Inc (trymirai), a 2.4-bit codec. Its Qwen3.8-27B "S" build is 8.45 GB and runs on Mirai's own Apple runtime "uzu", not llama.cpp or Splash. It is a compression of the base, so it cannot beat the base. Vendor speed on a base M4 is about 4 tok/s decode and 13 tok/s prefill. Not a candidate for an M4 Pro.
5. Ternary Bonsai 2 27B is also a compression of Qwen3.8-27B (5.95 or 7.21 GB). One small independent test (RTX 3090, 47 items) found it tied the Q4 base on tool choice (28/47 each) and lost overall (12/47 against 19/47). Same direction as the vendor's own 98.2% retention claim: smaller, not better.
6. Flint is Recursive's 39.8B-A2.5B coding MoE, released 2026-10-21, Apache-2.0, text only. Splash 1.4.1 supports it. It decides by itself when to reason, and Splash says settings cannot force reasoning on or off. That clashes with Perry's no-thinking interactive lane. Vendor scores only. Weak fit.
7. Ornith-1.5 exists in four sizes on Hugging Face: 9B, 35B-A3B, 122B, 397B (VERIFIED, 39 repos listed). I found no 4B and no 27B. The lineup mentions a 4B; I could not find it. The only independent tests are tiny: a RTX 5090 run where Ornith 35B-A3B, Ornith 9B and Qwen3.8-27B all scored 18/18 on a tool-use test, and a community tool-eval-bench run of 91/100 with no Qwen comparison.
8. New non-Qwen name worth testing: Nanbeige4.3-33B (Apache-2.0, 2026-10-24, text only). On its card it ties or beats Qwen3.8-27B in the same harness: Tau3-Bench 48.8 against 48.5, Terminal-Bench 2.1 80.9 against 73.0, Automation Bench 54.2 against 38.3 (all VENDOR). No third party has tested it yet.
9. Non-Qwen families in range do not beat Qwen on AA: Gemma 4 31B 14.7, Muse Glimmer 17.5, Granite 4.2 30B 12.7, Mistral Small 4 (119B) 11.3, K2 Horizon MoVA 36B-A4B 25.3 (text only), Nemotron 3.5 Bolt 74B-A9B 21.4 (all INDEPENDENT). Qwen3.8-27B is 20.2 with thinking off, 26.2 low, 27.6 medium, 33.7 xhigh.
10. For GUI work the only same-base tune with a plausible edge is Holo4-27B (CC BY-NC 4.0, now allowed): OSWorld-Verified 85.2 against 84.3 and OSWorld 2.0 61.7 against 48.0 (VENDOR, H Company's harness, no replication). It shares the base's speed and file format.
11. UI-Mate-27B (OSWorld-Verified 77.0, VENDOR) was tuned from Qwen3.6-27B and sits 7.3 points under the Qwen3.8-27B base claim. Hemmingway-1 and 1.5 are text-only writing tunes. Frontis-MA1-35B is an ML-research agent. None targets Perry's jobs.
12. Above 40 GB, on 96 to 128 GB Macs: Qwen3.8-Flash-Next (AA 39.8, Q2_0 about 66 GB), Ornith-1.5-122B (UD-Q4_K_XL about 80 GB, Splash supports it, no independent score) and Nemotron 3.5 Super VL 120B (AA 26.5, GGUF exists). None replaces the 27B for latency.
13. Walk of the Hugging Face trees: Qwen3.8-27B has 744 finetunes, 27 merges, 271 adapters; Qwen3.6-35B-A3B has 404, 39, 358 (VERIFIED, API, 2026-10-27). I sorted by downloads, likes and date and read the cards of about 45 candidates. The popular ones are classifiers, draft models, abliterations and token-saving tunes, not better brains.
14. Ranked shortlist for the 48 GB M4 Pro (21 GB free disk, so one model file at a time): 1) Holo4-27B, 17.8 GB. 2) Ornith-1.5-35B-A3B in the IQ4_XS build, 20.2 GB. 3) Nanbeige4.3-33B IQ4_XS, 18.6 GB. 4) Occamy-1.0 IQ4_XS, 19.6 GB. Tests in section 6.
15. Plain advice: keep plain Qwen3.8-27B as the deep lane. Treat Holo4-27B as the only real chance of a win, on screen actions. Treat Ornith as a speed play (27B quality at about 3B-active speed), not a quality play. Everything else needs a local test before anyone believes it.

---

## 0. Method, labels and limits

- **VERIFIED** (facts): file size, date, licence, base, download count, file list. Read from the Hugging Face API on 2026-10-27. Download counts are Hugging Face's rolling count and measure popularity only.
- **INDEPENDENT** (scores): a party that did not train the model ran the test and states the method. I use three kinds. AA (own harness on its own page). Small community runs with a method I could read. Public tools run by a third party.
- **VENDOR** (scores): the author, or a site that copies the author. Nobody checked it. BenchLM, MindStudio, OrcaRouter and similar sites copy vendor tables, so I count them as VENDOR.
- **UNVERIFIED**: second hand, or my arithmetic.
- How I walked the trees: `GET /api/models?filter=base_model:{finetune|merge|adapter}:{base}&sort=downloads` with pagination, for Qwen/Qwen3.8-27B and Qwen/Qwen3.6-35B-A3B. Then re-sorted by likes and by createdAt. I removed names with abliterat, uncensor, heretic, huihui, jailbreak, quant and format words before ranking (reason in lineup §1.3). A repo that sets no `base_model` tag is invisible to this walk. Ornith is one: its `base_model` is null. I found it by name search.
- AA: I downloaded the leaderboard page and parsed its embedded data (286 model records). Two content-farm pages quote an AA score of 52 for Qwen3.8-27B. The AA data I parsed says 33.7 at xhigh. I trust my parse of AA's own page and ignore the 52.
- Limits: I cannot see private evals. I could not read LMArena or the OSWorld board (JavaScript pages). The BFCL page I found was last updated 2025-12-16 and has no 2026 Qwen3.8 or tune rows.

---

## 1. The direct answer

**Is anything better than plain Qwen3.8-27B for Perry's three jobs?**

| Job | Better than plain Qwen3.8-27B? | Evidence |
|---|---|---|
| Screen actions | Maybe: Holo4-27B. No proof. | Holo4-27B vendor OSWorld-Verified 85.2 against 84.3 (VENDOR, +0.9, inside noise). OSWorld 2.0: 61.7 against 48.0 (VENDOR, H Company's harness). The official OSWorld 2.0 board lists no Holo4 row, and its best open result is 4.6% (r8 Appendix D). No independent score. |
| Tool calls and JSON | No. | No tune has an AA row. Independent mini tests tie (Ornith 18/18 against Qwen3.8-27B 18/18 on 18 runs, KGP Talkie). Nanbeige's vendor table ties on Tau3-Bench (48.8 against 48.5). |
| Short chat answers | No evidence either way. | Hemmingway-1 claims the best "everyday message" writing (VENDOR, LLM-judged, 80 requests) but is text only and untested on JSON. |

What is better is **speed at equal-ish quality**, and only in the MoE class:

- Ornith-1.5-35B-A3B decoded at 273.2 tok/s against 77.2 tok/s for Qwen3.8-27B on one RTX 5090, both at Q4_K_M (INDEPENDENT, one author, method in section 3.2). That is a dense-against-MoE effect, not proof of better answers.
- On the one small independent quality test I found, they tied.

**Why the tunes "tie or lose":**

1. The base moved. Ornith, Occamy and UI-Mate were tuned from Qwen3.5 or 3.6 and compared with those bases. Their cards do not compare with Qwen3.8-27B.
2. When another vendor puts them on a shared chart, Qwen3.8-27B wins or ties. Terminal-Bench 2.1 (Terminus 2): Ornith-1.5-35B-A3B 67.8 (Ornith card) against Qwen3.8-27B 73.0 (Nanbeige and Flint charts). All VENDOR.
3. Compressions (Bonsai, Mirai, ISTA, ByteShape, Saluki) cannot beat the model they compress. They trade quality for size. That is useful for a 24 GB Mac, not for a 48 GB Mac.

**The 20.2 point that matters for the interactive lane:** Perry runs thinking off in the interactive lane. AA's number for Qwen3.8-27B in that mode is 20.2, with Tau3-Banking 20.0%, Terminal-Bench 2.1 49.0%, AutomationBench 12.4% (INDEPENDENT). Almost every rival score in this report was measured with reasoning on, so it is not like for like. A tune that helps the no-thinking mode is the only kind that would help the interactive lane. No one has published that.

---

## 2. Independent evidence ledger

### 2.1 Artificial Analysis rows (INDEPENDENT, VERIFIED parse of the AA page, 2026-10-27)

"e" means AA estimated the index. Tau3B is Tau3-Banking. TB is Terminal-Bench 2.1. AutoB is AutomationBench. All in percent except the index.

| Model (AA row) | Open | Index | Tau3B | TB | AutoB | MMMU-Pro |
|---|---|---|---|---|---|---|
| Qwen3.8-Flash-Next | yes | 39.8 | 45.3 | 86.1 | 55.9 | 79.7 |
| Qwen3.8-27B xhigh | yes | 33.7 | 48.0 | 79.7 | 48.2 | 76.3 |
| Qwen3.8-27B medium | yes | 27.6 | 47.4 | 65.1 | 40.2 | 74.1 |
| Qwen3.8-27B low | yes | 26.2 | 32.1 | 67.4 | 30.1 | 73.7 |
| Qwen3.8-27B thinking off | yes | 20.2 | 20.0 | 49.0 | 12.4 | 69.9 |
| Nemotron 3.5 Super VL 120B-A12B | yes | 26.5 | not shown | not shown | 14.8 | not shown |
| Inkling Small (266B) | yes | 25.7 | 18.7 | 55.0 | 4.8 | 74.0 |
| K2 Horizon MoVA 36B-A4B (text only) | yes | 25.3 | 31.9 | 56.5 | 26.1 | not shown |
| Ling-3.0-flash-VL (125B) | yes | 24.6 | 34.4 | 64.4 | 15.6 | 78.9 |
| Nemotron 3.5 Bolt 74B-A9B | yes | 21.4 | not shown | not shown | 15.4 | not shown |
| K2 Horizon 7B (text only) | yes | 20.6 | 27.6 | 44.1 | 20.9 | not shown |
| Qwen3.6-35B-A3B reasoning | yes | 18.2 | 9.2 | 44.9 | 5.2 | 75.0 |
| Muse Glimmer 30B High | yes | 17.5 | 23.5 | 51.6 | 6.8 | 74.3 |
| Gemma 4 26B-A4B reasoning | yes | 16.7e | 11.9 | 38.9 | 1.9 | 69.2 |
| Qwen3.6-35B-A3B thinking off | yes | 15.2e | 5.3 | 41.5 | not shown | 71.0 |
| Gemma 4 31B reasoning | yes | 14.7 | 14.8 | 43.4 | 4.9 | 73.4 |
| Granite 4.2 30B | yes | 12.7 | 14.4 | 26.5 | 1.5 | not shown |
| Mistral Small 4 (119B) reasoning | yes | 11.3 | 4.9 | 20.9 | 0.9 | 56.8 |
| Nemotron 3 Nano 30B-A3B reasoning | yes | 8.9 | 5.9 | 6.7 | 0.9 | not shown |
| Magistral Small 1.2 | yes | 8.6e | 4.5 | 4.4 | 0.1 | 55.4 |
| Kimi Linear 48B-A3B | yes | 7.3e | not shown | not shown | not shown | not shown |

Rows I looked for and did not find: Ornith (any), Flint, Occamy, Holo (any), Bonsai, Mirai, UI-Mate, Hemmingway, Frontis, Nanbeige, GLM-4.7-Flash, Seed-OSS-36B, Devstral Small 2. GLM-4.7-Flash and Seed-OSS-36B are old (2025 and January 2026) and AA no longer lists them in the current data I parsed.

What the table says:

- Nothing in range beats Qwen3.8-27B at any effort level. The closest outside the Qwen family is K2 Horizon MoVA 36B-A4B (25.3), which is text only and sits under Qwen3.8-27B at low effort (26.2).
- On Tau3-Banking only Qwen3.8-27B at medium (47.4) and xhigh (48.0), and the 125B Flash-Next (45.3), reach the mid-40s. Nothing else in range is above 35.
- Qwen3.6-35B-A3B is weak on long tool tasks (Tau3-Banking 9.2) and that is the exact gap Occamy and Ornith say they close. Neither has been measured by AA.
- Thinking matters most. Qwen3.8-27B goes from 20.2 (off) to 27.6 (medium). A tune that cuts thinking tokens without losing score (Swift, Qwopus Flash) is aimed at the right problem for the deep lane.

### 2.2 Small independent tests I found (INDEPENDENT, small, method read)

| Test | Who, method | Result | Worth |
|---|---|---|---|
| Ornith against Qwen3.8-27B, speed, retrieval, reasoning, tool use | KGP Talkie. One RTX 5090 32 GB, Windows 11, llama-server b10448, Q4_K_M, f16 KV. Pure-Python grading, no LLM judge. Tool use: 10 tasks, 2 seeds, one dropped, 18 scored runs per model. Reasoning: 12 problems. | Tool use: Ornith 35B-A3B 18/18, Ornith 9B 18/18, Qwen3.8-27B 18/18, Gemma 4-26B-A4B 17/18. Hard reasoning (8 runs): 8/8, 8/8, 7/8, 8/8. Decode: 273.2, 192.7, 77.2, 232.4 tok/s. Author says the tasks are easier than the card's and that vision was not tested. | Shows a tie on easy tasks. Cannot separate the models. |
| Ornith-1.5-35B-A3B tool calling | Community post on the NVIDIA forum. tool-eval-bench v2.5.1, 69 scenarios, temperature 0, BF16, vLLM, DGX Spark, thinking on. | 91/100. Weak spots: autonomous planning 67%, instruction following 80%, context and state 80%. One safety flag (wrong unit). No Qwen run. | Single run. Gives a number Perry can reproduce with the same public tool. |
| Bonsai 2 27B against Qwen3.8-27B UD-Q4_K_XL | InsiderLLM. RTX 3090, PrismML llama.cpp fork. 47-item intent split with three fields (tool, mode, scope), exact match on all three. | Overall 12/47 against 19/47. Tool field 28/47 each. Mode 27 against 24. Scope 18 against 28. Valid JSON 47/47 both. Decode 77.6 against 42.1 tok/s. VRAM 8.1 GB against 17.7 GB. | Small, but it shows the cost of the 2-bit squeeze on conversation scope. |
| Flint on Macs | LLMCheck page collecting community runs. | llama.cpp b11804 Q4_1: 79.6 tok/s on M4 Pro 48 GB, 92.4 on M5 Pro 48 GB. A mlx-vlm run failed 41 of 85 tool calls (wrong argument names) though every task still passed. llama.cpp issue 31000 reports tool markup staying inside the reasoning field with the NVFP4 file. | Speed only. Tool calling is a risk. |
| Qwen3.8-27B on LiveBench and Arena | llmrun.dev aggregator. | LiveBench 2026 Coding 86.8, Reasoning 80.0, Long-Horizon 27.9 (Oct 2026, labelled Independent). LMArena Text 1437.1, WebDev 1591.4. | Context only. No tune has a row. |

### 2.3 What I searched and did not find

- BFCL V4 rows for any Qwen3.8 tune. Newest snapshot I saw (BenchLM, 2026-06-02) predates Qwen3.8.
- tau-bench reruns for any tune by a third party. AA's Tau3-Banking is the nearest, and it covers only bases.
- LMArena or OpenRouter quality data for Ornith, Occamy, Holo or Nanbeige. OpenRouter lists Flint (free), Bonsai 2 27B, Qwen3.8-27B and Qwen3.6-35B-A3B, but OpenRouter gives prices, not quality.
- Any r/LocalLLaMA thread with a method for Occamy, Holo4 or Nanbeige. Search found vendor copies only.

---

## 3. Candidate sheets

Columns: repo, base, licence, created, size at 4-bit (file plus vision file), GGUF and MLX, vision, downloads, engine, scores. All repo facts VERIFIED on 2026-10-27 unless marked.

### 3.1 Tunes of Qwen3.8-27B (dense 27B, same file format as the base)

| Repo | Base, licence, created | 4-bit size | GGUF / MLX | Vision | Downloads | Engine | Scores |
|---|---|---|---|---|---|---|---|
| **Qwen/Qwen3.8-27B** (control) | Apache-2.0, 2026-08-05 | unsloth UD-Q4_K_XL 17.56 + 0.93 = 18.49 GB. UD-IQ4_XS 14.25 GB. | Both | native | 7.5M (main), 6.0M (unsloth GGUF) | llama.cpp, Splash | AA above (INDEPENDENT). OSWorld-Verified 84.3 (VENDOR). |
| **Hcompany/Holo4-27B** | Qwen3.8-27B, **CC BY-NC 4.0** (re-admitted), 2026-09-24 | q4_k_m 16.88 + 0.93 = 17.81 GB | Official GGUF (19,281 dl). Community MLX (abenzerps). | native | 1,668 (main) | llama.cpp (same architecture). Splash UNVERIFIED. | OSWorld-Verified 85.2, OSWorld 2.0 61.7, AndroidWorld 85.1 (VENDOR, H Company harness: shell and memory over hundreds of steps, r8). No replication. |
| **tencent/UI-Mate-27B** and **UI-Mate-democua-27B** | **Qwen3.6-27B** (not 3.8), Apache-2.0, 2026-08-14 | bartowski GGUF (6,228 dl), mradermacher | GGUF, MLX 8-bit (majentik) | native | 758 and 441 | llama.cpp. Needs the official prompt and parser. | OSWorld-Verified 77.0, WindowsAgentArena 66.2, OSWorkerBench strict 41.00 (VENDOR). Agent checkpoint, not a chat model. |
| **prism-ml/Ternary-Bonsai-2-27B-gguf** | Qwen3.8-27B (compression), 2026-09-16 | PTQ1_0 5.95 GB, PQ2_0 7.21 GB, plus mmproj 0.63 (Q8) or 0.93 | GGUF, MLX 2-bit (32,330 dl) | native, separate mmproj | 2.1M (GGUF) | Splash (PQ2_0, with vision). Prism llama.cpp fork. Q2_0 pack on upstream is only for the 9B (lineup). | Vendor: 84.78 average over 14 benchmarks, 98.2% of FP16, BFCL v3 74.92 against 76.74 FP16 (VENDOR). Independent mini test above. |
| **trymirai/Qwen3.8-27B-S-experimental** (this is "Mirai") | Qwen3.8-27B (compression), Apache-2.0, 2026-09-22 | 8.45 GB (2.4 bits per weight), language model only | Safetensors for uzu and vLLM. Community GGUF (alesha-pro, 11.2 GB, needs a CUDA fork). No llama.cpp, no Splash. | The community card says vision comes from the base's mmproj | 1,296 (main), 15,496 (community GGUF) | Mirai "uzu" prebuilt runtime. macOS 26.4+, 24 GB or more. | Vendor speed: about 4 tok/s decode and 13 tok/s prefill on a base M4. 52 tok/s decode and 440 tok/s prefill on an M5 Pro (VENDOR). Card says numbers are provisional. |
| ukisai/Swift-Qwen3.8-27b and Swift-1.5 | Qwen3.8-27B, licence "other" (free under US$1M revenue; moot for a non-commercial project), 2026-09-08 and 09-16 | UNVERIFIED, same as base | GGUF exists | native | 3,936 and 8,409 | llama.cpp | 58.3% fewer thinking tokens, under 1% loss (VENDOR). Aims at the deep lane's cost. |
| Jackrong/Qwopus3.8-27B-Flash | Qwen3.8-27B, Apache-2.0, 2026-09-03 | like base | GGUF | native | 832 | llama.cpp | 12.8% faster decode, 80.7% MTP acceptance (VENDOR). Known Python indentation bug. |
| bottlecapai/ThinkingCap-Qwen3.8-27B | Qwen3.8-27B, **gated** | not readable | unknown | native | 4,196 | unknown | Gated repo, I could not read the card. Excluded. |
| migtissera/Tess-4.5-27B | Qwen3.8-27B, Apache-2.0, 2026-10-18 | like base | GGUF | text path in card | 549 | llama.cpp | 133/150 on BenchLocal, "level with its base" (VENDOR, and I could not find the BenchLocal suite). Says it ties. |
| bytkim/Qwen3.8-27B-pi, wesleysimplicio/Simplicio-27B, agentionai/Signal-3.8-27B, AlexWortega/Qwen3.8-27B-antislop | Qwen3.8-27B | like base | various | mixed | 3.0K, 2.2K, 9.6K, 589 | llama.cpp | Coding harness (Pi), SEARCH/REPLACE patches, sampling notes, style. Not Perry's jobs. |
| HemmingwayAI/Hemmingway-1 and 1.5 | Qwen3.8-27B / Hemmingway-1, **CC BY-NC 4.0** (re-admitted), 2026-09-20 / 2026-10-24 | bartowski Q4_K_M 17.44 GB, IQ4_XS 15.48 GB. No mmproj seen. | GGUF (mradermacher 240K dl) | **text only** (`qwen3_5_text`) | 7,619 (main) | llama.cpp | Writing: wins an 80-request head-to-head against bigger models, placed third on EQ-Bench 4 (VENDOR: the vendor's judge. EQ-Bench is public but I did not see its board). Hemmingway-1.5 is sold as undetectable by AI detectors. Not a brain. |
| JEV-27B, Clef, Eikos-27B, kev-27b, Tev-27B, d3 | Qwen3.8-27B | like base | various | mixed | JEV 491K | n/a | Typed-decision classifiers (lineup). They return probabilities, not text. Not a brain. |
| DavidAU, huihui, HauhauCS, Defiance, Dark-Scarlett, Whitehat | Qwen3.8-27B | like base | GGUF | mixed | very high | n/a | Abliterated, uncensored, roleplay or security tunes. Excluded (lineup §1.3). |

Merges of Qwen3.8-27B (27 repos, top by downloads): Ternary-Bonsai MTPLX packs (4.8K), Sanshoku and JetBrains 3.6/3.8 blends (1.5K, 1.1K), Zwielicht (1.5K), WineryLabs GrandCru. Nothing with a score I could verify.

### 3.2 Tunes of Qwen3.6-35B-A3B, and Ornith

| Repo | Base, licence, created | 4-bit size | GGUF / MLX | Vision | Downloads | Engine | Scores |
|---|---|---|---|---|---|---|---|
| **Qwen3.6-35B-A3B** (control, current fast lane) | Apache-2.0 | UD-IQ4_XS 17.73 + 0.90 GB (r8) | Both | native | n/a | llama.cpp, Splash | AA 18.2 reasoning, 15.2e off (INDEPENDENT). |
| **ornith-ai/Ornith-1.5-35B-A3B** | Qwen3.5-family MoE (`qwen3_5_moe`). `base_model` is null. MIT. 2026-08-18 | Official Q4_K_M 21.71 GB. bartowski IQ4_XS 19.28 GB, IQ3_M 17.37 GB, plus mmproj 0.90 | GGUF 3.9M dl. Official MLX 4, 6, 8-bit (332K dl for MLX). NVFP4, FP8, DFlash drafts. | native | 267,675 (main), 3.93M (GGUF) | llama.cpp. Splash lists only Ornith-1.5-122B by name. UNVERIFIED for the 35B. | Vendor: Terminal-Bench 2.1 67.8 (Terminus-2), SWE-bench Verified 79, DeepSWE 22 against Qwen3.6-35B-A3B 52.5, 73.4, 0 (VENDOR). Independent: KGP Talkie tie, tool-eval-bench 91/100 (section 2.2). |
| **ornith-ai/Ornith-1.5-9B** | MIT, 2026-08-18 | Q4_K_M 5.78 + 0.92 GB | GGUF 5.2M dl, MLX 4, 6, 8-bit | native | 464,941 | llama.cpp | Vendor: MCP-Atlas 54.2 against 46.8, Toolathlon 41.2 against 29.6 for Qwen3.5-9B (r8 §3.6). Independent: 18/18 tool use (KGP). |
| ornith-ai/Ornith-1.5-122B | MIT, 2026-10-16 | UD-Q4_K_XL 49.97 + 29.73 = 79.70 GB (+0.91 mmproj). Q4_K_M 75.84 GB. | GGUF, MLX 4, 8-bit | native | 76,295 | **Splash 1.4.1 supports it**, with its DFlash2 draft | No independent score. Fits 96 to 128 GB only. |
| ornith-ai/Ornith-1.5-397B | MIT | far above 128 GB | | | 223,694 | | Out of range. |
| **Accio-Lab/occamy-1.0** | Qwen3.6-35B-A3B, Apache-2.0, 2026-08-13 (GGUF 2026-09-15) | IQ4_XS 18.73 GB, Q4_K_S 19.89, Q4_K_M 21.17, IQ3_M 15.44, plus mmproj 0.90 | Official GGUF (17 variants, 783,484 dl), APEX GGUF, MLX 3 to 8-bit (text only, "Mac Metal acceptance pending") | native in BF16 and GGUF. **MLX is text only.** | 2,121 (main) | llama.cpp | Vendor (paper arXiv 2609.11977): AutomationBench Pass1 27.6 against 7.5, partial 69.1 against 39.4, Terminal-Bench 2.1 59.0 against 49.5 for the Qwen3.6 base (VENDOR). No third-party run. |
| **Hcompany/Holo4-35B-A3B** | Qwen3.6-35B-A3B, Apache-2.0, 2026-09-24 | q4_k_m 21.3 + 0.9 = 22.2 GB | Official GGUF (11,192 dl), community MLX | native | 2,711 | llama.cpp | OSWorld-Verified 80.8, OSWorld 2.0 30.9 (VENDOR). Long workflows favour the dense Holo4-27B (r8 §3.3). |
| endless-frontier/BigBang-v1 and Fx-Work | Qwen3.6-35B-A3B | UNVERIFIED | GGUF unverified | Fx-Work multimodal | 2.2K, 3.3K | | Science and office work tunes. Claims are vendor charts. Not GUI. |
| XYZAILab/XYZ-Aquila-mini, AlexWortega/SIQ-1-35B, t-tech/T-Search, juspay/xor, MemTensor/MemT-1.0-Nano, empero-ai/Qwen3.8-35B-A3B-Distill | Qwen3.6-35B-A3B | | | mostly text | 0.5K to 41K | | Deep-search, autoresearch, decision, memory and distill tunes (juspay/xor is a typed-decision classifier, MemT a memory model). Not Perry's jobs. |
| FrontisAI/Frontis-MA1-35B (and 30B) | Qwen3.6-35B-A3B, **CC BY-NC 4.0** (re-admitted), 2026-07-30 | bartowski GGUF (2,139 dl) | GGUF, MLX 4-bit | tag `image-text-to-text` | 181 | llama.cpp | "Execution-grounded model for evolutionary machine learning engineering and AutoResearch." No screen, tool-call or chat claim. Not for Perry. |

Merges of Qwen3.6-35B-A3B (39 repos): the notable ones are Ornith blends (EryriLabs BigBang-MTP, tepirale Agents-A1, Elsephire 80/20) with under 200 downloads each. No scores worth citing.

### 3.3 Non-Qwen families in range

| Repo | Licence, created | 4-bit size | GGUF / MLX | Vision | Downloads | Engine | Scores |
|---|---|---|---|---|---|---|---|
| **RecursiveSI/flint** (39.8B-A2.5B) | Apache-2.0, 2026-10-21. Trained from scratch, not a Qwen tune. | unsloth UD-IQ3_XXS 14.54, UD-Q3_K_XL 18.49, UD-Q4_K_XL 25.05 GB. ggml-org Q4_K_M 23.39 GB. Recursive Q4_1 25.99 GB. | GGUF (unsloth 149,888 dl). MLX third-party only. | **text only** | 10,574 (main) | llama.cpp. **Splash 1.4.1** (auto draft `incoai/Flint-DFlash2`, tool calling, structured output; "decides when to reason itself; reasoning settings cannot force it on or off"; no MLX). | Vendor: Terminal-Bench 2.1 54.9, SWE-bench Verified 74.2, IFBench 89.2 (VENDOR). Vendor Splash speed: 190 tok/s on an M5 Max 36 GB against 89 for llama.cpp (VENDOR). Community: 79.6 tok/s on an M4 Pro with llama.cpp (section 2.2). On OpenRouter as `recursive/flint-v1.0:free`. |
| **Nanbeige/Nanbeige4.3-33B** | Apache-2.0, 2026-10-24. Own base (`Nanbeige4.3-33B-Base`), Llama-style architecture. | bartowski IQ4_XS 18.64, Q4_K_M 20.79, Q5_K_M 25.07, Q6_K 29.02 GB | GGUF (bartowski 62,465 dl, AtomicChat, mradermacher), MLX 4-bit (several) | **text only** | 4,785 | llama.cpp should run it (Llama architecture, UNVERIFIED on Metal). Splash: no. | Vendor, same harness against Qwen3.8-27B, all at highest thinking: Terminal-Bench 2.1 80.9 against 73.0, Tau3-Bench 48.8 against 48.5, Automation Bench 54.2 against 38.3, Toolathlon-Verified 70.4 against 68.5, Claw-Eval 78.3 against 75.2, GDPval 84.8 against 86.4, SWE-Bench Pro 60.3 against 61.7 (VENDOR). Has `enable_thinking` and `preserve_thinking` switches. |
| nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB | OpenMDW-1.1, 2026-10-07 | 22.02 GB + mmproj 1.73 GB (native 2-bit) | Official GGUF (152,589 dl) | VLM | 10,877 (main) | UNVERIFIED | AA 21.4 (INDEPENDENT), below Qwen3.8-27B at low effort (26.2). Sits at the edge of the disk budget. |
| nvidia/Nemotron-3.5-Super-VL-120B-A12B | OpenMDW-1.1, 2026-10-12 | about 70 GB at 4-bit (UNVERIFIED, 124B params) | ggml-org, lmstudio, unsloth GGUF | VLM | 40,556 | UNVERIFIED | AA 26.5 (INDEPENDENT). 96 to 128 GB only. Under Qwen3.8-27B at medium. |
| IFM/K2-Horizon-MoVA-36B-A4B | Apache-2.0, 2026-09-01 | official GGUF (25,774 dl) | GGUF | text only | 12,104 | llama.cpp parser issue open (r8) | AA 25.3 (INDEPENDENT). Best non-Qwen AA row in range, but no vision and no non-thinking mode. |
| google/gemma-4-31B-it, gemma-4-26B-A4B-it | Apache-2.0, 2026-03-11 | | Both | native | 8.4M, 7.4M | | AA 14.7 and 16.7e. Tau3B 14.8 and 11.9. Below Qwen at equal size. |
| Muse Glimmer 30B | Apache-2.0, 2026-08-09 | | unsloth GGUF | native | 210K | | AA 17.5 (INDEPENDENT). |
| GLM-4.7-Flash (30B-A3B), Seed-OSS-36B, Devstral Small 2 (24B), Kimi Linear 48B-A3B, Mistral Small 4 (119B) | Various | | | mixed | 936K (GLM), 44K, 182K, 129K, 64K | | Old or weak. AA rows: Kimi Linear 7.3e, Mistral Small 4 11.3, Magistral Small 1.2 8.6e. Set aside. |
| MiniMax-H3 (33.1B on HF) | other | | | | 5.3M | | **Video generation model.** Not a language model. Dropped. |
| MiniMax-M3.1-Flash (220B), MiMo-V2.6-Flash (311B), GLM-5.3-Flash (321B), Inkling Small (266B) | various | all above about 90 GB at 3-bit | | | | | AA 42.7, 37.9, n/a, 25.7. Too large for the 96 to 128 GB class at useful quality (UNVERIFIED sizing). Dropped. |

### 3.4 Compressions of the base (not better models)

| Repo | What it is | Size | Runs on | Verdict |
|---|---|---|---|---|
| ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF | 2 to 3-bit | IQ2_XS 8.42 to IQ3_S 11.77 GB | llama.cpp | Vendor says IQ3_S ties BF16 on GPQA-Diamond (89.39 against 89.90). For 24 GB Macs (lineup §1.4). |
| byteshape Qwen3.8-27B | 2.56 to 3.84 bits | 8.84 to 13.08 GB | llama.cpp | Same. |
| ConwayResearch/Underdog-Saluki-27B-1.0 | IQ2-mix of Qwen3.8-27B | 7.89 GB + 0.93 mmproj | stock llama.cpp | Vendor: tool-calling 88 against 84 for "the full model" on Underdog Bench, a vendor suite (VENDOR). 594K dl on a related repo. A 2-bit file claiming to beat the full model on a private suite is a reason to test, not to believe. |
| Ternary Bonsai 2 (27B, 9B, 4B, 2B) | ternary | 27B: 5.95 or 7.21 GB | Splash, Prism fork | Section 3.1. Smaller sizes: lineup. |
| Mirai S | trellis codes | 8.45 GB | uzu only | Section 3.1. |

On a 48 GB Mac none of these is needed. They matter for 24 GB and 32 GB Macs.

---

## 4. Name by name

- **Ornith-1.5 (all sizes).** 9B, 35B-A3B, 122B, 397B (VERIFIED). No 4B and no 27B on Hugging Face under `ornith-ai` (I listed all 39 repos). MIT. Vendor claims beat Qwen3.6-35B-A3B and Gemma 4-31B, not Qwen3.8-27B. The card's table has no Qwen3.8-27B column. 35B-A3B is the only size that matters for a 48 GB Mac. The 122B needs 96 GB or more.
- **Ternary Bonsai 2 (27B and others).** Compression, section 3.1 and 3.4. The Splash README lists PQ2_0 with vision. OpenRouter hosts `prism-ml/ternary-bonsai-2-27b`.
- **Mirai.** Not a model line. It is trymirai, a company with a quantisation codec ("M", "L", "S", "XS") and an Apple runtime called uzu. It ships repacks of Qwen3.5, Qwen3.6, Qwen3.8, Muse Glimmer, LFM2.5 and Qwen3.8-Flash-Next. The "S" and "XS" 27B builds are marked experimental. A community fork claims 76.6 tok/s on a RTX 4070 (VENDOR, other author). On Macs, only uzu runs it. I found no quality table that compares Mirai S with the base.
- **Occamy-1.0.** Section 3.2. A repo title "occamy-ai/occamy-1.0" appears in bartowski's GGUF (bartowski/occamy-ai_occamy-1.0-GGUF, 2026-08-31, 2,624 downloads), but the API returns nothing for that org. I could not tell whether it is the same weights as Accio-Lab's. Unresolved.
- **Holo4 (27B, 35B-A3B).** Section 3.1 and 3.2. Both are official GGUF only as one `q4_k_m` file plus an mmproj.
- **UI-Mate.** Section 3.1. The 27B is a Qwen3.6-27B tune. It does not use the Qwen3.8 base, so it cannot be compared with Holo4-27B on base strength.
- **MiMo distills.** Only one exists at this size: MiMo-V2.6-Distill-Qwen-9B (9B, outside this report's range; lineup §1.2). The big MiMo-V2.6-Flash (311B, AA 37.9) is out of range.
- **Qwen3.8-Flash-Next.** 125B total with 6B active, plus 51B n-gram embedding and 4B MTP (the card; the file set is about 180B). AA 39.8, the best open row I could run on 128 GB. ISTA GSQ-RCO Q2_0 is 37.62 + 28.80 = 66.4 GB, IQ2_XS 68.0 GB, IQ3_XXS 75.8 GB. Splash supports it. Mirai also has an experimental "S" build. Licence `other`.
- **Flint.** The model Splash 1.4.1 added on 2026-10-26. Section 3.3.
- **Hemmingway and Frontis.** Re-admitted by licence, rejected on merit. Hemmingway-1 is a text-only writing model. Hemmingway-1.5 markets itself on beating AI-text detectors. Frontis-MA1 is for ML-engineering research.

---

## 5. What the tree walk found

Counts (VERIFIED, API, 2026-10-27, direct children only):

| Base | Finetune | Merge | Adapter |
|---|---|---|---|
| Qwen3.8-27B | 744 | 27 | 271 |
| Qwen3.6-35B-A3B | 404 | 39 | 358 |

Top by downloads after removing abliterated and quant formats:

- Qwen3.8-27B: JEV-27B (491K, classifier), DFlash2 draft models (371K, 70K), Dark-Scarlett (49K, roleplay), Comfy-Org repack, Ternary-Bonsai-2 MLX (32K), Cloudflare/clef (26K, classifier), Therapy-3.8, Signal-3.8-27B, Swift. By likes: clef 2,288, Hemmingway-1 892, Swift 636, DFlash2 drafts, d3, ThinkingCap (gated), Swift-1.5.
- Qwen3.6-35B-A3B: MemT-1.0-Nano (41K, memory), DFlash drafts (19K, 10K), Colibri quant (13K), empero Qwen3.8-35B-A3B-Distill (4K), Holo4-35B-A3B (2.7K), Opus-reasoning distill (2.7K), BigBang-v1, Occamy-1.0 (2.1K main). By likes: XYZ-Aquila-mini 443, DFlash 295, BigBang-v1 238, Occamy 236.
- Newest (last 7 days) on both: mostly quantisation experiments (2-bit, REAP expert pruning, NVFP4, DFlash2 drafts), 40-plus single-task `baseten/*-expert` SFT checkpoints, and tiny random test models. Nothing with a Perry-relevant claim.

Conclusion: the popular children are not better brains. Draft heads and classifiers dominate the download counts. The few agentic tunes (Occamy, Holo4, Fx-Work, BigBang, Tess-4.5, Qwen3.8-27B-pi) all compare with a base and none with the other tunes.

---

## 6. Ranked shortlist for the 48 GB M4 Pro (max 4)

Disk: 21 GB free means one model file at a time. Download, test, record the result in JSON, delete, then fetch the next. The control (Qwen3.8-27B UD-Q4_K_XL, 17.56 + 0.93 = 18.49 GB, VERIFIED) is the same size as the candidates, so it does not fit beside them. Keep the control's result file, not its weights, or test it first.

Shared harness: r8's P4 (50 Perry tasks: screen questions, one-step actions, five-step plans), thinking off for the interactive lane, same llama-server flags as `LocalEngine.swift`, three runs each. Add the public `tool-eval-bench` (MIT, 69 scenarios, any OpenAI-compatible endpoint including llama.cpp) so the Ornith 91/100 run can be reproduced against Qwen3.8-27B.

| Rank | Model | File and download | Why it is on the list | The one test that settles it |
|---|---|---|---|---|
| 1 | **Holo4-27B** (CC BY-NC 4.0) | `q4_k_m.gguf` 16.88 GB + `mmproj.f16.gguf` 0.93 GB = **17.81 GB** (Hcompany/Holo4-27B-GGUF) | Same base, same speed, same engine. Only tune with a vendor lead on screen actions over the 3.8 base, and a large one on OSWorld 2.0 (61.7 against 48.0). | The 40 recorded screen-action steps (goal, accessibility tree, screenshot), three runs, thinking off, against Qwen3.8-27B at UD-Q4_K_XL. Add 20 plain chat and JSON prompts. Adopt for the action lane if it wins by 5 step-success points, keeps the JSON rate within 3 points, and passes the stop-and-ask probe (a Send button, an ambiguous goal). If it only wins actions and loses chat, use it as the action model only. |
| 2 | **Ornith-1.5-35B-A3B** (MIT) | bartowski `IQ4_XS` 19.28 GB + `mmproj` 0.90 GB = **20.18 GB**. The official Q4_K_M (21.71 GB) leaves no disk room. | Only independent tests in this report (tie on tool use, 3.5 times the decode speed of the 27B on one RTX 5090). If it ties the 27B on Perry's tasks at MoE speed, it replaces Qwen3.6-35B-A3B as the fast lane and possibly the 27B for many turns. | tool-eval-bench (69 scenarios) plus the P4 five-step plans, thinking off, against Qwen3.8-27B and Qwen3.6-35B-A3B on the same Mac. First check 5 prompts that `enable_thinking:false` really turns the thinking block off (r8 §3.6 flagged no documented off switch). Adopt as fast lane if it is within 3 points of the 27B and its reference turn is at most 6 s (r8 §6.3 limit). |
| 3 | **Nanbeige4.3-33B** (Apache-2.0) | bartowski `IQ4_XS` **18.64 GB**. No vision file exists. | The only candidate whose card beats Qwen3.8-27B in the same harness on tool-heavy tests (Automation Bench 54.2 against 38.3, Toolathlon 70.4 against 68.5). New and unproven. | Text-only run of the 40 steps: both models get the accessibility tree and no screenshot. Compare step success and valid-JSON rate. Adopt only as a text-mode planner if it beats the 27B by 5 points. If the 27B's gap comes from the screenshot, Nanbeige is out for actions. Also check llama.cpp loads it on Metal (UNVERIFIED). |
| 4 | **Occamy-1.0** (Apache-2.0) | `IQ4_XS` 18.73 GB + `mmproj-occamy-1.0-F16.gguf` 0.90 GB = **19.63 GB** (Accio-Lab/occamy-1.0-GGUF) | Clearest agentic claim at MoE speed (AutomationBench 27.6 against 7.5 for its base, VENDOR) with vision. Likely under Qwen3.8-27B (Nanbeige's chart puts the 27B at 38.3 on a similar benchmark, not the same harness, UNVERIFIED), so it competes with Ornith for the fast lane, not with the 27B. | The five-step-plan subset (20 tasks, three runs, thinking off) with Occamy, Ornith and Qwen3.6-35B-A3B. Keep Occamy only if it beats Qwen3.6-35B-A3B by 10 points and lands within 5 of the 27B. If Ornith already wins, skip Occamy. |

Not on the list, with the reason:

- **Flint.** Text only, forced self-chosen reasoning on Splash (cannot be switched off), coding focus, tool-call quirks reported on two builds. If the owner wants it tested anyway: it is on OpenRouter as `recursive/flint-v1.0:free`, so Perry's bundled non-private test prompts can run with no download. Local files if needed: unsloth UD-Q3_K_XL 18.49 GB or UD-IQ3_XXS 14.54 GB. UD-Q4_K_XL (25.05 GB) does not fit the disk.
- **Holo4-35B-A3B.** Q4_K_M plus mmproj is 22.2 GB. It does not fit the free disk. Swap it in for rank 4 if a 4B or 9B disk clean-up frees 2 GB.
- **Bonsai, Mirai, Saluki, ISTA.** They shrink, they do not improve. Their tests belong to the 16 and 24 GB tiers (r8 P7).
- **UI-Mate-27B.** Tuned from Qwen3.6-27B, vendor score 77.0 against 84.3 for the 3.8 base.
- **Hemmingway.** Text-only writing model. If the owner wants a "voice" layer for short replies, it is a separate experiment and would need a second model resident.

---

## 7. Not verified

- Every score for every tune. No tune has an AA row, an OSWorld board row, or a third-party replication.
- Whether Holo4-27B, Nanbeige4.3-33B, Occamy-1.0 and Ornith-1.5-35B-A3B hold their quality in Perry's thinking-off, JSON-heavy path. All vendor cards test with reasoning on.
- Whether Splash runs Ornith-1.5-35B-A3B or Holo4 (the README lists the 122B only; release notes name Flint and the 122B).
- Whether llama.cpp loads Nanbeige4.3 and Nemotron 3.5 Bolt cleanly on Metal.
- Mirai S quality (no table compares it with the base) and its speed on an M4 Pro.
- Whether the "occamy-ai" mirror and the Accio-Lab repo are the same weights.
- The ThinkingCap card (gated) and the BenchLocal suite behind Tess-4.5's claim.
- Sizes of the 96 to 128 GB options other than the ones I read from file lists (Ornith-122B, Flash-Next Q2_0, Nemotron Super VL are partly estimated).

---

## Sources

Hugging Face API and cards (all read 2026-10-27):

- https://huggingface.co/api/models (tree walk: `filter=base_model:{finetune,merge,adapter}:Qwen/Qwen3.8-27B` and `Qwen/Qwen3.6-35B-A3B`)
- https://huggingface.co/ornith-ai (39 repos) and https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B
- https://huggingface.co/ornith-ai/Ornith-1.5-122B-GGUF and https://huggingface.co/unsloth/Ornith-1.5-122B-GGUF
- https://huggingface.co/bartowski/Ornith-1.5-35B-A3B-GGUF
- https://huggingface.co/Accio-Lab/occamy-1.0 and https://huggingface.co/Accio-Lab/occamy-1.0-GGUF
- https://huggingface.co/Hcompany/Holo4-27B-GGUF and https://huggingface.co/Hcompany/Holo4-35B-A3B-GGUF
- https://huggingface.co/tencent/UI-Mate-27B and https://huggingface.co/tencent/UI-Mate-democua-27B
- https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf
- https://huggingface.co/trymirai/Qwen3.8-27B-S-experimental and https://huggingface.co/alesha-pro/Qwen3.8-27B-S-mirai-GGUF
- https://huggingface.co/RecursiveSI/flint, https://huggingface.co/unsloth/flint-GGUF, https://huggingface.co/ggml-org/Flint-GGUF
- https://huggingface.co/Nanbeige/Nanbeige4.3-33B and https://huggingface.co/bartowski/Nanbeige_Nanbeige4.3-33B-GGUF
- https://huggingface.co/HemmingwayAI/Hemmingway-1, https://huggingface.co/HemmingwayAI/Hemmingway-1.5, https://huggingface.co/FrontisAI/Frontis-MA1-35B
- https://huggingface.co/ConwayResearch/Underdog-Saluki-27B-1.0
- https://huggingface.co/Qwen/Qwen3.8-Flash-Next and https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF
- https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB and https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16
- https://huggingface.co/migtissera/Tess-4.5-27B, https://huggingface.co/ukisai/Swift-Qwen3.8-27b, https://huggingface.co/Jackrong/Qwopus3.8-27B-Flash

Independent evidence:

- Artificial Analysis leaderboard (parsed): https://artificialanalysis.ai/leaderboards/models
- KGP Talkie, Ornith against Qwen3.8-27B on a RTX 5090: https://kgptalkie.com/tutorials/llm-benchmarking/ornith-1-5-9b-vs-35b-a3b-benchmark
- NVIDIA forum, Ornith-1.5 tool-eval-bench 91/100: https://forums.developer.nvidia.com/t/deepreinforce-ornith-1-5-family-released/380623/2
- InsiderLLM, Bonsai 2 against Qwen3.8-27B on a RTX 3090: https://insiderllm.com/guides/bonsai-2-27b-vs-qwen3-8-27b-rtx-3090/
- LLMCheck, Flint on Mac (community runs): https://llmcheck.net/blog/recursive-flint-on-mac/
- llmrun.dev, Qwen3.8-27B LiveBench and Arena rows: https://llmrun.dev/model/qwen-qwen3-8-27b/benchmarks
- tool-eval-bench (MIT, SeraphimSerapis), described at https://forums.developer.nvidia.com/t/introducing-tool-eval-bench-cli/366903
- BFCL V4 leaderboard (last updated 2025-12-16): https://gorilla.cs.berkeley.edu/leaderboard
- OpenRouter model list (Flint, Bonsai, Qwen3.8-27B): https://openrouter.ai/api/v1/models

Vendor and engine pages:

- Splash 1.4.1 release notes (Flint, Ornith-1.5-122B): https://github.com/incoai/splash/releases/tag/1.4.1
- Splash README (supported families): https://github.com/incoai/splash
- Occamy-1.0 paper: https://arxiv.org/abs/2609.11977 and site https://accio-lab.github.io/occamy/
- Recursive Flint coverage: https://www.marktechpost.com/2026/10/21/recursive-flint-local-coding-model/
- H Company Holo4 coverage: https://aiweekly.co/alerts/h-company-ships-holo4-agents-27b-hits-617-on-osworld-20
- BenchLM aggregator (copies vendor numbers): https://benchlm.ai/compare/ornith-1-5-35b-a3b-vs-qwen3-8-27b
- Earlier reports: `docs/research/2026-10-27/local-model-lineup.md`, `docs/research/2026-10-27/finetunes-and-cua.md`, `docs/research/2026-10-25/r8-local-models-best.md`
