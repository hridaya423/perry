# Large tier: the best model Perry can run on 32 to 128 GB Macs, ranked by usefulness per second

Date: 2026-10-27. Author: research sub-agent. Status: final. Research only. I downloaded no weights, built nothing and ran no model. Scratch files lived in `/tmp/sota`, not in the repo. This is the only file I wrote.

This extends `large-tunes-deep.md`, `local-model-lineup.md` and `finetunes-and-cua.md` (all 2026-10-27) and `r8-local-models-best.md` (2026-10-25). I do not repeat their tables. I cite them as "tunes-deep", "lineup", "tunes-cua" and "r8".

## Summary (15 lines)

1. The owner is right about speed. Ornith-1.5-35B-A3B decoded 273 tok/s against 77 for Qwen3.8-27B on one RTX 5090, and the two tied 18/18 on a small tool test (COMMUNITY, tunes-deep). The speed comes from the MoE shape, not from Ornith. Ornith-1.5 itself is only 9% faster than Qwen3.6-35B-A3B on an RTX 3090 (COMMUNITY, InsiderLLM).
2. My arithmetic for a 5-step Perry task on a 48 GB M4 Pro: a 3B-active MoE takes about 6 s per step, a 27B takes about 27 s per step (UNVERIFIED). The MoE finishes more tasks per second unless its per-step success falls under about 70%, against 95% for the 27B. That is a big margin. Speed wins first.
3. Quality gap on the independent board. Artificial Analysis (AA), thinking off: Qwen3.8-27B 20.2, Qwen3.6-35B-A3B 15.2e. On the hard tool test Tau3-Banking: 20.0 against 5.4 (INDEPENDENT, AA, parsed today). That gap is what the new MoE tunes claim to close. Nobody independent has measured them in AA.
4. New this pass: **Nex-N2.5-mini** (nex-agi, 35B-A3B, Apache-2.0, vision, bartowski GGUF). Vendor: OSWorld-Verified 71.2, OSWorld-G 82.9, Terminal-Bench 2.1 73.4, Toolathlon 54.6, AutomationBench 32.3 (VENDOR). Earlier reports missed it. Its thinking switch is `reasoning_effort:"none"`, not `enable_thinking:false`. Perry's current flag would not turn it off.
5. Ornith's own 122B card puts Qwen3.8-27B in the table: Terminal-Bench 2.1 71.9, SWE-bench Verified 76.8, MCP-Atlas 69.0, Toolathlon 67.1, ClawEval 75.4 (VENDOR). Ornith-35B-A3B's card: 67.8, 79, 70.2, 48.7, 72.5 (VENDOR, different card, harness not shared). Read together: Ornith-35B ties the 27B on terminal and MCP, beats it on SWE, and is far behind on Toolathlon (-18) and 3 behind on Claw.
6. Ornith loses knowledge. A community run (3 seeds, 100 questions, 4-bit): MMLU-Pro 78.0 for Ornith against 85.3 for stock Qwen3.6-35B-A3B (COMMUNITY, peculiar-ragdoll). Fine for screen and tool work. Bad for trivia.
7. A third-party Mac Studio M2 Ultra run found the 35B-A3B MoE about 3 times faster to a working fix than dense Qwen3.6-27B at accuracy parity on 10 agent tasks (COMMUNITY, Nail card). Same shape of result as item 1, on a Mac.
8. No tune beats its base on independent evidence. I walked 21 Hugging Face trees and read about 60 cards. Every win is VENDOR. Several authors say so against themselves (Carnice-V3, the Flash-Next 40B prune). AA has no row for Ornith, Nex, Occamy, Holo, Flint, Nanbeige, Sage, Xing, Kolibri or Laguna.
9. Only open model above Qwen3.8-27B on AA in range: **Qwen3.8-Flash-Next** (39.8, 125B-A6B). It is 66 GB at Q2_0 (Splash only) or 82 GB at IQ3_XXS. Vendor speed on Splash: 95 tok/s on an M5 Pro 64 GB. For 96 to 128 GB Macs it is the one real "Large" upgrade.
10. Everything else in 96 to 128 GB loses to the 27B on AA at medium effort (27.6): Nemotron 3.5 Super VL 26.5, Ling-3.0-flash-VL 24.6, Qwen3.5-122B-A10B 15.6 to 17.7e, gpt-oss-120b 11.6. Ornith-1.5-122B has no AA row; vendor says +3 to +10 over the 27B at 4 to 5 times the memory.
11. Families I checked and dropped: Gemma 4 (AA 13.1 to 16.7e), gpt-oss, GLM-4.5-Air and 4.7-Flash, Seed-OSS, Kimi Linear, Mistral Medium 3.5 and Small 4, Laguna XS 2.1 (loses to Qwen3.6 on its own card), Granite 4.2, LFM2.5-24B. GLM-5.3-Flash, Ling 3.1 Flash, Hy3 and DeepSeek V4.1 Flash are 300 to 760B. MiniMax-H3 is a video model.
12. Splash 1.4.1 serves fine-tunes of the Qwen3.8-27B and Qwen3.6-35B-A3B families and names Ornith-1.5-35B-A3B as one (VERIFIED, Splash DEVELOPMENT.md). Vendor speed on an M5 Pro: 27B 74 tok/s against 16 on llama.cpp. If the owner accepts Splash, the dense 27B becomes about as quick as a llama.cpp MoE.
13. Lineup (details in section 8): 32 to 36 GB and 48 GB run an A3B MoE as "Best" and the 27B as "Large". 64 GB adds higher quants. 96 to 128 GB adds Flash-Next on Splash. The MoE pick is Ornith-1.5-35B-A3B or Nex-N2.5-mini, decided by a local test.
14. Shortlist for the 48 GB M4 Pro with 21 GB free (section 9): 1) Ornith-1.5-35B-A3B IQ4_XS 20.18 GB, 2) Nex-N2.5-mini IQ3_M 19.86 GB, 3) Holo4-27B 17.81 GB, 4) Occamy-1.0 IQ4_XS 19.63 GB, 5) Dirk-Qwen3.8-27B IQ4_XS 15.18 GB. Run one file at a time.
15. Not verified: every tune score, every Mac speed for a model not named as measured, whether any of them keeps its edge with thinking off, and anything Perry-specific. OSWorld, ScreenSpot, BFCL and LMArena boards were unreadable or stale. Section 10 lists the rest.

---

## 0. Method, labels and limits

Labels. Every number carries one.

- **VERIFIED**: a fact I read from the Hugging Face API, a model card, a chat template, a config file or the AA page on 2026-10-27. File sizes, dates, licences, downloads, parameter counts, template switches.
- **INDEPENDENT**: a score from a party that did not train the model, with a harness I could read. Here that means AA only.
- **COMMUNITY**: a score from a third party with a method I read, but small, one author, or an author who sells a competing tune. Counts as weak independent evidence.
- **VENDOR**: the model's author, or a site that copies the author. Nobody checked it.
- **UNVERIFIED**: second hand, or my arithmetic. I name the formula.

How I walked Hugging Face.

- API calls: `GET /api/models?filter=base_model:{finetune|merge|adapter|quantized}:<repo>&sort=downloads` with page-following over the `Link` header, then re-sorted by date. I also ran `/api/models?author=...&sort=createdAt` for 14 labs, and a trending-score sweep (500 text and image-text models, filtered to 18 to 135B parameters).
- I removed names with abliterat, uncensor, heretic, huihui, quant and format words, then read the cards of the rest. I read low-download repos on purpose (under 100 downloads: Muse-Glimmer GUI LoRA, Qwen3.8-20B-Minitron, Whittle, Agens-Pilot, Carnice-V3, Davd-b01 Flash-Next prune, REAP-50 Ornith, and others).
- Ornith's `base_model` is null, but its children tag it. Walking `base_model:*:ornith-ai/Ornith-1.5-35B-A3B` found 36 finetunes, 10 merges, 3 adapters, 202 quantized. The earlier reports found Ornith by name only, so this tree is new. It surfaced Tiel-Coder, REAP-50, the DFlash drafts and two Ornith merges.
- AA: I downloaded `artificialanalysis.ai/leaderboards/models` and parsed its embedded `initialModels` array (272 records, 175 open weights). All AA numbers below come from that parse.
- Engines: I read the Splash README, `DEVELOPMENT.md` and release notes 1.2.1 to 1.4.1, and the llama.cpp release list (b11928 is current).

Limits.

- OSWorld, ScreenSpot-Pro and LMArena are JavaScript pages I could not read. BFCL's page was last updated 2025-12-16 (tunes-deep). I found no independent GUI score for any model in range.
- Web search found no hands-on Reddit or forum test for Nex-N2.5-mini, Occamy, Holo4 or Nanbeige4.3. Searches returned vendor copies and aggregators (BenchLM, MindStudio), which I count as VENDOR.
- I did not run anything, so every Mac speed is a cited number or my arithmetic.

---

## 1. Direct answer to "ornith is really useful if it's that much faster then isn't it?"

Yes. With one correction: the speed is a property of the MoE shape, and Ornith is one of several MoEs that share it.

**Speed evidence.**

| Claim | Number | Label and source |
|---|---|---|
| Ornith-1.5-35B-A3B vs Qwen3.8-27B decode, RTX 5090, Q4_K_M | 273.2 vs 77.2 tok/s | COMMUNITY, KGP Talkie (tunes-deep) |
| Ornith-1.5-35B-A3B vs Qwen3.6-35B-A3B decode, RTX 3090, llama-bench | 172.4 vs 158.2 tok/s (+9%); prefill 3,603 vs 3,694 (-2.5%) | COMMUNITY, InsiderLLM. Quants differ (bartowski Q4_K_M vs Unsloth UD-Q4_K_M) |
| MoE vs dense on a Mac Studio M2 Ultra 64 GB, oMLX, agent tasks | MoE "3 problems in the time the dense 27B solves one" at accuracy parity | COMMUNITY, Nail card (peculiar-ragdoll). The author sells the MoE tune |
| Same author, SWE-bench-Live, 25 problems | Qwen3.8-27B stock 16 solved at 50.2 min per attempt (median); Qwen3.8-27B with a terse template 15 at 20.1; Tiel (Ornith + terse template) 12 at 8.6; stock Qwen3.6-35B-A3B 8 at 5.5; Ornith stock 8 | COMMUNITY, Tiel and Dirk cards. One run per problem. The Tiel and Dirk rows are the author's own tunes |
| Qwen3.6-35B-A3B Q4_K_M on M5 Pro 48 GB, llama.cpp | 81.96 tok/s | COMMUNITY, Kapitsa harness via LLMCheck |
| Qwen3.6-35B-A3B on M4 Pro 48 GB, oMLX (MLX, not llama.cpp) | about 85 to 86 tok/s in 3 of 4 community runs; a fourth run 37.6 | COMMUNITY, omlx.ai |
| Flint (A2.5B) on M4 Pro 48 GB, llama.cpp b11804 Q4_1 | 79.6 tok/s | COMMUNITY, Kapitsa harness |
| Dense 27B, llama.cpp UD-Q4_K_M | 16 tok/s on M5 Pro 20-core, 17 on M3 Max 40-core | VENDOR, Splash README |
| Same machines, Splash | 27B 74 and 92 tok/s; 35B-A3B 175 and 209 | VENDOR, Splash README |

**Quality evidence.**

| Question | Number | Label |
|---|---|---|
| How far is the base MoE from the 27B with thinking off? | AA index 15.2e vs 20.2. Tau3-Banking 5.4 vs 20.0. Terminal-Bench 2.1 41.6 vs 49.1. | INDEPENDENT, AA |
| Does Ornith-35B close it? | Vendor tables: ties on terminal and MCP, behind on Toolathlon and Claw (item 5 of the summary) | VENDOR |
| Does Ornith-35B hold on easy tool tasks? | 18/18 for Ornith 35B, Ornith 9B and Qwen3.8-27B | COMMUNITY, tunes-deep |
| Does it lose knowledge? | MMLU-Pro 78.0 vs 85.3 (Qwen3.6-35B-A3B), 4-bit, 3 seeds, 100 questions | COMMUNITY, Tiel card |
| Hard multi-turn tool use? | Tool-eval-bench 91/100 on Ornith, no Qwen run. Weak: autonomous planning 67%, instruction following 80% | COMMUNITY, NVIDIA forum (tunes-deep) |

**Break-even arithmetic** (UNVERIFIED, my numbers on a 48 GB M4 Pro, llama.cpp):

- One Perry step is about 1,000 text tokens, one 640-token screenshot and a 150-token answer.
- 3B-active MoE: about 4 s to first token plus 150 tokens at 60 to 80 tok/s, so about 6 s (r8 planning value for first token; the decode range is bracketed by the community runs above).
- 27B at IQ4_XS: 16 s to first token plus 150 tokens at 14 tok/s, so about 27 s (lineup §3.9, derived).
- A 5-step task, per-step success `p`. Completions per second is `p^5 / (5 x time)`.
- 27B at p = 0.95: 0.77 / 135 s = 0.0057 per second. MoE at p = 0.90: 0.59 / 30 s = 0.0197 per second. The MoE is **3.4 times** better.
- The MoE only loses when `p^5 / 30 < 0.77 / 135`, which means `p < 0.70`.
- The step times are my estimates and the `p` values are assumed. Treat the 3.4 as the shape of the result, not a forecast.

**Conclusion.** For Perry's interactive lane the MoE class should be the default "Best", and the 27B should be the "Large" lane for hard jobs. That matches the current lineup. What changes is which MoE: base Qwen3.6-35B-A3B is the weakest of the A3B-class on long tool tasks (Tau3-Banking 5.4). Ornith, Nex and Occamy all claim to fix it. A local test picks the winner.

**Engine caveat.** If the owner allows Splash (Apache-2.0, `brew install incoai/tap/splash`, needs an M3 or newer chip and macOS 26.4 or later), the vendor gap between the 27B and the MoE shrinks: 74 against 175 tok/s on an M5 Pro, and 27B prefill uses the Neural Engine. Splash's own numbers, VENDOR. Perry's approved engine is llama.cpp (lineup §3.3). This report ranks for llama.cpp first and notes Splash where it changes the answer.

---

## 2. Hugging Face tree ledger (VERIFIED, API, 2026-10-27, direct children only)

| Base | Finetune | Merge | Adapter | Quantized | What the tree held |
|---|---|---|---|---|---|
| Qwen/Qwen3.8-27B | 744 | 27 | 271 | n/a | tunes-deep §5. I re-scanned by keyword (agent, tool, gui, distill, reap, prune, fast, flash, think, hermes, mcp). New: Qwen3.8-20B-Minitron, Carnice-V3, Agens-Pilot, Smaug-Mini. |
| Qwen/Qwen3.6-35B-A3B | 404 | 39 | 358 | n/a | Re-scan. New: Whittle line, SNEX-V1, Iris-mini, RAZOR prunes (19B and 28B), Qwen3.8-35B-A3B-Distill. |
| ornith-ai/Ornith-1.5-35B-A3B | 36 | 10 | 3 | 202 | New tree. Tiel-Coder (2.6M downloads on the MTP GGUF), REAP-50 (19B), DFlash drafts, abliterations, 2 merges. |
| ornith-ai/Ornith-1.5-122B | 7 | 0 | 0 | 44 | GGUF 13, MLX 21. Nothing else of value. |
| ornith-ai/Ornith-1.5-9B | 41 | 12 | 9 | 97 | Out of range (9B). Merges are coders. |
| Qwen/Qwen3.8-Flash-Next | 95 | 8 | 2 | 520 | REAP and prune attempts: sh0wie REAP-288 (125B), Davd-b01 40B prune (GPQA near chance), Jab1718 43B. Agnes-3.0-Qwen (API-first). |
| google/gemma-4-31B-it | 332 | 40 | 371 | 346 | Roleplay merges, QAT q4_0 (official Google), classifiers. No agent tune. |
| google/gemma-4-26B-A4B-it | 220 | 19 | 105 | 413 | Same. Wald-26B-A4B is a probability classifier. |
| openai/gpt-oss-120b | 124 | 1 | 252 | 134 | Safeguard model, derestricted tunes, "less-is-moe" 59B prunes. |
| openai/gpt-oss-20b | 570 | 7 | 480 | 254 | Mostly small LoRA tunes. |
| zai-org/GLM-4.5-Air | 39 | 0 | 12 | 66 | Cerebras REAP 82B-A12B, roleplay. Old. |
| zai-org/GLM-4.7-Flash | 81 | 0 | 22 | 107 | Cerebras REAP 23B-A3B, RAZOR 17B and 24B, coder tune. Old. |
| poolside/Laguna-XS-2.1 and S-2.1 | 13 and 22 | 0 | 0 and 1 | 41 and 96 | JANG quants, DSpark drafts, winnow prunes (S keep50 61B). |
| Nanbeige/Nanbeige4.3-33B | 8 | 0 | 1 | 77 | Only a DMS-2x variant, created today. |
| RecursiveSI/flint | 14 | 0 | 1 | 80 | Roleplay, uncensored, Opus-trace attempt (AlexWortega/flint-opus-step40, 0 downloads). |
| Accio-Lab/occamy-1.0 | 1 | 2 | 0 | 35 | MTP variant only. |
| Hcompany/Holo4-27B and 35B-A3B | 1 and 0 | 1 and 0 | 0 | 12 and 15 | Abliterated variant only. |
| IFM/K2-Horizon-MoVA-36B-A4B | 6 | 0 | 0 | 33 | MLA and FAST2 conversions. |
| nex-agi/Nex-N2.5-mini | 3 | 0 | 0 | 42 | GGUF from bartowski, mradermacher, abenzerps and others; MLX 4, 6, 8-bit. |
| Qwen/Qwen-AgentWorld-35B-A3B | 11 | n/a | n/a | 75 | A world simulator, not an agent brain. |
| InternScience/Sage-A1.5 | 7 | 2 | 0 | 32 | Science agent. SNEX-V1 merges it with Nex. |
| Qwen/Qwen3.5-122B-A10B | 56 | 0 | 12 | 168 | AREX-Base, TerminalHorizon-122B. No GUI tune. |
| Nemotron 3.5 Super VL | 10 | 0 | 0 | 31 | Domain tunes (finance, health), Bolt 74B. |
| Kolibri-1, Seed-OSS-36B, Kimi-Linear-48B, Qwen3-Next-80B, Ling-3.0-flash-VL, Muse-Glimmer-30B | 5, 21, 10, 40, 0, 58 | 0 to 3 | 0 to 16 | 10 to 193 | Drafters, REAP-35B (Kimi), Muse-Glimmer GUI-grounding LoRA (13 downloads). Nothing for Perry. |

What the walk says: the tail is long, and the bulk is noise. About 90% of children are quants, classifiers, abliterations, roleplay merges, draft heads or single-task SFT. The few agent tunes that publish a comparison compare with their own base, never with Qwen3.8-27B, and none has an independent score.

---

## 3. Independent evidence ledger

### 3.1 AA rows for open models in or near range (INDEPENDENT, VERIFIED parse)

Tau3B = Tau3-Banking. TB = Terminal-Bench 2.1. Auto = AutomationBench. "e" = AA estimated the index. All in percent except the index.

| Model (AA row) | Params (total-active) | Index | Tau3B | TB | Auto | MMMU-Pro | Fits |
|---|---|---|---|---|---|---|---|
| Qwen3.8-Flash-Next | 125B-6B (+51B n-gram table) | 39.8 | 45.4 | 86.1 | 55.9 | 79.8 | 96 GB+ only |
| Qwen3.8-27B xhigh | 27B dense | 33.7 | 48.0 | 79.8 | 48.2 | 76.3 | 32 GB+ |
| Qwen3.8-27B medium | 27B | 27.6 | 47.4 | 65.2 | 40.3 | 74.2 | |
| Qwen3.8-27B low | 27B | 26.2 | 32.2 | 67.4 | 30.1 | 73.8 | |
| Qwen3.8-27B thinking off | 27B | 20.2 | 20.0 | 49.1 | 12.4 | 69.9 | |
| Nemotron 3.5 Super VL | 124B-12B | 26.5 | n/a | n/a | 14.8 | n/a | 96 GB+ |
| K2 Horizon MoVA 36B-A4B (text only) | 36B-4B | 25.3 | 32.0 | 56.6 | 26.1 | n/a | 32 GB+ |
| Ling-3.0-flash-VL | 124B-5.5B | 24.6 | 34.4 | 64.4 | 15.7 | 79.0 | 96 GB+ |
| Nemotron 3.5 Bolt | 74B-9B | 21.4 | n/a | n/a | 15.5 | n/a | 64 GB+ |
| Qwen3.6-35B-A3B reasoning | 35B-3B | 18.2 | 9.3 | 44.9 | 5.2 | 75.0 | 32 GB+ |
| Qwen3.5-122B-A10B non-reasoning / reasoning | 122B-10B | 17.7e / 15.6 | 10.3 / n/a | 47.2 / n/a | n/a | 70.3 / 75.0 | 96 GB+ |
| Muse Glimmer 30B high | 30B | 17.5 | 23.5 | 51.7 | 6.8 | 74.3 | |
| Gemma 4 26B-A4B reasoning / non-reasoning | 26B-4B | 16.7e / 13.1 | n/a | n/a | n/a | 69.2 / 66.7 | |
| Qwen3.6-35B-A3B thinking off | 35B-3B | 15.2e | 5.4 | 41.6 | n/a | 71.0 | |
| Gemma 4 31B reasoning / non-reasoning | 31B | 14.7 / 13.9e | n/a / 8.9 | n/a / 29.2 | n/a | 73.4 / 70.3 | |
| Mistral Medium 3.5 | 128B | 14.2 | | | | 64.9 | |
| Nemotron 3.5 Lightning | 30B-3B | 12.9 | 8.9 | 24.3 | 0.8 | n/a | |
| Granite 4.2 30B | 30B | 12.7 | | | | n/a | |
| gpt-oss-120b high | 117B-5B | 11.6 | 12.8 | 26.2 | 0.2 | n/a | 64 GB+ |
| Qwen3-Next-80B-A3B reasoning (Instruct 9.6) | 80B-3B | 11.2e | | | | n/a | |
| Qwen3-Coder-Next | 80B-3B | 9.2 | | | | n/a | |
| Kimi Linear 48B-A3B | 48B-3B | 7.3e | | | | | |

Rows I looked for and did not find: Ornith (any size), Nex-N2.5-mini, Occamy, Holo4, Flint, Nanbeige4.3, Sage-A1.5, Xing4.0, Kolibri-1, Laguna (any), Raon-1, Whittle, Tiel, Dirk. Rows above 300B that beat the 27B (GLM-5.3-Flash 41.8, Ling 3.1 Flash 41.1, DeepSeek V4.1 Flash 45.1, MiMo-V2.6-Flash 37.9, Step 5 Preview 43.7) are far too large (VERIFIED parameter counts: 321B, 572B, 763B, 604B).

What the table says.

- Nothing in 20 to 130B beats Qwen3.8-27B at medium effort except Flash-Next.
- The non-Qwen families (Gemma 4, gpt-oss, Granite, Mistral, Nemotron Lightning, Kimi Linear) are far under. Gemma 4 26B-A4B has no Tau3-Banking row; Gemma 4 31B has 8.9 with thinking off.
- Ling-3.0-flash-VL (24.6, MIT, vision, 124B-A5.5B) is the best non-Qwen vision model in the 96 to 128 GB class. It is still under the 27B at medium effort and needs about 70 GB for IQ4_XS.
- Thinking helps Qwen3.8-27B a lot (20.2 off, 27.6 medium). The deep lane earns its cost on hard tasks. The interactive lane has no independent score for any tune.
- AA's median reasoning time for Qwen3.8-27B is 42 to 49 s per question on its API (low, medium, xhigh), and 40 s for Qwen3.6-35B-A3B. Thinking is expensive for every model, which supports a thinking-off interactive lane.

### 3.2 Community tests with a readable method

| Test | Method | Result | Worth |
|---|---|---|---|
| peculiar-ragdoll (Tiel, Dirk, Nail, Dagger cards) | SWE-bench-Live 25 problems, one run each. MMLU-Pro 100 questions x 3 seeds. Claw-Eval multi-turn 114 conversations. Mac Studio M2 Ultra 64 GB, oMLX, for the Nail runs. | See §1. Ornith MMLU-Pro 78.0, Qwen3.6 85.3. Claw-Eval: Tiel 67.2, Ornith 65.3, Nail 60.5. A terse template cut Claw-Eval answer tokens 59% and MMLU-Pro tokens per correct answer 22% on Dagger's base. | Best Mac-side data I found. The author sells these tunes. |
| KGP Talkie, InsiderLLM, InsiderLLM Bonsai, NVIDIA forum, LLMCheck | tunes-deep §2.2 | Ties on easy tool tasks; speed only | Already read |

### 3.3 What I searched and did not find

- Any independent GUI or OSWorld run for Holo4, Nex-N2.5-mini, UI-Mate or MAI-Gym. H Company opened its trajectories (VENDOR claim, `trajectories.hcompany.ai`), so a re-check is possible but I found none.
- BFCL V4 rows for any model above, tau-bench reruns for tunes, LMArena data for tunes, Reddit hands-on threads for Occamy, Holo4, Nex or Nanbeige4.3.
- Any ScreenSpot-Pro run by a third party on a model in this range, except a self-run ScreenSpot-v2 87% for a 13-download Muse-Glimmer LoRA (VENDOR).

---

## 4. Candidate sheet: A3B and A4B class MoE (the "Best for this Mac" slot)

All repo facts VERIFIED today. Scores are VENDOR unless marked.

| Model | Base, licence, date | 4-bit file (+ vision) | Active | Vision | GGUF / MLX | Downloads | Engine | Scores |
|---|---|---|---|---|---|---|---|---|
| **ornith-ai/Ornith-1.5-35B-A3B** | Qwen3.5/3.6-family MoE, `base_model` null. MIT. 2026-08-18 | bartowski IQ4_XS 19.28 + 0.90 = **20.18 GB**; Q4_K_M 21.86 + 0.90; Q5_K_M 25.49; Q6_K 30.53; Q8_0 37.81 | ~3B | Yes | GGUF 3.9M; MLX 4, 6, 8-bit | 267,675 | llama.cpp. Splash treats it as the Qwen3.6-35B-A3B family (VERIFIED) | Terminal-Bench 2.1 67.8, SWE-bench Verified 79, MCP-Atlas 70.2, Toolathlon 48.7, ClawEval 72.5 (all VENDOR). Community in §1. |
| **nex-agi/Nex-N2.5-mini** | Qwen3.5-35B-A3B-Base (UNVERIFIED, from the SNEX-V1 card). Apache-2.0. 2026-09-08 | bartowski IQ3_M 18.96 + 0.90 = **19.86 GB**; IQ4_XS 19.89 + 0.90 = **20.79 GB**; Q4_K_M 22.32 | ~3B | Yes (`qwen3_5_moe`, mmproj 0.90) | GGUF (bartowski 9,032 dl, abenzerps 8,213); MLX 4, 6, 8-bit | not tracked on main repo; GGUFs 9K | llama.cpp (arch is `qwen35moe`). Splash UNVERIFIED | OSWorld-Verified 71.2, OSWorld-G 82.9, OSWorld-2 30.5, WebArena-Verified 63.4, Terminal-Bench 2.1 73.4, AutomationBench 32.3, Toolathlon 54.6, SWE-Bench Pro 43.8, BrowseComp 83.4 (VENDOR, Nex card). A Reddit user's agent run of the older Nex-N2-mini against Qwen3.6-27B: Toolathlon 33.3 vs 50.0 (COMMUNITY, anecdotal, other model). |
| **Accio-Lab/occamy-1.0** | Qwen3.6-35B-A3B. Apache-2.0. 2026-08-13 | IQ4_XS 18.73 + 0.90 = **19.63 GB**; Q4_K_M 21.17 | ~3B | Yes | official GGUF 783K dl; MLX is text only | 2,121 (main) | llama.cpp | Claw-Eval 82.2, AutomationBench 27.6, Tau3-Banking 37.1, Terminal-Bench 2.1 59.0 (VENDOR, lineup). |
| **Hcompany/Holo4-35B-A3B** | Qwen3.6-35B-A3B. Apache-2.0. 2026-09-24 | q4_k_m 21.30 + 0.90 = 22.20 GB | ~3B | Yes | official GGUF | 2,711 | llama.cpp | OSWorld-Verified 80.8, OSWorld 2.0 30.9 (VENDOR). |
| peculiar-ragdoll/Tiel-Coder-35B-A3B-GGUF | Ornith weights, own imatrix quant, terse "Sharp" chat template. MIT. 2026-08-19 | UD-IQ4_XS 17.73 + 0.90 = **18.63 GB** | ~3B | Yes (Ornith's own projector) | GGUF 294K; MTP variant 2.6M | 294,132 | llama.cpp | See §1 and §3.2. Coding-leaning. Honest about weak trivia. |
| logic65/Whittle-Qwen-3.8-35B-A3B | A 3B-active student of Qwen3.8-27B in Flash-Next layout. Apache-2.0. 2026-09-30 | Q4_K_M 21.28 GB | ~3B | **No** | GGUF (stock llama.cpp, author says) | 2,437 | llama.cpp | One author, "research preview". Strict JSON 72/72, tool-stop 24/24, GSM8K 43/50, MATH-60 46/60 (VENDOR). Greedy decoding loops. Watch item. |
| Qwen/Qwen3.6-35B-A3B (control) | Apache-2.0 | UD-IQ4_XS 17.73 + 0.90 = 18.63 GB; UD-Q4_K_XL 22.36 + 0.90 | ~3B | Yes | Both | 4.2M | llama.cpp, Splash | AA table §3.1 (INDEPENDENT). |
| RecursiveSI/flint | Own base. Apache-2.0. 2026-10-21 | unsloth UD-Q3_K_XL 18.49 GB | 2.5B | No | GGUF | 10,574 | llama.cpp, Splash | tunes-deep §3.3. Text only; reasoning not switchable on Splash. |
| IFM/K2-Horizon-MoVA-36B-A4B | Apache-2.0 | official GGUF | 4B | No | GGUF | 12,104 | llama.cpp (parser issue, r8) | AA 25.3 (INDEPENDENT). Text only, no non-thinking mode. |
| Xing4.0-29B-A4B (China Telecom) | Own MLA + mHC architecture. Apache-2.0. 2026-09-16 | no GGUF seen | 4B | No | none found | 9,247 (1,857 likes) | **No llama.cpp support found** (UNVERIFIED) | Tau3-Bench 64.6, Claw-Eval 76.6, Terminal-Bench 2.1 57.5 (VENDOR). |
| poolside/Laguna-XS-2.1 | Own base. OpenMDW-1.1. 2026-06-20 | official Q4_K_M 20.27 GB | 3B | No | official GGUF | 638,881 | llama.cpp | Under Qwen3.6-35B-A3B on its own card (Terminal-Bench 2.0 37.5 vs 51.5, SWE-bench Verified 70.9 vs 73.4, VENDOR). Dropped. |
| tencent/Hy-Memory-30B-A3B, KRAFTON Raon-1-mini (gated), GrootTeam Groot-19B-A3B, LiquidAI LFM2.5-24B-A2B, Nemotron 3.5 Lightning | various | | 2 to 4B | text | | | | Memory model, Korean chat (gated), tiny REAP-like, hybrid, AA 12.9. None aimed at Perry. |

Rejected tunes of the MoE class, with the reason:

- **Qwen3.8-35B-A3B-Distill** (empero): MMLU and ARC loglikelihood only, no agent test.
- **Iris-mini, XYZ-Aquila-mini, T-Search, Apodex-1.1-mini**: web-search agents (BrowseComp 82 and similar, VENDOR). Not screen or tool-call work.
- **Sage-A1.5, SNEX-V1** (Sage + Nex merge): science agent; the merge's author says it is "not shown to improve".
- **KAT-Coder-V2.5-Dev, Humo-Coder, Tiel-Coder siblings**: coding.
- **Ornith REAP-50** (Ttimms, 19B, GGUF Q4_K_M 11.4 GB): expert-pruned to half. HumanEval+ 84.2% and MBPP+ 89.2% at NVFP4 on single greedy draws (VENDOR); SWE-bench Verified 44.0% against 79 for the unpruned model (VENDOR, both cards). Halving the experts costs a lot. No vision (vision tower stripped).
- **Qwen3.6 RAZOR/REAP prunes** (19B, 28B), **Flash-Next 40B prune**: the prune author reports GPQA 27.8% (near chance), MATH-500 17.8%, IFEval prompt-strict 37% for the 40B. Pruning is not a free speed-up.
- **Muse-Glimmer-30B-GUI-Grounding-Fast** (13 downloads): LoRA, ScreenSpot-v2 87% self-run (VENDOR). Interesting idea: it teaches a model to output the box only, about 5 tokens instead of 200 (VENDOR, card). Not a brain.
- **Qwen-AgentWorld-35B-A3B**: a world simulator. Its agent claims are for RL warm-up, not for acting.
- **DFlash, DSpark, MTP and EAGLE drafts** (hundreds of repos): they speed up a target in Splash or vLLM. In llama.cpp, DFlash drafts are text-only and break image requests (lineup §3.1), so they are off for Perry.

---

## 5. Candidate sheet: dense 20 to 36B

| Model | Base, licence, date | 4-bit file (+ vision) | Vision | Downloads | Engine | Scores and notes |
|---|---|---|---|---|---|---|
| Qwen/Qwen3.8-27B (control) | Apache-2.0, 2026-08-05 | unsloth UD-IQ4_XS 14.25 + 0.93 = **15.18 GB**; UD-Q4_K_XL 17.56 + 0.93 = 18.49 GB; Q5_K_XL 21.81; Q6_K 22.91; Q8_0 29.98 | Yes | 7.5M | llama.cpp, Splash | AA table. OSWorld-Verified 84.3 (VENDOR). |
| **Hcompany/Holo4-27B** | Qwen3.8-27B. **CC BY-NC 4.0** (allowed here). 2026-09-24 | q4_k_m 16.88 + 0.93 = **17.81 GB** | Yes | 1,668 main, 19,281 GGUF | llama.cpp (same arch). Splash plausible (family) | OSWorld-Verified 85.2, OSWorld 2.0 61.7 (VENDOR). Trajectories are public. No replication found. |
| **peculiar-ragdoll/Dirk-Qwen3.8-27B-GGUF** | Qwen3.8-27B weights, terse "Sharp" chat template, MTP head kept. Apache-2.0. 2026-08-14 | UD-IQ4_XS 14.25 + mmproj 0.93 = **15.18 GB** | Yes | 1.34M | llama.cpp | SWE-bench-Live 15/25 vs 16/25 stock, median 20.1 vs 50.2 min. Card says stock Qwen3.8-27B **forces `reasoning_effort=xhigh`** unless overridden (VERIFIED in the template: default is `xhigh`). |
| **Nanbeige/Nanbeige4.3-33B** | Own base. Apache-2.0. 2026-10-24 | bartowski IQ4_XS **18.64 GB** | **No** | 4,785 | llama.cpp (plain `LlamaForCausalLM`, 52 layers) | Against the 27B in its own table: Terminal-Bench 2.1 80.9 vs 73.0, Tau3-Bench 48.8 vs 48.5, Automation 54.2 vs 38.3 (VENDOR). It is a plain dense Llama stack, so no hybrid savings. KV cache is about 208 KiB per token (52 layers x 8 KV heads x 128 x 2 x 2 bytes, my arithmetic from the config), 6.8 GB at 32K, about 3 times the 27B's. Slower and larger than the 27B on a Mac. |
| UI-Mate-27B (Tencent) | Qwen3.6-27B. Apache-2.0 | bartowski GGUF | Yes | 758 | llama.cpp | OSWorld-Verified 77.0 (VENDOR). Older base. |
| Swift-Qwen3.8-27B / Swift-1.5 | licence `other` | like base | Yes | 3,936 / 8,409 | llama.cpp | 58% fewer thinking tokens (VENDOR). Deep lane only. |
| Qwopus3.8-27B-Flash, Tess-4.5, Signal-3.8, Carnice-V3 | Qwen3.8-27B | like base | Yes | 832, 549, 9,600, 69 | llama.cpp | Carnice-V3's own card: "weaker long-horizon completion and tool-contract performance than the base model" (VENDOR, self-report against itself). |
| **exnivo/Qwen3.8-20B-Minitron** | Qwen3.8-27B pruned from 64 to 44 layers, distilled back. Apache-2.0. 2026-08-16 | no GGUF seen | Yes (tower kept, untrained) | 127 | none yet | 19.7B parameters. Internal custom checks only (81% overall; pattern reasoning 20%). Author: "should not be assumed to match the 27B". A depth-pruned speed variant that would run about 28% faster if it held up. Untested. |
| Gemma 4 31B | Apache-2.0 | | Yes | 8.4M | llama.cpp | AA 14.7. Out. |
| Nemotron 3.5 Bolt 74B-A9B-24GB | OpenMDW-1.1 | 22.02 + 1.73 GB native 2-bit | Yes | 10,877 | UNVERIFIED | AA 21.4 (INDEPENDENT). Under the 27B at low effort. |
| ByteDance Seed-OSS-36B, Devstral Small 2, Mistral Small 3.2, Granite 4.2 30B, Muse Glimmer 30B | various | | mixed | | | AA: Granite 12.7, Glimmer 17.5; others have no current AA row. Out. |

---

## 6. Candidate sheet: big MoE for 64 GB and 96 to 128 GB (up to about 70 GB at 4-bit)

Usable GPU memory is about 75% of RAM (r8, lineup). That is 48 GB on a 64 GB Mac, 72 GB on 96 GB, 96 GB on 128 GB.

| Model | Params (total-active) | Licence, date | Files (VERIFIED) | Vision | AA | Fit and speed |
|---|---|---|---|---|---|---|
| **Qwen3.8-Flash-Next** | 125B-6B plus 51B n-gram table (180B on disk) | licence `other` (qwen-community-1.0), 2026-08-24 | ISTA GSQ-RCO Q2_0 **66.4 GB** (37.62 + 28.80); unsloth UD-IQ3_XXS 81.9 GB, UD-Q4_K_XL 111.3 GB, UD-IQ4_XS 93.7 GB | Yes | **39.8** (INDEPENDENT) | Splash: **95 tok/s decode, 1,312 tok/s prefill at 32K, 171 ms cached TTFT** on an M5 Pro 64 GB (VENDOR). llama.cpp can load the unsloth files (UNVERIFIED speed). 96 GB and up. |
| **Ornith-1.5-122B** | 125B, about 10B active (UNVERIFIED; 256 experts, 8 per token, same shape as Qwen3.5-122B-A10B) | MIT, 2026-10-16 | unsloth UD-IQ3_XXS 49.5 GB, UD-Q3_K_XL 59.8 GB, Q4_K_M 75.8 GB, UD-Q4_K_XL 79.7 GB, mmproj 0.91 GB | Yes | none | vs Qwen3.8-27B in its own table: TB 2.1 81.2 vs 71.9, SWE-bench Verified 84.5 vs 76.8, MCP-Atlas 74.6 vs 69.0, Toolathlon 70.8 vs 67.1, ClawEval 79.4 vs 75.4 (VENDOR). Splash 1.4.1 serves it. 96 GB at Q3_K_XL, 128 GB at Q4. About 3 times the work per token of an A3B MoE (my arithmetic). |
| Ling-3.0-flash-VL (inclusionAI) | 124B-5.5B | MIT, 2026-09-04 | bartowski IQ4_XS 69.4 GB, IQ3_M 67.6 GB, mmproj 0.88 | Yes | 24.6 | 96 GB and up. Under the 27B at medium. |
| Nemotron 3.5 Super VL | 124B-12B | OpenMDW-1.1, 2026-10-12 | unsloth UD-IQ3_XXS 59.8 GB, UD-Q4_K_XL 86.9 GB; mmproj 1.73 | Yes | 26.5 | OSWorld-Verified 51.1 on its own card (VENDOR). Out. |
| Kolibri-1 (Aleph Alpha) | 78B-3.46B | Apache-2.0, 2026-10-03 | bartowski IQ4_XS **43.6 GB**, Q4_K_M 49.8 GB | **No** | none | German and English reasoning model. A3B-class speed in 44 GB. No vision, no screen reading. Watch item for a 64 GB text lane. |
| Qwen3.5-122B-A10B | 122B-10B | Apache-2.0, 2026-02-24 | similar to Ornith-122B | Yes | 15.6 to 17.7e | Older, under the 27B. Out. |
| gpt-oss-120b | 117B-5B | Apache-2.0, 2025-08 | ggml-org MXFP4 **63.4 GB** | No | 11.6 | Fast, weak (Tau3-Banking 12.8). Out. |
| Laguna S 2.1 | 118B-8B | OpenMDW-1.1 | official Q4_K_M 96.0 GB | No | none | Over the memory budget. Out. |
| GLM-4.5-Air, Mistral Small 4 119B, Qwen3-Next-80B, Seed-OSS | | | | | 9 to 11.3 | Old and weak. Out. |

Verdict for these classes: on independent evidence, Flash-Next is the only model that beats the 27B. On vendor evidence, Ornith-122B does. Neither is a speed play. The 27B at Q6 or Q8 stays the "Large" lane on 64 GB. Flash-Next on Splash is the optional "Max" lane on 96 to 128 GB. Quality at Q2_0 is vendor-claimed only. The lineup's earlier read was KL divergence about 0.23 at sizes that fit a 64 GB Mac (not re-checked).

---

## 7. How to turn thinking off, per model (template facts VERIFIED today)

Perry's interactive lane passes `enable_thinking:false`. That works for most of the list but not for Nex.

| Model | Switch (llama-server) | Notes |
|---|---|---|
| Qwen3.8-27B, Holo4-27B, Dirk | `--chat-template-kwargs '{"enable_thinking":false}'` | Template default is `reasoning_effort=xhigh`. The deep lane sets `{"reasoning_effort":"medium"}` or `"low"` (VERIFIED). Dirk's template defaults to medium and adds a terseness prompt. |
| Ornith-1.5-35B-A3B | `{"enable_thinking":false}` | The template honours it (VERIFIED, 2 occurrences). r8 flagged "no documented off switch". The template says otherwise. Behaviour still needs a 5-prompt check. |
| Occamy-1.0, Nanbeige4.3-33B | `{"enable_thinking":false}` | VERIFIED in the templates. Both also have `preserve_thinking`. |
| **Nex-N2.5-mini** | `{"reasoning_effort":"none"}` | VERIFIED: the template renders `<think>\n\n</think>` for `none`, an open `<think>` otherwise, and has **no** `enable_thinking`. `enable_thinking:false` would be ignored and the model would think. |
| Splash (any supported model) | request `"reasoning_effort":"none"` or `--default-reasoning-effort none` | Splash maps it to `enable_thinking=false` and passes `reasoning_effort` too, so both template styles follow it (VERIFIED, DEVELOPMENT.md). Flint is the exception. |

---

## 8. Recommended lineups, weighted for speed

Rules I used. (1) The "Best" slot is a 3B-active MoE, because the owner prefers faster. (2) The "Large" slot is the most accurate model that still fits next to the user's other work, usually the dense 27B. (3) Both lanes cannot be resident together on 32 to 48 GB, so Perry swaps (`--sleep-idle-seconds`). (4) Downloads are weights plus the vision file. (5) Anything marked "pending" waits for the local test in §9.

Files:

- 9B: `unsloth/Qwen3.5-9B-GGUF` UD-Q4_K_XL 5.97 + 0.92 = 6.89 GB, UD-Q6_K_XL 8.76 + 0.92 = 9.68 GB.
- Qwen3.6-35B-A3B: `unsloth/Qwen3.6-35B-A3B-GGUF` UD-IQ4_XS 18.63 GB, UD-Q4_K_XL 23.26 GB.
- Ornith-35B: `bartowski/Ornith-1.5-35B-A3B-GGUF` IQ4_XS 20.18 GB, Q4_K_M 22.76 GB, Q5_K_M 26.39 GB, Q6_K 31.43 GB, Q8_0 38.71 GB (each plus mmproj 0.90).
- Qwen3.8-27B: `unsloth/Qwen3.8-27B-GGUF` UD-IQ4_XS 15.18 GB, UD-Q4_K_XL 18.49 GB, UD-Q6_K 22.91 GB, Q8_0 29.98 GB.

| Mac | Small | Best for this Mac | Large | Why |
|---|---|---|---|---|
| **32 to 36 GB** (usable 24 to 27 GB) | Qwen3.5-9B UD-Q4_K_XL, 6.89 GB | **Ornith-1.5-35B-A3B IQ4_XS, 20.18 GB** (pending). Fallback: Qwen3.6-35B-A3B UD-IQ4_XS, 18.63 GB. | Qwen3.8-27B UD-IQ4_XS, 15.18 GB (swaps with Best) | 20 GB fits 24 GB usable with a 32K context. On a 36 GB M3 Pro (150 GB/s) the 27B is slow, about 8 tok/s (lineup §3.9). |
| **48 GB** (usable 36 GB) | Qwen3.5-9B UD-Q6_K_XL, 9.68 GB | **Ornith-1.5-35B-A3B Q4_K_M, 22.76 GB** (pending). Action-lane challenger: Nex-N2.5-mini Q4_K_M 23.22 GB. | Qwen3.8-27B UD-Q4_K_XL, 18.49 GB. Action lane challenger: Holo4-27B, 17.81 GB. | The lineup picks UD-Q5_K_XL for the 27B. I pick Q4_K_XL for speed (21.81 vs 18.49 GB, about 15% more tokens per second). Both together are 41 GB, over 36 GB usable. |
| **64 GB** (usable 48 GB) | Qwen3.5-9B UD-Q6_K_XL, 9.68 GB | **Ornith-1.5-35B-A3B Q6_K, 31.43 GB** (pending). Q5_K_M 26.39 GB leaves room for the 27B. | Qwen3.8-27B UD-Q6_K, 22.91 GB | Best + Large at Q5_K_M + Q6_K = 49.3 GB, just over. Use Q5_K_M + UD-Q4_K_XL (44.9 GB) to keep both resident. No big MoE fits at useful quality. |
| **96 to 128 GB** (usable 72 to 96 GB) | Ornith-1.5-35B-A3B Q4_K_M, 22.76 GB | **Ornith-1.5-35B-A3B Q8_0, 38.71 GB** (pending) | **Qwen3.8-27B Q8_0, 29.98 GB**, resident beside Best. Optional Max lane for Splash users: Qwen3.8-Flash-Next ISTA Q2_0, 66.4 GB (needs 96 GB, comfortable at 128 GB). | The only model above the 27B on independent evidence is Flash-Next, and only on Splash. Ornith-1.5-122B UD-Q3_XXS 49.5 GB is the llama.cpp alternative, vendor-claimed only, and about 3 times slower per token than the 35B. |

Plain-English reading for the Setup screen. Small: quick and light. Best: "a big brain that only wakes part of itself for each word, so it feels fast". Large: "the most careful option, slower, use it for hard jobs".

If the owner dislikes shipping an unproven tune as "Best", keep Qwen3.6-35B-A3B in that slot and put Ornith or Nex behind a "try this faster-to-act model" switch until Perry-bench passes it.

Licence note: Ornith is MIT, Nex and Occamy are Apache-2.0, Qwen is Apache-2.0, Holo4-27B is CC BY-NC 4.0 (allowed for this free non-commercial app), Flash-Next is `other` (qwen-community-1.0, read it before bundling), Ling and Laguna are MIT and OpenMDW.

---

## 9. Ranked shortlist to benchmark on the 48 GB M4 Pro with about 21 GB free

Disk rule: one model file plus its vision file at a time. Download, test, write a JSON result, delete. All five fit if the previous one is deleted. Four of the five leave under 2 GB spare, so close big apps and delete the Hugging Face cache between runs. I downloaded none of them.

Shared harness: r8's P4 (50 Perry tasks: screen questions, one-step actions, five-step plans), thinking off, the `LocalEngine.swift` flags (`-ngl all -fa on -c 32768 -np 1 --image-max-tokens 640 --cache-ram 2048 --ctx-checkpoints 8 --checkpoint-min-step 1024 --jinja`), three runs each. Add tool-eval-bench v2.5.1 (69 scenarios, MIT) so the Ornith 91/100 run is reproducible against the controls. Controls: Qwen3.8-27B UD-IQ4_XS and Qwen3.6-35B-A3B UD-IQ4_XS. Run them first and keep only their result files.

Log for each run: time to first token, decode tok/s, step success, valid-JSON rate, stop-and-ask probe (a Send button, an ambiguous goal), and the 5-prompt thinking-off check.

| Rank | Model | Repo and exact files | Download | Why it is on the list | Engine and thinking-off switch | Adopt rule |
|---|---|---|---|---|---|---|
| 1 | **Ornith-1.5-35B-A3B** | `bartowski/Ornith-1.5-35B-A3B-GGUF`: `Ornith-1.5-35B-A3B-IQ4_XS.gguf` + `mmproj-Ornith-1.5-35B-A3B-f16.gguf` | **20.18 GB** (19.28 + 0.90) | Biggest download base (3.9M GGUF), MIT, Splash family, community tie with the 27B on easy tool tasks, a Mac-side agent result that favours the MoE shape. Weak on knowledge. | llama-server, `--chat-template-kwargs '{"enable_thinking":false}'`. Splash: `reasoning_effort:"none"`. | Fast lane if within 3 step-success points of the 27B and the reference turn is 6 s or less. Else keep Qwen3.6-35B-A3B. |
| 2 | **Nex-N2.5-mini** | `bartowski/nex-agi_Nex-N2.5-mini-GGUF`: `nex-agi_Nex-N2.5-mini-IQ3_M.gguf` + `mmproj-nex-agi_Nex-N2.5-mini-f16.gguf` | **19.86 GB** (18.96 + 0.90). IQ4_XS is 20.79 GB and leaves 0.2 GB, so use IQ3_M or free 2 GB first. | The strongest GUI and agent numbers I found at A3B size (OSWorld-Verified 71.2, OSWorld-G 82.9, Terminal-Bench 73.4, Toolathlon 54.6, all VENDOR). Earlier reports missed it. Vision included. | llama-server, `--chat-template-kwargs '{"reasoning_effort":"none"}'`. **Not** `enable_thinking`. | Replace rank 1 if it beats Ornith by 3 points on the 40 recorded screen steps at similar speed. Re-test IQ4_XS if IQ3_M looks degraded. |
| 3 | **Holo4-27B** | `Hcompany/Holo4-27B-GGUF`: `q4_k_m.gguf` + `mmproj.f16.gguf` | **17.81 GB** (16.88 + 0.93) | Same base, same speed and same engine as the 27B. Only tune with a vendor lead on screen actions (85.2 vs 84.3, and 61.7 vs 48.0 on OSWorld 2.0). | llama-server, `{"enable_thinking":false}`. CC BY-NC 4.0 is allowed here. | Action lane if it wins by 5 step-success points and holds the JSON rate within 3 points. |
| 4 | **Occamy-1.0** | `Accio-Lab/occamy-1.0-GGUF`: `occamy-1.0-IQ4_XS.gguf` + `mmproj-occamy-1.0-F16.gguf` | **19.63 GB** (18.73 + 0.90) | The clearest Tau3-Banking claim (37.1 vs 11.9 for its base, VENDOR) on the base's weakest test. | llama-server, `{"enable_thinking":false}` | Keep only if it beats Qwen3.6-35B-A3B by 10 points and does not lose to Ornith or Nex. Skip if ranks 1 and 2 already win. |
| 5 | **Dirk-Qwen3.8-27B** (Sharp template) | `peculiar-ragdoll/Dirk-Qwen3.8-27B-GGUF`: `Dirk-Qwen3.8-27B-UD-IQ4_XS.gguf` + `mmproj-F16.gguf` | **15.18 GB** (14.25 + 0.93) | Same weights as the 27B with a terse system prompt and the xhigh default removed. Community data: 15 vs 16 fixes in 40% of the time. Tests whether the "terse" prompt is a free speed-up for the deep lane. | llama-server, `{"enable_thinking":false}` for interactive. Deep lane: `{"reasoning_effort":"medium"}`. | Test the terse prompt on the stock 27B first: copy the prompt text from the Nail card (published). If that wins, skip this download. |

Not on the list, with the reason:

- **Nanbeige4.3-33B** (tunes-deep rank 3): text only. A plain dense Llama stack, so slower and with a 3-times larger KV cache than the 27B. Vendor lead is on tool benchmarks, but Perry needs vision.
- **Holo4-35B-A3B**: 22.20 GB, does not fit the free disk.
- **Qwen3.8-Flash-Next, Ornith-1.5-122B**: do not fit a 48 GB Mac.
- **Whittle-Qwen-3.8-35B-A3B**: text only, one author, greedy decoding loops. Re-check in a month.
- **Tiel-Coder IQ4_XS** (17.73 + 0.90 = 18.63 GB): same weights as rank 1 with a different quant and template. Use it only if the bartowski file is short on disk or the Sharp template matters.
- **Flint, Laguna XS, K2 Horizon, Xing4.0**: text only, or no llama.cpp path, or under Qwen3.6 on their own cards.
- **Qwen3.8-20B-Minitron**: no GGUF. Revisit if a quant appears with an independent score.
- **ISTA, ByteShape, Bonsai, Mirai**: compressions, not better models (tunes-deep §3.4).

Zero-download experiments worth doing first:

1. Copy the Sharp terse prompt (Nail card, "The secret sauce") onto the existing Qwen3.8-27B and Qwen3.6-35B-A3B runs and measure answer length and time (UNVERIFIED gain, vendor says -59% answer tokens on a 27B base).
2. Run `reasoning_effort:"none"` against the current Qwen3.8-27B template. Its default is xhigh. If Perry's interactive lane ever omits `enable_thinking:false`, it will think at the maximum.
3. Check Splash on the M4 Pro with the same files, if the owner approves the engine: `splash serve --model unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M --default-reasoning-effort none`. The vendor says 4.5 to 5.3 times the llama.cpp speed on a 27B. Nobody independent has measured it on an M4 Pro.

---

## 10. Not verified

- Every tune score: Ornith, Nex, Occamy, Holo4, Nanbeige, Whittle, Tiel and Dirk numbers are VENDOR or COMMUNITY. No AA row, OSWorld board row or replication exists for any of them.
- Whether any tune keeps its edge with thinking off. Every card measures with reasoning on, except Nex's Tau/Toolathlon runs, whose mode I did not find.
- My Mac speeds for the M4 Pro: 6 s (MoE) and 27 s (27B) per step are arithmetic from r8 and lineup anchors. The nearest measurements are community runs on an M5 Pro (llama.cpp 81.96 tok/s, Qwen3.6-35B-A3B) and an M4 Pro (oMLX 85 to 86; Flint 79.6).
- Splash on an M4 Pro for any model. Splash support for Nex-N2.5-mini, Holo4 and Occamy (the docs say "compatible fine-tunes" of the two families; I verified Ornith by name only).
- Nex-N2.5-mini's base model (second hand) and its OSWorld harness.
- Ornith-1.5-122B active parameters, Flash-Next quality at Q2_0, llama.cpp speed for Flash-Next, Ling-3.0-flash-VL and Kolibri on Metal.
- Whether `occamy-ai/occamy-1.0` (the bartowski mirror name) is the same weights as Accio-Lab's (tunes-deep, unresolved).
- Whether the Sharp template's terseness helps or hurts Perry's strict-JSON tool calls. The author's v22.3.1 notes say it fixes the thinking-off path with tools, but I did not run it.
- LMArena, BFCL, OSWorld and ScreenSpot boards: unreadable or stale. Reddit hands-on threads: not found.

---

## Sources

Hugging Face API and cards (all read 2026-10-27):

- Tree walks: https://huggingface.co/api/models?filter=base_model:finetune:ornith-ai/Ornith-1.5-35B-A3B (and merge, adapter, quantized; same for ornith-ai/Ornith-1.5-122B, ornith-ai/Ornith-1.5-9B, Qwen/Qwen3.8-27B, Qwen/Qwen3.6-35B-A3B, Qwen/Qwen3.8-Flash-Next, google/gemma-4-31B-it, google/gemma-4-26B-A4B-it, openai/gpt-oss-120b, openai/gpt-oss-20b, zai-org/GLM-4.5-Air, zai-org/GLM-4.7-Flash, poolside/Laguna-XS-2.1, poolside/Laguna-S-2.1, Nanbeige/Nanbeige4.3-33B, RecursiveSI/flint, Accio-Lab/occamy-1.0, Hcompany/Holo4-27B, Hcompany/Holo4-35B-A3B, IFM/K2-Horizon-MoVA-36B-A4B, nex-agi/Nex-N2.5-mini, Qwen/Qwen-AgentWorld-35B-A3B, ByteDance-Seed/Seed-OSS-36B-Instruct, moonshotai/Kimi-Linear-48B-A3B-Instruct, Aleph-Alpha/Kolibri-1, Qwen/Qwen3.5-122B-A10B, Qwen/Qwen3-Next-80B-A3B-Instruct, inclusionAI/Ling-3.0-flash-VL, InternScience/Sage-A1.5, meta-models/Muse-Glimmer-30B, nvidia Nemotron 3.5 Super VL)
- https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B and https://huggingface.co/ornith-ai/Ornith-1.5-122B (benchmark tables, chat template)
- https://huggingface.co/bartowski/Ornith-1.5-35B-A3B-GGUF, https://huggingface.co/unsloth/Ornith-1.5-122B-GGUF
- https://huggingface.co/nex-agi/Nex-N2.5-mini and https://huggingface.co/bartowski/nex-agi_Nex-N2.5-mini-GGUF
- https://huggingface.co/peculiar-ragdoll/Tiel-Coder-35B-A3B-GGUF, https://huggingface.co/peculiar-ragdoll/Dirk-Qwen3.8-27B-GGUF, https://huggingface.co/peculiar-ragdoll/Nail-Qwen3.6-35B-A3B-GGUF, https://huggingface.co/peculiar-ragdoll/Qwen-Sharp-Chat-Templates
- https://huggingface.co/Ttimms/Ornith-1.5-35B-A3B-REAP-50-GGUF
- https://huggingface.co/logic65/Whittle-Qwen-3.8-35B-A3B and https://huggingface.co/logic65/Whittle-Qwen-3.8-35B-A3B-GGUF
- https://huggingface.co/Davd-b01/qwen3.8-flash-next-40b-prune-research
- https://huggingface.co/exnivo/Qwen3.8-20B-Minitron, https://huggingface.co/kai-os/Carnice-V3, https://huggingface.co/Blockway/Agens-Pilot
- https://huggingface.co/poolside/Laguna-XS-2.1, https://huggingface.co/poolside/Laguna-S-2.1, https://huggingface.co/poolside/Laguna-XS-2.1-GGUF
- https://huggingface.co/Aleph-Alpha/Kolibri-1, https://huggingface.co/bartowski/Kolibri-1-GGUF
- https://huggingface.co/inclusionAI/Ling-3.0-flash-VL, https://huggingface.co/bartowski/Ling-3.0-flash-VL-GGUF
- https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-BF16, https://huggingface.co/unsloth/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-GGUF
- https://huggingface.co/XingChen-AGI/Xing4.0-29B-A4B, https://huggingface.co/InternScience/Sage-A1.5, https://huggingface.co/gbuzhf/SNEX-V1, https://huggingface.co/AllSpark-Research/Iris-mini
- https://huggingface.co/empero-ai/Qwen3.8-35B-A3B-Distill, https://huggingface.co/lemuralabs/Muse-Glimmer-30B-GUI-Grounding-Fast, https://huggingface.co/Qwen/Qwen-AgentWorld-35B-A3B
- https://huggingface.co/Nanbeige/Nanbeige4.3-33B (config and chat template), https://huggingface.co/bartowski/Nanbeige_Nanbeige4.3-33B-GGUF
- https://huggingface.co/Hcompany/Holo4-27B-GGUF, https://huggingface.co/Hcompany/Holo4-35B-A3B-GGUF, https://huggingface.co/Accio-Lab/occamy-1.0-GGUF
- https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF, https://huggingface.co/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF, https://huggingface.co/ggml-org/gpt-oss-120b-GGUF

Independent and community evidence:

- Artificial Analysis leaderboard (parsed): https://artificialanalysis.ai/leaderboards/models
- InsiderLLM, Ornith 1.5 35B vs Qwen 3.6 35B on RTX 3090: https://insiderllm.com/guides/ornith-1-5-35b-vs-qwen-3-6-35b-rtx-3090/
- KGP Talkie (via tunes-deep): https://kgptalkie.com/tutorials/llm-benchmarking/ornith-1-5-9b-vs-35b-a3b-benchmark
- LLMCheck, Flint and Qwen3.6-35B-A3B on Mac: https://llmcheck.net/blog/recursive-flint-on-mac/
- oMLX community runs on M4 Pro 48 GB: https://omlx.ai/benchmarks/5zxiqdh8, https://omlx.ai/benchmarks/cooa5fyn, https://omlx.ai/benchmarks/ivmnze5g, https://omlx.ai/benchmarks/gujo2ju6
- NVIDIA forum tool-eval-bench (via tunes-deep): https://forums.developer.nvidia.com/t/deepreinforce-ornith-1-5-family-released/380623/2
- Reddit anecdote on Nex-N2-mini vs Qwen3.6-27B: https://reddit.sentinel-team.org/posts/1u37ckw/snapshots/2026-06-13T02%3A56%3A06.64152Z
- Aggregators counted as VENDOR: https://benchlm.ai/compare/ornith-1-5-35b-a3b-vs-qwen3-6-35b-a3b, https://www.mindstudio.ai/blog/ornith-1-5-35b-a3b-benchmarks, https://benchmarklist.com/models/nex-agi-nex-n2.5-mini/
- H Company trajectories and Holo4 coverage: https://aiweekly.co/alerts/h-company-ships-holo4-agents-27b-hits-617-on-osworld-20

Engines:

- Splash README: https://github.com/incoai/splash, DEVELOPMENT.md: https://github.com/incoai/splash/blob/main/DEVELOPMENT.md, release notes: https://github.com/incoai/splash/releases/tag/1.4.1 (also 1.4.0, 1.3.2, 1.3.1, 1.3.0)
- llama.cpp releases: https://github.com/ggml-org/llama.cpp/releases (b11928, 2026-10-27)

Earlier reports in this repo: `docs/research/2026-10-27/large-tunes-deep.md`, `local-model-lineup.md`, `finetunes-and-cua.md`, `docs/research/2026-10-25/r8-local-models-best.md`.
