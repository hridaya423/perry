# Local model lineup for Perry, per type of Mac

Date: 2026-10-27. Author: research sub-agent. Status: final. Research only. I downloaded no weights and no engines, built nothing, and launched nothing. Every speed in this file comes from a cited source or from my own arithmetic, never from my own run.

## Summary (15 lines)

1. The draft ladder is right in size and file names: 4B UD-Q4_K_XL 2.91 + 0.67 = 3.58 GB, 9B UD-Q4_K_XL 5.97 + 0.92 = 6.89 GB, Qwen3.8-27B UD-Q4_K_XL 17.56 + 0.93 = 18.49 GB (Hugging Face file listings, 2026-10-27). Qwen3.8 has no small models, so every tier below 27B is Qwen3.5 or a derivative.
2. "cua's computer use model is really good too no?" For Perry, no. cua-s1-4b-0.2 is a 4B LoRA adapter for closed-option decisions ("which listed option is right"). It has no GGUF and no MLX build, only Core ML ports by a third party. Cua's own README says "bring your own agent and model". The useful part of Cua for Perry is cua-driver, which Perry already uses.
3. No GUI fine-tune beats Qwen3.8-27B for Perry. Vendor OSWorld-Verified: Qwen3.8-27B 84.3, Holo4-27B 85.2 (non-commercial licence, unusable), UI-Mate-27B 77.0, MAI-Gym-9B 76.2, UI-Venus-2-9B 70.8. No GUI score is independent.
4. New since the 2026-10-25 reports: MAI-Gym-9B (Apache-2.0, 2026-10-16, community GGUF), MiMo-V2.6-Distill-Qwen-9B (MIT, official GGUF, large vendor tool-use gains), Occamy-1.0 (35B-A3B agent, Apache-2.0), DeskForge-Qwen3.5-4B (GUI grounding), and ISTA/ByteShape 3-bit 27B quants that put a 27B near 10 GB.
5. Verdict on fine-tunes: all quality claims are vendor-only. Ship the base Qwen models, which have independent Artificial Analysis scores, and run four challengers through Perry-bench: MiMo-9B, MAI-Gym-9B, Occamy-1.0 and Ornith-1.5. A swap is a file change because they share one architecture.
6. Abliterated and uncensored variants (720 flagged among 9,588 Qwen derivatives I fetched) do not belong in the lineup. They remove refusals in an agent that clicks Send and Delete on a screen that can carry injected text.
7. `--cache-reuse` is useless for Perry: the server disables it with an mmproj loaded and on hybrid models. The prefix cache that works is the recurrent-state checkpoint (`--ctx-checkpoints`), which the current flags already use. Put the screenshot last and send only the newest one.
8. MTP helps a dense 27B on M5 Max (+78%), barely helps the MoE (+9%), and hurt on M2 Max (-25%) and on Qwen3.5-9B under Metal (-11% to -28%, llama.cpp issue 23752). Keep it off for small models and the MoE.
9. Speed is bandwidth for decode and compute for prefill. My derived numbers: a 4B on an M4 base decodes about 32 tok/s, a 9B about 15, a 27B IQ4_XS about 6.5 (UNVERIFIED, arithmetic on llama-bench rows). A base chip cannot make a 27B feel quick. A Pro chip can make it usable. An M5 makes it comfortable.
10. Lineup: 8 GB gets Qwen3.5-2B (2.0 GB). 16 GB base gets 2B / 4B / 9B. 24 GB gets 4B / 9B / 9B-Q6, plus an experimental 27B at 3-bit on Pro chips. 32 to 36 GB gets 9B / 35B-A3B IQ4_XS / 27B IQ4_XS. 48 GB gets 35B-A3B Q4_K_XL and 27B Q5_K_XL. 64 GB and up add Q6_K and Q8_0.
11. The 8 GB story, said plainly: a 2B model reads the screen and does simple one-step jobs. It is a weak planner (Artificial Analysis index 6.9, estimated). Anything harder should go to the cloud brain, and Perry should say so before it sends anything.
12. ModelFit change 1: at 24 GB the 0.75 fit rule blocks every 27B, including 3-bit ones that need about 13 GB active. Add a 3-bit rung behind a flag, or leave 24 GB at 9B Q6_K_XL.
13. ModelFit change 2: add the chip class to the rule. A 24 GB M4 base and a 24 GB M4 Pro need different answers, because prefill is 1.6 times and decode 2.3 times faster on the Pro (r8, section 6.1).
14. Not verified: any measured Metal number for Qwen3.5/3.8 on 8, 16 or 24 GB machines, the Metal working-set share below 48 GB, the 3-bit quants' real quality, and every vendor score. Section 5 lists the rest.
15. Next steps: add MiMo-9B, MAI-Gym-9B, Occamy-1.0 and DeskForge-4B to Perry-bench; keep the onboarding benchmark as the final chooser of the rung; do not default to anything with a non-commercial or pending licence.

---

## 0. Method and labels

- Read first, not repeated here: `docs/research/2026-10-25/r3-local-models.md` and `r8-local-models-best.md`. I cite r8 as "r8 §x". Where r8 already answers a question I give the pointer and add only what is new.
- Read: `Packages/PerryBrain/Sources/PerryBrain/Local/ModelFit.swift` and `App/Brain/LocalEngine.swift`. Current flags: `-ngl all -fa on -c 32768 -np 1 --image-max-tokens 640 --cache-ram 2048 --ctx-checkpoints 8 --checkpoint-min-step 1024`, interactive lane `enable_thinking:false`, deep lane `--reasoning-effort medium --reasoning-budget 4096 --reasoning-preserve`, optional `--spec-type draft-mtp --spec-draft-n-max 2`. ModelFit uses `fitShare = 0.75` of the Metal working set and `diskHeadroomGB = 2.0`.
- Labels:
  - **independent**: measured by a party that did not train the model (Artificial Analysis, community benchmark repos).
  - **vendor**: the model's author published it. Nobody checked it.
  - **derived**: my arithmetic on cited rows. Formula: decode ≈ effective bandwidth ÷ file size; prefill ≈ throughput ÷ (2 × active parameters). Marked UNVERIFIED.
  - **VERIFIED (HF)**: a file size or licence read from the Hugging Face API on 2026-10-27.
- Hugging Face coverage: I fetched the full derivative trees (finetune, merge, adapter, quantized relations) of Qwen3.5-0.8B, 2B, 4B, 9B, 27B, 35B-A3B, Qwen3.6-27B, 35B-A3B, Qwen3.8-27B and Qwen3.8-Flash-Next. That gave 9,588 distinct derivative records. I read about 130 model cards and listings by hand. I cannot claim to have seen every upload. Downloads are a popularity signal, not a quality signal.
- The llama.cpp release I checked is b11925 (2026-10-27).

---

## 1. Q1: Best general brain per Mac class, from the whole Hugging Face corner

### 1.1 Method and the headline

I looked for any derivative that beats its base on something Perry needs: tool calls, following multi-step instructions, reading a screen. The result is short.

- **Only the base models have independent scores.** Artificial Analysis (AA) lists Qwen3.8-27B at index 33.7 (xhigh), 27.6 (medium), 20.2 (thinking off); Qwen3.6-35B-A3B at 18.2; Qwen3.5-9B at 11.2 (thinking) and 13.3 estimated (off); Qwen3.5-4B at 13.1 estimated; Qwen3.5-2B at 6.9 estimated (r8 §3.1, source: https://artificialanalysis.ai/leaderboards/models).
- **No derivative I found has an AA row, an OSWorld board row, or a third-party replication.** Every claim below is vendor.
- **Therefore:** the lineup defaults to the Qwen base, with Unsloth UD quants (the best-measured quant family, r8 §B.2). Derivatives enter as challengers.

### 1.2 Derivatives worth knowing, with licence and what is actually claimed

All rows were read from the HF API and the model card on 2026-10-27. Scores are vendor unless stated.

| Model | Base | Size, licence | Claim | Perry verdict |
|---|---|---|---|---|
| MiMo-V2.6-Distill-Qwen-9B (Xiaomi) | Qwen3.5-9B | 9B, **MIT**. Official GGUF: ggml-org (Q8_0 9.53 GB + mmproj 0.62 GB). Bartowski GGUF: IQ4_XS 5.23, Q4_K_M 5.84, Q4_K_L 6.20, Q5_K_M 6.88, Q6_K_L 8.11, mmproj 0.92 GB. Created 2026-09-21. | Against Qwen3.5-9B on its card: AutomationBench 30.3 vs 5.0, Toolathlon-Verified 35.2 vs 25.9, Terminal-Bench 2.1 37.1 vs 27.0, OfficeQA 19.5 vs 9.0, SWE-Bench Verified 61.1 vs 60.0. | **Lead challenger for the 9B slot.** Large tool-use gain, vision file included, permissive licence. Vendor only. |
| MAI-Gym-9B (Tongyi-MAI) | Qwen3.5-9B | 9B, Apache-2.0. Community GGUF only (mradermacher): Q4_K_M 5.63 GB, IQ4_XS 5.23 GB, mmproj-f16 0.92 GB. Created 2026-10-16, 207 downloads on the base repo. | OSWorld-Verified 76.2, MobileWorld 78.4, "state of the art among open GUI agents under 10B" (arXiv 2610.20939, Oct 2026). | **Lead challenger for GUI actions at 9B.** It is an agent checkpoint, so chat and tool-calling quality outside GUI tasks is untested. |
| Occamy-1.0 (Accio-Lab) | Qwen3.6-35B-A3B | 35B-A3B, Apache-2.0. Official GGUF: IQ4_XS 18.73 GB, Q4_K_M 21.17 GB, IQ3_M 15.44 GB, mmproj-F16 0.90 GB. 783,484 downloads on the GGUF repo. Created 2026-08-13, updated 2026-10-02. | On its card, against Qwen3.6-35B-A3B: Claw-Eval 82.2 vs 69.5, tau3-Bench Banking 37.1 vs 11.9, AutomationBench pass 27.6 vs 7.5, Terminal-Bench 2.1 59.0 vs 49.5. AA's independent tauBanking for the base is 9.3, which fits the card's 11.9 for the base. | **Lead challenger for the 32 to 64 GB "fast" slot.** The base's weak spot is multi-step tool use. Occamy targets exactly that. Vendor only. A second card named "occamy-ai/occamy-1.0" turned up in search and returned nothing from the API. I could not resolve that. |
| Ornith-1.5 (ornith-ai): 9B, 35B-A3B, 122B, 4B | Qwen3.5/3.6 architecture | MIT. 9B GGUF Q4_K_M 5.78 GB, 35B-A3B Q4_K_M 21.71 GB. 5.2M and 3.9M downloads on the GGUF repos. | MCP-Atlas 54.2 vs 46.8 and Toolathlon 41.2 vs 29.6 against Qwen3.5-9B (r8 §3.6). A competitor table shows weaker IFEval and IFBench. Opens every answer with a thinking block. | Challenger only, per r8. 122B (MIT, 2026-10-16, 76k downloads) is out of range for consumer Macs. |
| DeskForge-Qwen3.5-4B (docling-project) | Qwen3.5-4B | 4B, Apache-2.0. **No GGUF** from the author. The sibling DeskForge-Gemma4-E4B has a mradermacher GGUF. Created 2026-09-30. | ScreenSpot-Pro 49.0 vs 30.2 for the base, ScreenSpot-v2 92.1 vs 80.1, OSWorld-G 63.8 vs 51.2, MMBench-GUI 80.1 vs 61.8 (card, vendor). Grounding only, answers as a `pyautogui` call with fractional coordinates. | Interesting for the 8 and 16 GB tiers as a **grounding helper**, but it has no GGUF, so Perry would need to convert it. Not a brain. |
| Ternary-Bonsai-2-9B (prism-ml) | Qwen3.5-9B | 9B at 2.4 to 2.6 GB, Apache-2.0. The Q2_0 pack (2.56 GB + 0.62 GB mmproj) runs on **upstream** llama.cpp. PQ2_0 and PTQ1_0 need the PrismML fork. | Prism claims near-FP16 quality for the 27B (r8). I did not find a 9B quality table I trust. | **The only credible 8 GB upgrade path** (3.2 GB for a 9B). Needs Perry-bench and a quality check first. Vendor only. |
| Swift-1.5-Qwen3.8-27B (ukisai) | Qwen3.8-27B | 27B, licence "other" (free up to US$1M yearly revenue, r8). | 58.5% fewer thinking tokens at +0.35% score (vendor). | Test for the deep lane. Licence blocks a default for an AGPL project. |
| Qwopus3.8-27B-Flash (Jackrong) | Qwen3.8-27B | 27B, Apache-2.0, GGUF. | 12.8% faster decode, 80.7% MTP acceptance, less runaway reasoning (vendor). | Test for the deep lane. |
| JetBrains Qwen3.8-3.6-27B-blend | merge of Qwen3.6-27B and 3.8-27B | 27B, Apache-2.0, "unofficial JetBrains derivative". | Fewer output tokens on a 100-task internal coding benchmark (vendor). | Coding focus. Skip. |
| Signal-3.8-27B (agentionai) | Qwen3.8-27B | 27B, Apache-2.0. | Card prescribes temperature 0.6, min-p 0.05, KV q8_0 or f16, and warns that a 4-bit value cache causes runaway repetition. | Useful sampling note. No score I could check. |
| sabi-noema, Tess-4.5-27B, VeriLoop-E2, AREX-2 (27B), AREX-Turbo (4B) | Qwen3.8-27B / Qwen3.5-4B | Apache-2.0. | Agentic RL, engineering, code and physics, and deep-research focus. | Not GUI or desktop tool use. Skip. |
| MiniCPM-V-4.7 (1B, 35B-A3B) | own | 1B GGUF 0.55 to 2.02 GB, Apache-2.0. Created 2026-10-06. | Vision-language. I found no Perry-relevant score. | Possible 8 GB helper. Test. |
| Gemma 4 (12B, 26B-A4B, E4B) | Google | Apache-2.0. | AA index 6.5 to 16.7e, below Qwen at equal size (r8 §3.7). | Set aside. |
| Holo-3.1 (0.8B, 4B, 9B, 35B-A3B), Holo4-35B-A3B | Qwen3.5/3.6 | Apache-2.0. Holo4-35B-A3B official GGUF Q4_K_M 21.3 GB. | OSWorld 80.8 for Holo4-35B-A3B (vendor, r8). | GUI challenger on 32 GB and up. |
| Holo4-27B | Qwen3.8-27B | **CC BY-NC 4.0**. | OSWorld 85.2 (vendor). | Cannot ship or default. |
| Qwen3.8-Flash-Next (125B-A6B) | new architecture | licence qwen-community-1.0, GGUF 72.6 to 111.3 GB. | AA 39.8 (independent). KL divergence about 0.23 at sizes that fit a 64 GB Mac (from my earlier read of the quant card, not re-checked today). | Set aside for every tier below 128 GB. |
| JEV (autotrust), Clef / Clef-Flash (Cloudflare), Tev1, cua-s1 | Qwen3.5 | Apache-2.0. | "Decision" models: they return probabilities for listed options, not free text. Popular (JEV-27B-VL 2.7M downloads). | Not a brain. They cannot write a reply or emit a tool call. |
| Hemmingway-1, Frontis-MA1-35B | Qwen3.8-27B / Qwen3.6-35B-A3B | CC BY-NC 4.0. | Writing style. | Excluded by licence and purpose. |

**Models that distill another vendor's outputs.** Qwable-9B-Claude-Fable-5, Qwythos-9B-Claude-Mythos-5-1M (also "deeply uncensored"), and TeichAI Qwen3.8-27B-Fable-Distill label themselves Apache-2.0, but they were trained on another vendor's model outputs. That label does not settle whether the training data's terms of use allow it. Perry should not ship them. I did not assess the legal question further.

### 1.3 Abliterated and uncensored variants (licence and safety)

- Scale: I counted 720 of 9,588 Qwen derivative records with `abliterat`, `uncensor`, `heretic`, `huihui` or `jailbreak` in the name or tags. Biggest: Bahushruth/Qwen3.6-35B-A3B-abliterated-v4 (530,537 downloads), JonathanColetti/Qwen3.8-27B-Uncensored (47,300), huihui-ai/Huihui-Qwen3.8-27B-abliterated (34,377), HauhauCS Qwen3.8-27B "Aggressive" with an MTP head (card claims 0/465 refusals). A bartowski GGUF of darkc0de/XORTRON-AgentRICO carries the abliterated and uncensored tags with no licence field.
- Licence: most inherit Apache-2.0 from Qwen. That is fine for AGPL. Several have no licence field.
- Why not to ship them in Perry:
  1. Perry reads arbitrary screen content and can click Send, Delete and Pay. Refusal behaviour is one of the few defences against instructions injected by a web page or email. Abliteration removes it, by design.
  2. The huihui card calls its method "crude, proof-of-concept". Removing a direction from the weights can also change tool-call behaviour. I found no evaluation of that.
  3. A product that offers "uncensored" brains on the download screen carries a trust cost the owner has not asked for.
- Verdict: leave them out. If the owner wants power users to bring any GGUF, add a "use my own model file" box later, outside the curated lineup.

### 1.4 Quant uploaders

| Uploader | What they give | Use for Perry? |
|---|---|---|
| unsloth | UD ("dynamic") GGUFs, mmproj, MTP variants (`unsloth/Qwen3.5-{2,4,9}B-MTP-GGUF`, `Qwen3.6-35B-A3B-MTP-GGUF`, a 1.37 GB `MTP/mtp-Qwen3.8-27B-Q4_0.gguf` head). Qwen3.8-27B GGUF repo created 2026-08-13, 6.0M downloads. | **Yes, first choice.** r8 §B.2: 14 of the 26 positions on the size-against-quality frontier. |
| ggml-org | Official-style reference GGUFs (MiMo Q8_0). | Yes where no Unsloth file exists. |
| bartowski | Fast GGUFs of new models, usually imatrix quants (e.g. MiMo-9B, UI-Venus-2-9B, Groot-19B-A3B). | Yes as a fallback. |
| mradermacher | Plain and "i1" imatrix GGUFs, often the only GGUF of niche models (MAI-Gym-9B, Holo4-27B). | Fallback only. Smaller trust surface is better. |
| ISTA-DASLab | Qwen3.8-27B GSQ-RCO quants: IQ2_XS 8.42, IQ2_S 9.26, IQ3_XXS 10.09, IQ3_S 11.77 GB (and "-mtp" files +0.35 GB). Created 2026-08-28, 1.25M downloads. Card table (vendor): IQ3_S matches BF16 on AIME25 (100.0) and LiveCodeBench v6 (85.71), GPQA-Diamond 89.39 vs 89.90; IQ3_XXS 88.89; IQ2_XS 84.85 and 76.57. | **Experimental 3-bit 27B** for 24 GB Pro chips. Not a default. |
| byteshape | Qwen3.8-27B IQ2_XXS 8.84, IQ3_XXS 9.92, IQ3_XS 10.35, IQ3_S 11.04, IQ4_XS 13.08 GB (bits per weight 2.56 to 3.84). Embeds an MTP head under 250 MB. 2.0M downloads. | Same role as ISTA. |
| mlx-community, lmstudio-community, nightmedia, others | MLX and GGUF conversions. In r8's KL table, MLX 4-bit (KL 0.0573) is 3.1 times worse than UD-Q4_K_XL (0.0182). | MLX only if Perry adds an MLX path. |
| AtomicChat, mudler (APEX), Accio-Lab | Own quant recipes. | Not evaluated. |

### 1.5 Best general brain per class

"Best" here means best by independent evidence, with the vendor-only challenger named. The speeds are in section 3.9 and the exact files in section 4.

| Class | Best by independent evidence | Strongest challenger (vendor only) |
|---|---|---|
| 8 GB | Qwen3.5-2B (AA 6.9e). The 4B only if the fit rule passes. | Ternary-Bonsai-2-9B Q2_0 (9B in 3.2 GB). MiniCPM-V-4.7-1B as a helper. |
| 16 GB, base chip | Qwen3.5-4B (tau2 92.1, AA 13.1e). | MiMo-V2.6-Distill-Qwen-9B on M5. |
| 16 GB, Pro chip | Qwen3.5-9B (AA 11.2 to 13.3e). | MiMo-9B, MAI-Gym-9B for actions. |
| 24 GB | Qwen3.5-9B at Q4/Q6; on a Pro chip, an experimental 27B at 3-bit. | MiMo-9B. |
| 32 to 36 GB | Qwen3.6-35B-A3B (fast), Qwen3.8-27B IQ4_XS (deep). | Occamy-1.0 for the fast lane. |
| 48 GB | Same pair at Q4_K_XL and Q5_K_XL. | Occamy-1.0, Holo4-35B-A3B for actions. |
| 64 GB and up | Same pair at Q6_K and Q8_0. | Occamy-1.0, Holo4-35B-A3B. |

---

## 2. Q2: Computer-use and GUI-agent models

### 2.1 Direct answer to "cua's computer use model is really good too no?"

No, not as a replacement for the brain, and not in the form it ships.

1. **What it is.** `cua-ai/cua-s1-4b-0.2` (created 2026-09-22, Apache-2.0, 57 likes) is two LoRA adapters ("text" and "multimodal") on a frozen Qwen3.5-4B for "closed-option computer-use element/action decisions". It picks among listed options. It does not plan open-ended tasks. Siblings: `cua-s1-4b-0.1`, `cua-s1-nano-0.1`, `cua-s1-forms` (all 2026-09). I found nothing newer on the `cua-ai` organisation on 2026-10-27.
2. **How it runs.** The model card shows only a Python `peft` loader. No GGUF, no MLX build. The only ports I found are Core ML (FluidInference/cua-s1-4b-coreml and cua-s1-forms-coreml), ONNX and a JS port, all third-party. To use it in llama.cpp Perry would have to merge the adapter and convert it itself.
3. **How good it is.** The Cua benchmark repo (`libs/cua-bench-s1`) shows large wins on in-distribution form tasks, such as safety gates, pagination and multi-step submit. On the external OSWorld next-action task (out of domain) element accuracy is around 0.4 to 0.5, which is near the 0.5 chance line the table prints, and task accuracy is near zero for every model. I did not re-verify the column headers of that table today, so read it as "the repo's own numbers show a narrow specialist".
4. **What Cua says itself.** The root README: "Bring your own agent and model, or explore CUA-S1 for specialized decisions. Cua provides the computer and automation tools."
5. **Where Cua helps Perry.** Cua Driver (accessibility tree, screenshots, clicks and typing, background delivery) is the eyes and hands. Perry already uses it. The model still has to come from somewhere else.

Sources: https://huggingface.co/cua-ai/cua-s1-4b-0.2, https://github.com/trycua/cua, https://huggingface.co/FluidInference/cua-s1-4b-coreml.

### 2.2 The GUI-agent field (all scores vendor)

| Model | Base | Size, licence | OSWorld-Verified | Other | GGUF + mmproj? |
|---|---|---|---|---|---|
| Qwen3.8-27B (the baseline) | itself | 27B, Apache-2.0 | 84.3 | OSWorld 2.0 48.0, AndroidWorld 81.9 (r8 §3.3) | Yes, Unsloth |
| Holo4-27B | Qwen3.8-27B | 27B, **CC BY-NC 4.0** | 85.2 | OSWorld 2.0 61.7 (H Company harness) | Yes (official q4_k_m 16.88 GB + mmproj 0.93) |
| Holo4-35B-A3B | Qwen3.6-35B-A3B | Apache-2.0 | 80.8 | OSWorld 2.0 30.9 | Yes (official q4_k_m 21.3 GB + mmproj 0.9) |
| Holo-3.1 (0.8B, 4B, 9B, 35B-A3B) | Qwen3.5/3.6 | Apache-2.0 | 80.0 (35B, metric not named) | AndroidWorld 71 (4B, 9B) | 35B official; others community |
| UI-Mate-27B (Tencent) | Qwen3.6-27B | Apache-2.0 | **77.0** | WindowsAgentArena 66.2 | No GGUF found (9B has a community GGUF) |
| UI-Mate-9B | Qwen3.5-9B | Apache-2.0 | 66.2 | | Community (prithivMLmods Q4_K_M 5.63 GB) |
| **MAI-Gym-9B** (Tongyi) | Qwen3.5-9B | Apache-2.0 | **76.2** | MobileWorld 78.4 | Community (mradermacher) |
| UI-Venus-2-9B (inclusionAI) | Qwen3.5-9B | licence **pending** | 70.8 | ScreenSpot-Pro 73.0 | Bartowski (Q4_K_M 5.91 GB + mmproj 0.92) |
| UI-Venus-1.5-2B / 8B / 30B-A3B | Qwen3-VL | Apache-2.0 | none | ScreenSpot-Pro 57.7 / 68.4 / 69.6, AndroidWorld up to 77.6 | Not checked |
| MAI-UI-2B / 8B | Qwen | Apache-2.0 | none | MAI-UI ScreenSpot-Pro 73.5, AndroidWorld 76.7 (card) | Not checked |
| Fara1.5 (4B, 9B, 27B; Microsoft) | Qwen3.5 | MIT | browser only | WebVoyager, Online-Mind2Web, WebTailBench | Not checked |
| DeskForge-Qwen3.5-4B | Qwen3.5-4B | Apache-2.0 | none | ScreenSpot-v2 92.1, ScreenSpot-Pro 49.0 | No |
| Qwen3.5-9B (baseline small) | itself | Apache-2.0 | 41.8 (UI-Venus card) | AndroidWorld 57.8 | Yes, Unsloth |
| cua-s1-4b-0.2 | Qwen3.5-4B | Apache-2.0 | n/a (closed options) | | No |
| UI-TARS, OpenCUA, GTA1, Northstar-CUA-Fast, Qwen-CUA | older or different base | various | Northstar-CUA-Fast 37.01 (own card) | | Not Qwen3.5 architecture. Not examined further. They are all older than the Qwen3.5 family and their cards report lower numbers than the ones above. |

Official OSWorld boards list none of the Qwen3.8, Holo3.1/4, UI-Venus-2, UI-Mate or MAI-Gym models (r8 §3.3). Treat the table as claims.

### 2.3 Is any of them better than Qwen3.8-27B or a small Qwen3.5 for Perry's loop?

Perry's loop is: accessibility tree plus a screenshot, then the next action.

- **Against Qwen3.8-27B:** no. The best claim that Perry can legally ship is Holo4-35B-A3B at 80.8, below Qwen3.8-27B at 84.3 (both vendor). The only model above it, Holo4-27B at 85.2, carries a non-commercial licence. UI-Mate-27B (77.0) and MAI-Gym-9B (76.2) trail it. A specialist that loses to its own base's newer generation is not a win.
- **Against a small Qwen3.5 (4B, 9B):** yes, probably, for actions. The Qwen3.5-9B base scores 41.8 on OSWorld-Verified (UI-Venus card). MAI-Gym-9B claims 76.2, UI-Venus-2-9B 70.8, UI-Mate-9B 66.2, all on the same base. Even with a discount for vendor harnesses and for Perry having the accessibility tree, a 9B GUI specialist is the most credible upgrade for 16 to 24 GB. The risk is losing general chat and tool-call quality. I found no data on that.
- **For 8 GB:** DeskForge-Qwen3.5-4B (grounding 92.1 on ScreenSpot-v2) and Holo-3.1-4B are the 4B candidates. Neither has an official GGUF.
- **Verdict:** keep the Qwen base as the default brain. Add MAI-Gym-9B as an "actions" challenger on 16 to 24 GB, Holo4-35B-A3B on 32 GB and up, and test each in Perry-bench on Perry's own tasks. Adopt a specialist only if it beats the base by a clear margin (r8 suggests 5 points) and keeps chat and tool-call quality.

### 2.4 Can they run in llama.cpp on a Mac?

Yes for everything in the table that has a Qwen3.5 or 3.6 or 3.8 base. They share the architecture, so llama.cpp loads them as it loads the base, with an `--mmproj` file for vision. The catch is the supply chain: MAI-Gym, UI-Mate and UI-Venus have only community GGUFs, and Holo-3.1 4B and 9B have none from the author. Perry should convert and host its own audited copy of any that ship.

---

## 3. Q3: Every optimisation for fast local turns on Apple Silicon

r8 §2 and §5 already map the hardware model and the win-pc settings. This section adds the checks I did on 2026-10-27, resolves the open questions, and gives per-class flag sets.

### 3.1 Flag-by-flag table

Evidence is from the llama.cpp server README and server source (b11925), r8, and the issues named.

| Setting | What it does here | Recommendation | Evidence |
|---|---|---|---|
| `-ngl all` | All layers on the GPU. | Keep. | Unified memory; nothing to split. |
| `-fa on` | Flash attention. | Keep on. | Default path for hybrid models. |
| `-c` (context) | KV allocation. | 6144 on 8 GB, 16384 on 16 to 24 GB, 32768 from 32 GB. | KV is small on these hybrids: 32 KiB per token for the 4B and 9B, 64 KiB for the 27B (r8 §2.5). A Perry turn is about 2K tokens. |
| `-ctk q8_0 -ctv q8_0` | 8-bit KV. | 8 GB and 16 GB only. | KL divergence 0.024 to 0.039 (r8 §B.3). It saves about 0.25 GiB at 16K on a 4B, which matters only on 8 GB. Never `q4_0` keys. |
| `-b`, `-ub` | Prompt batch sizes. | Keep the defaults (2048 and 512). Perry-bench sweeps `-ub` 512, 1024, 2048 on one M4 and one M5. | The Splash prefill rows used 2,048-token chunks (r8 §2.3). I found no sourced gain for a larger `-ub` on Metal. UNVERIFIED. |
| `--image-max-tokens` | Caps the vision encoder. | 320 on 8 GB, 640 on 16 to 24 GB and on M1 to M4, 1024 on M5 Pro, Max and Ultra. | Encoder cost is superlinear: 1,189 ms for 640 by 488 pixels and 40,129 ms for a 4,015-token image on an M2 with 16 GB (llama.cpp PR 21443, via r8 §2.6). |
| Screenshot downscale (client side) | Fewer pixels before encoding. | Send the **frontmost window** only, with the longest edge at 1280 px or less. One token covers 32 by 32 pixels (r8 §2.6), so 1280 by 800 is about 1,000 tokens and 960 by 600 about 560. The accessibility tree supplies exact text, so the picture only needs layout and colour. | Arithmetic from r8 §2.6. |
| `--cache-reuse` | Shift-and-reuse cached chunks. | **Do not use.** | The server disables it when an mmproj is loaded and when the memory cannot shift (hybrid/recurrent models). Read in `server-context.cpp`, b11925. |
| `--ctx-checkpoints N`, `--checkpoint-min-step` | Recurrent-state checkpoints. This is the prefix cache that actually works on Qwen3.5/3.6/3.8. | Keep: 8 and 1024. Keep the system prompt and the tool schema as a byte-stable prefix. | Hybrid models reuse prefixes only through checkpoints (r8 §5, row 5). |
| Image position in the prompt | An image resets reuse after it. | Put the **newest screenshot last** and send only that one. Drop old images from history. | llama.cpp issue 26994 (image prompt cache never hits, open). Issue 30357: changed whitespace in reasoning text forces a full re-prefill on hybrid models, so resend reasoning byte for byte. |
| `--cache-ram` | RAM prompt cache. | 1024 MiB on 8 to 24 GB, 2048 above. | Server default is 8192 MiB (r8 §5). |
| `--cache-idle-slots`, `--kv-unified` | Idle-slot cache, unified KV. | Leave default. With `-np 1` they change nothing. | Server README. |
| `-np 1` | One slot. | Keep. | One user, one conversation. |
| `-lm mmap` (default), `--mlock` | Weight loading. | Keep mmap. **Never `--mlock`** and never raise `iogpu.wired_limit_mb`. | Wiring a 20 GB model starves macOS on a shared Mac. r8 §2.4 already forbids changing the wired limit. |
| `--n-cpu-moe` | Keeps MoE expert layers on the CPU. | **Do not use.** | It exists for machines with a small GPU and big system RAM. Apple silicon has one memory pool. |
| `--fit on --fit-target 2048` | Server shrinks context if memory is short. | Keep, as r8 recommends. | Server README. |
| `--sleep-idle-seconds 300` | Unload after idle. | Keep. | Frees memory on a shared Mac. |
| `--warmup` | Initial empty run. | Keep default. | |
| `--spec-type draft-mtp --spec-draft-n-max 2` | MTP drafting. | Dense 27B on M5 chips. Off for the MoE and for 2B, 4B, 9B. Elsewhere on only if the onboarding benchmark shows 15% or more on a 150-token answer. | See 3.2. |
| `--spec-type draft-dflash` | External block drafter. | **Off.** | DFlash2 drafts are text-only and break image requests with an HTTP 500 (ByteShape card). |
| `--spec-type ngram-*`, `draft-simple`, `draft-eagle3`, `draft-dspark` | Other drafters. | Off. | r8 §5, row 4: ngram repeated earlier errors on win-pc. |
| `--reasoning-effort`, `--reasoning-budget`, `--chat-template-kwargs` | Thinking control. | As in `LocalEngine.swift` now. | r8 §5 rows 6 to 9. |

### 3.2 MTP and speculative decoding, in one place

- M5 Max, dense 27B: decode 17.7 to 31.5 tok/s (+78%), first token 6.35 to 7.61 s. MoE: 89.2 to 97.1 tok/s (+9%) (r8 §5, source https://github.com/stared/benching-local-llms-on-apple-silicon).
- M2 Max, MoE via Ollama: 46.2 to 34.6 tok/s (-25%) (r8 §5, RaynarDM dataset).
- **New:** llama.cpp issue 23752 reports Qwen3.5-9B with MTP on Metal at -11% to -28% (build b9330). I read the issue; it is one report on one build, so treat it as "can hurt small models on Metal", not as a rule.
- **New:** MTP now works with images (llama.cpp PR 30257, merged 2026-10-10).
- Net rule: MTP is a bet on a compute-rich chip with a dense model. Perry's own benchmark decides.

### 3.3 MLX against llama.cpp, per chip

I found no new independent run after r8. Summary of r8 §4:
- M5 Max (one author, build 9430): llama.cpp decodes 4 to 10% faster and answers short prompts 2.2 times sooner. MLX prefills 3 to 22% faster.
- M2 to M4 chips: measured rows favour MLX for Qwen MoE decode by 3 to 63% (HIESCH, BASERT, RAYNAR).
- On hybrid models, mlx-swift-lm re-reads the whole prompt every turn (issue 660), where llama.cpp keeps checkpoints. For Perry's multi-turn pattern that favours llama.cpp.
- Quality at equal bits favours GGUF: UD-Q4_K_XL KL 0.0182 against MLX 4-bit 0.0573 (r8 §B.1).
- Decision: ship llama.cpp, as already approved.

### 3.4 Quant choice per chip

KL divergence of Qwen3.6-27B quants against bf16 (r8 §B.1, https://github.com/asher/mlx-kld): UD-Q6_K_XL 0.0048, Q6_K 0.0065, UD-Q5_K_XL 0.0094, **UD-Q4_K_XL 0.0182**, Q4_K_M 0.0204, **IQ4_XS 0.0242**, UD-Q3_K_XL 0.0474, Q3_K_S 0.0927.

- IQ4_XS is 19% smaller than UD-Q4_K_XL for the 27B (14.25 against 17.56 GB). On a bandwidth-limited chip that is about 23% more decode speed for 0.006 more KL divergence. **Use IQ4_XS for the 27B on 32 GB and on any Pro chip with 36 GB or less, and Q4_K_XL from 48 GB.**
- Bandwidth-rich chips (M-Max, M5 Pro) gain less from the smaller file, so spend the memory on Q5 or Q6 where it fits.
- **For models of 9B and below, stay at UD-Q4_K_XL or higher.** I did not find a measurement that shows small models tolerate IQ4 or 3-bit as well as big ones, and fewer parameters leave less to lose (UNVERIFIED reasoning, not a measured result).
- Tool calling is the weakest category under quantisation: KL 0.177 at Q8_0 for Qwen3.6-35B-A3B (r8 §B.2). This argues for Q6_K or Q8_0 where memory allows.
- 3-bit: r8 says do not ship 3-bit. ISTA GSQ-RCO and ByteShape claim near-lossless 3-bit 27B on AIME25, GPQA and LiveCodeBench (vendor). Those are task scores on reasoning and code, not tool-call validity. Keep the 3-bit rung behind a flag until Perry-bench passes it on tool calls.

### 3.5 MoE against dense on bandwidth-limited chips

- Decode: a MoE reads only its active experts (about 1.9 GB per token for Qwen3.6-35B-A3B at 5 bits per weight), so decode barely depends on chip bandwidth. Measured: 58.6 tok/s on an M2 Max (Q4_K_M, 21.7 GB), 69 on an M5 Pro (vendor) (r8 §2.2).
- Prefill: ∝ active parameters, so a 3B-active MoE prefills 3 to 9 times faster than a dense 9B or 27B (r8 §2.3). That is the big win for Perry, whose time sits in prefill.
- The catch is memory: the whole 18 to 23 GB file must be resident. That is why the MoE starts at 32 GB.
- **An idea nobody has tested for Perry:** Qwen3.6-35B-A3B UD-IQ3_XXS (13.21 GB + 0.90 GB mmproj) on a 24 GB Mac. It would decode and prefill faster than a dense 9B and use less memory than a 27B. I found no KL data for that quant. Add it to Perry-bench.

### 3.6 Prewarm, sleep and the prefix cache

- On hotkey-down, wake the server and send a one-token request that carries the stable prefix (system prompt, tool schema). This fills the checkpoint before the user finishes speaking.
- `--sleep-idle-seconds 300` unloads after five idle minutes. With mmap the file stays in the page cache, so the reload is quick. r8 estimates a 22 GB swap at 4 to 6 seconds from the SSD (UNVERIFIED).
- The stable prefix must be byte-identical across turns. No timestamps in the system prompt.

### 3.7 Thinking and sampling

Unchanged from `LocalEngine.swift` and r8 §5. Interactive lane: thinking off, temperature 0.7. Deep lane: effort medium, budget 4096. Signal-3.8-27B's card adds a warning that is worth copying: use min-p 0.05 to stop runaway repetition, and never use a 4-bit value cache.

### 3.8 Recommended flag sets per class

All sets start from the current `LocalEngine.swift` flags and change only what is listed.

| Class | Changes from current flags |
|---|---|
| 8 GB | `-c 6144 --cache-ram 256 --image-max-tokens 320 -ctk q8_0 -ctv q8_0`; no MTP; `--ctx-checkpoints 4`; one model only, no deep lane. |
| 16 GB base | `-c 16384 --cache-ram 1024 --image-max-tokens 640 -ctk q8_0 -ctv q8_0`; no MTP. |
| 16 to 18 GB Pro | `-c 16384 --cache-ram 1024 --image-max-tokens 640`; f16 KV; no MTP. |
| 24 GB base | `-c 16384 --cache-ram 1024 --image-max-tokens 640`; no MTP. |
| 24 GB Pro | Same, plus `--image-max-tokens 1024` on M5 Pro. 27B 3-bit (experimental): MTP file only if the benchmark approves. |
| 32 to 36 GB | `-c 32768 --cache-ram 2048`; MoE without MTP; 27B deep lane IQ4_XS with MTP only on M5. |
| 48 GB | Same; Q4_K_XL / Q5_K_XL; MTP on the deep lane if the benchmark shows 15% or more. |
| 64 GB and up | Same; both models can stay resident; `--sleep-idle-seconds` can be longer. |

### 3.9 Speeds (derived, UNVERIFIED)

I derived decode speed from the effective bandwidth implied by the llama-bench rows for Llama-2 7B Q4_0 on each chip (ggml-org/llama.cpp discussion 4167: https://github.com/ggml-org/llama.cpp/discussions/4167) divided by file size. Prefill uses compute throughput from the same rows divided by 2 × active parameters, with no efficiency loss, so real prefill will be somewhat lower. "First token" is a 1,640-token turn (1,000 text tokens + 640 image tokens) plus an encoder estimate. Treat these as ranges, not promises. Measured or vendor anchors appear in r8 §2.2 and §2.3.

| Chip | 2B Q4_K_XL decode / first token | 4B Q4_K_XL | 9B Q4_K_XL | 27B IQ4_XS |
|---|---|---|---|---|
| M1 | 40 tok/s / 9 s | 19 / 13 s | 9 / 23 s | 4 / 61 s |
| M2 | 62 / 6 s | 29 / 9 s | 14 / 15 s | 6 / 40 s |
| M3 | 61 / 6 s | 28 / 9 s | 14 / 15 s | 6 / 38 s |
| M4 | 69 / 5 s | 32 / 7 s | 15 / 12 s | 6.5 / 32 s |
| M1 Pro | 104 / 4 s | 48 / 6 s | 23 / 10 s | 10 / 27 s |
| M2 Pro | 111 / 3 s | 51 / 5 s | 25 / 8 s | 10 / 21 s |
| M3 Pro | 88 / 3 s | 40 / 5 s | 20 / 8 s | 8 / 21 s |
| M4 Pro (20-core) | 145 / 2.4 s | 67 / 3.6 s | 33 / 6 s | 14 / 16 s |
| M2 Max | 188 / 1.6 s | 87 / 2.4 s | 42 / 4 s | 18 / 11 s |
| M4 Max | 237 / 1.2 s | 109 / 1.8 s | 53 / 3 s | 22 / 8 s |
| M5 | 91 / 1.5 s | 42 / 2.2 s | 20 / 3.8 s | 8.5 / 10 s |
| M5 Pro | 189 / 0.7 s | 87 / 1 s | 42 / 1.7 s | 18 / 4.4 s |
| M5 Max | 342 / 0.3 s | 157 / 0.5 s | 77 / 0.9 s | 32 / 2.2 s |

Cross-checks against measurements: derived M4 Pro 27B prefill of 110 tok/s sits near the vendor figure of 125 for Bonsai-2-27B on an M4 Pro (r8 §2.3). Derived M5 Max 27B decode of 32 tok/s (IQ4_XS) is consistent with the measured 18.4 tok/s for the 29 GB Q8_0 file on the same chip (18.4 × 29.05 ÷ 14.25 = 37.5, so my table is a little low, not high).

MoE rows (Qwen3.6-35B-A3B, llama.cpp), measured or vendor, from r8 §2.2 and §2.3: M2 Max 58.6 tok/s decode and 671 tok/s prefill on a 4,096-token prompt (one author); M5 Pro 69 tok/s decode and 1,968 tok/s prefill (vendor); M5 Max 92.9 tok/s (independent). For the M4 Pro I use r8's planning value of about 60 tok/s and a 4 s first token (UNVERIFIED).

---

## 4. Q4: The lineup per Mac class

Download size is the weight file plus the mmproj (vision) file, both VERIFIED (HF) on 2026-10-27. "RAM while running" is warm weights plus an allowance of 1 to 3 GB for context, compute buffers and the 1 GB RAM cache (r8 §6.1, UNVERIFIED). Speeds are the derived ranges of section 3.9 or the MoE anchors, UNVERIFIED unless marked.

Plain descriptions follow the owner's rule: no jargon, no em dashes.

### 4.1 Files used

| Short name | Repo | File | Weights + vision |
|---|---|---|---|
| 2B | `unsloth/Qwen3.5-2B-GGUF` | `Qwen3.5-2B-UD-Q4_K_XL.gguf` + `mmproj-F16.gguf` | 1.34 + 0.67 = **2.01 GB** |
| 4B | `unsloth/Qwen3.5-4B-GGUF` | `Qwen3.5-4B-UD-Q4_K_XL.gguf` + `mmproj-F16.gguf` | 2.91 + 0.67 = **3.58 GB** |
| 4B light | same repo | `Qwen3.5-4B-IQ4_XS.gguf` + mmproj | 2.48 + 0.67 = **3.15 GB** |
| 9B | `unsloth/Qwen3.5-9B-GGUF` | `Qwen3.5-9B-UD-Q4_K_XL.gguf` + `mmproj-F16.gguf` | 5.97 + 0.92 = **6.89 GB** |
| 9B high | same repo | `Qwen3.5-9B-UD-Q6_K_XL.gguf` + mmproj | 8.76 + 0.92 = **9.68 GB** |
| 35B-A3B (light) | `unsloth/Qwen3.6-35B-A3B-GGUF` | `Qwen3.6-35B-A3B-UD-IQ4_XS.gguf` + `mmproj-F16.gguf` | 17.73 + 0.90 = **18.63 GB** |
| 35B-A3B | same repo | `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` + mmproj | 22.36 + 0.90 = **23.26 GB** |
| 35B-A3B (high) | same repo | `Qwen3.6-35B-A3B-UD-Q6_K.gguf` + mmproj | 29.31 + 0.90 = **30.21 GB** |
| 35B-A3B (max) | same repo | `Qwen3.6-35B-A3B-Q8_0.gguf` + mmproj | 36.90 + 0.90 = **37.80 GB** |
| 27B (light) | `unsloth/Qwen3.8-27B-GGUF` | `Qwen3.8-27B-UD-IQ4_XS.gguf` + `mmproj-F16.gguf` | 14.25 + 0.93 = **15.18 GB** |
| 27B | same repo | `Qwen3.8-27B-UD-Q4_K_XL.gguf` + mmproj | 17.56 + 0.93 = **18.49 GB** |
| 27B (high) | same repo | `Qwen3.8-27B-UD-Q5_K_XL.gguf` + mmproj | 20.88 + 0.93 = **21.81 GB** |
| 27B (higher) | same repo | `Qwen3.8-27B-UD-Q6_K.gguf` + mmproj | 21.98 + 0.93 = **22.91 GB** |
| 27B (max) | same repo | `Qwen3.8-27B-Q8_0.gguf` + mmproj | 29.05 + 0.93 = **29.98 GB** |
| 27B 3-bit (experimental) | `ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF` | `Qwen3.8-27B-GSQ-RCO-IQ3_XXS.gguf` + the mmproj from the Unsloth repo | 10.09 + 0.93 = **11.02 GB** |
| MTP head (27B) | `unsloth/Qwen3.8-27B-GGUF` | `MTP/mtp-Qwen3.8-27B-Q4_0.gguf` | +1.37 GB |

### 4.2 Per class

| Class | Small | Recommended for this Mac | Large |
|---|---|---|---|
| **8 GB** (M1 to M4 base) | 2B (2.01 GB) | **2B** (2.01 GB) | 4B light (3.15 GB), only if the fit rule passes |
| **16 GB base** (M1 to M4) | 2B (2.01 GB) | **4B** (3.58 GB). On M5 base: 9B. | 9B (6.89 GB) |
| **16 to 18 GB Pro** (M1/M2/M3 Pro) | 4B (3.58 GB) | **9B** (6.89 GB) | none worth shipping |
| **24 GB base** (M2/M3/M4/M5 base) | 4B (3.58 GB) | **9B** (6.89 GB) | 9B high (9.68 GB) |
| **24 GB Pro** (M4 Pro, M5 Pro) | 4B (3.58 GB) | **9B high** (9.68 GB) | 27B 3-bit, experimental (11.02 GB) |
| **32 to 36 GB** (Pro/Max) | 9B (6.89 GB) | **35B-A3B light** (18.63 GB) | 27B light (15.18 GB) |
| **48 GB** (Pro/Max) | 9B high (9.68 GB) | **35B-A3B** (23.26 GB) | 27B high (21.81 GB) |
| **64 GB** (Max) | 9B high (9.68 GB) | **35B-A3B high** (30.21 GB) | 27B higher (22.91 GB) or max (29.98 GB) |
| **96 to 128 GB** (Max/Ultra) | 35B-A3B (23.26 GB) | **35B-A3B max** (37.80 GB) | 27B max (29.98 GB); both stay loaded |

Speeds, RAM and descriptions:

| Class and tier | Download | RAM while running | Expected speed (UNVERIFIED unless marked) | Plain description |
|---|---|---|---|---|
| 8 GB, 2B | 2.0 GB | about 3 GB | 40 to 70 tok/s, first answer in 5 to 9 s | Quick and light. Reads your screen and handles short questions and simple one-step jobs. |
| 8 GB, 4B light | 3.2 GB | about 4.5 GB | 19 to 32 tok/s, first answer in 7 to 13 s | A little smarter, but your Mac may feel tight. Close big apps first. |
| 16 GB base, 4B | 3.6 GB | about 6 GB | 19 to 32 tok/s, 7 to 13 s | Quick and capable. A good balance of speed and brains for everyday jobs. |
| 16 GB base, 9B | 6.9 GB | about 9 GB | 9 to 15 tok/s, 12 to 23 s | Smarter, but you will wait longer for each answer. |
| 16 to 18 GB Pro, 9B | 6.9 GB | about 9 GB | 20 to 25 tok/s, 8 to 10 s | Smarter and still quick on your Mac. Better with longer instructions. |
| 24 GB base, 9B | 6.9 GB | about 9 GB | 14 to 15 tok/s on M2 to M4, 12 to 15 s | Smarter and fits easily. The answer takes a few seconds to start. |
| 24 GB, 9B high | 9.7 GB | about 12 GB | 33 tok/s on M4 Pro scaled by file size, about 22 tok/s; 6 to 8 s | The same brain with finer detail. A little slower, a little more careful. |
| 24 GB Pro, 27B 3-bit | 11.0 GB | about 13 to 14 GB | 14 to 19 tok/s on M4 Pro, first answer about 16 s; M5 Pro about 4 s | Perry's biggest brain squeezed to fit. Strongest answers, but slow on older chips. Experimental. |
| 32 to 36 GB, 35B-A3B light | 18.6 GB | about 21 GB | about 60 tok/s and 3.6 s (M2 Max measured 58.6 for a larger quant) | A large brain that only wakes part of itself for each word, so it feels quick. |
| 32 to 36 GB, 27B light | 15.2 GB | about 18 GB | 16 to 20 tok/s, 10 to 14 s | Perry's most capable private brain. Takes its time on hard jobs. |
| 48 GB, 35B-A3B | 23.3 GB | about 25 GB | about 60 tok/s on M4 Pro; first answer about 4 s | Large and quick. Good at jobs with several steps. |
| 48 GB, 27B high | 21.8 GB | about 25 GB | 10 to 11 tok/s on M4 Pro (15 with MTP); first answer about 15 s | The most careful option. Use it for hard jobs and let it think. |
| 64 GB, 35B-A3B high | 30.2 GB | about 33 GB | about 50 tok/s on M5 Pro, 1.2 s | The same quick brain with finer detail. |
| 96 to 128 GB, 35B-A3B max | 37.8 GB | about 40 GB | 92.9 tok/s (M5 Max, independent) | Fast and very accurate. Plenty of room for other apps. |
| 96 to 128 GB, 27B max | 30.0 GB | about 33 GB | 18.4 tok/s (31.5 with MTP) (M5 Max, independent) | Perry's most capable brain at full detail. Stays loaded next to the fast one. |

The speed, RAM and fit figures for 8, 16 and 24 GB are my arithmetic. No source I found measured Qwen3.5 or Qwen3.8 under llama.cpp on those machines.

### 4.3 The 8 GB story, honestly

- An 8 GB Mac has about 5 to 6 GB the GPU may use (the share is UNVERIFIED: I measured it only at 78% on a 48 GB Mac, r8 §2.4). After the OS and a browser, a 2B model with its vision file (2.0 GB, about 3 GB active) fits. A 4B (3.15 to 3.58 GB) fits only with a short context, a small image budget and little else running.
- What the 2B does well: read what is on screen, answer short questions, rewrite a sentence, take a single clear action when the accessibility tree names the target. Artificial Analysis rates it 6.9 (estimated), and tau2 69.0 (r8 §3.1).
- What it does badly: plan three or more steps, recover from an error, follow long instructions. Say so in the app. When a task is too big, ask the user before sending anything to the cloud brain.
- Free help: on macOS 26 and later Apple's own on-device model needs no download and has its memory managed by the system (r8 §3.4). Use it as the helper for titles, routing and rewrites where Apple Intelligence is on.
- Upgrade path to test: Ternary-Bonsai-2-9B Q2_0, a 9B in 2.56 GB plus a 0.62 GB vision file, which upstream llama.cpp can run. If Perry-bench shows it beats the 2B on tool calls, an 8 GB Mac gets a 9B-class brain in about 3.2 GB. I treat that as unproven.
- Suggested copy for the picker: "This Mac has 8 GB, so the private brain is small. It is good for quick questions and simple jobs. For bigger jobs Perry can ask the cloud brain, with your say-so."

### 4.4 Changes to ModelFit and the lineup code

1. **24 GB fit rule.** ModelFit blocks every 27B at 24 GB (active memory 18 to 21 GB against 0.75 of a working set of about 18 GB). A 3-bit 27B needs about 13 to 14 GB active, which passes. Add that rung, mark it experimental, and require a Pro or Max chip.
2. **Chip class.** The rung choice should use the chip, not only RAM. Prefill is 1.6 times and decode 2.3 times faster on a 24 GB Pro than on a 24 GB base (r8 §6.1). Use the onboarding benchmark to pick between the 9B and the 4B on base chips.
3. **8 GB.** Offer the 2B as the default, not the 4B. Offer the 4B light as an opt-in.
4. **Names.** "Small", "Recommended for this Mac" and "Large" should come from this table, not from fixed 4B / 9B / 27B.
5. **Perry-bench additions** (all share the Qwen architecture, so each is a file swap): MiMo-V2.6-Distill-Qwen-9B Q4_K_M, MAI-Gym-9B Q4_K_M, Occamy-1.0 IQ4_XS, Holo4-35B-A3B Q4_K_M, Ornith-1.5-9B and 35B-A3B, Ternary-Bonsai-2-9B Q2_0 on 8 GB, Qwen3.6-35B-A3B UD-IQ3_XXS on 24 GB, and the ISTA IQ3_XXS 27B on 24 GB Pro. Pass criteria: valid tool calls, correct next-action on Perry's own tasks, first-token time, memory.
6. **Licence gate.** Block any model with a non-commercial or pending licence from being a default or a download option: Holo4-27B, Hemmingway-1, Frontis-MA1-35B, UI-Venus-2-9B until its licence is confirmed, Swift-1.5 and ThinkingCap-Qwen3.8 ("other"), Qwen3.8-Flash-Next (qwen-community-1.0).

---

## 5. What I could not verify

- **Measured Metal speeds** for Qwen3.5-2B, 4B, 9B and for Qwen3.8-27B on 8, 16 and 24 GB Macs. No independent run found. Section 3.9 is arithmetic.
- **The Metal working-set share** below 48 GB (web search could not confirm the 8, 16 and 24 GB fractions). I assume about 75%.
- **Every GUI and tool-use score** for derivatives (MiMo-9B, MAI-Gym-9B, Occamy-1.0, UI-Mate, UI-Venus-2, Holo, Ornith, DeskForge). All vendor. Official OSWorld boards list none of the new models.
- **Whether a GUI specialist keeps chat and tool-call quality.** No data.
- **Quality of 3-bit 27B quants on tool calls.** The ISTA and ByteShape tables measure AIME25, GPQA and LiveCodeBench, not tool-call validity.
- **The `-ub` benefit on Metal** and the exact `-b` best value. Not found.
- **MTP gain on an M4 Pro** with llama.cpp. Untested. The only Metal data are an M5 Max win and M2 Max and Qwen3.5-9B losses.
- **How `llama-server` loads the separate 27B MTP head file.** Not confirmed.
- **Whether the shipped llama.cpp binary has the M5 tensor path.** Unverified (r8 §5).
- **The "occamy-ai/occamy-1.0" duplicate** card. Not resolved.
- **Qwen3.8-Flash-Next's KL figure** (about 0.23). From my earlier read; not re-checked after the context reset.
- **MAI-UI, Fara1.5, UI-Venus-1.5 and UI-TARS GGUF availability.** Not checked.
- **Legal status of models distilled from another vendor's outputs.** Not assessed.
- **Cua column headers** in the cua-bench-s1 table. Not re-verified; I cite the pattern only.

---

## 6. Sources

All read 2026-10-27 unless stated.

**Earlier reports**
- `docs/research/2026-10-25/r3-local-models.md`, `docs/research/2026-10-25/r8-local-models-best.md` (this repository). r8 §F lists its own sources.

**Repository files read**
- `Packages/PerryBrain/Sources/PerryBrain/Local/ModelFit.swift`, `App/Brain/LocalEngine.swift`.

**Hugging Face model and file listings** (HF API, `https://huggingface.co/api/models/<repo>`)
- https://huggingface.co/unsloth/Qwen3.5-2B-GGUF, https://huggingface.co/unsloth/Qwen3.5-4B-GGUF, https://huggingface.co/unsloth/Qwen3.5-9B-GGUF
- https://huggingface.co/unsloth/Qwen3.5-4B-MTP-GGUF, https://huggingface.co/unsloth/Qwen3.5-9B-MTP-GGUF
- https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF, https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF, https://huggingface.co/unsloth/Qwen3.6-27B-GGUF
- https://huggingface.co/unsloth/Qwen3.8-27B-GGUF, https://huggingface.co/Qwen/Qwen3.8-27B
- https://huggingface.co/XiaomiMiMo/MiMo-V2.6-Distill-Qwen-9B, https://huggingface.co/ggml-org/MiMo-V2.6-Distill-Qwen-9B-GGUF, https://huggingface.co/bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF
- https://huggingface.co/Tongyi-MAI/MAI-Gym-9B, https://huggingface.co/mradermacher/MAI-Gym-9B-GGUF, https://arxiv.org/abs/2610.20939
- https://huggingface.co/Accio-Lab/occamy-1.0, https://huggingface.co/Accio-Lab/occamy-1.0-GGUF
- https://huggingface.co/ornith-ai/Ornith-1.5-9B, https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B, https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF, https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-GGUF, https://huggingface.co/ornith-ai/Ornith-1.5-122B
- https://huggingface.co/docling-project/DeskForge-Qwen3.5-4B
- https://huggingface.co/prism-ml/Ternary-Bonsai-2-9B-gguf, https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf
- https://huggingface.co/tencent/UI-Mate-27B, https://huggingface.co/tencent/UI-Mate-9B, https://huggingface.co/prithivMLmods/UI-Mate-9B-GGUF
- https://huggingface.co/inclusionAI/UI-Venus-2-9B, https://huggingface.co/bartowski/UI-Venus-2-9B-GGUF, https://huggingface.co/inclusionAI/UI-Venus-1.5-2B
- https://huggingface.co/Tongyi-MAI/MAI-UI-2B
- https://huggingface.co/Hcompany/Holo4-27B, https://huggingface.co/Hcompany/Holo4-27B-GGUF, https://huggingface.co/Hcompany/Holo4-35B-A3B, https://huggingface.co/Hcompany/Holo4-35B-A3B-GGUF, https://huggingface.co/Hcompany/Holo-3.1-35B-A3B-GGUF, https://hcompany.ai/newsroom/holo4
- https://huggingface.co/microsoft/Fara1.5-9B
- https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF, https://huggingface.co/byteshape/Qwen3.8-27B-GGUF
- https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-27b, https://huggingface.co/Jackrong/Qwopus3.8-27B-Flash, https://huggingface.co/JetBrains/Qwen3.8-3.6-27B-blend, https://huggingface.co/agentionai/Signal-3.8-27B, https://huggingface.co/bottlecapai/ThinkingCap-Qwen3.8-27B
- https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated, https://huggingface.co/Bahushruth/Qwen3.6-35B-A3B-abliterated-v4, https://huggingface.co/empero-ai/Qwythos-9B-Claude-Mythos-5-1M
- https://huggingface.co/autotrust/JEV-9B, https://huggingface.co/Cloudflare/clef-flash, https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf
- https://huggingface.co/cua-ai/cua-s1-4b-0.2, https://huggingface.co/FluidInference/cua-s1-4b-coreml, https://huggingface.co/Tzafon/Northstar-CUA-Fast
- Model trees: `https://huggingface.co/api/models?filter=base_model:<repo>` for each base named in section 0.

**GitHub and engines**
- https://github.com/trycua/cua (README, `libs/cua-bench-s1`, `libs/cua-s1`)
- https://github.com/ggml-org/llama.cpp (release b11925, `tools/server/README.md`, `tools/server/server-context.cpp`)
- https://github.com/ggml-org/llama.cpp/issues/23752 (MTP on Metal), https://github.com/ggml-org/llama.cpp/issues/26994 (image prompt cache), https://github.com/ggml-org/llama.cpp/issues/30357 (reasoning whitespace re-prefill), https://github.com/ggml-org/llama.cpp/pull/30257 (MTP with images), https://github.com/ggml-org/llama.cpp/pull/21443 (encoder timing)
- https://github.com/ggml-org/llama.cpp/discussions/4167 (llama-bench by chip), https://github.com/ggml-org/llama.cpp/discussions/23470 (KV quantisation)
- https://github.com/stared/benching-local-llms-on-apple-silicon, https://github.com/asher/mlx-kld, https://huggingface.co/datasets/RaynarDM/apple-silicon-llm-benchmarks, https://localbench.substack.com/p/qwen-36-35b-a3b-gguf-quality-benchmark, https://localbench.substack.com/p/kv-cache-quantization-benchmark
- https://artificialanalysis.ai/leaderboards/models (index values via r8 §3.1)
- https://os-world.github.io/ (official boards, via r8 §3.3)
