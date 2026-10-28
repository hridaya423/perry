# SOTA for the tiny tier: best model up to about 4B for Perry

Date: 2026-10-27. Author: research sub-agent. Status: final. Research only. I downloaded no weights, ran no model, and built nothing. Every speed here is a source or my own arithmetic, and I say which.

This extends `local-model-lineup.md`, `finetunes-and-cua.md` and `large-tunes-deep.md` in this folder, and `docs/research/2026-10-25/r8-local-models-best.md`. I do not repeat their tables. Where they already cover a model I add only what is new.

## Summary (15 lines)

1. Nothing new and official exists in range. Qwen has shipped no model below 27B since Qwen3.5 0.8B/2B/4B (2026-02-27/28, VERIFIED, HF API). Google, Mistral, IBM and Microsoft have shipped no newer small vision model either. The tiny tier is still Qwen3.5 plus derivatives.
2. The cost of a Perry click step is mostly prefill (screenshot tokens plus the vision encoder), not decode. Liquid says so in plain words: speculation "does not accelerate" prefill (VENDOR, Liquid blog). So size and image token count buy speed. Draft heads and MTP do not.
3. Scaling the owner's 9B anchor (15/16 clicks at 1.4 s) by file size, a 4B should take about 0.7 s, a 2B about 0.4 s and a 0.8B about 0.15 s (UNVERIFIED, arithmetic, section 1). Measure before trusting any of it.
4. Independent evidence is thin. The only INDEPENDENT scores are Artificial Analysis (AA) rows for base models. No tune has an AA row, a BFCL row, or a leaderboard row. I found no r/LocalLLaMA or GitHub eval of a small GUI tune.
5. The best independent hint is a warning. Three outside teams measured the same Qwen3.5 base and got very different grounding scores. Qwen3.5-4B ScreenSpot-Pro: 60.3 on Qwen's card (VENDOR) against 30.2 from DeskForge's harness (third party). Qwen3.5-2B ScreenSpot-v2: 66.5 (Liquid) against 86.25 (gui-assist-grounder). The prompt and coordinate format decide the score. Test every model in the format it was trained on.
6. Strongest tune for Perry's 16 GB slot: DeskForge-Qwen3.5-4B v1.1 (Apache-2.0, 2026-09-30). Against its own base, same harness, held-out: ScreenSpot-v2 80.11 to 92.14, ScreenSpot-Pro 30.17 to 49.02, OSWorld-G 51.24 to 63.83 (VENDOR, authors ran both rows). Same architecture as Qwen3.5-4B, so it needs no new engine. No GGUF exists yet; conversion is needed.
7. Strongest non-Qwen3.5 tune: GUI-Owl-1.5-4B-Instruct (MIT, Qwen3-VL base). Claims ScreenSpot-Pro 66.8, ScreenSpot-v2 93.2, OSWorld-Verified 48.2 (VENDOR, paper). Community GGUF exists (2.50 GB + 0.45 GB). Its 2B sibling claims OSWorld-Verified 43.5 (VENDOR), above Qwen3.5-4B's 35.6 (VENDOR), in 1.56 GB.
8. Best 8 GB find: patrickballou/gui-assist-grounder, a LoRA on Qwen3.5-2B (Apache-2.0, 2026-10-17, 52 downloads). Emits `{"point_2d": [x, y]}` on a 0 to 1000 grid. ScreenSpot-v2 86.25 to 90.35, macOS split 73.4 to 92.4 (VENDOR, same harness). The authors also checked it on a Mac. It only grounds. It cannot plan or chat.
9. Speed tricks are mostly dead ends here. Qwen3.5 MTP in llama.cpp does not run with `--mmproj` (VERIFIED, Unsloth card). DFlash and EAGLE3 drafts target SGLang/vLLM. LFM and MiniCPM DSpark drafts exist, but nobody reports image prefill gains. I found no depth-pruned or layer-reduced Qwen3.5 with vision and with evidence.
10. Distills of big reasoning or agent models exist at 0.8B to 4B (Qwen3.8-4B-Distill with 258,029 downloads, Claude-Opus distills, a Qwen3.8-27B GUI distill into Qwen3-VL-4B). Most are text only or mobile only. None has independent evidence. The Claude and other closed-teacher distills carry unclear teacher terms.
11. Non-Qwen small VLMs lose on tool use. AA: Gemma 4 E4B 9, Ministral 3 3B 5, LFM2.5-VL-1.6B 5* (INDEPENDENT, VERIFIED today) against Qwen3.5-4B 13* (* means AA estimated it). Gemma 4 E4B tau2 is 42.2 and E2B 24.5 (VENDOR, Google card). Keep LFM2.5-VL-3B only as a speed wildcard.
12. Dead ends I checked and dropped: Ternary-Bonsai-2 (a 4B in 1.15 GB, but speed gain is decode only and quality is unmeasured), GoClick (230M Florence-2 grounder, not llama.cpp), AUBIN Gemma 4 screen tune (ScreenSpot 69.3), GELab-Zero, GUI-Libra (Android), Holo2/3.1 (no usable numbers in text).
13. Ranked shortlist of 5 for the 16 GB mini: Qwen3.5-4B (control), DeskForge-Qwen3.5-4B v1.1, GUI-Owl-1.5-4B-Instruct, Qwen3.5-2B (control), GUI-Owl-1.5-2B-Instruct. Section 6 has exact files, sizes, coordinate formats and flags.
14. Provisional picks: 16 GB gets Qwen3.5-4B UD-Q4_K_XL (3.58 GB) with escalation to the 9B when a click fails the JSON or bounds check. 8 GB gets Qwen3.5-2B UD-Q4_K_XL (2.01 GB). Both are provisional until the mini runs the five.
15. Not verified: any seconds-per-step for any model here, every GUI score, the prompt format of GUI-Owl and DeskForge under an enforced JSON schema, and whether llama.cpp handles the DeskForge and gui-assist conversions. Section 8 lists the rest.

---

## 0. Method, labels and limits

**Labels.**
- **VERIFIED**: I read it today from the HF API, a file listing, a model card, a repo file, or the AA page. Includes sizes, dates, licences, downloads, and the numbers printed on a card (the card text is verified; the claim in it is still the author's).
- **VENDOR**: the author published the score. I read it. Nobody checked it.
- **INDEPENDENT**: measured by a party that did not train the model. I name who.
- **UNVERIFIED**: second hand, or my arithmetic. I name the formula.
- Downloads are HF's rolling 30-day count. They measure popularity, not quality.

**What I walked.**
- I walked the full `finetune`, `merge` and `adapter` trees through `https://huggingface.co/api/models?filter=base_model:<rel>:<repo>`, all pages, for 29 bases: Qwen3.5 0.8B, 2B, 4B; Qwen3-VL 2B and 4B (Instruct and Thinking); Qwen2.5-VL-3B; Gemma 4 E2B-it and E4B-it; MiniCPM-V 4.6 and 4.7-1B; LFM2.5-VL 1.6B and 3B, LFM2-VL-3B; SmolVLM2-2.2B; Ministral-3-3B; InternVL3.5 1B, 2B, 4B; granite-vision-4.1-4b; Phi-4-multimodal; moondream2; FastVLM 0.5B and 1.5B; Florence-2-large; WeVisOne-VL 2B and 4B; nvidia LocateAnything-3B.
- That returned 8,444 derivative records (8,443 distinct repos). Of those, 7,433 have under 100 downloads, 3,901 have under 10, 198 have 1,000 or more, and 258 are abliterated or uncensored. Because I paged to the end, a separate recency sort adds nothing. I read the list by download rank, then by keyword (GUI, ground, agent, tool, json, distill, flash, prune, draft, DFlash, MTP, EAGLE) across the low-download tail.
- Tree sizes (finetune/merge/adapter): Qwen3.5-0.8B 583/3/497. Qwen3.5-2B 632/3/277. Qwen3.5-4B 1,135/21/861. Qwen3-VL-2B-Instruct 289/0/118. Qwen3-VL-4B-Instruct 506/2/230. Qwen2.5-VL-3B 889/0/307. Gemma 4 E2B 426/4/225. Gemma 4 E4B 436/3/436. SmolVLM2-2.2B 46/0/31. LFM2.5-VL-3B 21/0/1. MiniCPM-V-4.7-1B 13/0/1. Ministral-3-3B 38/0/7. Others are under 60.
- I did not walk the `quantized` relation for every base. My first attempt returned zero rows because of a tooling bug, which I fixed for the later run. I spot-checked `quantized:` for the shortlist repos only.
- I searched HF for new small vision models by `num_parameters` and by `createdAt`, `downloads`, `likes` and `trendingScore`. I also listed the newest repos of Qwen, Google, Liquid, OpenBMB, HF, IBM, Microsoft, Mistral, OpenGVLab, NVIDIA, Apple and prism-ml.
- I read about 40 model cards, including repos with under 100 downloads.
- I parsed the AA leaderboard page today (274 rows).
- Web searches for independent evidence (BFCL rows, ScreenSpot-Pro boards, LocalLLaMA tests, Mac speed tests) returned nothing usable for these models. I list what they did return.

**Exclusions.** Same as the earlier reports: abliterated and uncensored builds (Perry clicks Send and Delete on screens that can carry injected text), no-licence repos, non-commercial research-only gating that blocks even Perry (none found in range), text-only repacks unless I say so.

**Housekeeping.** I used a short scratch script in `/tmp` for the tree walk and deleted it. The harness keeps its own task output files in a temp folder. I wrote no other file.

---

## 1. What a Perry step costs, and what that means for ranking

**Anchor (owner-supplied, not re-measured by me):** Qwen3.5-9B Q4, llama.cpp, `--image-min-tokens 1024`, enforced JSON schema, 0-1000 coordinates: 15/16 click targets at 1.4 s per step on a 16 GB M4 mini.

**Where the time goes.**
- Prefill: the vision encoder runs on every screenshot patch, then the language model reads about 1,000 image tokens plus text. This is compute bound.
- Decode: a click answer is short, so decode is a smaller part. Spoken answers are longer, and there decode matters.
- Liquid states it directly for edge devices: prefill is a larger share of latency, and speculation does not accelerate it (VENDOR, https://www.liquid.ai/blog/lfm2-5-vl-dspark, summary of the fetched page).
- Doosra, a tool-calling tune, cut its prompt about 8x (2,100 to 280 tokens) because "reading the prompt is the slow part" on a laptop (VENDOR, model card). Short prompts and a small image budget are the cheapest speed levers for any model.

**Scaling by file size (UNVERIFIED).** Formula: 1.4 s times (weights plus mmproj GB) divided by 6.89 GB (the 9B UD-Q4_K_XL 5.97 plus mmproj 0.92). I cannot reconcile 1.4 s with a plain compute estimate for a base M4, so read these as relative factors only. The vision encoder is a fixed cost, so the real gain from 4B to 2B is smaller than the file ratio.

| Model | Weights + mmproj (VERIFIED, HF) | Ratio to 9B | Scaled step (UNVERIFIED) |
|---|---|---|---|
| Qwen3.5-9B UD-Q4_K_XL (anchor) | 5.97 + 0.92 = 6.89 GB | 1.00 | 1.4 s (owner) |
| Qwen3.5-4B UD-Q4_K_XL | 2.91 + 0.67 = 3.58 GB | 0.52 | about 0.7 s |
| GUI-Owl-1.5-4B Q4_K_M, Q8 mmproj | 2.50 + 0.45 = 2.95 GB | 0.43 | about 0.6 s |
| LFM2.5-VL-3B Q4_K_M, Q8 mmproj | 1.67 + 0.58 = 2.26 GB | 0.33 | about 0.45 s |
| Qwen3.5-2B UD-Q4_K_XL | 1.34 + 0.67 = 2.01 GB | 0.29 | about 0.4 s |
| GUI-Owl-1.5-2B Q4_K_M, Q8 mmproj | 1.11 + 0.45 = 1.56 GB | 0.23 | about 0.3 s |
| Qwen3.5-0.8B UD-Q4_K_XL | 0.56 + 0.20 = 0.76 GB | 0.11 | about 0.15 s |

**Chip, not RAM, sets the clock.** An 8 GB M1 has less GPU than a 16 GB M4. Expect the 8 GB class to be slower than these scaled numbers on older chips (UNVERIFIED).

**Qwen3.5 architecture note.** Qwen3.5 small models mix Gated DeltaNet (linear) layers with full attention: 4B has 24 linear and 8 full layers, 2B has 18 and 6 (VERIFIED, HF card and Bonsai card). A Metal kernel for that op landed in llama.cpp; one reported number is 0.8B Q4_K_M tg128 on M4 Max 170 to 213 tok/s (UNVERIFIED, found through a search snippet of the commit). I found no prefill number. Qwen3-VL-based tunes (GUI-Owl, MAI-UI, UI-Venus, Holo2) use plain attention. Whether that is faster or slower on Metal is untested. It is a reason to put a plain-attention model in the benchmark.

---

## 2. Independent evidence ledger

### 2.1 Artificial Analysis (INDEPENDENT, VERIFIED, parsed today from https://artificialanalysis.ai/leaderboards/models)

`*` means AA estimated the index. "Reasoning" and "non-reasoning" are AA's own row labels.

| Model | AA Intelligence Index | Vision | Note |
|---|---|---|---|
| K2 Horizon 3.7B | 16 | no | text only |
| Qwen3.5-9B (non-reasoning) | 13* | yes | reference |
| Qwen3.5-4B (reasoning) | 13* | yes | |
| Qwen3.5-4B (non-reasoning) | 11* | yes | |
| MiniCPM5-2B | 12 | no | text only |
| Qwen3.5-9B (reasoning) | 11 | yes | |
| Granite 4.2 3B | 9 | no | |
| Gemma 4 E4B (reasoning) | 9 | yes | non-reasoning 7* |
| Gemma 4 E2B (reasoning) | 8* | yes | non-reasoning 6* |
| Nanbeige4.1-3B | 8* | no | |
| LFM2.5-2.6B | 8* | no | |
| Qwen3.5-2B (reasoning) | 7* | yes | non-reasoning 6* |
| Phi-4 Mini | 6* | no | |
| Qwen3.5-0.8B (reasoning) | 6* | yes | non-reasoning 5* |
| MiniCPM-V 4.6 1.3B | 6* | yes | |
| LFM2.5-VL-1.6B | 5* | yes | |
| Ministral 3 3B | 5 | yes | measured, not estimated |

Two things stand out. First, the 4B in reasoning mode (13*) ties the 9B without thinking (13*). Compare like with like and the 9B leads: 4B non-reasoning 11* against 9B non-reasoning 13*. That is a gap of 2 estimated points for about half the cost, which fits the owner's rule. Second, no vision model below 4B beats Qwen3.5 on this index.

Earlier reports (copied, not re-read today) give AA tau2 for Qwen3.5-4B at 92.1 (reasoning) and 87.7 (not), 2B at 69.0 and 81.6, 0.8B at 47.7 and 65.2, MiniCPM-V 4.6 1.3B at 87.7 (INDEPENDENT, AA, via `finetunes-and-cua.md` section 0.1).

### 2.2 Outside measurements of grounding for Qwen3.5 small bases

None of these is a neutral leaderboard. Each is a tune author who ran the base in their own harness. They are INDEPENDENT of Qwen, and they show how much the harness matters.

| Model | Benchmark | Qwen's own card (VENDOR) | Outside number | Who measured it |
|---|---|---|---|---|
| Qwen3.5-4B | ScreenSpot-Pro | 60.3 | 30.17 | DeskForge authors: thinking off, greedy, 128 tokens, 2,097,152 pixel cap |
| Qwen3.5-4B | ScreenSpot-v2 | not on card | 80.11 (DeskForge), 78.5 (Liquid) | two separate harnesses |
| Qwen3.5-4B | OSWorld-G / UI-Vision / MMBench-GUI | not on card | 51.24 / 17.24 / 61.83 | DeskForge |
| Qwen3.5-2B | ScreenSpot-Pro | 54.5 | not found | |
| Qwen3.5-2B | ScreenSpot-v2 | not on card | 86.25 (gui-assist, clean 1,244 rows), 66.5 (Liquid) | two separate harnesses, 20 points apart |
| Qwen3.5-0.8B | ScreenSpot-Pro | 46.5 | 46.5 on an aggregator marked "imported", not independent | benchlm |

Reading: ScreenSpot-Pro is a high resolution professional-app test and is harsher than Perry's screens. ScreenSpot-v2 is closer to ordinary apps. On v2, the 4B base lands near 80 and the 2B base lands anywhere from 66 to 86 depending on prompt. Qwen3.5-2B can look bad if you ask in the wrong format. That is the single most useful independent finding for the tiny tier.

Sources: https://huggingface.co/docling-project/DeskForge-Qwen3.5-4B, https://huggingface.co/patrickballou/gui-assist-grounder, https://huggingface.co/LiquidAI/LFM2.5-VL-3B, https://benchlm.ai/benchmarks/screenspot-pro.

### 2.3 Vendor scores for the Qwen3.5 small bases (VENDOR, VERIFIED text of the cards)

| | 0.8B | 2B | 4B |
|---|---|---|---|
| ScreenSpot-Pro (VENDOR) | 46.5 | 54.5 | 60.3 |
| OSWorld-Verified (VENDOR) | not listed | not listed | 35.6 |
| AndroidWorld (VENDOR) | not listed | not listed | 58.6 |
| BFCL-V4 (VENDOR) | 25.3 | 43.6 | 50.3 |
| TAU2-Bench (VENDOR) | 11.6 | 48.8 | 79.9 |
| IFEval / IFBench (VENDOR) | 52.1 or 44.0 / 21.0 | 61.2 or 78.6 / 41.3 | 89.8 / 59.2 (thinking table) |
| OCRBench (VENDOR) | 74.5 or 79.1 | 84.5 or 85.4 | 85.0 |
| RefCOCO avg (VENDOR) | 79.3 / 77.8 | 84.8 / 84.3 | 88.1 |

Source: the three cards, https://huggingface.co/Qwen/Qwen3.5-4B and its siblings. Qwen's 2B card compares against Qwen3-VL-2B (ScreenSpot-Pro 48.5, VENDOR) and Qwen3-VL-4B (59.5, VENDOR). The 2B tau2 of 48.8 on the card is far below AA's 69.0 to 81.6, which is another sign that harness choice moves these numbers by 20 points.

### 2.4 What I searched and did not find

- BFCL V4 rows for Qwen3.5-4B or 2B on the official board: not found. The Berkeley page showed no per-model text; aggregators repeat Qwen's card.
- ScreenSpot-Pro or OSWorld leaderboard rows for any tiny tune: not found. Both are script-driven pages.
- r/LocalLLaMA or GitHub eval of Qwen3.5 2B/4B clicking, or of GUI-Owl, Holo, MAI-UI at small sizes: not found.
- LMArena rows at this size: not found.
- An independent Mac speed test for any model in this report: not found. oMLX community benchmarks exist (https://omlx.ai/benchmarks), but their small-model rows do not state the quantisation. One row shows Qwen3.5-2B at 440 tok/s prefill and 4.3 tok/s decode on a 16 GB M2 with 6.8 GB peak memory (INDEPENDENT, community, quantisation unstated). I treat it as an outlier and do not use it.

---

## 3. Candidate ledger

Columns: size is the 4-bit weights plus the vision file, VERIFIED from HF file listings unless marked. "V" means vision is supported. Dates are repo creation dates.

### 3.1 Qwen3.5 family and direct tunes

| Repo | Base | Licence | Date | Downloads | 4-bit size | GGUF / MLX | V | Scores |
|---|---|---|---|---|---|---|---|---|
| Qwen/Qwen3.5-4B | own | Apache-2.0 | 2026-02-27 | 7,408,893 | 2.91 + 0.67 GB (Unsloth UD-Q4_K_XL) | Unsloth GGUF (1,249,130 dl); mlx-community 4bit (54,411); OptiQ 4bit | yes | AA 13*/11*; vendor and outside rows in 2.2 and 2.3 |
| Qwen/Qwen3.5-2B | own | Apache-2.0 | 2026-02-28 | 3,198,686 | 1.34 + 0.67 GB | Unsloth GGUF (420,359 dl); mlx-community 4bit | yes | AA 7*/6*; see 2.2 and 2.3 |
| Qwen/Qwen3.5-0.8B | own | Apache-2.0 | 2026-02-28 | 3,568,672 | 0.56 + 0.20 GB | Unsloth GGUF; mlx-community 4bit | yes | AA 6*/5*; ScreenSpot-Pro 46.5 (VENDOR) |
| docling-project/DeskForge-Qwen3.5-4B (v1.1) | Qwen3.5-4B | Apache-2.0 | 2026-09-30 | 9,297 | bf16 repo only. A Q4 would be about 2.9 + 0.67 GB (UNVERIFIED, same architecture) | **none** found (`quantized:` empty) | yes | Table 3.1a below (VENDOR) |
| patrickballou/gui-assist-grounder | Qwen3.5-2B (LoRA r16, merged) | Apache-2.0 | 2026-10-17 | 52 | bf16 merged repo plus 16.8M-parameter LoRA. A Q4 would be about 1.34 + 0.67 GB (UNVERIFIED) | **none** found | yes | Table 3.1b below (VENDOR) |
| Hcompany/Holo-3.1-4B | Qwen3.5 4B/9B/0.8B and Qwen3.6-35B-A3B (card) | Apache-2.0 | 2026-05-29 | 3,463 | mradermacher GGUF (7,959 dl), prithivMLmods GGUF (4,167) | GGUF yes; MLX 4bit by pipenetwork (161) | yes | AndroidWorld "58% to 71%" for 4B and 9B together; other numbers only in images (VENDOR) |
| Hcompany/Holo-3.1-0.8B | Qwen3.5-0.8B | Apache-2.0 | 2026-05-29 | 7,915 | mradermacher GGUF (888 dl) | GGUF yes | yes | chart images only (VENDOR) |
| microsoft/Fara1.5-4B | Qwen3.5-4B | MIT | 2026-07-17 | 1,923 | bartowski Q4_K_M 2.88 GB + 0.67 (earlier report) | GGUF yes | yes | browser agent; trained to stop at payments and sign-in (earlier report) |

**3.1a DeskForge-Qwen3.5-4B v1.1 vs its base** (VENDOR, authors ran both rows; thinking off, greedy, 128-token cap, 2,097,152 pixel cap):

| Benchmark | Qwen3.5-4B | DeskForge v1.1 |
|---|---|---|
| ScreenSpot-Pro | 30.17 | 49.02 |
| ScreenSpot-v2 | 80.11 | 92.14 |
| OSWorld-G | 51.24 | 63.83 |
| UI-Vision | 17.24 | 38.17 |
| MMBench-GUI | 61.83 | 80.13 |
| DeskForge-1M held-out mean | 76.26 | 81.56 |
| WebArena-Infinity tasks solved (v1.0, Qwen3.6-27B planner) | 31 of 119 | 50 of 119 |
| OpenApps tasks solved (v1.0, same planner) | 3 of 100 | 15 of 100 |

It answers with one `pyautogui` line where coordinates are fractions of the screen with four decimals (VERIFIED, card). A Gemma 4 E4B version also exists (`docling-project/DeskForge-Gemma4-E4B`, not read).

**3.1b gui-assist-grounder vs Qwen3.5-2B base** (VENDOR, same harness; ScreenSpot-v2-clean is 1,244 of 1,272 rows):

| Split | Base | Released |
|---|---|---|
| ScreenSpot-v2-clean | 86.25 | 90.35 |
| Icons | 78.1 | 85.4 |
| Linux | 68.8 | 89.77 |
| macOS | 73.4 | 92.41 |
| AndroidWorld | 70.5 | 84.89 |
| Agent tasks (12 x 3 runs) | 18/36 | 17/36 (noise) |

The card says the merged checkpoint "serves `grounder` only". It reports the same hit rate on a Mac as on an H200 (87.0% both, 99.0% agreement) for the vLLM path. Output is `{"point_2d": [x, y]}` on a 0 to 1000 grid, which already matches Perry's strict-JSON, 0-1000 convention. The vision encoder is frozen and only the language model has a LoRA.

### 3.2 Qwen3-VL based GUI tunes (plain-attention architecture)

| Repo | Base | Licence | Date | Downloads | 4-bit size | GGUF / MLX | Scores (VENDOR unless marked) |
|---|---|---|---|---|---|---|---|
| mPLUG/GUI-Owl-1.5-4B-Instruct | Qwen3-VL (card; 4.4B params, so the 4B) | MIT | 2026-02-14 | 2,048 | Q4_K_M 2.50 GB + mmproj Q8 0.45 GB or f16 0.84 GB (mradermacher) | mradermacher GGUF (5,779 dl); i1 GGUF (738). No MLX seen | ScreenSpot-Pro 66.8, ScreenSpot-v2 93.2, OSWorld-G 63.7, MMBench-GUI L2 83.24, OSWorld-Verified 48.2, AndroidWorld 69.8, OSWorld-MCP 31.7, WindowsAA 29.4. With zoom crops ScreenSpot-Pro 75.6. |
| mPLUG/GUI-Owl-1.5-2B-Instruct | Qwen3-VL (2.1B params, so the 2B) | MIT | 2026-02-14 | 3,606 | Q4_K_M 1.11 GB + mmproj Q8 0.445 GB | mradermacher GGUF (4,141); MLX 4bit by clinan (55) | ScreenSpot-Pro 57.8, ScreenSpot-v2 89.7, OSWorld-G 52.8, MMBench-GUI L2 72.17, OSWorld-Verified 43.5, AndroidWorld 67.9, OSWorld-MCP 33.0. With zoom crops ScreenSpot-Pro 70.4. |
| Tongyi-MAI/MAI-UI-2B | Qwen3-VL-2B likely (2.1B params, UNVERIFIED) | Apache-2.0 | 2025-12-25 | 1,748 | Q4_K_M 1.11 GB + mmproj Q8 0.445 GB | mradermacher GGUF (1,091); mlx-community 6bit (123) | ScreenSpot-Pro 57.4 (62.8 zoom), ScreenSpot-v2 92.5, OSWorld-G 52.0, UI-Vision 30.3, MMBench-GUI L2 82.6, AndroidWorld 49.1 (arXiv 2512.22047). |
| inclusionAI/UI-Venus-1.5-2B | Qwen3-VL series | Apache-2.0 | 2026-02-09 | 4,175 | mradermacher GGUF (659 dl) | GGUF yes; mlx-community 6bit | ScreenSpot-Pro 57.7 (card). The card gives no other 2B numbers in text. |
| Hcompany/Holo2-4B | Qwen3-VL-4B-Thinking | Apache-2.0 | 2025-11-10 | 16,554 | mradermacher GGUF (1,065) | GGUF yes | ScreenSpot-Pro 57.2, OSWorld-G 69.4, ScreenSpot-v2 93.2; navigation WebVoyager 80.2, OSWorld 37.7, AndroidWorld 64.6. Holo2's own reproduction of Qwen3-VL-4B-Thinking: ScreenSpot-Pro 41.4, ScreenSpot-v2 90.0 (VENDOR). |
| stepfun-ai/GELab-Zero-4B-preview | Qwen3-VL-4B-Instruct | Apache-2.0 | 2025-11-28 | 871 | GGUFs by Mungert (5,809), bartowski (1,745) | GGUF yes | Phone agent for Android over ADB. No scores on the card. Not a desktop model. |
| GUI-Libra/GUI-Libra-4B | Qwen3-VL-4B-Instruct | Apache-2.0 | 2026-02-24 | 229 | none found | none found | Action format `point_2d: [x, y]`, tied to an Android style action list. No scores read. |
| GUI-Gym/Qwen3-VL-4B-sft-qwen3.8-27b-full-tasks-with-recovery-sft | Qwen3-VL-4B-Instruct | none stated | 2026-10-27 | 0 | none | none | A distill: SFT on Qwen3.8-27B traces, then recovery data from a teacher. Mobile only (MobileGym). Per-run success about 35 to 41%. Too new and too narrow for Perry. |

The older Qwen3-VL-4B and 2B are themselves usable bases: Qwen3-VL-4B-Instruct has 4,010,838 downloads and Qwen3-VL-2B-Instruct 1,671,716 (VERIFIED). Qwen's vendor ScreenSpot-Pro is 59.5 for the 4B and 48.5 for the 2B. Both have official GGUFs (Qwen/Qwen3-VL-4B-Instruct-GGUF 546,975 downloads).

### 3.3 Non-Qwen small VLMs

| Repo | Licence | Date | Downloads | 4-bit size | GGUF / MLX | V | Evidence | Verdict |
|---|---|---|---|---|---|---|---|---|
| LiquidAI/LFM2.5-VL-3B | LFM Open License v1.0 (VERIFIED file; I did not read the commercial thresholds. Perry is non-commercial) | 2026-08-11 | 26,888 | Q4_K_M 1.67 GB + mmproj Q8 0.58 GB (official) | Official GGUF (31,513 dl); MLX OptiQ 4bit (790); DSpark drafter (1,140) | yes | In Liquid's own table: ScreenSpot-v2 80.7 (Qwen3.5-4B 78.5, Qwen3.5-2B 66.5, Gemma 4 E4B 50.9, Gemma 4 E2B 31.1, InternVL3.5-4B 84.2), RefCOCO 87.9, BFCLv4 32.5 (Qwen3.5-4B 53.6), ToolSandBox 59.5 (Qwen3.5-4B 65.0). All VENDOR. Coordinates are integers in [0, 1000]. Tool calls default to Pythonic lists. Native 512x512 tiles plus a thumbnail. | Speed wildcard. Weaker tools than Qwen3.5-4B. |
| openbmb/MiniCPM-V-4.7-1B | Apache-2.0 | 2026-10-06 | 155,428 | Q4_K_M 0.67 GB + mmproj 0.90 GB (4x) or 1.11 GB; Q4_0 0.64 GB | Official GGUF (101,179); MLX 4bit and 8bit; DSpark drafter GGUF 0.44 GB | yes | Card: "substantially outperforms Qwen3.5 0.8B" in score and efficiency (VENDOR, chart image only). Mixed 4x or 16x visual token compression. No GUI score anywhere. | Smallest sensible vision model. Untested for clicks. Reserve. |
| ewin-reg/MiniCPM-V-4.7-1B-Agentic-FwS(-FlashREINFORCE) | Apache-2.0 | 2026-10-19 and 25 | 193 / 44 | official-style GGUF by the author (252 dl) | GGUF yes | yes | Tool calling tune. Exact first-call match 0.414 on 1,000 held-out rows from Nemotron tool-calling prompts, against 0.334 for a Claude Haiku 5.5 subagent reference (VENDOR, author's run, Haiku run under a different harness). | A hobby tune. The Haiku row is not like for like. Do not rely on it. |
| google/gemma-4-E4B-it, E2B-it | Apache-2.0 | 2026-03-02 | 4,027,807 / 3,060,002 | E4B is 4.5B effective, 8B with embeddings; E2B is 2.3B effective, 5.1B with embeddings (VENDOR card) | Many GGUF and MLX builds (unsloth E2B GGUF 460,401) | yes (image budgets 70, 140, 280, 560, 1120 tokens, VERIFIED) | tau2 42.2 (E4B) and 24.5 (E2B) (VENDOR). AA 9 and 8* (INDEPENDENT). ScreenSpot-v2 50.9 and 31.1 in Liquid's table (VENDOR, competitor-run). AUBIN-E4B-Screen, a LoRA, reaches ScreenSpot 69.3 after two rounds on 30% of its data (VENDOR). | Loses on tool use and grounding. Drop. |
| mistralai/Ministral-3-3B-Instruct-2512 | Apache-2.0 | 2025-10-31 | 82,866 | official GGUF (56,685 dl) | yes | yes (0.4B vision encoder) | AA 5 (INDEPENDENT). Native function calling and JSON (VENDOR). No GUI numbers found. | Drop. |
| prism-ml/Ternary-Bonsai-2-4B / 2B | Apache-2.0 | 2026-09-23 | 60,728 / 142,684 | 4B: PQ2_0 1.146 GB, Q2_0 1.212 GB, PTQ1_0 0.949 GB, mmproj Q8 0.366 GB. 2B: PQ2_0 0.52 GB, mmproj Q8 0.36 GB | GGUF needs the PrismML fork; upstream runs only `Q2_0`. MLX 2-bit builds exist (prism-ml). | yes | Ternary weights of Qwen3.5. Vendor says instruction following matches full precision (launch post, via search, VENDOR). No benchmark table on the GGUF card. Vendor says a draft head was slower than plain decoding at 2B. | A memory saver. Not a prefill saver. Reserve for 8 GB later. |
| HongxinLi/GoClick-Base / Large | MIT | 2026-05-09 | 663 / 422 | 230M parameters (VENDOR, arXiv abstract) | transformers only; Florence-2 | yes | Two-stage: a planner writes a function description, GoClick outputs the point. No scores read. | Not llama.cpp. Out of scope. |
| Others checked | | | | | | | SmolVLM2-2.2B GUI tune (2,362 dl, older); InternVL3.5 1B/2B/4B (few derivatives, none GUI); granite-vision-4.1-4b (document model); Phi-4-multimodal (AA 6*); moondream2 (2024); FastVLM 0.5B/1.5B (Apple licence, captioning tunes only); WeVisOne-VL, GroundingPI, Mage-VL (object grounding and video, not GUI); LiquidAI d1-3B and d1-omni-600M (decision models that return typed answers in one pass, cannot write a tool call) | Drop. |

### 3.4 Distills, tool-call tunes, speed tunes, compressions (tiny tier)

| Repo | What it is | Evidence | Verdict |
|---|---|---|---|
| empero-ai/Qwen3.8-4B-Distill (258,029 dl) and -2B-Distill (3,039) | Distill of Qwen3.8 into Qwen3.5 4B and 2B. Text path only. | Vendor gains on a chain-of-thought harness (earlier report). | No vision. Not for Perry. |
| Jackrong/Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled (v1, v2; 335 and 460 dl), Qwen3.5-0.8B-Claude-4.6-Opus-Reasoning-Distilled (136), clzoro Qwen3.5-4B-Claude-distill (60 and 56) | Distills on Claude outputs. | No benchmarks read. | Teacher terms unclear. Skip. |
| Pepps233/Qwen3.5-0.8B-ToolCalling-OPD and -SFT (195, 196 dl) | 0.8B tool-call tune, on-policy distill from a frozen Qwen3.5-4B teacher, 1,477 xLAM and ToolACE prompts. | BFCL-style sample scores 70.80, 71.00, 71.40, mean 71.07 on the author's own samples (VENDOR). Not the BFCL board. | Shows 0.8B can learn the call format. Evidence is weak. |
| Sarthak213/doosra-qwen3.5-4b-toolcalls-v2 (811 dl, GGUF yes) | Tool caller for one 25-tool cricket app. | Author notes v1 beat the base only on templated questions. | Useful lesson: tune on your own prompts, keep the prompt short. Not a general model. |
| airev-ae/Qwen-0.8B-AgentJSON (144), kdy1/JSONLLM-Qwen3.5-4B-v0.1 (304), ermiaazarkhalili Qwen3.5-0.8B-Function-Calling-xLAM (61), divagr1925/Qwen3.5-4B-Qwenputer-Filesystem (530) | JSON and tool-call tunes. | Cards give no independent numbers. | Not worth a slot. Perry's enforced schema already gives valid JSON. |
| z-lab/Qwen3.5-4B-DFlash (12,556), modal-labs copy, rasyosef/Qwen3.5-2B-DFlash2, nchapman/Qwen3.5-4B-DFlash2, yuyijiong/Qwen3.5-4B-Eagle3, Moonlight556/Qwen3.5-0.8B-DFlash | Speculative draft models. | DFlash servers: SGLang, vLLM PR. No llama.cpp path stated. | Decode only. No help for prefill. |
| unsloth/Qwen3.5-4B-MTP-GGUF (102,389 dl) | Qwen3.5-4B with MTP head for `--spec-type draft-mtp --spec-draft-n-max 6`. | Card: "`-np > 1` and `--mmproj` are not yet supported with MTP" (VERIFIED). Unsloth claims about 1.5 to 2x faster generation (VENDOR). Earlier report: MTP hurt Qwen3.5-9B under Metal. | Cannot run with Perry's vision lane. Skip. |
| LiquidAI/LFM2.5-VL-3B-DSpark, openbmb/MiniCPM-V-4.7-1B-DSpark(-gguf) | Speculative drafters for vision models. | Liquid: decoding 1.57 to 2.14x on M3 Ultra llama.cpp, 2.30 to 3.13x on M5 Max MLX-VLM, end-to-end 1.30 to 1.77x and 1.56 to 2.62x; FP16, batch 1, up to 2,048 output tokens (VENDOR). Quantised models "out of scope". | Helps long spoken answers only, and not on quantised weights. Skip for now. |
| j-llm/Qwen3.5-2B-SpeedX | Text-only, all 24 layers converted to Gated DeltaNet. | Experimental, no vision. | Interesting, not usable. |
| Kodjaoglanian/Qwen-3.5-4B-Auto-ASVD, -ASVD-Healed | Low-rank factorised 4B. | No vision evidence. | Skip. |
| bayliner1980/Qwen3.5-0.8B-MoE-A0.6B (209), nchapman/Qwen3.5 DFlash2, FastFlowLM NPU builds | Odd compressions and NPU ports. | No evidence. | Skip. |
| K2 Horizon 3.7B (IFM, Apache-2.0) | Own base, text only. | AA 16 (INDEPENDENT). Earlier reports: no non-thinking mode, tool parser issue. | Possible text planner only. |
| MiniCPM5-2B (OpenBMB) | Own base, text only. | AA 12 (INDEPENDENT). | Possible text planner only. |

Nothing in 3.4 changes the shortlist. The one pattern worth copying is the Doosra lesson and the Pepps233 one: a small model learns Perry's call format fast if you tune it on Perry's own traces. That is a future project, not a download.

---

## 4. Coordinate conventions and prompt formats, by model

| Model | Coordinates | Output format | Source |
|---|---|---|---|
| Qwen3.5 (all sizes) | 0 to 1000 relative to the image | Free choice. Perry's schema forces JSON. | Owner's run (9B); gui-assist card describes the same grid on Qwen3.5-2B |
| DeskForge-Qwen3.5-4B | fractions 0.0 to 1.0, four decimals | One line `pyautogui.click(x=0.0000, y=0.0000)` and similar, from a fixed system prompt | VERIFIED, card |
| gui-assist-grounder | integers 0 to 1000 | `{"point_2d": [x, y]}`. Screenshot up to about 2,073,600 pixels plus one target description | VERIFIED, card |
| GUI-Owl-1.5 | relative 0 to 1000 "by default" | Structured function call (tool call) with an "action conclusion". Exact system prompt not shown in the README; it lives in `mobile_use/` and `computer_use/` scripts of X-PLUG/MobileAgent | VERIFIED, GitHub README and paper text |
| MAI-UI-2B | integers scaled by 999, then divided to 0 to 1 | `<grounding_think>...</grounding_think><answer>{"coordinate": [x,y]}</answer>` from a fixed grounding prompt | VERIFIED, MAI-UI repo `mai_grounding_agent.py` and `prompt.py` |
| UI-Venus-2 (Qwen3.5-based, 9B; shown for contrast) | [0, 1000] | user-only message, `[x, y]` | VERIFIED, repo README. The 1.5-2B README does not state it (UNVERIFIED) |
| LFM2.5-VL-3B | integers 0 to 1000 for boxes | Pythonic tool list by default | VERIFIED, card |
| Gemma 4 E2B/E4B | not stated for pointing | native function calling | card says "pointing" is supported; format not read (UNVERIFIED) |
| Holo-3.1 | not stated on card or blog | native function calling, structured JSON | VERIFIED absence; formats are in the H Company cookbook, not read |

---

## 5. How I ranked: usefulness per second

Perry's owner said "usually a much faster and slightly worse accuracy is better". So I ranked on expected steps that land per second, in this order:

1. **Same engine and flags as the 15/16 run.** A model that only needs a file swap can be tested in an hour. That favours Qwen3.5-4B, Qwen3.5-2B, DeskForge and gui-assist.
2. **Least added risk to JSON and tool calling.** Perry enforces a JSON schema. A tune trained on a different action text format may fight the grammar. That raises the risk on GUI-Owl, MAI-UI and DeskForge, and lowers it on gui-assist (already JSON).
3. **Smallest file for a given grounding claim.** GUI-Owl-1.5-2B (1.56 GB) claims more agentic ability than Qwen3.5-4B (3.58 GB), but only in its authors' harness.
4. **Evidence quality.** A same-harness, held-out base-versus-tune table (DeskForge, gui-assist) beats a bare leaderboard claim. Both are still author-run.

What I would not trust: any GUI-Owl or MAI-UI headline that mixes zoom crops, thinking, or custom harnesses.

---

## 6. Ranked shortlist of 5 to benchmark on the 16 GB mini

Test all five on the same 16 real Perry screenshots from the 9B run. Report valid-JSON rate, click hits out of 16, seconds per step (median of 5), and peak memory. Use the 9B's 15/16 at 1.4 s as the bar. I rank by expected usefulness per second, not by raw accuracy.

### 1. Qwen3.5-4B (control and likely 16 GB pick)

- Repo: `unsloth/Qwen3.5-4B-GGUF`. Files: `Qwen3.5-4B-UD-Q4_K_XL.gguf` (2.91 GB) plus `mmproj-F16.gguf` (0.67 GB). Download 3.58 GB (VERIFIED). Lighter option: `Qwen3.5-4B-IQ4_XS.gguf` 2.48 GB.
- MLX alternative: `mlx-community/Qwen3.5-4B-MLX-4bit` (54,411 dl) or `mlx-community/Qwen3.5-4B-OptiQ-4bit`.
- Coordinates: 0 to 1000. Prompt: the current Perry prompt. No change.
- Flags: exactly the 9B run's flags (`-ngl all -fa on`, `--image-min-tokens 1024`, JSON schema, `enable_thinking:false`). Non-thinking VL sampling on the card is temperature 0.7, top_p 0.8, top_k 20, presence_penalty 1.5 (VERIFIED). With a schema, try temperature 0 for clicks as an extra run.
- Do not add `--spec-type draft-mtp`: unsupported with `--mmproj`.
- Why first: AA index 11* non-reasoning against 13* for the 9B (INDEPENDENT, estimated), tau2 87.7 non-reasoning against 85.1 for the 9B (INDEPENDENT, earlier report), zero integration risk, about half the cost (UNVERIFIED).

### 2. DeskForge-Qwen3.5-4B v1.1 (best-evidenced tune)

- Repo: `docling-project/DeskForge-Qwen3.5-4B` (use revision `main`, which is v1.1; `v1.0` is the paper checkpoint). bf16 safetensors, Apache-2.0. No GGUF or MLX exists (VERIFIED, `quantized:` is empty).
- Do: convert with llama.cpp's `convert_hf_to_gguf.py` (model and `--mmproj`), then quantise to Q4_K_M or UD-style. Same architecture as the control, so UNVERIFIED but expected to work. Expect about 2.7 + 0.67 GB.
- Coordinates: fractions 0.0 to 1.0 with four decimals. Prompt: the fixed system prompt on the card (pyautogui actions, "no explanation, no code fence"). Constrain output with a GBNF grammar for `pyautogui.click(x=0.0000, y=0.0000)` style lines, not Perry's JSON schema. Map to pixels by multiplying by the screenshot size.
- Flags: same as the control. Authors evaluated with thinking off, greedy decoding, a 128-token cap and a 2,097,152-pixel cap on the screenshot. Match that: `--image-max-tokens` about 2,048 and `--temp 0`.
- Why second: same-harness gains of 12 to 19 points on five desktop grounding sets and 15 vs 3 on OpenApps (VENDOR). Perry runs on desktop. Risk: the action space is its own; chat and JSON quality outside that prompt are untested.

### 3. GUI-Owl-1.5-4B-Instruct (best other-architecture challenger)

- Repo: `mradermacher/GUI-Owl-1.5-4B-Instruct-GGUF`. Files: `GUI-Owl-1.5-4B-Instruct.Q4_K_M.gguf` (2.50 GB) plus `GUI-Owl-1.5-4B-Instruct.mmproj-Q8_0.gguf` (0.45 GB). Download 2.95 GB (VERIFIED). No MLX build seen.
- Licence MIT. Based on Qwen3-VL (plain attention).
- Coordinates: relative 0 to 1000 by default (VERIFIED, README). Prompt: use the cookbook prompt from `X-PLUG/MobileAgent` (`computer_use`) for the first run, because the README does not print it. Then try Perry's schema and see if hits hold.
- Flags: the authors' vLLM settings use a screenshot cap of 3,072,000 pixels (shortest edge 65,536). In llama.cpp use `--image-min-tokens 1024` and set `--image-max-tokens` to roughly 1,600 (Qwen3-VL tokens cover 32x32 pixels each, so 3,072,000 pixels is about 3,000 tokens; I cut it for speed; arithmetic, UNVERIFIED).
- Why third: highest vendor grounding at this size (ScreenSpot-Pro 66.8, above Qwen3.5-9B's 65.2 on its card, both VENDOR) and a different engine path.

### 4. Qwen3.5-2B (8 GB control)

- Repo: `unsloth/Qwen3.5-2B-GGUF`. Files: `Qwen3.5-2B-UD-Q4_K_XL.gguf` (1.34 GB) plus `mmproj-F16.gguf` (0.67 GB). Download 2.01 GB (VERIFIED). MLX: `mlx-community/Qwen3.5-2B-MLX-4bit`.
- Coordinates: 0 to 1000. Prompt and flags as the control.
- Test with the exact format used in gui-assist's harness (`{"point_2d": [x, y]}`, 0 to 1000) as well as Perry's. Outside numbers for this base differ by 20 points between prompts (section 2.2).
- Why fourth: the real baseline for the 8 GB class. About 0.4 s per step by scaling (UNVERIFIED).

### 5. GUI-Owl-1.5-2B-Instruct (8 GB challenger)

- Repo: `mradermacher/GUI-Owl-1.5-2B-Instruct-GGUF`. Files: `GUI-Owl-1.5-2B-Instruct.Q4_K_M.gguf` (1.11 GB) plus `GUI-Owl-1.5-2B-Instruct.mmproj-Q8_0.gguf` (0.445 GB). Download 1.55 GB (VERIFIED). MLX: `clinan/GUI-Owl-1.5-2B-Instruct-MLX-4bit` (55 dl).
- Coordinates and prompt: as the 4B.
- Why fifth: claims OSWorld-Verified 43.5 and ScreenSpot-v2 89.7 (VENDOR) in the smallest useful file. If it holds up on Perry's screenshots it would let an 8 GB Mac run an agent-grade model at about 0.3 s per step (UNVERIFIED).

### Reserves, in order (test if a shortlist model fails or finishes early)

1. `patrickballou/gui-assist-grounder` on Qwen3.5-2B. JSON output already fits Perry. Convert to GGUF, or ship it as a LoRA over the stock 2B and swap it on for click calls only (llama.cpp `--lora` after `convert_lora_to_gguf.py`; UNVERIFIED for the Qwen3.5 hybrid layers). Adds almost no memory on 8 GB. The LoRA file is about 16.8M parameters (VENDOR).
2. `mradermacher/MAI-UI-2B-GGUF` Q4_K_M 1.11 GB + mmproj Q8 0.445 GB. ScreenSpot-v2 92.5 (VENDOR). Emits a reasoning block first, so decode is longer.
3. `LiquidAI/LFM2.5-VL-3B-GGUF` Q4_K_M 1.67 GB + `mmproj-LFM2.5-VL-3B-Q8_0.gguf` 0.58 GB. Different architecture, 0-1000 boxes, weaker tool use.
4. `openbmb/MiniCPM-V-4.7-1B-gguf` Q4_K_M 0.67 GB + `mmproj-model-f16-4x.gguf` 0.90 GB. Smallest. Check the 16x token compression for speed. No GUI evidence.
5. `mradermacher/Holo-3.1-4B-GGUF` and Holo-3.1-0.8B. Native function calling. No usable numbers in text.
6. `prism-ml/Ternary-Bonsai-2-4B-gguf` `Ternary-Bonsai-2-4B-Q2_0.gguf` 1.212 GB + mmproj Q8 0.366 GB. Total 1.58 GB for a 4B-class model on upstream llama.cpp. Quality unmeasured.

---

## 7. Provisional pick per Mac class

Both picks are provisional. They rest on file sizes, vendor claims and one owner measurement at 9B. No tiny model has been timed on the mini.

| Class | Provisional pick | Download | Scaled step (UNVERIFIED) | Swap rule |
|---|---|---|---|---|
| **16 GB** | **Qwen3.5-4B UD-Q4_K_XL**, with the 9B (6.89 GB, already benchmarked) as the fallback when the 4B returns invalid JSON or a click outside the screen. | 3.58 GB (VERIFIED) | about 0.7 s, against 1.4 s for the 9B | Swap to DeskForge-Qwen3.5-4B or GUI-Owl-1.5-4B only if it lands at least 14 of 16 clicks and keeps the JSON rate. |
| **8 GB** | **Qwen3.5-2B UD-Q4_K_XL** | 2.01 GB (VERIFIED) | about 0.4 s on a base M4; slower on M1 to M3 | Swap to GUI-Owl-1.5-2B (1.55 GB) if it lands at least 13 of 16 and the 2B control is worse. Add the gui-assist LoRA as a click-only helper if it converts cleanly. |

Honest limits for the 8 GB class. A 2B reads the screen and takes one clear step. It plans poorly (AA index 7* for reasoning and 6* for not; both INDEPENDENT estimates). When a task is longer than a few steps, Perry should say so and offer the cloud brain before sending anything, as the lineup report already proposes.

A two-rung cascade also fits the owner's rule. Run the small model first. If its JSON fails the schema, or the click lands outside the screen, or the screen did not change after the click, retry once with the next size up. This keeps the average step near the small model's time and keeps the 9B's accuracy for the hard steps.

---

## 8. What I could not verify

- Seconds per step on Apple silicon for any tiny model. Section 1 is arithmetic on file sizes. I could not reconcile the owner's 1.4 s with a compute estimate for a base M4.
- Every GUI score in this report. All are VENDOR except the AA rows and the outside rows in 2.2, which are still not a neutral board.
- GUI-Owl's and Holo's exact prompts. The GUI-Owl README names `mobile_use/` and `computer_use/` scripts; I did not open them. H Company's cookbook was not read.
- MAI-UI-2B's and UI-Venus-1.5-2B's base model. Parameter counts (2.1B and 2.4B) point to Qwen3-VL-2B; neither card says so in the text I read.
- Whether llama.cpp converts and runs DeskForge and gui-assist cleanly, and whether a LoRA over Qwen3.5's hybrid layers loads with `--lora`.
- Whether Qwen3-VL based GGUFs (GUI-Owl) are faster or slower than Qwen3.5 on Metal at the same size.
- LFM Open License v1.0 commercial thresholds. Perry is non-commercial, so I expect no block, but I did not read past the definitions.
- Ternary-Bonsai-2 quality. The vendor's instruction-following claim came through a search summary, and the GGUF card has no benchmark table.
- Whether Doosra-style short prompts or a Perry-trace fine-tune would beat every download here. It probably would, and that is the biggest untested lever.

---

## Sources

All pages read on 2026-10-27 unless noted.

Hugging Face API and file listings
- https://huggingface.co/api/models (filters `base_model:finetune:`, `base_model:merge:`, `base_model:adapter:`, `base_model:quantized:`, `num_parameters`, `author`, `search`) and `/api/models/<repo>/tree/main` for every file size quoted
- https://huggingface.co/unsloth/Qwen3.5-4B-GGUF, https://huggingface.co/unsloth/Qwen3.5-2B-GGUF, https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF
- https://huggingface.co/mradermacher/GUI-Owl-1.5-4B-Instruct-GGUF, https://huggingface.co/mradermacher/GUI-Owl-1.5-2B-Instruct-GGUF, https://huggingface.co/mradermacher/MAI-UI-2B-GGUF
- https://huggingface.co/LiquidAI/LFM2.5-VL-3B-GGUF, https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf, https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-gguf

Model cards
- https://huggingface.co/Qwen/Qwen3.5-4B, https://huggingface.co/Qwen/Qwen3.5-2B, https://huggingface.co/Qwen/Qwen3.5-0.8B
- https://huggingface.co/docling-project/DeskForge-Qwen3.5-4B
- https://huggingface.co/patrickballou/gui-assist-grounder
- https://huggingface.co/mPLUG/GUI-Owl-1.5-2B-Instruct
- https://huggingface.co/Tongyi-MAI/MAI-UI-2B
- https://huggingface.co/inclusionAI/UI-Venus-1.5-2B
- https://huggingface.co/Hcompany/Holo-3.1-0.8B, https://huggingface.co/Hcompany/Holo-3.1-4B, https://huggingface.co/Hcompany/Holo2-4B
- https://huggingface.co/stepfun-ai/GELab-Zero-4B-preview, https://huggingface.co/GUI-Libra/GUI-Libra-4B
- https://huggingface.co/GUI-Gym/Qwen3-VL-4B-sft-qwen3.8-27b-full-tasks-with-recovery-sft
- https://huggingface.co/LiquidAI/LFM2.5-VL-3B, https://huggingface.co/LiquidAI/LFM2.5-VL-3B-DSpark, https://huggingface.co/LiquidAI/d1-3B
- https://huggingface.co/openbmb/MiniCPM-V-4.7-1B, https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-DSpark-gguf
- https://huggingface.co/google/gemma-4-E4B-it
- https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512
- https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-gguf
- https://huggingface.co/emrevrg/AUBIN-E4B-Screen
- https://huggingface.co/HongxinLi/GoClick-Base
- https://huggingface.co/ewin-reg/MiniCPM-V-4.7-1B-Agentic-FwS-FlashREINFORCE
- https://huggingface.co/unsloth/Qwen3.5-4B-MTP-GGUF
- https://huggingface.co/z-lab/Qwen3.5-4B-DFlash
- https://huggingface.co/Pepps233/Qwen3.5-0.8B-ToolCalling-OPD
- https://huggingface.co/Sarthak213/doosra-qwen3.5-4b-toolcalls-b
- https://huggingface.co/j-llm/Qwen3.5-2B-SpeedX
- https://huggingface.co/BAAI/AREX-Turbo
- https://huggingface.co/Kodjaoglanian/Qwen-3.5-4B-Auto-ASVD
- https://huggingface.co/microsoft/Mage-VL, https://huggingface.co/tencent/WeVisOne-VL-4B, https://huggingface.co/GroundingPI/GroundingPI
- https://huggingface.co/Navanjana/AgentEye-Grounder-0.8B-v1, https://huggingface.co/MTalha2001/LOCUS-0.8B

Papers, repos and vendor pages
- https://arxiv.org/html/2602.16855 (GUI-Owl-1.5 / Mobile-Agent-v3.5 grounding tables)
- https://arxiv.org/html/2512.22047v1 (MAI-UI)
- https://arxiv.org/abs/2604.23941 (GoClick)
- https://github.com/X-PLUG/MobileAgent/tree/main/Mobile-Agent-v3.5 (GUI-Owl coordinate convention)
- https://github.com/Tongyi-MAI/MAI-UI (`MAI-UI/src/mai_grounding_agent.py`, `MAI-UI/src/prompt.py`)
- https://github.com/inclusionAI/UI-Venus (`models/grounding/README.md`)
- https://www.hcompany.ai/holo3.1, https://hub.hcompany.ai/quickstart
- https://www.liquid.ai/blog/lfm2-5-vl-dspark

Independent and aggregate evidence
- https://artificialanalysis.ai/leaderboards/models (274 rows parsed)
- https://benchlm.ai/benchmarks/screenspot-pro
- https://omlx.ai/benchmarks and https://omlx.ai/benchmarks/zbrphqpz
- https://gorilla.cs.berkeley.edu/leaderboard (searched; no per-model text for these models)

Earlier reports in this repo
- docs/research/2026-10-27/local-model-lineup.md, finetunes-and-cua.md, large-tunes-deep.md
- docs/research/2026-10-25/r8-local-models-best.md
