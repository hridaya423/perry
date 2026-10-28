# Captain + subagent grounding: what the literature says

Scope: planner/grounder splits for GUI agents, 2023–2026. Sources were read via arXiv HTML and abstracts, through a summarizing fetch tool. Numbers are as reported by authors. Items I could not verify are listed at the end.

## 1. What the planner should send the grounder

- **Describe the target in three ways at once: visual, positional, functional.** UGround defines these three referring-expression styles and notes composites are common. Dropping positional expressions cost 0.9 points on ScreenSpot (76.9 to 76.0). https://arxiv.org/html/2410.05243v3
- **Long planner-style descriptions beat short benchmark instructions.** Phi-Ground-7B scores 43.2 on ScreenSpot-Pro with short instructions and 55.0 with long descriptions from an o4-mini planner (+11.8). The 4B model reaches 51.5. UI-Vision rises from 27.2 to 36.2. https://arxiv.org/html/2507.23779v1
- **The grounder must be trained on the style you send.** Phi-Ground says mismatched train and test description styles change results significantly. Check whether Holo-4B and GUI-Owl-2B saw long descriptions. https://arxiv.org/html/2507.23779v1
- **Prompt format.** UGround uses: "In the screenshot, what are the pixel element coordinates corresponding to {Description}?" Agent S2 passes `click(element_description)` plus the screenshot to its grounder. https://arxiv.org/html/2410.05243v3, https://arxiv.org/html/2504.00906v1
- **Put the text before the image.** Text-first input beat image-first by +4.1 (6 crops) and +2.9 (15 crops) on ScreenSpot-Pro. https://arxiv.org/html/2507.23779v1
- **Planner errors dominate.** UGround found the most common failure is a plausible description of the wrong on-screen element, then hallucinated elements, then descriptions too generic to pinpoint. Phi-Ground attributes 24.8% of errors to planner mistakes. https://arxiv.org/html/2410.05243v3, https://arxiv.org/html/2507.23779v1
- **Icons are the weak spot.** OS-Atlas-7B: 28.1% text vs 4.0% icon on ScreenSpot-Pro. Tell the planner to quote visible text when it exists and add functional plus neighbor context for icons. https://arxiv.org/html/2504.07981v1
- **Region hints.** ScreenSeekeR has the planner name the target plus likely neighboring elements and areas. Removing neighbor inference cost 1.7 points (48.1 to 46.4). https://arxiv.org/html/2504.07981v1
- **Image tokens matter more than model size.** Phi-Ground reports performance is bottlenecked below about 2000 image tokens (4B model: ~1045 tokens at 7 crops, ~2353 at 16). This matches your 15/60 (1024) vs 31/60 (2048). ScreenSpot-v2 is largely insensitive to token count. https://arxiv.org/html/2507.23779v1

## 2. Test-time tricks, with measured gains

| Trick | Gain | Cost | Source |
|---|---|---|---|
| Confidence-gated zoom (8 samples, T=0.9, consensus vote, else one zoom) | ScreenSpot-Pro: Qwen2.5-VL-7B 27.6 to 41.0; UI-Venus-7B 50.0 to 61.8; UI-Venus-72B 59.2 to 67.8. ScreenSpot-v2: +0.2 to +4.2 | One extra pass only on uncertain cases. No latency figure given | https://arxiv.org/html/2604.14113 |
| Unconditional iterative zoom (DiMo-GUI) | ScreenSpot-v2 accuracy fell 81.84 to 77.20 | 6:43:07 vs 35:47 runtime | same |
| ReGround (ground, crop around the prediction, re-ground) | OS-Atlas-7B: 18.9 to 40.2. Iterative zooming/narrowing: 31.0/31.9 | 2+ passes | https://arxiv.org/html/2504.07981v1 |
| Planner-guided recursive search (ScreenSeekeR, GPT-4o planner) | OS-Atlas-7B: 18.9 to 48.1. Without recursion: 41.9. Majority vote instead of patch scoring: 46.8 | Many planner and grounder calls. Not reported | same |
| Marker-feedback re-grounding (Chain-of-Ground) | Qwen3-VL-32B: 61.4 single to 65.8 dual to 67.5 triple. 7B to 235B to 32B chain: 68.4 | 2 to 3 calls | https://arxiv.org/html/2512.01979 |
| Planner samples K=8 actions and a judge picks one (GTA1) | OSWorld 41.3 to 43.4 at 50 steps, 43.4 to 45.2 at 100 | K parallel planner calls | https://arxiv.org/html/2507.05791v3 |

Crop details that held up:
- ReGround crop-size sweep for OS-Atlas-7B (512/768/1024/1280 px): 25.1, 34.2, 40.2, 40.1. UGround-7B peaked at 768 and was flat otherwise. Crops that are too small lose context. https://arxiv.org/html/2504.07981v1
- UI-Zoomer, UI-Venus-7B: fixed crop ratios 0.8, 0.5, 0.3 scored 55.2, 59.6, 61.4. An adaptive Gaussian crop scored 61.8. Shifting the window inward at screen edges beat clipping (61.8 vs 60.3) and shrinking (58.5). https://arxiv.org/html/2604.14113
- Chain-of-Ground warns that large markers occlude neighbors and small ones get missed. It also warns that reusing one model for every step repeats its errors. A different or small first model helped. https://arxiv.org/html/2512.01979
- GTA1 uses no voting and no clustering. Its grounder is RL-trained on a click-inside-box reward only. Adding IoU or format rewards hurt (ScreenSpot-Pro 50.1 vs 44.5). https://arxiv.org/html/2507.05791v3
- Marker-draw verification by the planner appears in PC Agent (red marks on boundary and click point) and GUI-PRA (cropped view with a marker for a judge). I found no paper that measures the gain in isolation. https://arxiv.org/pdf/2412.17589, https://arxiv.org/pdf/2509.23263

## 3. When to fall back

- **Sampling dispersion is the best-evidenced signal.** SafeGround draws K=10 samples at T=1.0, bins them, and scores dispersion. K=5 to 10 helps and 10 to 15 barely changes it. AUROC is 0.75 (Holo1.5-7B) and 0.81 (Holo1.5-3B). That is useful, not strong. A calibrated threshold then cascades to a stronger model. Holo1.5-7B plus Gemini-3-pro reached 58.66% vs 53.28% Gemini-only on ScreenSpot-Pro. https://arxiv.org/html/2602.02419v2
- **Token confidence adds a little.** UI-Zoomer: spatial consensus alone 60.81, token confidence alone 61.10, combined 61.80. https://arxiv.org/html/2604.14113
- **Verbalized confidence is poorly calibrated.** Baseline expected calibration error is 0.48 to 0.63. HyperClick trains it down to 0.25. Off-the-shelf Holo or GUI-Owl will not give a usable number without sampling. https://arxiv.org/html/2510.27266
- **Raw frontier-model coordinates were poor in 2025.** GPT-4o grounded directly scored 0.8% on ScreenSpot-Pro. This says nothing about current Claude. https://arxiv.org/html/2504.07981v1
- **AX snapping: no published evidence.** Related facts only. Agent S2 uses text (OCR) and structural experts beside the visual one, and removing them cut subtask success from 70.6% to 65.2% (OCR) and 73.7% to 69.4% (structural). Screen2AX reports its reconstructed AX data beats native macOS AX metadata by 2.2x on grounding, so native macOS AX is often incomplete. https://arxiv.org/html/2504.00906v1, https://research.macpaw.com/publications/screen2axvisionbasedapproachautomatic

## 4. Verification and recovery

- **Agent S2:** the Worker returns SUCCESS or FAILURE per subgoal, refines its description to self-correct, and the Manager replans. No separate verifier. Proactive replanning added +4.6 (15-step) and +6.2 (50-step) points. Planning failures were the largest failure class. https://arxiv.org/html/2504.00906v1
- **Agent S3 / BJudge:** run several full rollouts, convert each to a behavior narrative, and pick the best. OSWorld reached 72.6%. It multiplies cost, so it suits offline or high-stakes use. https://arxiv.org/abs/2510.02250
- **Step-level cascade:** a small policy runs by default and a stuck monitor (loops, repeated ineffective actions) and a milestone monitor escalate to a strong model. https://arxiv.org/abs/2604.27151
- **StateAct:** structured program state beats pixels where it exists. Cost per task fell about 9x and OSWorld 2.0 success rose from 20.6% to 26.9% on the same Claude backbone. https://arxiv.org/abs/2607.22798
- **Misclick handling.** The papers give no recipe beyond re-describe, replan, and re-ground. Nothing measured "mark failed point as negative".

## 5. Cost and latency

- **The planner dominates.** For Agent S2, planning and reflection are 76–96% of task latency. Even the best agents take 2.7–4.3x more steps than a human. Later steps run about 3x slower than early ones. A 2 to 5 s local grounder is the small term. https://arxiv.org/abs/2506.16042
- **Grounder quality moves agent success.** o3 plus Jedi-7B scored 51% on OSWorld. GPT-4o plus Jedi-3B/7B scored 24.0/27.0. The "23% to 51%" headline has an ambiguous baseline row in the table. https://arxiv.org/html/2505.13227v3
- **Agent S3** recommends UI-TARS-1.5-7B as its grounder. https://pypi.org/project/gui-agents
- **CoAct-1** averages about 10 steps per task via coding actions (secondary source). https://alphaxiv.org/abs/2508.03923
- **Holo3.1** (0.8B/4B/9B/35B-A3B): end-to-end agent step time fell from 6.8 s to 3.3 s on a DGX Spark with NVFP4 and harness changes. Q4 GGUF on a MacBook M4 Pro does 5.5 requests/min. These are agent steps, not grounder-only calls. https://hcompany.ai/newsroom/holo3.1
- **No like-for-like comparison** of planner+grounder vs end-to-end frontier computer-use (dollars or seconds per step) was found.

## Recommended design for Perry

1. **AX first, grounder second.** Have the planner emit an element description. Match it against AX label, role and description. Act via AX when there is a unique match. Call the grounder only for AX-less targets (canvas, icons, custom views). Evidence: Agent S2 structural/text experts, StateAct, Screen2AX on AX gaps.
2. **Planner writes long, three-part descriptions.** Format: visible text or type, position relative to named neighbors or region, function, plus app and window name. Put the text before the image. Expected gain is about +9 to +12 points on hard sets, but only if Holo and GUI-Owl were trained on long descriptions. Test this first on the 41-item set.
3. **Run the grounder at about 2000 image tokens when accuracy matters.** Your own 15/60 to 31/60 matches Phi-Ground's "below ~2000 tokens is the bottleneck". Budget 5 s for hard steps and use ~900 tokens for easy ones.
4. **Gate zoom on disagreement, never zoom always.** Take 5 to 10 samples at T≈0.9–1.0 from one image encode (my assumption: prefill is reused in llama.cpp, so extra samples are cheap; benchmark it). Accept when they cluster. Otherwise crop to about 0.3–0.5 of the screen around the median, shift the window at edges, and re-ground once at T=0. Expect +9 to +13 points on ScreenSpot-Pro-style sets from UI-Zoomer. Do not zoom unconditionally.
5. **Fallback ladder.** Order: dispersion above threshold, then zoom retry, then planner marker check, then AX snap or cloud-model grounding. Calibrate the threshold on your 41-item and 60-item sets, following SafeGround's held-out FDR method.
6. **Snap to AX as a consistency check, not a blind move.** If the predicted point falls inside an AX element whose label matches the description, snap to its center. If it falls in an unrelated element, treat that as disagreement and escalate. This is my design inference. No paper tests it, so measure it.
7. **Planner marker check only on escalation.** Draw a small ring on a crop of the predicted region and ask the planner "is this the target?". Use a small marker, since big ones occlude (Chain-of-Ground). It costs a planner call, which is the dominant latency term, so keep it off the happy path.
8. **Verify after every action and recover by changing the description.** Compare the screen or AX diff against the expected outcome. On failure, record the failed point as negative, have the planner re-describe from a new angle (Agent S2's refine-description loop), and add a stuck monitor for repeated identical actions. Reduce planner turns first, since they dominate latency.

## Could not verify

- No H Company grounding numbers for Holo1.5 through Holo3.1 beyond third-party AUROC figures. The Holo3.1 page gave no grounding scores or prompt guidance.
- Not read in detail: OS-Atlas, Aguvis, UI-TARS, OpenCUA, GUI-Owl-1.5 and Mobile-Agent-v3.5 grounding prompts. No claims about them are made above.
- No paper on AX snapping, and none on isolated marker-verification gains.
- Several 2026 arXiv items (UI-Zoomer, SafeGround, StateAct, step-level cascade) came from search results and fetched summaries only.
- The Agent S2 and Phi-Ground texts contain internal inconsistencies noted by the fetch tool (planner identity, table labels).
- Jedi's "23 to 51" baseline is ambiguous. CoAct-1 step counts come from a secondary summary.
- The OSWorld-Human PDF was unreadable. Its figures come from the arXiv abstract plus search-result summaries.
