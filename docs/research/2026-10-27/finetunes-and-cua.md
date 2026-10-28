# Fine-tunes and CUA models for Perry

Date: 2026-10-27. Author: research sub-agent. Status: final. Read-only research. I downloaded no weights. I ran no models. Every speed here is a source or my own arithmetic, and I say which.

This extends `docs/research/2026-10-27/local-model-lineup.md` (called "lineup" below) and `docs/research/2026-10-25/r8-local-models-best.md` (called "r8"). I do not repeat their tables. Where they already cover a model I give a pointer and add only what is new.

## Summary (15 lines)

1. Owner question 1 ("is Qwen 3.5 2B really the best?"): at 2B and 4B, no tune has independent evidence, so the base stays. The only independent scores (Artificial Analysis, AA) cover bases. AA has no row for any fine-tune of a small Qwen. Nobody independent has compared a Qwen3.5 tune with its base.
2. The owner's instinct is right at 9B, for computer use. MAI-Gym-9B claims OSWorld-Verified 76.2 against 41.8 for its Qwen3.5-9B base (VENDOR, read on the project page). A gain of 34 points survives a heavy discount. It has no independent check yet. It is the first tune I would test.
3. At 27B and 35B-A3B the tunes lose or tie. Qwen3.8-27B scores 84.3 itself (VENDOR). UI-Mate-27B, a tune of the older Qwen3.6-27B, scores 77.0 (VENDOR). The next base generation overtook the tune.
4. Non-Qwen families do not beat Qwen for Perry. Best independent small non-Qwen: MiniCPM5-2B (AA 12.5) and K2 Horizon 3.7B and 7B (AA 15.6 and 20.6). All three are text only. Gemma 4 and LFM score far lower on tool use (AA tau2 about 21 to 44 against 85 to 95 for Qwen).
5. New names since the lineup: GUI-Owl-1.5 (2B/4B/8B, MIT), EvoCUA-8B (Apache), MiniCPM-V-4.7 (1B and 35B-A3B, Apache, official GGUF), Holo-3.1 GGUFs, UI-Venus-1.5 (2B/8B/30B-A3B, Apache), Muse-Glimmer-30B (dense, Apache, AA 17.5).
6. Owner question 2 ("whats wrong with using cua models?"): two different things share the name. The trycua models (cua-s1) are small option pickers, not agents. The real computer-use models (UI-TARS, OpenCUA, GUI-Owl, Holo, MAI-UI) are fine, but see points 7 to 9.
7. cua-s1-4b-0.2 picks one letter from at most 26 options Perry must list first. It has no GGUF and no MLX build. On the external OSWorld next-action test its element accuracy is 0.435 against a 0.50 chance line, and task accuracy is 0.013 (VERIFIED, trycua README read today). It is a specialist for forms.
8. The older GUI models are now behind plain Qwen3.5. Qwen3.5-9B claims ScreenSpot-Pro 65.2 (VENDOR). OpenCUA-7B claims 50.0, GTA1-7B-2507 50.1, UI-TARS-1.5-7B 49.6 (all VENDOR).
9. Real costs of a GUI tune: custom prompts and parsers, coordinate formats that differ by model, untested chat and JSON quality, no Apple-silicon speed data, and licence traps (Holo4-27B non-commercial, UI-Venus-2-9B no licence at all, Phi-Ground pickle files).
10. Hard-task collapse: on OSWorld 2.0 the 9B tunes score 3.7/11.3 (MAI-Gym-9B) and 0.0/7.5 (UI-Venus-2-9B), against 19.4/48.0 for Qwen3.8-27B (VENDOR, MAI-Gym page). Small tunes help on routine steps and fail on long tasks.
11. Two-model design: sound in principle, weak in practice for Perry. Perry already has the accessibility tree and element frames. Qwen3.5 bases already ground (ScreenSpot-Pro 46.5, 54.5, 60.3, 65.2 for 0.8B, 2B, 4B, 9B, VENDOR). A separate 2B grounder is no better than a 4B planner.
12. Best grounder if you want one: UI-Venus-1.5-8B (Apache, ScreenSpot-Pro 68.4 VENDOR, 5.03 + 0.75 GB community GGUF). On 16 GB load it only when the planner is 2B or 4B and the tree has no match. On 48 GB it fits beside the 27B (about 24 GB total).
13. Ship now: all bases from the lineup, unchanged. Add four challengers to Perry-bench: MAI-Gym-9B, MiMo-V2.6-Distill-Qwen-9B, Holo-3.1-4B, GUI-Owl-1.5-2B. On the 48 GB Mac add Occamy-1.0, Holo4-35B-A3B, MiniCPM-V-4.7-35B-A3B.
14. Excluded with reason: abliterated or uncensored builds (they remove refusals in an agent that clicks Send on screens that can carry injected text), non-commercial licences, no-licence repos, and Claude-trace distills (terms of use unclear, and text only).
15. Not verified: every GUI score, every tune score, any seconds-per-step on a Mac for a GUI model (the one measurement is a Core ML port of cua-s1-4b, 0.7 to 1.65 s on an M5 Pro), and whether llama.cpp runs each community GGUF well. The OSWorld and ScreenSpot-Pro boards are JavaScript pages I could not read.

---

## 0. Method, labels and limits

- **VERIFIED** (for facts): file size, date, licence tag, base model, download count. Read from the Hugging Face API on 2026-10-27. Downloads are HF's rolling 30-day count and measure popularity, not quality.
- **INDEPENDENT** (for scores): a party other than the model's author measured it. Here that means Artificial Analysis only. I parsed its leaderboard page on 2026-10-27 (272 model rows).
- **VENDOR**: the author published the score. I read it on their card or page. Nobody checked it. Every GUI and tune score in this report is VENDOR unless marked.
- **UNVERIFIED**: second hand, or my arithmetic. I name the formula.
- I tried the OSWorld and ScreenSpot-Pro leaderboards. Both are JavaScript pages that returned no rows. r8 Appendix D already says the official OSWorld sheet lists none of the 2026 models. So I treat all GUI scores as claims.
- Searches for an independent comparison of a Qwen3.5 tune against its base on BFCL, and for independent reviews of Occamy-1.0 and MiMo-9B, found none. I found only vendor tables, copies of them, and one informal blog test.
- Abliterated and uncensored builds are excluded everywhere, for one reason: Perry reads arbitrary screen text and can click Send, Delete and Pay, and refusals are one of the few defences against instructions injected by a page. Examples I saw: UI-Mate-9B-heretic, MiniCPM-V-4.7-35B-A3B-Uncensored, Qwen3-VL-8B-Instruct-abliterated (662,961 downloads).
- Other exclusions: licences that bar commercial use or redistribution, repos with no licence, gated repos, and distills of closed-model outputs (terms of use of the teacher unclear).

### 0.1 What independent evidence exists (AA, parsed 2026-10-27)

All INDEPENDENT. "e" means AA estimated the index. tau2 is the AA agentic tool-use test.

| Model | Index | tau2 | IFBench | Vision? |
|---|---|---|---|---|
| Qwen3.5-0.8B (reasoning / not) | 6.1e / 5.4e | 47.7 / 65.2 | 21.5 / 21.6 | yes |
| Qwen3.5-2B (reasoning / not) | 6.9e / 6.2e | 69.0 / 81.6 | 31.5 / 29.1 | yes |
| Qwen3.5-4B (reasoning / not) | 13.1e / 10.8e | 92.1 / 87.7 | 52.0 / 33.3 | yes |
| Qwen3.5-9B (reasoning / not) | 11.2 / 13.3e | 86.8 / 85.1 | 66.7 / 37.8 | yes |
| Qwen3.6-35B-A3B (reasoning / not) | 18.2 / 15.2e | 95.3 / 85.1 | 64.4 / 36.2 | yes |
| Qwen3.8-27B (xhigh / medium / not) | 33.7 / 27.6 / 20.2 | not shown | not shown | yes |
| MiniCPM-V 4.6 1.3B (not) | 5.7e | 87.7 | 26.7 | yes |
| MiniCPM5-2B | 12.5 | not shown | not shown | no |
| K2 Horizon 3.7B / 7B | 15.6 / 20.6 | not shown | not shown | no |
| K2 Horizon MoVA 36B-A4B | 25.3 | not shown | not shown | no |
| Muse Glimmer 30B (High) | 17.5 | not shown | not shown | yes |
| Ling-3.0-flash-VL (125B) | 24.6 | not shown | not shown | yes |
| Gemma 4 E2B / E4B (reasoning) | 7.8e / 8.9 | 20.8 / 20.8 | 38.0 / 44.2 | yes |
| Gemma 4 12B / 26B-A4B (reasoning) | 14.2e / 16.7e | 36.3 / 43.6 | 73.5 / 72.4 | yes |
| LFM2.5-VL-1.6B | 4.8e | 8.5 | 33.1 | yes |
| Phi-4-multimodal | 5.8e | not shown | not shown | yes |

**No fine-tune of a small Qwen (0.8B to 27B) has an AA row.** The only Qwen-derived rows are Nex-N2-Pro (397B base) and old INTELLECT-3 and HyperNova entries. So for question 1 the honest status is: no independent evidence exists for any tune at the sizes Perry ships.

---

## Part A. Best fine-tune per size slot

Perry's four jobs: read a screenshot, plan short multi-step computer tasks, emit tool calls and JSON, answer short questions. Vision is required (or a matching mmproj file).

### A.0 Why "base" is not a lazy default

1. Qwen3.5 is already a computer-use model. Its own cards (VENDOR) list ScreenSpot-Pro 65.2 (9B), 60.3 (4B), 54.5 (2B), 46.5 (0.8B), OSWorld-Verified 41.8 (9B) and 35.6 (4B), AndroidWorld 57.8 and 58.6. That is why the GUI tunes of 2025 look weak next to it.
2. Tunes inherit the base's architecture, so Perry's engine runs them unchanged. A swap is a file change. That makes testing cheap, so I recommend testing even without independent evidence.
3. Most "smart" tunes on the Hub are text-only (a vision-language model repacked as text, or trained only on text). Perry needs the screenshot. I dropped those from the shortlists and list them in A.6.
4. Many distills train on traces from closed models (Claude Opus, Fable, Mythos). The label says Apache-2.0. The teacher's terms of use may say otherwise. I did not assess the legal question. I do not recommend shipping them.

### A.1 Slot 0.8B to 2B (8 GB Macs)

| Candidate | Base, licence, date | Files (VERIFIED) | Vision | Downloads | Scores |
|---|---|---|---|---|---|
| **Qwen3.5-2B** (the base) | Alibaba, Apache-2.0, early 2026 | Unsloth UD-Q4_K_XL 1.34 GB + mmproj 0.67 GB (lineup) | yes | 111,998 (Unsloth repo) | AA index 6.9e/6.2e, tau2 69.0/81.6 (INDEPENDENT). ScreenSpot-Pro 54.5 (VENDOR). |
| GUI-Owl-1.5-2B-Instruct (mPLUG) | MIT, 2026-02-14. Base not stated on the card I read (UNVERIFIED: Qwen3-VL-2B) | mradermacher GGUF Q4_K_M 1.11 GB + mmproj 0.45 (Q8) or 0.82 (f16). No GGUF from the author. | yes | 3,606 (main), 4,141 (GGUF) | OSWorld-Verified 43.5, AndroidWorld 67.9, OSWorld-MCP 33.0, MobileWorld 31.3, WindowsAA 25.8 (VENDOR, authors' table) |
| MiniCPM-V-4.7-1B (OpenBMB) | Apache-2.0, 2026-10-06, own base | Official GGUF Q4_K_M 0.67 GB + mmproj 0.90 (4x compression) or 1.11 | yes | 155,428 (main), 101,179 (GGUF) | Card claims it "substantially outperforms Qwen3.5 0.8B" (VENDOR, chart image only). Its predecessor MiniCPM-V 4.6 1.3B: AA index 5.7e, tau2 87.7, IFBench 26.7 (INDEPENDENT). |
| Holo-3.1-0.8B (H Company) | Apache-2.0, 2026-05-29, 1.1B params | No GGUF found from the author or mradermacher | yes | 7,915 | Chart images only (VENDOR). |

Considered and dropped: Qwen3.8-2B-Distill (empero-ai, 3,039 downloads: text path only, vision removed; GSM8K and MMLU gains are VENDOR on a CoT harness), Darwin-2B-Opus (trained on Claude Opus traces, text only, GPQA 37.37 VENDOR), Marlin-2B (gated), Gemma 4 E2B (AA 6.5e to 7.8e, tau2 about 21), LFM2.5-VL-1.6B and 3B (custom "lfm" licence, AA 4.8e), Phi-4-multimodal (old, AA 5.8e), MiniCPM5-2B (best small AA score at 12.5 but no vision; see the idea below).

**Idea nobody has tested (UNVERIFIED):** MiniCPM5-2B (1.56 GB, AA 12.5, tauBanking 20.8 in r8) beats Qwen3.5-2B (6.9e) by 5.6 index points but cannot see. Perry sends accessibility-tree text for most steps. A text-only planner plus the 0.8B vision model for screenshots could beat one 2B model on an 8 GB Mac. It needs a test, not a decision.

**Ranked shortlist to benchmark (max 3):**
1. Qwen3.5-2B (control).
2. GUI-Owl-1.5-2B-Instruct. Biggest claimed gain at this size. No general-quality data.
3. MiniCPM-V-4.7-1B. Half the size, so a real help on 8 GB. Its older sibling shows the tool-call score is competitive.

**Verdict: ship base (Qwen3.5-2B).** Evidence: no tune has independent evidence, and the two GUI claims are in a harness Perry does not use.
**Single test that settles it** (16 GB M4 mini): 40 recorded Perry steps (goal + accessibility tree + screenshot), 3 runs each. Score step success, valid-JSON rate and seconds per step for the three models. Adopt a challenger only if it beats the base by 5 points of step success and keeps the JSON rate. Add 20 plain chat and JSON prompts to catch a tune that forgot how to talk.

### A.2 Slot 4B (16 GB base Macs)

| Candidate | Base, licence, date | Files (VERIFIED) | Vision | Downloads | Scores |
|---|---|---|---|---|---|
| **Qwen3.5-4B** (the base) | Apache-2.0 | Unsloth UD-Q4_K_XL 2.91 + 0.67 GB | yes | 144,005 | AA 13.1e/10.8e, tau2 92.1/87.7, Terminal-Bench-Hard 18.2 (INDEPENDENT). ScreenSpot-Pro 60.3, OSWorld-V 35.6, AndroidWorld 58.6, BFCL-V4 50.3 (VENDOR). |
| Holo-3.1-4B (H Company) | Apache-2.0, 2026-05-29. Card lists Qwen3.5-4B/9B/0.8B and Qwen3.6-35B-A3B as bases. 5.17B params | mradermacher Q4_K_M 3.07 GB + mmproj 0.37 (Q8) or 0.67. prithivMLmods also has one. | yes | 3,463 (main), 7,959 (GGUF) | AndroidWorld 71 (r8). Card gives a chart image only (VENDOR). Native function calling. |
| GUI-Owl-1.5-4B-Instruct | MIT, 2026-02-14 | mradermacher Q4_K_M 2.50 GB + mmproj 0.45 or 0.84 | yes | 2,048 (main), 5,779 (GGUF) | OSWorld-V 48.2, AndroidWorld 69.8, MobileWorld 32.3, WindowsAA 29.4 (VENDOR) |
| Fara1.5-4B (Microsoft) | MIT, 2026-07-17 | bartowski Q4_K_M 2.88 GB + mmproj 0.67 | yes | 1,923 (main), 7,460 (GGUF) | Browser only. Screenshot-only. Trained to stop at "critical points" (payments, sign-in, send). WebVoyager, Online-Mind2Web, WebTailBench numbers were not read. |
| DeskForge-Qwen3.5-4B (docling-project) | Apache-2.0, 2026-09-30 | No GGUF | yes | 9,297 | Grounding only (lineup). |
| K2 Horizon 3.7B (IFM) | Apache-2.0, 2026-09-01 | Official GGUF | **no** | 23,304 | AA index 15.6 (INDEPENDENT), above the 4B's 13.1e. Text only. Lineup/r8: no non-thinking mode, tool-call parser issue. |

Dropped: Qwen3.8-4B-Distill (258,029 downloads, the most popular tune; text only), NeoHorse-1-4B (2,553 likes; text only; its own table says macro average 64.87 against 58.94 for the base, VENDOR), Gemma 4 E4B (AA 8.9, tau2 20.8), Qwen-Drive-1.0-4B (autonomous driving), Intern-Decision-4B, H2O-Lightning-4B, JEV and Clef (decision models that return option probabilities, not text).

**Ranked shortlist:**
1. Qwen3.5-4B (control).
2. Holo-3.1-4B. Built for local agents, native function calling, Apache, a GGUF exists.
3. GUI-Owl-1.5-4B-Instruct. Highest claimed OSWorld-Verified at this size (48.2 against 35.6 for the base).

**Verdict: ship base (Qwen3.5-4B).** Evidence: AA ranks it well on tool use (tau2 92.1), and no tune has any independent score. The GUI-Owl gain of 12.6 OSWorld points is large enough to deserve the test.
**Test:** same as A.1, plus a 10-task "stop and ask" probe (a screen with a Send button and an ambiguous goal). Fara's critical-point behaviour is the thing to copy if the others fail it.

### A.3 Slot 9B (16 GB Pro and 24 GB Macs)

| Candidate | Base, licence, date | Files (VERIFIED) | Vision | Downloads | Scores |
|---|---|---|---|---|---|
| **Qwen3.5-9B** (the base) | Apache-2.0 | Unsloth UD-Q4_K_XL 5.97 + 0.92 GB | yes | 98,440 | AA 11.2 / 13.3e, tau2 86.8 / 85.1, IFBench 66.7 / 37.8 (INDEPENDENT). ScreenSpot-Pro 65.2, OSWorld-V 41.8, AndroidWorld 57.8, BFCL-V4 66.1 (VENDOR). |
| **MAI-Gym-9B** (Tongyi-MAI) | Qwen3.5-9B (project page), Apache-2.0, 2026-10-16 | mradermacher Q4_K_M 5.63 GB + mmproj 0.62 (Q8) or 0.92. No author GGUF. | yes | 207 (main), 1,670 + 3,057 (GGUF) | OSWorld-V 76.2 (base 41.8), MobileWorld 78.4 (base 18.0), AndroidWorld 75.9 (57.8), MacAgentBench 41.3 (20.7), MobileGym 46.5 (9.0), OSWorld 2.0 3.7/11.3 (0.0/2.5). VENDOR, read on the project page and arXiv 2610.20939. |
| MiMo-V2.6-Distill-Qwen-9B (Xiaomi) | Qwen3.5-9B, MIT, 2026-09-21 | lineup: ggml-org Q8_0 9.53 + 0.62; bartowski Q4_K_M 5.84 + 0.92 | yes | 21,185 | Tool-use gains in lineup §1.2 (VENDOR). One informal blog test saw it call tools correctly. |
| Holo-3.1-9B | Qwen3.5-9B family, Apache-2.0, 2026-05-29 | mradermacher Q4_K_M 5.63 + 0.92 | yes | 689 (main), 7,358 (GGUF) | AndroidWorld 71 (r8). Chart image only. |
| GUI-Owl-1.5-8B-Instruct / Thinking | MIT, 2026-02-14 | mradermacher Q4_K_M 5.03 + 0.75 (Q8 mmproj) or 1.16 | yes | 4,797 / 22,523 | OSWorld-V 52.3 / 52.9, AndroidWorld 69.0 / 71.6, WebVoyager 69.9 / 78.1 (VENDOR) |
| UI-Mate-9B (Tencent) | Qwen3.5-9B, Apache-2.0, 2026-08-14 | bartowski GGUF (9,432 downloads) | yes | 1,355 | OSWorld-V 66.2 (VENDOR). Card says use the official harness and parser. |
| EvoCUA-8B-20260105 (Meituan) | Apache-2.0, 2026-01-13. Base Qwen3-VL-8B (UNVERIFIED) | Community Q4_K_S 4.80 GB + mmproj 1.16; mlx-community 8-bit | yes | 1,544 | OSWorld 46.1 at 50 steps (VENDOR). The 32B claims 56.7. |
| UI-Venus-2-9B (inclusionAI) | Qwen3.5-9B, **no licence file or tag at upstream** (VERIFIED), 2026-08-26 | bartowski Q4_K_M 5.91 + 0.92 (tagged Apache by the uploader, not the author) | yes | 13,703 | OSWorld-V 70.8, ScreenSpot-Pro 73.0 (VENDOR). **Excluded until the author adds a licence.** |

Dropped: Fara1.5-9B (browser only, MIT, keep for a later web lane), NeoHorse-1-9B (text only), OmniCoder-9B and Carnice-9b (coding and Hermes-harness tunes), Qwythos and Qwable (Claude-trace distills), LensVLM-9B (Apple, licence tag `apple-amlr`, research use likely; UNVERIFIED, not read), Gemma 4 12B (AA 14.2e but tau2 36.3, far below Qwen), GLM-4.6V-Flash (MIT, December 2025, no AA row).

**Ranked shortlist:**
1. MAI-Gym-9B. Claims the largest jump over the base, same architecture, Apache.
2. MiMo-V2.6-Distill-Qwen-9B. Generalist tool-use gain, MIT, an official-style GGUF exists.
3. Holo-3.1-9B or GUI-Owl-1.5-8B. Take Holo if function calling matters, GUI-Owl if you want the higher OSWorld claim.

**Verdict: ship base today (Qwen3.5-9B). Expect to ship MAI-Gym-9B or MiMo as the action model if the local test passes.** Evidence for expecting a win: a 34-point OSWorld jump on the same base is too large to be only a harness effect, and four separate labs (Tongyi, Tencent, inclusionAI, mPLUG) each report a 9B or 8B tune between 52 and 76 against a base of 41.8. They are still four vendors, not four checks. Evidence against shipping today: all vendor, MAI-Gym's chat and JSON quality is untested, its OSWorld 2.0 score (3.7/11.3) shows it fails long tasks, and its GGUF is community-built.
**Test** (16 GB M4 mini, which fits a 9B Q4 plus mmproj at about 9 GB): the A.1 suite, 3 runs, 40 steps, plus 20 chat and JSON prompts. Adopt MAI-Gym only if it beats the base by 10 step-success points, loses no more than 3 on the JSON rate, and passes the stop-and-ask probe.

### A.4 Slot 27B dense (48 GB Macs)

| Candidate | Base, licence, date | Files | Vision | Downloads | Scores |
|---|---|---|---|---|---|
| **Qwen3.8-27B** (the base) | Apache-2.0 | Unsloth UD-Q4_K_XL 17.56 + 0.93 GB (lineup) | yes | 6.0M (GGUF repo, lineup) | AA 33.7 xhigh / 27.6 medium / 26.2 low / 20.2 off (INDEPENDENT). OSWorld-V 84.3, AndroidWorld 81.9 (VENDOR, Qwen card). |
| UI-Mate-27B (Tencent) | Qwen3.6-27B, Apache-2.0, 2026-08-14 | bartowski GGUF (6,228 downloads). The lineup said no GGUF; this one exists. | yes | 758 (main) | OSWorld-V 77.0 (VENDOR). The base it was tuned from scores 63.9 on the Qwen3.8 card, so it added 13 points and was then overtaken by the next base. |
| Qwopus3.8-27B-Flash, Swift-1.5-Qwen3.8-27B, Signal-3.8-27B | Qwen3.8-27B | lineup §1.2 | yes | 8,409 (Swift-1.5) | Speed and token-saving claims only (VENDOR). Swift-1.5 licence is "other". |
| Holo4-27B | Qwen3.8-27B, **CC BY-NC 4.0** | official GGUF 16.88 + 0.93 | yes | 19,281 | OSWorld-V 85.2 (VENDOR). **Cannot ship.** |
| Muse-Glimmer-30B (Meta) | own dense model, 29.6B incl. a 1.8B vision encoder, Apache-2.0, 2026-08-09 | unsloth GGUF (757,717 downloads) | yes | 210,071 | AA 17.5 at High effort (INDEPENDENT), below Qwen3.8-27B at low effort (26.2). OSWorld-V 65.9 (VENDOR, in the Qwen card's table). |
| Fara1.5-27B | Qwen3.5-27B, MIT | bartowski GGUF | yes | 2,700 | Browser only. |

**Ranked shortlist:** 1. Qwen3.8-27B (control). 2. Qwopus3.8-27B-Flash (deep-lane speed). 3. UI-Mate-27B only if the 48 GB test shows the base mis-clicks.
**Verdict: ship base (Qwen3.8-27B).** Evidence: it has the independent AA score, it claims the best OSWorld-Verified of any shippable model (84.3), and the one open-licence GUI tune of this size scores lower. A tune has to beat 84.3 to matter, and the only one that claims to (Holo4-27B) is non-commercial.
**Test** (48 GB M4 Pro, 27B IQ4_XS or Q4_K_XL): run Qwopus-Flash against base on the 40-step suite and measure tokens per step and seconds per step. Adopt it only for the deep lane if the success rate is equal and the time drops 15% or more.

### A.5 Slot 35B-A3B MoE (32 to 128 GB Macs)

| Candidate | Base, licence, date | Files | Vision | Downloads | Scores |
|---|---|---|---|---|---|
| **Qwen3.6-35B-A3B** (the base) | Apache-2.0 | Unsloth UD-Q4_K_XL 22.36 + 0.90 GB | yes | n/a | AA 18.2 / 15.2e, tau2 95.3 / 85.1 (INDEPENDENT) |
| Occamy-1.0 (Accio-Lab) | Qwen3.6-35B-A3B, Apache-2.0, 2026-08-13 | Official GGUF IQ4_XS 18.73, Q4_K_M 21.17 + mmproj 0.90 (lineup) | yes | 783,484 (GGUF repo) | Claw-Eval 82.2 vs 69.5, tauBanking 37.1 vs 11.9, AutomationBench 27.6 vs 7.5 (VENDOR, lineup). A write-up on aiweekly repeats the paper's numbers and is not independent. |
| Holo4-35B-A3B | Qwen3.6-35B-A3B, Apache-2.0, 2026-09-25 | Official GGUF Q4_K_M 21.3 + 0.9 | yes | 11,192 (GGUF) | OSWorld-V 80.8, OSWorld 2.0 30.9 (VENDOR, r8). |
| Holo-3.1-35B-A3B | Apache-2.0, 2026-05-29 | Official GGUF, 164,475 downloads | yes | 424 (main) | OSWorld 80.0, metric not named (VENDOR). |
| MiniCPM-V-4.7-35B-A3B (OpenBMB) | own build, 35.2B params, Apache-2.0, 2026-10-06 | Official GGUF: IQ4_XS 18.73, Q4_K_M 21.17, "mix_q3gud_im" 15.50 + mmproj 0.91 or 1.12 | yes | 289,535 (main), 263,780 (GGUF) | Card says "higher overall score in less inference time than Qwen3.6 35B-A3B" (VENDOR, chart image only). It states a base of none (UNVERIFIED whether it derives from Qwen3.6). |
| Ornith-1.5-35B-A3B | MIT | Official GGUF 21.71 (lineup) | lineup | 3.9M (GGUF) | lineup §1.2 |
| K2 Horizon MoVA 36B-A4B (IFM) | own, Apache-2.0, 2026-09 | Official GGUF | **no** | 25,774 (GGUF) | **AA 25.3 against 18.2 for the Qwen base (INDEPENDENT).** Text only. r8: no non-thinking switch, parser bug for low-effort tool calls. |
| Ling-3.0-flash-VL (inclusionAI) | MIT, 2026-09-04, 124.8B params | bartowski IQ4_XS about 69 GB, Q4_K_M about 79 GB | yes | 12,173 | AA 24.6 (INDEPENDENT). Too big below 96 GB. |

Dropped: BigBang-v1, XYZ-Aquila-mini (deep-search and research agents), SIQ-1-35B, T-Search, MemT (not GUI), Frontis-MA1-35B (CC BY-NC), CyberStrike-OffSec (security, licence "other"), Nemotron 3.5 Lightning 30B-A3B (AA 12.9, text only, NVIDIA licence).

**Ranked shortlist:**
1. Occamy-1.0. Best fit for multi-step tool plans, the base's known weak spot (tauBanking 9.3 in r8).
2. Holo4-35B-A3B. Best GUI action claim among shippable MoE models.
3. MiniCPM-V-4.7-35B-A3B. Official GGUF with a 15.5 GB variant that could fit 24 GB Macs, and a vendor claim of equal quality in less time.

**Verdict: ship base (Qwen3.6-35B-A3B).** Evidence: AA tau2 95.3 and no tune has an independent score. Every challenger shares the base's architecture, so each test is a file swap. The one independent signal against the Qwen base is K2 Horizon MoVA (AA 25.3), and it cannot see, so it is only a candidate text planner.
**Test** (48 GB M4 Pro): the 40-step suite across base, Occamy and Holo4-35B for step success, JSON rate, and first-token time. Add one multi-step plan task (5 steps with a mid-task error) to expose the tauBanking-style weakness.

### A.6 Popular tunes that do not fit Perry (one line each)

| Tune | Why not |
|---|---|
| Qwen3.8-{2B,4B,9B,35B-A3B}-Distill (empero-ai) | Text path only (vision removed). Vendor gains on a CoT harness. |
| NeoHorse-1-{4B,9B} (2,553 and 1,038 likes) | Text only, no vision weights. Vendor-only table. |
| Clef, Clef-Flash, JEV, Intern-Decision, H2O-Lightning, Tev1, LemonDecider | Decision models. They return probabilities for listed options. They cannot write a reply or a tool call. |
| Qwythos, Qwable, TeichAI Fable distills, Darwin-Opus | Trained on another vendor's outputs. Terms unclear. Text only. |
| OmniCoder-9B, OxCoder-9B, Carnice-9b, Tess, AREX | Coding or one-harness tunes. |
| Hemmingway-1, Frontis-MA1 | CC BY-NC. |
| Qwen-Drive-1.0-4B | Autonomous driving. |
| Abliterated, heretic, uncensored builds | Refusals removed (see section 0). |

### A.7 Non-Qwen families, in one answer

| Family | Best model I found | Why it loses for Perry |
|---|---|---|
| Gemma 4 | E4B, 12B, 26B-A4B (Apache) | AA tau2 20.8 to 43.6 against 85 to 95 for Qwen (INDEPENDENT). Weak tool use. |
| Phi | Phi-4-multimodal (AA 5.8e), Phi-Ground (grounding only) | Old and weak; Phi-Ground is custom code in pickle files. |
| SmolLM / SmolVLM | SmolVLM2-2.2B GUI tune (one community GGUF, 191 downloads) | No independent score. Not competitive at this size. |
| LFM | LFM2.5-VL-1.6B (4.8e) and 3B, LFM2.5-2.6B (8.4e) | Custom licence; low scores. |
| MiniCPM | MiniCPM-V 4.6 and 4.7 (vision), MiniCPM5-2B (text, AA 12.5) | Only family to challenge Qwen at 1B to 2B. Worth testing (A.1). |
| InternVL | Nothing newer than 3.x on the Hub for sizes under 40B in my searches | No evidence. |
| GLM | GLM-4.6V-Flash 9B (MIT, Dec 2025) | Older than Qwen3.5, no AA row. GLM-5.3-Flash is far above consumer RAM. |
| Muse (Meta) | Muse-Glimmer-30B (dense, Apache) | AA 17.5. No gain over Qwen3.6-35B-A3B at 18.2. A GUI-grounding LoRA exists (88.1 ScreenSpot-v2, VENDOR). |
| K2 Horizon | 3.7B, 7B, MoVA 36B-A4B | Strong AA scores per size (15.6, 20.6, 25.3) but text only. |

---

## Part B. CUA models

### B.1 The two things called "cua"

1. **trycua / cua-ai** is the Cua company. Its HF org `cua-ai` holds four checkpoints (VERIFIED, 2026-10-27). The `trycua` org on HF has no models.
2. **"CUA" as a category** (computer-use agent) covers dozens of vision-language models trained to operate a screen.

The lineup answered the first meaning. This section extends it and adds the second.

### B.2 What the cua-ai models are

| Model | What it is | Output | Size | Files | Licence | Date |
|---|---|---|---|---|---|---|
| cua-s1-forms | From-scratch option scorer for form filling | One probability per option (`fill X`, `check`, `click`, `skip`) | 706,048 params (2.8 MB) | safetensors + JSON | MIT | 2026-09-18 |
| cua-s1-nano-0.1 | From-scratch option scorer | One logit per (element, action) option | 855,296 params | safetensors | Apache-2.0 | 2026-09-21 |
| cua-s1-4b-0.1 and 0.2 | Two LoRA adapters (text and multimodal) on frozen Qwen3.5-4B | One letter A to Z, max 26 options | 4B | PEFT adapters only. No GGUF, no MLX | Apache-2.0 | 2026-09-21, 09-22 |

Evidence, all VERIFIED by reading `libs/cua-bench-s1/README.md` today (these are the repo's own numbers, so VENDOR as to who ran them):

- 4b-0.2 on the cross-dataset GUI-360 text split: 0.83 to 1.00 task accuracy on five of six families, against 0.25 chance.
- On the external OSWorld next-action test, out of domain: task accuracy 0.013, element accuracy 0.435, against a printed chance of 0.50. The untrained baseline "semif" gets 0.531.
- On `chess`: 0.067 task accuracy. On `game_control`: 0.024.
- The nano model scores 0.000 on every cross-dataset row and 1.000 on its own training split. Its card says it "mostly reflects its training distribution".
- On live agentic environments (`cua_bench_basic`, N=18): 0.944 text, 0.722 multimodal for 4b-0.2.

The cards and README say it plainly: these are "closed-option" deciders. Perry would have to enumerate every (element, action) pair first, then ask the model to pick. The model never plans, never emits coordinates and never writes a reply.

**Speed on a Mac (the only GUI-adjacent measurement I found):** FluidInference's Core ML port of cua-s1-4b-0.2 on an M5 Pro with 24 GB, macOS 27, GPU: about 0.7 s per text decision and 1.65 s per multimodal decision on an idle machine, 1.1 s and 3 s under load (third-party model card, self-measured, so VENDOR for the porter). The port needs 2.6 GB (GPTQ text) to 6.8 GB (fp16) and runs through their FluidUse Swift package. The Neural Engine path falls back to CPU at 19 s per decision.

Cua's own README: "Bring your own agent and model." The part that helps Perry is Cua Driver, which Perry already uses.

### B.3 The computer-use model families

"Runs on macOS" below means: a GGUF exists on the Hub (VERIFIED) and the base architecture is one llama.cpp supports (Qwen2-VL, Qwen2.5-VL, Qwen3-VL, Qwen3.5). That a community GGUF loads and clicks well is **UNVERIFIED**: I ran nothing. "MLX" means an mlx-community or similar build exists. "Core ML" exists only for cua-s1.

Output formats come from the cards I read; the ones marked (U) I did not read this session.

| Family and versions | What it outputs | Sizes | Licence | Mac path | Scores (all VENDOR unless marked) |
|---|---|---|---|---|---|
| **UI-TARS** (ByteDance): 2B/7B/72B (Jan 2025, Qwen2-VL), 1.5-7B (Apr 2025, Qwen2.5-VL). UI-TARS-2 is closed (another card lists it as "Closed"). | Thought plus a click or type action with box coordinates (U) | 2B, 7B, 72B | Apache-2.0 | GGUF: Mungert 1.5-7B Q4_K_M 4.78 GB, 133,465 downloads. MLX: 1.5-7B-4bit (452 downloads), 2B 4-bit. | 1.5-7B: ScreenSpot-Pro 49.6 (own card scale table) or 42.0 (GTA1's re-run, starred); OSWorld 27.5 (own card), 27.4 at 100 steps (OpenCUA's table). Full proprietary UI-TARS-1.5: 42.5 and 61.6. |
| **OpenCUA** (xlang-ai): 7B, 32B, 72B (Jul 2025, Qwen2.5-VL) | `pyautogui.click(x=1443, y=343)` Python, absolute pixels | 7B, 32B, 72B | MIT | No GGUF or MLX in the top Hub results. 7B has an exl2 and a BnB copy. | 7B: ScreenSpot-Pro 50.0, ScreenSpot-v2 92.3, OSWorld-G 55.3, OSWorld-V 26.6 to 27.9. 32B: 34.8. 72B: 45.0. |
| **GUI-Owl / Mobile-Agent** (mPLUG): GUI-Owl-7B (Aug 2025), GUI-Owl-1.5 2B/4B/8B/32B Instruct and Thinking (Feb 2026) | Tool and MCP calls with actions (U) | 2B to 32B | MIT | GGUF (mradermacher, see A.1 to A.3) | See A.1 to A.3. 32B: OSWorld-V 56.5, WindowsAA 44.8. |
| **UI-Venus** (inclusionAI): Ground-7B/72B, Navi-72B (Aug 2025), 1.5 2B/8B/30B-A3B (Feb 2026), 2-9B (Aug 2026) | Grounding points and agent actions (U) | 2B, 7B, 8B, 9B, 30B-A3B, 72B | Apache-2.0 (all but 2-9B, which has none) | GGUF: 1.5-2B Q4_K_M 1.28 GB, 1.5-8B 5.03 GB, 1.5-30B-A3B 18.56 GB (mmproj 0.45 to 1.16 extra). | 1.5: ScreenSpot-Pro 57.7 / 68.4 / 69.6; 30B: OSWorld-G 70.6, AndroidWorld 77.6. 2-9B: OSWorld-V 70.8, ScreenSpot-Pro 73.0. |
| **Holo** (H Company): Holo1.5 (3B/7B/72B), Holo2 (4B/8B/30B-A3B/235B, Nov 2025), Holo-3.1 (0.8B/4B/9B/35B-A3B, May 2026), Holo4 (27B, 35B-A3B, Sep 2026) | Coordinate actions; Holo-3.1 adds native function calling | 0.8B to 235B | Apache for most; **CC BY-NC for Holo4-27B, Holo2-30B-A3B and 235B** | GGUF: 3.1-4B 3.07 GB, 3.1-9B 5.63 GB (community); 3.1-35B-A3B and Holo4-35B-A3B official. | Holo2-4B: OSWorld 37.7, AndroidWorld 64.6, WebVoyager 80.2. Holo4 in A.4, A.5. |
| **MAI-UI** (Tongyi): 2B, 8B (Dec 2025) | Coordinates and mobile actions (U) | 2B, 8B (and larger) | Apache-2.0 | GGUF: 2B Q4_K_M 1.11 GB, 8B 5.03 GB. MLX: 2B 6-bit, 8B 4/6/bf16. | Family headline: ScreenSpot-Pro 73.5, OSWorld-G 70.9, AndroidWorld 76.7. The card does not say which size gets 73.5 (UNVERIFIED for 2B and 8B). |
| **MAI-Gym-9B** (Tongyi, Oct 2026) | Not stated on the page I read (UNVERIFIED) | 9B | Apache-2.0 | Community GGUF | A.3 |
| **Fara / Fara1.5** (Microsoft): Fara-7B (Oct 2025), Fara1.5 4B/9B/27B (2026) | Coordinate-grounded click and drag actions; pauses at critical points | 4B to 27B | MIT | bartowski GGUF for all four | Browser tasks only (WebVoyager, Online-Mind2Web, WebTailBench). No desktop score. |
| **GTA1** (Salesforce): 7B, 7B-2507, 32B, 72B | One `(x,y)` point (grounding only) | 7B to 72B | Apache-2.0 on 7B and 7B-2507 | mradermacher GGUF for 7B-2507 | 7B-2507: ScreenSpot-v2 92.4, ScreenSpot-Pro 50.1, OSWorld-G 55.1. 32B: 95.2, 63.6, 65.2. |
| **InfiGUI-G1** 3B/7B (Aug 2025) | Grounding point | 3B, 7B | Apache-2.0 (Android-Control variants "other") | mradermacher GGUF | Not read. |
| **Phi-Ground / Phi-Ground-Any** (Microsoft) | Relative coordinates 0 to 10000 | 4B, Phi-3.5-vision base | MIT | **None.** Custom code, pickle `.bin`, fixed 1680 by 1008 input. Not llama.cpp. | Chart image only. |
| **ShowUI-2B** (showlab, Nov 2024, Qwen2-VL-2B) | Coordinates (U) | 2B | MIT | Community Q4_K_M GGUF; MLX 4/6/8-bit | Old. |
| **Aguvis-7B** (xlang, Dec 2024) | pyautogui-style actions (U) | 7B | none shown | mradermacher GGUF | Old. |
| **OS-Atlas** Base/Pro 4B and 7B (Nov 2024) | Grounding points (U) | 4B, 7B | Apache-2.0 | mradermacher GGUF for 7B | Old. |
| **UGround-V1** 2B/7B/72B (Jan 2025) | Grounding point (U) | 2B, 7B, 72B | Apache (2B/7B); 72B "other" | mradermacher GGUF | ScreenSpot-Pro 31.1 (7B, in GTA1's table). |
| **EvoCUA** 8B/32B (Meituan, Jan 2026) | pyautogui-style actions (U) | 8B, 32B | Apache-2.0 | Community GGUF (32B has only an mmproj upload), MLX 8-bit | 8B: OSWorld 46.1. 32B: 56.7, WindowsAA 56.48. |
| **Qwen-CUA** (Qwen + xlang, Aug 2026) | XML `computer_use` actions on a 0 to 999 grid | 397B-A17B, 807 GB | Apache-2.0 | Not for a Mac | OSWorld-V 86.2 (in MAI-Gym's table). |
| **Northstar-CUA-Fast** (Tzafon) | not read | n/a | Apache-2.0 | none | 37.01 on its own card (lineup). |
| **Muse-Glimmer-30B-GUI-Grounding-Fast** (lemuralabs, LoRA) | One box `[x1,y1,x2,y2]` as fractions | 30B base + LoRA | Apache-2.0 | none | ScreenSpot-v2 88.1, parse rate 99.7% (VENDOR). |

Three things stand out.

1. **Coordinate formats are all different.** OpenCUA gives absolute pixels (the card has a "coordinate systems" warning). Qwen-CUA gives 0 to 999. Phi-Ground gives 0 to 10000. The Muse LoRA gives 0 to 1. GTA1 asks for the resized image's pixels. A wrong resize or a wrong divisor puts every click in the wrong place. Perry would need one parser and one image-resize rule per model.
2. **The tunes are tied to their harness.** UI-Mate's card says to use "the official prompt, response parser, and interaction harness". UI-Venus-2 recommends temperature 1.0 and a 262,144-token window for general agent tasks. MAI-Gym trains and evaluates with one harness to avoid drift. Perry's prompts are not their prompts, so their published scores would not transfer as-is.
3. **Pixel-only training.** Qwen-CUA says its evaluation gives no DOM or accessibility data. Fara1.5 is "vision-only at perception time". Perry's best input is the accessibility tree. A model trained to ignore text structure may read it poorly.

### B.4 Speed per step on Apple silicon

Nobody measured a GUI agent step on a Mac, apart from the Core ML cua-s1 row in B.2. A search for UI-TARS, Holo, GUI-Owl and MAI-UI Mac latency returned only general LLM speed posts.

My arithmetic (UNVERIFIED): a grounding call is about 700 input tokens (one 640-token screenshot plus a short prompt) and 20 output tokens. I scaled the lineup's 1,640-token first-token figures by 700 ÷ 1,640 = 0.43.

| Mac | 2B | 4B | 9B |
|---|---|---|---|
| M4 base | about 2.1 s + 0.3 s decode | about 3.0 s + 0.6 s | about 5.1 s + 1.3 s |
| M4 Pro | about 1.0 s + 0.1 s | about 1.5 s + 0.3 s | about 2.6 s + 0.6 s |

A full agent step also carries history and the accessibility tree, so expect 2 to 3 times these for a planning step. The lineup's table gives the whole-turn figures.

### B.5 Answer to the owner: "whats wrong with using cua models?"

Plainly:

**Nothing is wrong with using a computer-use model. Three things are wrong with what people usually mean.**

1. **"The Cua model" is not an agent.** cua-s1 picks one answer from a list that Perry has to write first. It cannot plan, cannot give coordinates, cannot talk. Its own out-of-domain OSWorld result is near chance. It has no GGUF or MLX build. Use Cua Driver (already in Perry). Skip cua-s1 except as a possible fast form-filler later.
2. **The older computer-use models are behind plain Qwen3.5.** UI-TARS-1.5-7B, OpenCUA-7B and GTA1-7B all sit near 42 to 55 on ScreenSpot-Pro. Qwen3.5-9B base claims 65.2 and the 4B claims 60.3. Those 2025 models were built on Qwen2.5-VL, an older generation. Do not adopt them.
3. **The new Qwen3.5-based tunes (MAI-Gym, Holo-3.1, GUI-Owl, UI-Venus-1.5, UI-Mate) are real candidates, but the evidence is all vendor-made.** At 9B the claimed gain is large (OSWorld-Verified 41.8 to 76.2). At 27B and above it vanishes (Qwen3.8-27B alone scores 84.3). They may forget how to chat or emit JSON, nobody has checked, and they collapse on hard long tasks (OSWorld 2.0 near zero for 9B tunes).

Practical costs if Perry adopts one: its own prompt and parser per model, a per-model coordinate rule, a licence check (Holo4-27B is non-commercial, UI-Venus-2-9B has no licence, Phi-Ground ships pickle files), a community GGUF to audit and host, and no speed data to plan the experience.

**Do not make a GUI tune the default brain.** Test MAI-Gym-9B as the action model on 16 to 24 GB Macs. If it beats the base by 10 points and keeps chat and JSON quality, make it the default action model. Otherwise keep the base.

### B.6 The two-model design (planner plus grounder)

Idea: a general planner says "click Send". A small grounding model turns that into coordinates.

**For it:** a small model is cheap to load. The grounder never needs to chat. Grounding tunes are the most reliable GUI skill.

**Against it, for Perry:**
1. Perry's accessibility tree already carries element frames. Grounding is needed only for apps with poor trees (canvases, games, some Electron apps). That is the minority of steps.
2. The Qwen3.5 bases ground by themselves: ScreenSpot-Pro 46.5 (0.8B), 54.5 (2B), 60.3 (4B), 65.2 (9B) (VENDOR). A 2B grounder such as UI-Venus-1.5-2B (57.7) is no better than a 4B planner doing it alone.
3. A second model costs memory (1.3 to 6 GB) and a second prefill (B.4). On an 8 GB or 16 GB base Mac that cost is real.
4. Two separate models mean two image-resize rules and two coordinate parsers.

**Verdict:** keep it as a fallback, not a default. Load the grounder only when the planner has no tree match.

**Best grounder for the role:**

| Mac | Pick | Why | Footprint | Caveat |
|---|---|---|---|---|
| 16 GB | **UI-Venus-1.5-8B** (Apache-2.0) when the planner is the 2B or 4B. With a 9B planner, no grounder. | ScreenSpot-Pro 68.4 and OSWorld-G in the 60s to 70s (VENDOR), 8 points above Qwen3.5-4B's own 60.3. | Q4_K_M 5.03 GB + mmproj 0.75 GB. Load on demand beside a 3.6 GB 4B planner (about 9.4 GB). | Community GGUF (mradermacher). Gain is vendor-only. If 5.8 GB is too much, UI-Venus-1.5-2B (1.28 + 0.45 GB, 57.7) adds almost nothing over a 4B planner. |
| 48 GB | **UI-Venus-1.5-8B again** if you want one, or none. | Beside a 27B Q4_K_XL (18.49 GB) it totals about 24.3 GB, well inside the 37.4 GiB Metal working set (r8). | 5.8 GB. | The 30B-A3B (69.6, 18.56 + 0.71 GB) adds only 1.2 points and with the 27B totals about 37.8 GB, which exceeds the working set. Not worth it. The 27B itself is the stronger grounder; I did not find its ScreenSpot-Pro score on its card (UNVERIFIED). |

Runner-up at both tiers: Holo-3.1-4B (3.07 + 0.67 GB). I could not read its grounding scores (chart image only), so I cannot rank it.

**The single local test** (16 GB mini, then 48 GB Pro): 50 screenshots of AX-poor apps with a known click target. Compare the planner alone against planner plus UI-Venus-1.5-8B on hit rate (click inside the element box) and seconds per step. Adopt the grounder only if it adds 8 or more points of hit rate and costs under 3 s.

---

## Sources

Hugging Face API and cards (all read 2026-10-27):
- https://huggingface.co/cua-ai/cua-s1-4b-0.2
- https://huggingface.co/cua-ai/cua-s1-nano-0.1
- https://huggingface.co/cua-ai/cua-s1-forms
- https://huggingface.co/FluidInference/cua-s1-4b-coreml
- https://github.com/trycua/cua/tree/main/libs/cua-bench-s1 (README read via raw.githubusercontent.com)
- https://huggingface.co/Qwen/Qwen3.5-9B, https://huggingface.co/Qwen/Qwen3.5-4B, https://huggingface.co/Qwen/Qwen3.5-2B, https://huggingface.co/Qwen/Qwen3.8-27B
- https://huggingface.co/Tongyi-MAI/MAI-Gym-9B and https://tongyi-mai.github.io/MAI-Gym/ and https://arxiv.org/abs/2610.20939
- https://huggingface.co/Hcompany/Holo-3.1-4B, https://huggingface.co/Hcompany/Holo2-4B
- https://huggingface.co/inclusionAI/UI-Venus-2-9B, https://huggingface.co/inclusionAI/UI-Venus-1.5-2B
- https://huggingface.co/mPLUG/GUI-Owl-1.5-8B-Instruct
- https://huggingface.co/Tongyi-MAI/MAI-UI-8B
- https://huggingface.co/microsoft/Fara1.5-9B, https://huggingface.co/microsoft/Phi-Ground-Any
- https://huggingface.co/Salesforce/GTA1-7B-2507
- https://huggingface.co/xlangai/OpenCUA-7B, https://huggingface.co/xlangai/Qwen-CUA
- https://huggingface.co/ByteDance-Seed/UI-TARS-1.5-7B
- https://huggingface.co/meituan/EvoCUA-8B-20260105
- https://huggingface.co/tencent/UI-Mate-9B
- https://huggingface.co/lemuralabs/Muse-Glimmer-30B-GUI-Grounding-Fast
- https://huggingface.co/meta-models/Muse-Glimmer-30B
- https://huggingface.co/openbmb/MiniCPM-V-4.7-1B, https://huggingface.co/openbmb/MiniCPM-V-4.7-35B-A3B, https://huggingface.co/openbmb/MiniCPM-V-4.6
- https://huggingface.co/empero-ai/Qwen3.8-2B-Distill, https://huggingface.co/FINAL-Bench/Darwin-2B-Opus
- https://huggingface.co/TokenRhythm/NeoHorse-1-4B, https://huggingface.co/TokenRhythm/NeoHorse-1-9B
- https://huggingface.co/h2oai/h2o-lightning-4b, https://huggingface.co/Qwen/Qwen-Drive-1.0-4B, https://huggingface.co/kai-os/Carnice-9b
- https://huggingface.co/endless-frontier/BigBang-v1, https://huggingface.co/XYZAILab/XYZ-Aquila-mini
- GGUF listings: https://huggingface.co/mradermacher/GUI-Owl-1.5-2B-Instruct-GGUF, https://huggingface.co/mradermacher/GUI-Owl-1.5-4B-Instruct-GGUF, https://huggingface.co/mradermacher/GUI-Owl-1.5-8B-Instruct-GGUF, https://huggingface.co/mradermacher/MAI-UI-2B-GGUF, https://huggingface.co/mradermacher/MAI-UI-8B-GGUF, https://huggingface.co/mradermacher/MAI-Gym-9B-GGUF, https://huggingface.co/mradermacher/Holo-3.1-4B-GGUF, https://huggingface.co/mradermacher/Holo-3.1-9B-GGUF, https://huggingface.co/mradermacher/UI-Venus-1.5-2B-GGUF, https://huggingface.co/mradermacher/UI-Venus-1.5-8B-GGUF, https://huggingface.co/mradermacher/UI-Venus-1.5-30B-A3B-GGUF, https://huggingface.co/bartowski/UI-Venus-2-9B-GGUF, https://huggingface.co/bartowski/Fara1.5-4B-GGUF, https://huggingface.co/bartowski/Fara1.5-9B-GGUF, https://huggingface.co/Mungert/UI-TARS-1.5-7B-GGUF, https://huggingface.co/bartowski/tencent_UI-Mate-27B-GGUF, https://huggingface.co/bartowski/Ling-3.0-flash-VL-GGUF, https://huggingface.co/unsloth/Inkling-Small-GGUF
- HF listing API used for searches and derivative trees: https://huggingface.co/api/models

Independent evidence:
- Artificial Analysis leaderboard, parsed 2026-10-27: https://artificialanalysis.ai/leaderboards/models

Web searches (all returned vendor or secondary material, no independent tune-vs-base comparison):
- https://aiweekly.co/alerts/occamy-10-open-35b-edges-gpt-56-sol-on-claw-eval-average
- https://aiweekly.co/alerts/cua-open-sources-cua-s1-forms-a-706k-parameter-system-1-model-for-filling-web
- https://codersera.com/blog/xiaomi-mimo-v2-6-flash-distill-9b-guide-2026/amp/
- https://jacar.es/?p=7565
- https://www.benchlm.ai/benchmarks/screenSpotPro
- https://arxiv.org/pdf/2511.05502 (general Apple-silicon engine comparison; no GUI models)

Boards I could not read (JavaScript pages): https://gui-agent.github.io/grounding-leaderboard/ and http://osworld-v1.xlang.ai/
