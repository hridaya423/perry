# Best mid-tier local model for Perry (7B to 14B dense, MoE up to about 10 GB)

Date: 2026-10-27. Author: research sub-agent. Status: final. Research only. I downloaded no weights, built nothing and ran no model. Scratch files lived in /tmp and are deleted. This is the only file I wrote.

Reads on top of `local-model-lineup.md`, `finetunes-and-cua.md`, `large-tunes-deep.md` (all 2026-10-27) and `r8-local-models-best.md` (2026-10-25). I do not repeat their tables. I add the mid tier, the coordinate and prompt formats, and the MoE and pruned-model angle they skipped.

## Summary (15 lines)

1. Answer: nothing I found beats a Qwen3.5-9B-family model in the 16 GB class today. The ranking is by usefulness per second, and every challenger score is VENDOR. The only INDEPENDENT numbers cover base models.
2. Your MAI-Gym-9B result (8/16) most likely comes from the coordinate convention. Every sibling harness from the same team uses 0 to 999 or 0 to 1000 normalised coordinates, never pixels. Pixels read as 0 to 1000 come out short by about `y * (1 - 1000/H)`. That is 27 to 45 px at y 300 to 500 on a 1100 px tall screenshot, which matches your 25 to 45 px. This is an inference (UNVERIFIED). You can check it by re-scoring the saved outputs, with no new run.
3. Every Qwen3/Qwen3.5-lineage GUI tune I traced uses 0 to 1000 relative coordinates: Holo-3.1 and Holo4 (docs read today), UI-Venus-2, GUI-Owl-1.5, UI-Mate, GroundGUI-8B, MAI-UI. Holo documents a click prompt and a JSON schema almost identical to your winning Qwen3.5 test. Test Holo-3.1-9B first.
4. UI-Venus-2-9B has no licence at the author's repo (VERIFIED, `license: None`). You ruled out no-licence weights, so it is out.
5. Best new speed idea: a pruned Qwen3.6-35B-A3B. `crucible-labs/Qwen3.6-35B-A3B-REAP-48-v2-GGUF` is 9.43 GB, keeps 3B active parameters, and the uploader measured it on a 16 GB M4 mini under Metal: prefill 417 tok/s, decode 29.2 tok/s (VENDOR, llama-bench `-p 512 -n 128`). A dense 9B decodes at about 15 tok/s there (UNVERIFIED, my arithmetic). The repo is text only. Pair it with the Unsloth mmproj and test whether vision still works (UNVERIFIED).
6. No small vision MoE under 10 GB is usable in llama.cpp today. ZAYA1-VL-8B (0.7B active) needs a custom transformers fork. Moondream 3.1 (9B-A2B) needs its own engine and only points and captions. LFM2.5-8B-A1B, LFM2.5-24B-A2B and Ling-3.0-tiny are text only and think by default.
7. Gemma 4 12B is the best non-Qwen mid model on paper (Apache-2.0, QAT q4_0 6.98 GB + 0.18 GB mmproj). It loses for Perry. AA tau2 tool use is 31.9 to 36.3 against 85.1 to 86.8 for Qwen3.5-9B (INDEPENDENT). A third party measured the smaller Gemma 4 E4B at ScreenSpot-Pro 1.83 before tuning (DeskForge card).
8. Speculative decoding does not help Perry. Replies are about 30 tokens, so prefill dominates. llama.cpp now supports `draft`, `draft-eagle3`, `draft-dflash`, `draft-dspark` and `draft-mtp` (docs read today). On the same M4 mini, DFlash cost 5% to 53% decode speed (uploader measurement, VENDOR).
9. The Hugging Face walk: Qwen3.5-9B has 1,188 finetunes, 35 merges, at least 800 adapters and 625 quantizations. I also walked Qwen3-VL-8B (679 + 79), Gemma 4 12B (263), Gemma 4 E4B (436), MiMo-9B (30), Ministral 3 (22), plus 3,700 repos from size-range crawls and about 40 organisation lists. I read about 30 cards.
10. The popular Qwen3.5-9B tunes are not better brains. They are decision heads (Clef-Flash, JEV, elephant-1, APUS-Reflex), uncensored builds, writing and role-play tunes, and coding or math distills. I found no tool-calling or JSON-mode tune with any independent score.
11. Low-download finds worth a look: PrentisAI/GroundGUI-8B (76 downloads, ScreenSpot-Pro 63.9 VENDOR), docling-project/DeskForge-Gemma4-E4B (grounding tune of Gemma 4 E4B, fractions as output), allenai tmax-9b and qwen35-9b-* (terminal agent research tunes), OpenMobile-2-9B (Android only).
12. Independent evidence is thin. AA covers bases only. BFCL has no 2026 rows for these models. ScreenSpot-Pro, OSWorld and LMArena pages gave me no rows. DeskForge ran a third-party grounding table that puts UI-Venus-2-9B at 78.9 and Gemma4-31B at 70.7, but its authors sell a competing tune.
13. Shortlist for the 16 GB mini (max 5): 1) Qwen3.5-9B control, 2) Holo-3.1-9B, 3) MAI-Gym-9B re-run with normalised coordinates, 4) Qwen3.6-35B-A3B REAP-48 v2 plus Unsloth mmproj, 5) MiMo-V2.6-Distill-Qwen-9B. Ornith-1.5-9B is the reserve.
14. Provisional picks: 16 GB gets Qwen3.5-9B UD-Q4_K_XL until a challenger wins by 2 or more of 16 targets at equal or lower step time. 24 GB gets Qwen3.5-9B UD-Q6_K_XL, or REAP-48 if its vision test passes. Section 7 has the file names.
15. Not verified: every challenger GUI score, the MAI-Gym convention, REAP-48 vision, any 9B or MoE llama-bench figure on the mini, and the claim that mismatched `-b` and `-ub` corrupts Qwen3.5 state under Metal (it was measured on ROCm).

---

## 0. Method and labels

- **VERIFIED**: I read it from the Hugging Face API, a repo file, or a vendor doc page on 2026-10-27. This covers file sizes, licences, dates, base models and download counts. Downloads are Hugging Face's rolling 30-day figure and measure popularity only.
- **INDEPENDENT**: a party that did not train the model measured it and states the method. Here that means Artificial Analysis (AA) and one third-party grounding table (marked).
- **VENDOR**: the author, or the uploader of a quantized build, published it. Nobody checked it.
- **UNVERIFIED**: second hand, or my arithmetic.
- AA: I parsed the embedded data on https://artificialanalysis.ai/leaderboards/models (266 scored records, 172 open weights). "e" means AA estimated the index. tau2 is AA's tool-use test.
- Tree walks, all through `https://huggingface.co/api/models?filter=base_model:{finetune|merge|adapter|quantized}:<repo>&sort=downloads` with cursor paging. I removed names with abliterat, uncensor, heretic, huihui, quant and format words before reading. I kept the under-100-download repos in view by also filtering on agent, GUI, tool, grounding, distill, prune, draft and speed words. A repo with no `base_model` tag is invisible to this walk (MAI-Gym-9B and Ornith are such repos). I found them by organisation and name search.
- Size-range crawls: `pipeline_tag=image-text-to-text&num_parameters=min:5B,max:17B`, sorted by downloads (900), recency (900) and trending (400). Same range for `text-generation` (600 + 600). Author crawls covered Qwen, google, mistralai, LiquidAI, ibm-granite, ByteDance-Seed, zai-org, openbmb, XiaomiMiMo, nvidia, microsoft, allenai, tencent, Tongyi-MAI, inclusionAI, stepfun-ai, moonshotai, Zyphra, Hcompany, mPLUG, apple, swiss-ai, facebook, arcee-ai, LGAI-EXAONE and others.
- Gaps: the adapter walk for Qwen3.5-9B stopped at my 800 cap. OSWorld, ScreenSpot-Pro and LMArena are JavaScript pages and returned nothing. BFCL's official page was last updated 2025-12-16.
- Perry needs vision. A text-only model can be a planner only if a second model reads the screen. The earlier report judged that two-model design weak for Perry, and I agree. I list text-only models separately.

---

## 1. What exists in range (and what does not)

### 1.1 Families that ship in range, with the verdict

| Family | Mid-size model | Licence, date | Vision | Verdict for Perry |
|---|---|---|---|---|
| Qwen3.5 | 9B (9.65B with ViT) | Apache-2.0, 2026-02-27 | yes | The base to beat. Owner's test: 15/16 at 1.4 s. |
| Qwen3-VL | 8B Instruct, Thinking | Apache-2.0, 2025-10-11 | yes | Older. 679 + 79 finetunes. Only useful as a base for old GUI tunes. |
| Qwen3.8 | none below 27B (VERIFIED, author list) | | | Nothing to add. |
| Gemma 4 | 12B Unified, E4B, E2B | Apache-2.0 (card links the Apache terms), 12B on 2026-05-23 | yes (12B also audio) | Weak tool use and no GUI training. Section 3.4. |
| Ministral 3 | 8B, 14B | Apache-2.0, Dec 2025 | yes | AA index 5.5 and 6.0, tau2 26.6 and 27.2 (INDEPENDENT). Loses. |
| Granite 4.2 | 8B (text), vision-4.1-4B | Apache-2.0, Aug 2026 | 4B only | 8B is text only. AA index 11.1. |
| GLM | GLM-4.6V-Flash 10B | MIT, 2025-12-07 | yes | Older, no AA row. GLM-5.3-Flash is 321B. |
| InternVL | 3.5-8B, 14B | Apache-2.0, 2025-08 | yes | Nothing newer on the Hub in range. |
| MiniCPM-V | 4.5 (8.7B), 4.6 (1.3B), 4.7 (1B and 35B-A3B) | Apache-2.0 | yes | No 4.x 8B after Aug 2025. 4.7-35B-A3B is 35B. |
| Step3-VL | 10B | Apache-2.0, 2026-01-13 | yes | AA index 7.7. Loses. |
| Moondream 3.1 | 9B total, 2B active | Moondream Model License (custom) | yes | Own engine only. Pointing and captions, no planner. |
| ZAYA1-VL | 8B total, 0.7B active | Apache-2.0, 2026-04-20 | yes | Needs a transformers fork. No GUI numbers. Section 3.2. |
| LFM2.5 | 8B-A1B, 24B-A2B | `other` (LiquidAI licence) | no (VL is 3B dense) | Text only, always thinks. Section 3.2. |
| K2 Horizon | 7B (9.0B params), 3.7B | Apache-2.0, 2026-09-01 | no | Highest independent index in range (20.6) but text only. |
| Phi-4 | reasoning-vision 15B | MIT, 2026-01-23 | yes | 15B, Q4 about 9 GB. No AA row, no GUI claim found. Not pursued. |

### 1.2 INDEPENDENT scores (AA, parsed today)

| Model | Index | tau2 | IFBench | MMMU-Pro | Note |
|---|---|---|---|---|---|
| Qwen3.5-9B non-reasoning | 13.3e | **85.1** | 37.8 | 66.8 | The relevant mode for Perry |
| Qwen3.5-9B reasoning | 11.2 | **86.8** | 66.7 | 69.2 | |
| Qwen3.5-4B reasoning | 13.1e | 92.1 | 52.0 | 65.4 | Cross-reference, lower tier |
| Gemma 4 12B reasoning | 14.2e | 36.3 | 73.5 | 69.7 | |
| Gemma 4 12B non-reasoning | 9.4e | 31.9 | 45.2 | 62.0 | |
| Gemma 4 E4B reasoning / non | 8.9 / 7.5e | 20.8 / 26.0 | 44.2 / 40.5 | 51.4 / 51.2 | |
| Gemma 4 26B-A4B reasoning / non | 16.7e / 13.1e | 43.6 / 40.4 | 72.4 / 45.4 | 69.2 / 66.7 | 15 GB at Q4, outside the range |
| Ministral 3 14B / 8B | 6.0 / 5.5 | 27.2 / 26.6 | 32.0 / 29.1 | 49.8 / 46.0 | |
| Granite 4.2 8B | 11.1 | not shown | not shown | none | text only |
| LFM2.5-8B-A1B | 7.2e | 16.1 | 55.6 | none | text only; vendor claims BFCL-style strength |
| Step3 VL 10B | 7.7 | not shown | not shown | | |
| Qwen3.6-35B-A3B reasoning / non | 18.2 / 15.2e | 95.3 / 85.1 | 64.4 / 36.2 | | The base of the REAP-48 model |
| K2 Horizon 7B / 3.7B | 20.6 / 15.6 | not shown | not shown | none | text only |
| G9v3-3B (AI9Stars) | 10.8 | not shown | | | text only, 3B |

Read: for tool calling, Qwen is two to three times ahead of every other mid family. Gemma 4's own card claims Tau2 69.0% for the 12B (VENDOR). AA measures 31.9 to 36.3. The two harnesses differ, and I did not reconcile them. No tune of any of these has an AA row. MiMo-9B, Ornith, MAI-Gym, Holo, UI-Mate and GUI-Owl have no independent score of any kind (VERIFIED, absent from the AA data).

---

## 2. Qwen3.5-9B derivatives: what the tree walk found

All VERIFIED today. "dl" is the main repo's rolling downloads.

### 2.1 Worth testing

| Repo | Base, licence, date | What it is | dl | Vision | Files | Scores |
|---|---|---|---|---|---|---|
| `Hcompany/Holo-3.1-9B` | Qwen3.5-9B, Apache-2.0, 2026-05-29 | Computer-use agent, native function calling, documented prompt | 689 (GGUF repo 7,358) | yes | mradermacher: Q4_K_M 5.63, IQ4_XS 5.23, Q6_K 7.36 GB; mmproj Q8 0.62 or f16 0.92 | VENDOR chart only. Card has no numbers in text. Earlier report: AndroidWorld 71 (VENDOR). |
| `Tongyi-MAI/MAI-Gym-9B` | Qwen3.5-9B (paper), Apache-2.0, 2026-10-16 | RL-trained GUI agent. No `base_model` tag. | 207 (GGUF 1,670 + 3,057) | yes | mradermacher: Q4_K_M 5.63, IQ4_XS 5.23 GB; mmproj Q8 0.62, f16 0.92 | VENDOR: OSWorld-Verified 76.2, MobileWorld 78.4 (arXiv 2610.20939). Base 41.8 (VENDOR). |
| `XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B` | Qwen3.5-9B, MIT, 2026-09-21 | SFT on MiMo agent data: code, cyber, general agent, visual coding | 21,185 | yes | ggml-org official (8,312 dl); bartowski (994,686 dl): Q4_K_M 5.84, IQ4_XS 5.23, Q6_K 7.79 GB; mmproj 0.92 | VENDOR: Toolathlon-Verified 35.2 vs 25.9, AutomationBench 30.3 vs 5.0, Terminal-Bench 2.1 37.1 vs 27.0, SWE-Bench Verified 61.1 vs 60.0. "Visual" is visual coding, not GUI grounding. |
| `ornith-ai/Ornith-1.5-9B` | Qwen3.5 lineage (no base tag), MIT, 2026-08-18 | Self-improvement RL, reasoning by default | 464,941 (GGUF 5,217,055) | yes (mmproj in the official GGUF repo) | Q4_K_M 5.78, Q5_K_M 6.64, Q8_0 9.79 GB; mmproj 0.92; official DFlash draft 1.3B | VENDOR: Terminal-Bench 2.1 46.2 vs 21.3 for Qwen3.5-9B on the card. No GUI score. |

### 2.2 Considered and dropped (one line each)

| Repo | Why dropped |
|---|---|
| `Cloudflare/clef-flash` (44,538 dl, 885 likes), `autotrust/JEV-9B` (725,231 dl), `baselabs/elephant-1`, `apus-ailab/APUS-Reflex-9B`, `vllm-sr/Decision-1.0-Lux-9B` | "Decision models". They return a probability for each allowed option in one pass. No free text, no coordinates. A possible router later, not a brain. |
| `empero-ai/Qwen3.8-9B-Distill` (9,162 dl) | 70k traces from Qwen3.8 2.4T, math and code weighted. Always opens with `<think>`. Its own table shows GSM8K down 1.5 points. |
| `Jackrong/...Claude-4.6-Opus / Gemini-3.1 / GLM5.1 / DeepSeek-V4-Flash` distills, `empero-ai` Qwythos and Qwable | Reasoning-trace distills of closed models. Terms of the teacher unclear, text-focused, thinking-heavy. |
| `inclusionAI/UI-Venus-2-9B` (13,703 dl) | **No licence** at the author (`license: None`). The Apache tag on bartowski's GGUF is the uploader's. Excluded by your rule. |
| `tencent/UI-Mate-9B` (1,355 dl) | VENDOR OSWorld-Verified 66.2. The card says an agent checkpoint that needs the official prompt, parser and harness (`Tencent/UI-Mate`). Harness cost is high. |
| `OpenMobile-2/OpenMobile-2-9B` | Android only. AndroidWorld 74.0 (VENDOR). |
| `microsoft/Fara1.5-9B` | Browser only. |
| `inclusionAI/ZwZ2-9B` | Multi-region visual QA (+4.96 on 25 benchmarks, VENDOR). Not an action model. |
| `allenai/tmax-9b`, `qwen35-9b-*` | Terminal-agent research checkpoints. No GUI, no GGUF. |
| `summerMC/Qwen3.5-9B-SpeedX9-GDN32` | Converts the model to linear attention. Needs a custom CUDA engine. Not llama.cpp. |
| `z-lab/Qwen3.5-9B-DFlash`, `yuyijiong/Qwen3.5-9B-Eagle3`, Ornith DFlash | Speculative drafts. Section 5. |
| 600+ other repos | Role-play, medical, SQL, SEO, safety-research, abliterated and benchmark-entry tunes. |

### 2.3 GUI tunes of other bases (low download, in range)

| Repo | Base | Licence | dl | Claim (VENDOR) | Note |
|---|---|---|---|---|---|
| `PrentisAI/GroundGUI-8B` (2026-10-08) | Qwen3-VL-8B-Instruct | Apache-2.0 | 76 | ScreenSpot-v2 95.2, ScreenSpot-Pro 63.9, OSWorld-G 65.4, UI-Vision 38.3 | Grounding only. 0 to 1000 grid. Needs the `scalecua_toolcall` system prompt from its repo. |
| `docling-project/DeskForge-Gemma4-E4B` (2026-10-05) | Gemma 4 E4B | Apache-2.0 | 5,579 | ScreenSpot-v2 79.56, ScreenSpot-Pro 21.95 (base 46.86 and 1.83) | Outputs `pyautogui` calls with fractions. 4B-class only. |
| `mPLUG/GUI-Owl-1.5-8B-Instruct / Think` | Qwen3-VL | MIT | 4,797 / 22,523 | OSWorld-Verified 52.3 / 52.9 (earlier report) | Older than the Qwen3.5 tunes. |
| `Hcompany/Holo2-8B` | Qwen3-VL-8B | Apache-2.0 | 246 | not read | Old pixel convention (section 4). |
| `zhandrew/ai-kvm-grounder-8b` | GUI-Owl-1.5-8B | MIT | 23 | none | Single-person tune. No claims. |
| `GUI-Libra-8B`, `MemGUI-8B-SFT`, `UI-MOPD/*` | Qwen3-VL-8B | Apache-2.0 | under 100 | none read | Research checkpoints. |

---

## 3. Small MoE and speed-oriented models

### 3.1 Why MoE matters here

Decode speed is memory bandwidth divided by the bytes read per token. A 3B-active MoE reads about a third of what a 9B dense reads. Prefill is compute-bound, and the screenshot makes it the bigger share of a Perry step. The only measurement on your machine class is below.

### 3.2 The measured one: pruned Qwen3.6-35B-A3B

`crucible-labs/Qwen3.6-35B-A3B-REAP-48-v2-GGUF` (created 2026-08-25, Apache-2.0 tag, 3,659 downloads, 30 likes). REAP removes 48% of the routed experts (133 of 256 remain). Eight are still routed per token, so about 3B parameters stay active.

| Fact | Value | Label |
|---|---|---|
| File | `Qwen3.6-35B-A3B-REAP-48-v2.gguf`, 9.43 GB (8.78 GiB) | VERIFIED |
| Vision | None in the repo (text only). Base mmproj is `unsloth/Qwen3.6-35B-A3B-GGUF/mmproj-F16.gguf`, 0.90 GB. Compatibility with the pruned model is not tested by anyone I found. | VERIFIED file, UNVERIFIED fit |
| Speed on **M4 mini 16 GB, Metal**, `llama-bench -p 512 -n 128 -ngl 999 -fa 1 -r 3` | prefill 417.18 tok/s, decode 29.24 tok/s | VENDOR (uploader) |
| Quality | KL vs the pruned f16: mean 0.0196, top-1 agreement 96.2%. HumanEval+ 90.9%, MBPP+ 75.7%, BFCL-simple 93.2% (own harness, ROCm). | VENDOR |
| Base model, for scale | AA index 18.2 reasoning, 15.2e non-reasoning; tau2 95.3 / 85.1 | INDEPENDENT (base) |
| Pruning cost | The author of a different prune (IAmTheRealGumbo) shows HumanEval 94.5% at 50% of experts, 85.4% at 25%, 9.1% at 10%. | VENDOR |
| Uploader's flags | `-b 512 -ub 512` on a 16 GB Mac (memory), `-fa on`, `-ctk bf16 -ctv bf16`, matched `-b` and `-ub` | VENDOR |
| DFlash draft on this Mac | n=2: decode down 4.9% (code) and 28% (prose); n=4: down 20.6% and 53% | VENDOR |

Cautions:
- It does not fit comfortably on 16 GB. The uploader reports a 12 GiB Metal working set. Weights 8.78 GiB + mmproj about 0.84 GiB leaves about 2 GiB for KV and buffers. Cut `-c` to 8192 for the test.
- Expert pruning was calibrated on text. Image-token handling may degrade. Test it before trusting it.
- The uploader says mismatched `-b` and `-ub` corrupts the recurrent state of quantized Qwen3.5/3.6 models (perplexity 1402.95 against 2.72). I found only ROCm reports (llama.cpp issue 28211, HIP, gfx1151) and nothing on Metal. This matters to your 9B tests too. Run one pass with `-b 2048 -ub 2048` to rule it out. UNVERIFIED on Metal.
- Other prunes: `keithnull/Qwen3.6-VL-REAP-26B-A3B-GGUF` has vision built in (Q4_K_M 16.27, IQ4_XS 14.59, Q3_K_S 11.7 GB + mmproj 0.9). That is a 24 GB model. `IAmTheRealGumbo/...REAP-64-experts` (10.93B) has HumanEval 85.4% and no GGUF I found. `Nickyang/...RAZOR-19B-A3B-E128of256` and `crucible-labs` v1 exist. None has GUI evidence.

### 3.3 Other small MoE (none usable for the screen job)

| Model | Total / active | Licence | Vision | Why not |
|---|---|---|---|---|
| ZAYA1-VL-8B (Zyphra, 2026-04-20, 322,819 dl) | 8B / 0.7B | Apache-2.0 | yes | Needs `Zyphra/transformers@zaya1-vl`. Only GGUF is one 172-download upload. On its own card it trails Qwen3.5-4B on Blink, MMMU and RealWorldQA (VENDOR). No GUI or tool numbers. |
| Moondream 3.1 (2026-06-30) | 9B / 2B | custom | yes | Runs on Photon, not llama.cpp. Offers query, detect, point and caption only. A possible pointing helper. |
| LFM2.5-8B-A1B (2026-05-28, 31,608 dl) | 8.3B / 1.5B | `other` | no | Text only. Reasoning model. AA tau2 16.1 (INDEPENDENT). Official DSpark draft (328M, "about 2.5x", VENDOR) but llama.cpp DSpark supports only Qwen3 backbones today (docs). |
| LFM2.5-24B-A2B (2026-10-12, 22,698 dl) | 24B / 2.45B | `other` | no | Always thinks. About 13 to 14 GB at Q4 (UNVERIFIED). 184 tok/s on M5 Max (VENDOR). |
| Ling-3.0-tiny (2026-08-10, MIT) | 7.9B / small | MIT | no | AA index 11.1 (INDEPENDENT), text only, MLX path needs a patched Ollama. |
| Kimi-VL-A3B (2025-04-09) | 16B / 3B | MIT | yes | Old, about 10 GB at Q4. No GUI evidence. |
| Gemma 4 26B-A4B | 25.8B / 4B | Apache-2.0 | yes | 15 GB class, AA tau2 40 to 44. Not mid. |
| Nemotron 3.5 Lightning 30B-A3B | 30B / 3B | NVIDIA licence | no | About 17 GB at Q4, text only. |

### 3.4 Gemma 4 in detail

- `google/gemma-4-12B-it`: 11.95B, Apache-2.0, 2026-05-23, 1,786,994 downloads, text + image + audio, native function calling (card).
- Official GGUF: `google/gemma-4-12B-it-qat-q4_0-gguf`, `gemma-4-12b-it-qat-q4_0.gguf` 6.98 GB + `mmproj-gemma-4-12b-it-qat-q4_0.gguf` 0.18 GB (VERIFIED). An official `-assistant` drafter (0.4B) exists.
- Card scores (VENDOR): MMMU Pro 69.1, Tau2 69.0%. No GUI benchmark appears. The card lists "screen and UI understanding" and "pointing" as skills, with no coordinate convention.
- INDEPENDENT: AA tau2 31.9 to 36.3 (above). Third-party grounding: DeskForge's table has Gemma 4 31B at 70.7 on its own held-out set and Gemma 4 E4B at ScreenSpot-Pro 1.83 before tuning.
- Community tunes (`yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2`, 961 dl, 109 likes): the card is a personal update post with no scores. Skip.
- Verdict: keep it as a chat or voice answer candidate (its IFBench is higher). Do not use it for clicks.

---

## 4. GUI tunes: exact prompt and coordinate format

Every convention below is read from the author's code, docs or card today. Where a tune has no published format I say so.

| Model | Coordinates | Prompt and output | Source | Label |
|---|---|---|---|---|
| **Qwen3.5-9B** (your winner) | 0 to 1000 relative, JSON schema enforced by you | Your own prompt, thinking off | your test | VERIFIED by you |
| **Holo-3.1-9B**, Holo4 | **Integers 0 to 1000, normalised to the exact image you send, origin top-left.** `abs = x/1000 * width`. Send and scale against the same bytes. | Single-shot localization: one user turn, **image first, then text**, no history, thinking off (`chat_template_kwargs: {enable_thinking: false}`), `temperature=0`, JSON via structured output. Exact text below. | hub.hcompany.ai core-concepts and element-localization pages; docs name Holo4 and Holo3.1-35B-A3B | VERIFIED page; applies to the 9B by family (UNVERIFIED) |
| **MAI-Gym-9B** | **Not published.** The harness is "coming soon". The paper says its GUI actions follow Qwen-UI-Agent (Appendix A.3), which lists actions but no range. Sibling code from the same team: MAI-UI divides by `SCALE_FACTOR = 999`; OpenGCUA's desktop harness says "Coordinates are NORMALIZED integers in [0, 1000]", `coordinate_range: 1000`. | Sibling MAI-UI grounding prompt below. Sibling OpenGCUA desktop prompt: `pyautogui` calls inside `<tool_call>...</tool_call>`, "Never copy raw pixel coordinates". | github.com/Tongyi-MAI/MAI-UI `src/prompt.py`, `src/mai_grounding_agent.py`; github.com/Tongyi-MAI/OpenGCUA `packages/harness/examples/osworld/maiui_agent.py`, `configs/macos_demo.json` | VERIFIED code; MAI-Gym itself UNVERIFIED |
| UI-Venus-2-9B (excluded) | 0 to 1000, point `[x,y]`; `[-1,-1]` if infeasible | User-only prompt, no system message, thinking off, temperature 0 | github.com/inclusionAI/UI-Venus `models/grounding/ui_venus2_gd.py` | VERIFIED |
| GUI-Owl-1.5 | 0 to 1000 relative by default | tool calls | X-PLUG/MobileAgent `Mobile-Agent-v3.5/README.md` | VERIFIED |
| UI-Mate-9B | "relative"; tool text says "the screen's resolution is 1000x1000" | Needs `Tencent/UI-Mate` `agents/ui_mate_agent.py` | repo code | VERIFIED |
| GroundGUI-8B | 0 to 1000 | `<tool_call>{"name":"computer_use","arguments":{"action":"left_click","coordinate":[x,y]}}</tool_call>`; system prompt `scalecua_toolcall` lives in its repo | HF card | VERIFIED |
| DeskForge-Gemma4-E4B | Fractions of the screen | `pyautogui` call | HF card | VERIFIED |
| Holo1 / 1.5 / 2 (older) | **Pixels** of the smart_resized image | `Click(x, y)` text | hai-cookbook `utils/localization.py` | VERIFIED |
| Gemma 4 base | Unknown | Unknown | none found | UNVERIFIED |

### 4.1 Exact Holo localization prompt (VERIFIED, element-localization page)

```
Localize an element on the GUI image according to the provided target and output a click position.
 * You must output a valid JSON following the format: {"properties":{"x":{"description":"X coordinate as integer in [0, 1000]","maximum":1000,"minimum":0,"type":"integer"},"y":{"description":"Y coordinate as integer in [0, 1000]","maximum":1000,"minimum":0,"type":"integer"}},"required":["x","y"],"title":"VisualLocalizerOutput","type":"object"}
 Your target is:
<element description>
```

Use it with your enforced JSON schema, `temperature 0`, thinking off. This is almost your Qwen3.5 recipe, so it is a fair test. For agent loops (not the click step), Holo says: thinking on, temperature 0.8, wrap each screenshot as `<observation>\n[image]\n</observation>` in a user turn, keep the last 3 screenshots, and end tasks with an `answer` tool. Holo also warns that any resize, crop or DPI mismatch between the image sent and the image scaled against causes misclicks.

### 4.2 MAI-UI grounding prompt (VERIFIED, the public sibling of MAI-Gym)

System message:

```
You are a GUI grounding agent. 
## Task
Given a screenshot and the user's grounding instruction. Your task is to accurately locate a UI element based on the user's instructions.
First, you should carefully examine the screenshot and analyze the user's instructions,  translate the user's instruction into a effective reasoning process, and then provide the final coordinate.
## Output Format
Return a json object with a reasoning process in <grounding_think></grounding_think> tags, a [x,y] format coordinate within <answer></answer> XML tags:
<grounding_think>...</grounding_think>
<answer>
{"coordinate": [x,y]}
</answer>
```

User turn: instruction text, then the image. The no-reasoning variant in their eval forces the reply to start with `<tool_call>\n{"name": "grounding", "arguments": {"action": "click", "coordinate": [` and divides by 1000 (eval script) or 999 (agent code). Temperature 0.

### 4.3 How to test MAI-Gym fairly (cheap first)

1. **Re-score, no new run.** Take the saved 8/16 outputs. If every x and y is at most 1000, multiply by `W/1000` and `H/1000` of the image you sent and re-check the hits. If they land, the convention is confirmed and the 8/16 was a harness bug.
2. If values exceed 1000, they were pixels and the 8/16 stands.
3. Run it with the Holo prompt above, and again with the 4.2 prompt plus the guide text. Same 16 targets, same `--image-min-tokens 1024`.

Why the pixel reading fits your symptom (inference, UNVERIFIED): reading `y_norm` as pixels is short by `y*(1 - 1000/H)`. For H near 1100 and y from 300 to 500 that is 27 to 45 px. The x error would grow with width and was probably clipped in your scoring.

### 4.4 Behaviour traps that affect step time

- Holo, MiMo and Ornith are reasoning-first. Thinking on will blow a 1.4 s step to many seconds. Turn it off for the click step. Whether MiMo's template honours `enable_thinking:false` is UNVERIFIED (its card shows the flag set to True and uses SGLang `--reasoning-parser mimo`).
- Perry's click step is a single-shot localization. Use the Holo "single call" settings, not the agent-loop settings.
- Image tokens: Qwen3.5 uses 32 px per token (patch 16, merge 2, from `processor_config.json`). A 1024-token minimum is a large share of the step.

---

## 5. Speed tricks, with what is actually supported

| Trick | Support in llama.cpp (docs read today) | Fit for Perry |
|---|---|---|
| `draft` (small model) | yes | Replies are short. Gain is small. |
| `draft-mtp` | yes | Hurt Qwen3.5-9B under Metal (-11% to -28%, issue 23752 per the lineup report). Keep off. |
| `draft-eagle3` | yes. Qwen3.5-9B draft exists (`yuyijiong/Qwen3.5-9B-Eagle3`, 0.5B, 213 dl). Not on the supported list. | Not worth it. |
| `draft-dflash` | yes, needs `-fa on`. Drafts exist: `z-lab/Qwen3.5-9B-DFlash` (1.3B, 4,710 dl), `modal-labs/Qwen3.5-9B-DFlash`, Ornith's. | Measured regression on the M4 mini (section 3.2). |
| `draft-dspark` | yes, Qwen3 backbones only | LFM drafts do not load yet. |
| Gemma 4 `-assistant` drafters | Eagle3/DSpark routes exist for the 31B and 26B-A4B (RedHatAI). The 12B assistant is not on the list. | Skip. |
| Linear-attention conversion (SpeedX9) | no | CUDA only. |

Conclusion: the speed lever for Perry is fewer prefill tokens and fewer active parameters, not drafting. Keep the existing recurrent-state checkpoint cache from the lineup report.

---

## 6. Independent evidence hunt: what I found

- AA: covers bases only (section 1.2). No tune.
- BFCL: official page last updated 2025-12-16, no 2026 rows. A BenchLM snapshot (2026-07-29) lists LFM2.5-8B-A1B at 49.7 and no Qwen3.5-9B, Gemma 4 12B or MiMo row. BenchLM copies vendor tables, so I count it as VENDOR.
- ScreenSpot-Pro, OSWorld, LMArena: boards are JavaScript pages, nothing readable. A benchmark aggregator lists Qwen3.5-4B 60.3 and Qwen3.5-2B 54.5 as "imported". Those match the vendor figures, so they are VENDOR.
- DeskForge held-out grounding table (THIRD PARTY, competing author, own data): UI-Venus-2-9B 78.92 mean, Gemma4-31B 70.74, GroundNext-7B 70.55, UI-TARS-1.5-7B 65.25, Gemma4-E4B 12.27, DeskForge-Gemma4-E4B 85.12. Qwen3.5-9B, Holo-3.1 and MAI-Gym were not in it.
- Small community runs: none found for Qwen3.5-9B tunes against base on tools or JSON. The previous reports found two tiny tool-use tests for Ornith (all 18/18, and 91/100 with no baseline). I found nothing new.
- Speed: no independent llama.cpp prefill figure for Qwen3.5-9B on a 16 GB M4. A web search found a blog claiming about 22 tok/s on a 16 GB M4 base (MLX, earlier toolchain, UNVERIFIED) and calculator pages (estimates). The only measured MoE row is the crucible one.

---

## 7. Ranked shortlist: benchmark these on the 16 GB mini

Ranking is usefulness per second: expected accuracy on Perry's click and plan steps, weighted by step time. All challengers share the Qwen3.5 architecture except #4, so the same llama.cpp flags work. Download sizes are VERIFIED file sizes (weights + mmproj).

Common flags (from your test): `--image-min-tokens 1024`, enforced JSON schema, 0 to 1000 coordinates, thinking off, `temperature 0`. Also run one pass with `-b 2048 -ub 2048` (section 3.2 caution).

| # | Model | Repo and files | Download | Prompt and coordinates | Extra flags and notes |
|---|---|---|---|---|---|
| 1 | **Qwen3.5-9B (control)** | `unsloth/Qwen3.5-9B-GGUF`: `Qwen3.5-9B-UD-Q4_K_XL.gguf` 5.97 GB + `mmproj-F16.gguf` 0.92 GB | 6.89 GB | Your current prompt, 0 to 1000 | Already 15/16 at 1.4 s. Re-run beside every challenger on the same day. |
| 2 | **Holo-3.1-9B** | `mradermacher/Holo-3.1-9B-GGUF`: `Holo-3.1-9B.Q4_K_M.gguf` 5.63 GB + `Holo-3.1-9B.mmproj-f16.gguf` 0.92 GB (or mmproj-Q8_0 0.62 GB) | 6.55 GB (6.25 with Q8 mmproj) | Section 4.1 exactly. 0 to 1000. | Thinking off for clicks. Apache-2.0. Community GGUF only: convert and host your own audited copy if it wins. |
| 3 | **MAI-Gym-9B, re-run** | `mradermacher/MAI-Gym-9B-GGUF`: `MAI-Gym-9B.Q4_K_M.gguf` 5.63 GB + `MAI-Gym-9B.mmproj-f16.gguf` 0.92 GB | 6.55 GB | First re-score old outputs (4.3). Then Holo prompt, then MAI-UI prompt (4.2), 0 to 1000 and 0 to 999. | Apache-2.0. Longest-shot claim (OSWorld 41.8 to 76.2, VENDOR) but unpublished prompt. Same-day control needed. |
| 4 | **Qwen3.6-35B-A3B REAP-48 v2 (MoE speed play)** | `crucible-labs/Qwen3.6-35B-A3B-REAP-48-v2-GGUF`: `Qwen3.6-35B-A3B-REAP-48-v2.gguf` 9.43 GB + `unsloth/Qwen3.6-35B-A3B-GGUF`: `mmproj-F16.gguf` 0.90 GB | 10.33 GB | Same as your Qwen recipe, 0 to 1000 | `-b 512 -ub 512 -c 8192 -fa on`; try `-ctk bf16 -ctv bf16`. No draft model. First step: does an image prompt even work (UNVERIFIED)? Then run `llama-bench -p 512 -n 128 -fa 1` for #1 and #4 on the same box. Quit other apps; headroom is about 2 GiB. |
| 5 | **MiMo-V2.6-Distill-Qwen-9B** | `ggml-org/MiMo-V2.6-Distill-Qwen-9B-GGUF` (official, MIT) or `bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF`: `...-Q4_K_M.gguf` 5.84 GB + `mmproj-MiMo-V2.6-Distill-Qwen-9B-f16.gguf` 0.92 GB | 6.76 GB | Your recipe. Test JSON strictness, tool calls and plan steps rather than clicks. | MIT. Needs `enable_thinking:false` to stay fast (UNVERIFIED that its template allows it). Its gains are agentic text tasks, so score it on Perry's plan and tool-call prompts. |
| reserve | Ornith-1.5-9B | `ornith-ai/Ornith-1.5-9B-GGUF`: `Ornith-1.5-9B-Q4_K_M.gguf` 5.78 GB + `mmproj-Ornith-1.5-9B-BF16.gguf` 0.92 GB | 6.70 GB | Your recipe | MIT. 5.2M GGUF downloads, the most used tune in range. Reasoning by default. Replace #5 with it if MiMo's template fails the no-think test. |

Adoption rule (from the earlier report): a challenger must beat the control by 2 or more of 16 targets (about 10 points) at equal or lower median step time, keep JSON validity at 100% with the schema on, and pass 20 chat and tool-call prompts. For #4 the bar is the same accuracy at a lower step time.

Do not spend time on: UI-Venus-2-9B (no licence), Gemma 4 12B for clicks, any decision-head model, any text-only MoE, any abliterated build, speculative drafts.

### 7.1 Provisional pick per Mac class

| Class | Pick today | Files | Download | Change it if |
|---|---|---|---|---|
| **16 GB** (M4 base mini, your test box) | **Qwen3.5-9B UD-Q4_K_XL** | `Qwen3.5-9B-UD-Q4_K_XL.gguf` + `mmproj-F16.gguf` | 6.89 GB | Holo-3.1-9B or MAI-Gym-9B clears the adoption rule: swap in that tune, same size. If REAP-48 works with vision and its step time drops with equal accuracy, offer it only when the user has no other large apps (headroom is thin at 16 GB). |
| **24 GB** | **Qwen3.5-9B UD-Q6_K_XL** | `Qwen3.5-9B-UD-Q6_K_XL.gguf` 8.76 GB + `mmproj-F16.gguf` 0.92 GB | 9.68 GB | REAP-48 passes the vision test: it fits with room for context and is the faster option on this class. The winning 16 GB tune at Q6_K (7.36 GB for the Holo/MAI-Gym files) replaces the base. Qwen3.6-35B-A3B UD-IQ4_XS is 17.73 + 0.90 = 18.63 GB, at the edge of a 0.75 fit rule on 24 GB (18 GB). |

Both picks are provisional. They rest on one 16-target test, an AA tool-use gap that favours Qwen by 2 to 3 times, and the absence of any independent evidence for a better mid model.

---

## 8. What I could not verify

- Any challenger's GUI score. All are VENDOR, and the official OSWorld and ScreenSpot-Pro boards listed none of them.
- MAI-Gym-9B's prompt and range. The conclusion in section 4 comes from sibling code, not from MAI-Gym itself.
- Whether the Holo docs (written for Holo4 and Holo3.1-35B-A3B) apply unchanged to the 9B.
- REAP-48 with an image prompt, and its step time against the 9B on the mini.
- Any llama-bench prefill or decode row for a dense 9B on the 16 GB M4. My 15 tok/s is arithmetic (bandwidth divided by file size).
- The `-b`/`-ub` corruption claim and the bf16 KV requirement on Metal.
- Whether MiMo and Ornith templates honour a no-think switch.
- Pruned-model behaviour on image tokens.
- Gemma 4's pointing convention.
- A full adapter walk for Qwen3.5-9B (capped at 800).

---

## Sources

Hugging Face API and repos (all read 2026-10-27):
- https://huggingface.co/api/models (filter=base_model:finetune|merge|adapter|quantized:Qwen/Qwen3.5-9B, Qwen/Qwen3-VL-8B-Instruct, Qwen/Qwen3-VL-8B-Thinking, google/gemma-4-12B-it, google/gemma-4-E4B-it, XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B, mistralai/Ministral-3-8B-Instruct-2512, Ministral-3-14B-Instruct-2512; plus num_parameters and author queries)
- https://huggingface.co/Tongyi-MAI/MAI-Gym-9B
- https://huggingface.co/Hcompany/Holo-3.1-9B
- https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B
- https://huggingface.co/ornith-ai/Ornith-1.5-9B and https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF
- https://huggingface.co/google/gemma-4-12B-it and https://huggingface.co/google/gemma-4-12B-it-qat-q4_0-gguf
- https://huggingface.co/crucible-labs/Qwen3.6-35B-A3B-REAP-48-v2-GGUF
- https://huggingface.co/keithnull/Qwen3.6-VL-REAP-26B-A3B-GGUF
- https://huggingface.co/IAmTheRealGumbo/Qwen3.6-35B-A3B-REAP-64-experts
- https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF and https://huggingface.co/unsloth/Qwen3.5-9B-GGUF
- https://huggingface.co/mradermacher/MAI-Gym-9B-GGUF and https://huggingface.co/mradermacher/Holo-3.1-9B-GGUF
- https://huggingface.co/bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF and https://huggingface.co/ggml-org/MiMo-V2.6-Distill-Qwen-9B-GGUF
- https://huggingface.co/inclusionAI/UI-Venus-2-9B
- https://huggingface.co/tencent/UI-Mate-9B
- https://huggingface.co/PrentisAI/GroundGUI-8B
- https://huggingface.co/docling-project/DeskForge-Gemma4-E4B
- https://huggingface.co/Zyphra/ZAYA1-VL-8B
- https://huggingface.co/moondream/moondream3.1-9B-A2B
- https://huggingface.co/LiquidAI/LFM2.5-8B-A1B and https://huggingface.co/LiquidAI/LFM2.5-24B-A2B
- https://huggingface.co/inclusionAI/Ling-3.0-tiny
- https://huggingface.co/OpenMobile-2/OpenMobile-2-9B
- https://huggingface.co/inclusionAI/ZwZ2-9B
- https://huggingface.co/Cloudflare/clef-flash
- https://huggingface.co/empero-ai/Qwen3.8-9B-Distill
- https://huggingface.co/summerMC/Qwen3.5-9B-SpeedX9-GDN32

GUI formats and papers:
- https://hub.hcompany.ai/models-api/build-an-agent/core-concepts.md
- https://hub.hcompany.ai/models-api/element-localization.md
- https://raw.githubusercontent.com/hcompai/hai-cookbook/HEAD/utils/localization.py
- https://github.com/Tongyi-MAI/MAI-UI (`src/prompt.py`, `src/mai_grounding_agent.py`, `evaluation/grounding/models/MAI_UI.py`)
- https://github.com/Tongyi-MAI/OpenGCUA (`packages/harness/examples/osworld/maiui_agent.py`, `packages/harness/configs/macos_demo.json`)
- https://github.com/Tongyi-MAI/MAI-Gym and https://arxiv.org/html/2610.20939
- https://arxiv.org/html/2607.28227 (Qwen-UI-Agent technical report)
- https://github.com/inclusionAI/UI-Venus (`models/grounding/ui_venus2_gd.py`)
- https://github.com/Tencent/UI-Mate (`agents/ui_mate_agent.py`)
- https://github.com/X-PLUG/MobileAgent (`Mobile-Agent-v3.5/README.md`)

Independent and tooling:
- https://artificialanalysis.ai/leaderboards/models
- https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/speculative.md
- https://github.com/ggml-org/llama.cpp/issues/28211
- https://gorilla.cs.berkeley.edu/leaderboard
- https://benchlm.ai/benchmarks/bfcl-v4
- https://benchmarklist.com/benchmarks/screenspot_pro/
- https://www.techplained.com/qwen-3-5-apple-silicon
