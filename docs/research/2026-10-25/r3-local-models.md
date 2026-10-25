# R3: Local models for Perry's "On this Mac" path

Date: 2026-10-25. Scope: research only. No model was downloaded, no app was launched, no build or test ran.
Example machine for notes: MacBook Pro `Mac16,7`, Apple M4 Pro, 48 GB (`sysctl hw.memsize` = 51539607552; `system_profiler SPHardwareDataType`). Memory pressure was 0 and `kern.memorystatus_level` was 59 at the time of reading.

Conventions. "(inference)" marks my own reasoning from cited facts. "(vendor)" marks a number that the model author reports for their own harness. "(estimate)" marks a number from an aggregator model, not a measurement. "(unverified)" marks a claim I could not confirm from a primary page. Every other claim carries a URL.

---

## 0. Summary of findings

1. Cua does ship a "fine-tuned for computer use" local model family, called CUA-S1. It is not a general GUI agent. It picks one option from a closed list. The 4B checkpoints are LoRA adapters on Qwen3.5-4B. The model card measured 19.5 to 50.2 s per decision on an M1 Ultra and did not measure peak memory ([MODEL_CARD.md](https://github.com/trycua/cua/blob/main/libs/cua-s1/MODEL_CARD.md)). It should stay an experiment.
2. The better single local model for Perry in late 2026 is a general Qwen3.5 VLM (4B or 9B, MLX 4-bit, 3.0 GB or 5.95 GB). It reports ScreenSpot-Pro 60.3 / 65.2, OSWorld-Verified 35.6 / 41.8, and BFCL-V4 50.3 / 66.1 (vendor, [4B card](https://huggingface.co/Qwen/Qwen3.5-4B), [9B card](https://huggingface.co/Qwen/Qwen3.5-9B)). One model can be both brain and grounder, so the user pays one RAM cost.
3. Apple's on-device model needs no download and is the right zero-cost default. Its context is 8,192 tokens, it has tool calling and guided generation, and it gains image input on macOS 27. Perry's current provider uses none of that.
4. For runtime, an MLX Swift helper process is the best fit for "lowest idle RAM". Killing the helper frees all of its memory. It needs a new third-party dependency, so it needs approval.
5. Ollama and LM Studio already work through Perry's discovery code and cost no new dependency. They need the user to install an app first.
6. Local models are far behind cloud on multi-step desktop tasks. The honest line is "private, free, offline, good for short steps and questions about the screen".

---

## 1. What Perry supports today (10 lines)

1. `App/Brain/BrainController.swift:12-20`: the model choice `.local` is labelled "On this Mac". It routes to Apple Intelligence or to a discovered local server model.
2. `App/Brain/BrainController.swift:270-278`: `onDeviceRouteAvailable` is true when Apple Foundation Models is available on macOS 26+, or when a discovered local model passed its capability check.
3. `App/Onboarding/OnboardingDirector.swift:27` and `BrainController.swift:284-290`: onboarding makes the on-device route the default only if the user never chose a model. A saved choice is never overridden.
4. `Packages/PerryBrain/Sources/PerryBrain/Providers/AppleFoundationModelProvider.swift`: wraps `SystemLanguageModel.default`. It flattens the transcript into one prompt string, makes a new `LanguageModelSession` on each call, and passes no tools and no images. Capabilities are `[.local, .streaming]`.
5. `Packages/PerryBrain/Sources/PerryBrain/Router/LocalServerDiscovery.swift`: probes Ollama at `127.0.0.1:11434` and LM Studio at `127.0.0.1:1234` with a 0.3 s timeout. It reads the loaded context window from `api/ps` (Ollama) or `api/v1/models` (LM Studio).
6. `Packages/PerryBrain/Sources/PerryBrain/Providers/ProviderPreset.swift:32-36`: loopback presets exist for Ollama, LM Studio, llama.cpp, vLLM, and Jan.
7. `App/Brain/BrainModelSettingsView.swift:34-60`: the Settings page lists discovered models. The user taps "Check capabilities". The probe asks for streaming, vision, and tools (`BrainController.swift:240`).
8. `Packages/PerryBrain/Sources/PerryBrain/Grounding/ElementChooser.swift` and `scripts/lab/cua-s1-sidecar/server.py`: `CuaS1Chooser` posts `/choose` to a loopback sidecar. The sidecar defaults to a heuristic backend. [docs/plans/megaplan-iii-painkiller.md:36,365,433](../../plans/megaplan-iii-painkiller.md) says cua-s1 is "not a planner" and becomes a default only if it scores within 3 points of the frontier model.
9. `App/CuaDriverClient.swift:543-581`: each capture returns a screenshot (JPEG or PNG) plus an accessibility snapshot. A local VLM can use either or both.
10. Not present: MLX, any model download, any RAM budget, any unload timer, any chip or memory tiering. `project.yml:14-16` shows Sparkle as the only third-party package. The idle budget in `AGENTS.md` is average CPU at most 0.5% and max RSS at most 180 MB. A model loaded inside the Perry process would break that budget.

Also relevant: [docs/tone-sheet.md](../../tone-sheet.md) already says "8 GB of unified memory is under the 16 GB floor for usable 4–7B quantized models" and wants specifics, not apologies.

---

## 2. Local computer-use and GUI-grounding models

### 2.1 What "the cua local model" is

Cua's own local models are the CUA-S1 family. The README calls it "our family of small, specialized System 1 models for computer use" ([trycua/cua](https://github.com/trycua/cua)). Weights are on the [cua-ai Hugging Face org](https://huggingface.co/api/models?author=cua-ai&limit=30), created 2026-09-18 to 2026-09-22.

| Checkpoint | What it is | Size / base | Licence | Source |
|---|---|---|---|---|
| `cua-s1-form-v0` (HF `cua-s1-forms`) | Picks fill, check, click, or skip per form element. Does not write values. | 706,048 params, text only | MIT | [model card](https://github.com/trycua/cua/blob/main/libs/cua-s1/MODEL_CARD.md) |
| `cua-s1-nano-0.1` | Scores candidate (element, action) pairs in one pass. | about 855K trainable params, frozen SmolVLM-256M or SigLIP-base | Apache-2.0 | same |
| `cua-s1-4b-0.1` / `0.2` | Picks one of at most 26 options by reading option-letter logits. | LoRA adapters on frozen Qwen3.5-4B (base is 9.32 GB) | Apache-2.0 (adapters only) | same |

Facts that matter for Perry, all from the [model card](https://github.com/trycua/cua/blob/main/libs/cua-s1/MODEL_CARD.md):

- It is "an early, source-only research release". Membership in the family "does not imply general computer-use capability".
- `4b-0.2` scored 0.944 (text) and 0.722 (multimodal) on live episodes across 13 single-widget environments with a step cap. It has no score for `general_decision`.
- `form-v0` scored 97.5% in distribution and 29.3% (12 of 41) on held-out forms.
- On one Apple M1 Ultra, a warm CPU float32 decision took 19.5 to 50.2 s. GPU and CUDA latency are not measured. Peak memory for 4B inference is not measured. "8 GB hosts cannot load the base model."
- No MLX, Core ML, or GGUF build of the 4B adapters is published. (inference: the adapters could be merged and quantized, but no one has shown that.)
- The 706K form model has a Core ML conversion by FluidInference. It runs at about 0.9 ms per decision on the Neural Engine, but it "does not read résumés, reason about dropdown options, or write free text" ([FluidUse](https://github.com/FluidInference/FluidUse)).

Cua's agent library lists other local models through the `huggingface-local/` prefix: UI-TARS-1.5-7B (full agent), and grounding-only OpenCUA-7B/32B, GTA1-7B/32B/72B, and Holo1.5-3B/7B/72B. The cua.ai docs pages returned 404 during this session, so this list comes from a search summary of [cua.ai grounding models](https://cua.ai/agent-sdk/supported-agents/grounding-models) and [composed agents](https://cua.ai/agent-sdk/supported-agents/composed-agents) (unverified against the pages). The same summary says the local path uses Transformers and needs a GPU with substantial VRAM. It is not an Apple Silicon path.

Cua Driver's optional `cua-perception` extension uses OmniParser's icon detector. The release ledger records that model as AGPL-3.0-only ([notices](https://github.com/trycua/cua/blob/main/libs/cua-driver/docs/perception-third-party-notices.md)). Perry should not bundle it without a licence decision.

### 2.2 Candidate GUI models that run on a Mac

"Plans" means the model chooses multi-step actions. "Grounds" means it returns click coordinates for a described element. All scores are vendor-reported unless noted. Harnesses differ, so do not compare across rows too tightly.

| Model | Params | MLX 4-bit size | Plans / grounds | ScreenSpot-Pro | Other scores | Licence | MLX build |
|---|---|---|---|---|---|---|---|
| Qwen3.5-4B | 4B (5B with vision, per HF) | 3.03 GB | both (general VLM) | 60.3 | OSWorld-Verified 35.6, AndroidWorld 58.6 ([card](https://huggingface.co/Qwen/Qwen3.5-4B)) | Apache-2.0 | [mlx-community/Qwen3.5-4B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit) |
| Qwen3.5-9B | 9B (10B with vision) | 5.95 GB | both | 65.2 | OSWorld-Verified 41.8, AndroidWorld 57.8 ([card](https://huggingface.co/Qwen/Qwen3.5-9B)) | Apache-2.0 | [mlx-community/Qwen3.5-9B-MLX-4bit](https://huggingface.co/mlx-community/Qwen3.5-9B-MLX-4bit) |
| UI-Venus-1.5-8B | 8B (9B listed) | 5.77 GB | both ("end-to-end GUI agent") | 68.4 | 30B-A3B sibling: ScreenSpot-V2 96.2, OSWorld-G 70.6, AndroidWorld 77.6 ([card](https://huggingface.co/inclusionAI/UI-Venus-1.5-8B)) | Apache-2.0 | [UI-Venus-1.5-8B-4bit](https://huggingface.co/mlx-community/UI-Venus-1.5-8B-4bit) |
| UI-Venus-1.5-2B | 2B | 2.48 GB (6-bit; no 4-bit seen) | both | 57.7 ([perea.ai](https://www.perea.ai/research/gui-grounding-models-2026)) | OSWorld-G 59.4 | Apache-2.0 (family) | [UI-Venus-1.5-2B-6bit](https://huggingface.co/mlx-community/UI-Venus-1.5-2B-6bit) |
| Holo2-8B | 8B (9B listed) | no 4-bit seen; bf16 is 17.55 GB | both | 58.9 | ScreenSpot-v2 93.2, OSWorld-G 70.1, OSWorld 39.9, WebVoyager 80.2 ([card](https://huggingface.co/Hcompany/Holo2-8B)) | Apache-2.0 | [Holo2-8B-bf16](https://huggingface.co/mlx-community/Holo2-8B-bf16) |
| UI-TARS-1.5-7B | 7B | 4.88 GB | both | 49.6 | OSWorld 27.5 ([card](https://huggingface.co/ByteDance-Seed/UI-TARS-1.5-7B)) | Apache-2.0 | [UI-TARS-1.5-7B-4bit](https://huggingface.co/mlx-community/UI-TARS-1.5-7B-4bit) |
| Fara1.5-4B | 4B | 4.22 GB (OptiQ-4bit) | both, **browser only** | not reported | WebVoyager 80.8, Online-Mind2Web 57.3 ([card](https://huggingface.co/microsoft/Fara1.5-4B)) | MIT | [Fara1.5-4B-OptiQ-4bit](https://huggingface.co/mlx-community/Fara1.5-4B-OptiQ-4bit) |
| Holo3-35B-A3B | 35B, 3B active | 8-bit only seen; Qwen3.5-35B-A3B 4-bit is 20.4 GB | both | not readable on card | OSWorld-Verified 77.8 ([card](https://huggingface.co/Hcompany/Holo3-35B-A3B)) | Apache-2.0 | [Holo3-35B-A3B-8bit](https://huggingface.co/mlx-community/Holo3-35B-A3B-8bit) |
| GTA1-7B | 7B | not checked | grounds only | 50.0 | OSWorld-G 56.2 ([perea.ai](https://www.perea.ai/research/gui-grounding-models-2026)) | not checked | not checked |
| CUA-S1-4B | LoRA on 4B | none | **chooser only** | n/a | see 2.1 | Apache-2.0 adapters | none |

Notes:

- Sizes are the sum of `.safetensors` bytes from the Hugging Face API for the `mlx-community` repo, except Fara1.5 and UI-Venus 6-bit, which use `usedStorage` and may include extra files. The Qwen3.6-35B-A3B 4-bit repo is 20.42 GB ([API](https://huggingface.co/api/models/mlx-community/Qwen3.6-35B-A3B-4bit?blobs=true)).
- Holo3 and Holo4 target big machines. Holo4-27B reports 85.2% on H's own OSWorld harness and 61.7% on OSWorld 2.0. Its licence is reported as non-commercial. Holo4-35B-A3B is Apache-2.0 and scores 30.9% on OSWorld 2.0 ([aiweekly](https://aiweekly.co/alerts/h-company-ships-holo4-agents-27b-hits-617-on-osworld-20), [HF](https://huggingface.co/Hcompany/Holo4-35B-A3B)). Third-party coverage flags a contamination concern on one H benchmark. Treat these as ceilings, not as expected Perry quality.
- The latest 2026 releases are Fara1.5 (4B/9B/27B, May to July 2026), Holo3 (April), Holo4 (late September), and Qwen3.5 (March). I found no GUI-specific model below 2B that beats Qwen3.5-4B on ScreenSpot-Pro.
- I did not evaluate OpenCUA, GTA1 MLX builds, MAI-UI, Moondream, or OmniParser as Perry candidates. MAI-UI-8B reports 65.8 on ScreenSpot-Pro ([perea.ai](https://www.perea.ai/research/gui-grounding-models-2026)).
- Fit to Perry (inference): Perry already feeds a model an accessibility tree plus a screenshot. The accessibility tree supplies candidates, so most steps need choice, not pixel grounding. Pixel grounding matters for canvas apps. A general VLM such as Qwen3.5 covers both. A specialist grounder adds a second model and a second RAM cost for a small gain.

### 2.3 Latency per step

No source gives a measured per-step latency for a full GUI step on M-series. The data I found:

- UI-Venus-1.5-8B 4-bit: about 195 to 200 prompt tokens/s and 52.1 to 67.6 generated tokens/s on an unnamed Apple Silicon machine. The same page reports 18.77 GB peak memory in its tests, which is much larger than the 5.4 GB of weights ([HF card](https://huggingface.co/mlx-community/UI-Venus-1.5-8B-4bit)). It also reports "localization drift" at 4-bit versus 6-bit and bf16.
- Fara1.5 trains mostly at 1440×900 ([card](https://huggingface.co/microsoft/Fara1.5-4B)).
- (inference) A 1440×900 image costs on the order of 1.5K to 2K visual tokens in Qwen-VL-style encoders. At 200 prompt tokens/s that is 8 to 10 s of prefill before any output. On an M5 the first-token time is 3.3 to 4.1× lower than on an M4 ([Apple](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)). So screenshot steps are practical on M4 Pro and above, and slow on base M1 to M3.

Perry must measure this on its own captures. See section 9.

---

## 3. Local "brain" models

### 3.1 Apple Foundation Models (no download)

| Item | Fact | Source |
|---|---|---|
| Models | AFM 3 Core: 3B dense. AFM 3 Core Advanced: 20B sparse, 1 to 4B active, "unlocked by and optimized for our most capable Apple silicon systems". Apple names no Macs. | [Apple ML](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models) |
| Memory | The full Advanced model sits in flash. Only the selected experts load into DRAM per prompt. No GB figure. | same |
| Context | `SystemLanguageModel.contextSize` is 8192 in Apple's session. A tester on macOS 27.0.1 measured a hard error at 8,138 tokens. A Michael Tsai quote still says 4K, which looks stale. | [WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/), [guide](https://github.com/emiluzelac/on-device-apple-foundation-model), [Tsai](https://mjtsai.com/blog/2026/06/16/apple-foundation-models-in-appleos-27/) |
| Tool calling | Custom `Tool` types with `@Generable` arguments. The new model is "more capable at logic and tool calling". Built-in `OCRTool`, `BarcodeReaderTool`, and a Spotlight search tool. | WWDC26 241 |
| Guided generation | Yes, through `@Generable`. | WWDC26 241 |
| Vision | Image attachments in prompts on the new model (`Attachment(NSImage)`). Larger images cost more tokens and latency. | WWDC26 241 |
| Token counting | `contextSize` and `tokenCount(for:)`, from 26.4. | WWDC26 241 |
| Model protocol | New `LanguageModel` protocol. `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` conform. `MLXLanguageModel` and `CoreAILanguageModel` are open-source conformers. | [WWDC26 339](https://developer.apple.com/videos/play/wwdc2026/339/) |
| Availability | `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)`. The user must enable Apple Intelligence, and the model downloads once. | local SDK `FoundationModels.swiftinterface` (MacOSX27.0.sdk), [guide](https://github.com/emiluzelac/on-device-apple-foundation-model) |
| Quality | Apple compares only to its own earlier models. No Qwen or Gemma comparison. A tester calls it "a small model" that sometimes ignores instructions. | Apple ML page, guide |
| Limits | 8K context cannot hold a full accessibility tree plus history for most apps (inference). Guardrail false positives were reduced but not removed. | WWDC26 241 |

Perry impact: the macOS 27 additions (`LanguageModel` protocol, image attachments) are marked `@available(macOS 27.0, …)` in the local SDK. Perry targets macOS 26+, so they need availability gates. On macOS 26 the provider stays text-only.

### 3.2 Open models

Sizes are MLX 4-bit weights from the HF API. Quality columns are vendor-reported. The Gemma 4 and Qwen columns use different tool benchmarks, so do not compare them directly.

| Model | Release | Weights (4-bit) | Context | Tool and agent scores | Licence | Source |
|---|---|---|---|---|---|---|
| Qwen3.5-0.8B / 2B | 2026-03 | 0.65 / 1.74 GB | 262K native | no scores read | Apache-2.0 | [mlx-community](https://huggingface.co/mlx-community/Qwen3.5-2B-MLX-4bit) |
| Qwen3.5-4B | 2026-03 | 3.03 GB | 262K native | BFCL-V4 50.3, TAU2 79.9 | Apache-2.0 | [card](https://huggingface.co/Qwen/Qwen3.5-4B) |
| Qwen3.5-9B | 2026-03 | 5.95 GB | 262K native | BFCL-V4 66.1, TAU2 79.1 | Apache-2.0 | [card](https://huggingface.co/Qwen/Qwen3.5-9B) |
| Gemma 4 E2B / E4B | 2026-03-31 | 3.55 / 5.15 GB (with embeddings) | 128K | tau2 24.5 / 42.2 | Apache-2.0 | [model card](https://ai.google.dev/gemma/docs/core/model_card_4) |
| Gemma 4 26B-A4B (MoE, 3.8B active) | 2026-03-31 | 15.34 GB | 256K | tau2 68.2 | Apache-2.0 | same |
| Gemma 4 12B Unified | 2026 | about 11 GB (qat-4bit repo) | 256K | tau2 69.0 | Apache-2.0 | same |
| Qwen3.6-27B (dense) | 2026-04 | 16.07 GB | 262K | SWE-bench Verified 77.2 | Apache-2.0 | [card](https://huggingface.co/Qwen/Qwen3.6-27B) |
| Qwen3.6-35B-A3B (MoE, 3B active) | 2026-04 | 20.42 GB | 262K | TAU3-Bench 67.2, MCP-Atlas 62.8 | Apache-2.0 | [card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B) |
| gpt-oss-20b | 2025 | 12.08 GB (MXFP4, measured by Apple) | not read | not read | not read | [Apple](https://machinelearning.apple.com/research/exploring-llms-mlx-m5) |

Not evaluated: Llama, Mistral, Phi, and SmolLM. I gathered no 2026 evidence that they beat Qwen3.5 or Gemma 4 for this job. Phi-4 Mini and Llama 3.x appear only in aggregator speed tables.

Verdict (inference): for tool calling and screenshots in one model, Qwen3.5-4B and 9B are the pick. Both are multimodal, small, and Apache-2.0. Gemma 4 E2B and E4B are weaker on tool use (tau2 24.5 and 42.2). The Qwen3.6 MoE models suit 32 GB and up.

### 3.3 Tokens per second

All of these are community or aggregator numbers. Treat them as order of magnitude.

| Chip, RAM | Model | Engine | tok/s | Method | Source |
|---|---|---|---|---|---|
| M1, 8 GB | Gemma 4 E2B Q4_K_M | Ollama | 44 | estimate | [llmcheck](https://llmcheck.net/benchmarks) |
| M1, 16 GB | Phi-4 Mini Q4_K_M | Ollama | 24 | estimate | llmcheck |
| 8 GB tier | Qwen3.5-4B | not stated | 25 to 35 | community | [InsiderLLM](https://insiderllm.com/guides/best-local-llms-mac-2026/) |
| 16 GB tier | Qwen3.5-9B Q4_K_M | not stated | 20 to 40 | community | InsiderLLM |
| M4 Pro, 24 GB | Qwen3-8B Q4_K_M | Ollama | 44 | estimate | llmcheck |
| M4 Pro, 24 GB | Gemma 4 26B-A4B Q4_K_M | Ollama | 72 | estimate | llmcheck |
| M4 Pro, 48 GB | Qwen3.5-4B / 9B / Gemma 4 26B, 4-bit | MLX server | 83 / 50 / 76 | vendor repo | [Rapid-MLX](https://github.com/raullenchai/Rapid-MLX) (as summarised by search; unverified) |
| M5 Pro, 48 GB | Qwen3.6-35B-A3B 4-bit | MLX | 94.3 | community | llmcheck |
| M4 Max, 128 GB | Qwen3-30B-A3B 4-bit | MLX vs llama.cpp | 110 vs 90 | sourced | llmcheck |

Apple's own measurement on 24 GB MacBook Pros (4096-token prompt, 128 generated tokens): the M5 is 3.3 to 4.1× faster to first token and 1.19 to 1.27× faster to generate than the M4. Bandwidth is 120 GB/s (M4) versus 153 GB/s (M5) ([Apple](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)). The same page gives memory in use: Qwen3-8B 4-bit 5.61 GB, Qwen3-14B 4-bit 9.16 GB, Qwen3-30B-A3B 4-bit 17.31 GB. Generation speed follows memory bandwidth, not RAM size ([InsiderLLM](https://insiderllm.com/guides/best-local-llms-mac-2026/)).

---

## 4. Runtimes

| Runtime | New dependency for Perry? | Licence | Swift effort | Idle memory | Unload | Cold load | Notes |
|---|---|---|---|---|---|---|---|
| Apple FoundationModels | No (system framework) | system | Low. Provider exists. Add tools, images (27+), and `prewarm()`. | System-managed. Perry cannot size it. The Advanced model pages experts from flash ([Apple](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models)). | Not under app control. | Unmeasured. Use `prewarm()`. | Smallest quality ceiling. Needs Apple Intelligence on. |
| MLX Swift LM (`MLXLLM`, `MLXVLM`, `MLXFoundationModels`) | **Yes**: [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) plus swift-huggingface and swift-transformers | MIT | Medium. Gives `LanguageModelSession` access on the 27 SDK. | Weights stay resident until released. MLX also keeps a buffer cache. `Memory.cacheLimit`, `memoryLimit`, `clearCache()`, `snapshot()` control it ([source](https://raw.githubusercontent.com/ml-explore/mlx-swift/main/Source/MLX/Memory.swift)). | Release the model and call `clearCache()`. In a helper process, exit the process. | Unmeasured (inference: several seconds for 3 to 6 GB). | SwiftPM cannot compile Metal shaders. The final build must go through Xcode ([mlx-swift](https://github.com/ml-explore/mlx-swift)). Perry already builds with `xcodebuild`. Binary size is not documented; measure it. |
| llama.cpp | **Yes** (XCFramework or a bundled `llama-server`) | MIT ([repo](https://github.com/ggml-org/llama.cpp)) | High. C API, no first-party Swift package found. | `--sleep-idle-seconds` puts an idle server model to sleep ([Jan/llama.cpp search result](https://jan.ai/integrations/llamacpp)). mmap behaviour not confirmed from the page. | Server sleep or process exit. | Unmeasured. | MLX is reported 10 to 30% faster on supported Apple models, with the gap narrowing ([InsiderLLM](https://insiderllm.com/guides/best-local-llms-mac-2026/)). |
| Ollama | No (user installs it). Perry already discovers it. | not re-verified here | None. Exists. | Default keep-alive is 5 min. `keep_alive: 0` or `ollama stop` unloads now. Negative keeps forever ([FAQ](https://docs.ollama.com/faq)). | Per request, via `keep_alive`. | User-visible on first request. | Perry can set `keep_alive` per request. It cannot pull models without a new flow. |
| LM Studio | No (user installs it). Perry already discovers it. | proprietary app (not re-verified) | None. Exists. | JIT models default to 60 min idle TTL. At most one JIT model stays loaded with auto-evict on. `lms load --ttl N` sets a TTL ([docs](https://lmstudio.ai/docs/developer/core/ttl-and-auto-evict)). | `ttl` field per request. | JIT on first request. | Server must be running. |
| Core AI (new, macOS 27) | No (system) | system | Unknown. Needs model conversion. | "Fine-grained inference memory management" ([WWDC26 guide](https://developer.apple.com/wwdc26/guides/macos/)). | Documented as app-controlled (unverified). | "Ahead-of-time compilation for faster loads". | Targets specialists. No Qwen3.5 build found. Watch item. |

Lowest idle RAM, in order (inference): (1) a helper process that exits when idle, (2) Ollama with `keep_alive: 0`, (3) Apple Foundation Models, where the OS owns the cost, (4) MLX in the Perry process, because the allocator cache and fragmentation can keep RSS up after release. Superwhisper's users already notice this: one reported a local LLM staying at about 900 MB after long idle ([feedback](https://feedback.superwhisper.com/board/p/let-s1-mini-unload-when-superwhisper-is-idle)).

**Recommended shape (inference):** run MLX in a small bundled helper executable that Perry starts on demand and stops on idle. This keeps Perry's own RSS under the 180 MB budget, isolates model crashes, and makes "unload" a process exit. Perry already spawns helpers (the Codex app-server, the cua driver), and `App/Perry.entitlements` carries no sandbox.

**Approval needed:** `mlx-swift-lm`, `swift-huggingface`, `swift-transformers`, and any model download path. Ollama, LM Studio, and Apple Foundation Models need none.

---

## 5. Machine-fit tiering

Rules for the table (inference, unless cited):

- Weights come from section 2.2 and 3.2. Warm RAM is weights plus about 10% runtime. Active RAM adds the key-value cache for a 4K to 8K context. Peak adds a screenshot prefill. Apple measured +0.3 to 0.8 GB over weights at 4K context ([Apple](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)). The UI-Venus 18.77 GB peak shows that vision can spike far higher when the cache is not limited. Set `Memory.cacheLimit` and measure.
- macOS and background apps use 2 to 3 GB on an 8 GB Mac. Usable model memory is about 5 to 6 GB on 8 GB and 12 to 13 GB on 16 GB. A model file at 60 to 70% of total memory is the ceiling ([InsiderLLM](https://insiderllm.com/guides/best-local-llms-mac-2026/)).
- Read the real GPU limit at runtime with `MTLDevice.recommendedMaxWorkingSetSize`. MLX sizes its buffer pool from it ([Memory.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift/main/Source/MLX/Memory.swift)). `iogpu.wired_limit_mb` reads 0 (default) on the example Mac.
- Default budget cap: 25% of RAM, rounded up to the next preset, with a 2 GB minimum. Stretch presets may reach 50% of RAM. (A model file at 60 to 70% of RAM is the hard ceiling in the source above.)
- Chip rule: base M1 to M3 (bandwidth about 68 to 100 GB/s): drop one size class for screenshot work, or use accessibility-tree text only. M4 and up: use the table. M5: screenshot prefill is 3 to 4× faster, so keep the table. Pro and Max chips have 273 GB/s and above and run MoE models well.

| Unified memory | Default brain + grounder (one model) | Stretch option (load on demand) | Idle, cold | Idle, warm | Active | Peak (screenshot) | Budget cap |
|---|---|---|---|---|---|---|---|
| 8 GB | Apple Foundation Models. No download. Text-only local use. | Qwen3.5-2B 4-bit (1.74 GB), text and accessibility tree | 0 | 0 (Apple) or about 2 GB | about 2.5 GB | about 3 GB (inference: avoid screenshots) | 2 GB |
| 16 GB | Qwen3.5-4B 4-bit (3.03 GB) | Qwen3.5-9B 4-bit (5.95 GB) | 0 | 3.2 to 3.5 GB | 3.6 to 4.5 GB | about 5.5 GB | 4 GB |
| 24 GB | Qwen3.5-9B 4-bit (5.95 GB) | Gemma 4 12B (about 11 GB) | 0 | 6.0 to 6.5 GB | about 7 GB | about 8.5 GB | 8 GB (25% of 24 GB is 6 GB, rounded up to the 8 GB preset) |
| 32 GB | Qwen3.5-9B 4-bit | Gemma 4 26B-A4B 4-bit (15.3 GB) | 0 | 6.0 to 6.5 GB | about 7 GB | about 8.5 GB | 8 GB, or 16 GB for stretch |
| 48 GB (this Mac) | Qwen3.5-9B 4-bit warm | Qwen3.6-35B-A3B 4-bit (20.4 GB) | 0 | 6 GB, or 21 GB for stretch | 7 GB, or 23 GB | 8.5 GB, or about 25 GB | 12 GB, or 24 GB for stretch |
| 64 GB and up | Qwen3.6-35B-A3B 4-bit warm | Holo3-35B-A3B 8-bit for grounding, only if it wins Perry's benchmark | 0 | 21 GB | 23 GB | about 25 GB | 24 GB or more |

Chip notes for the 48 GB row (M4 Pro, 273 GB/s): Qwen3.5-9B 4-bit runs at about 50 tok/s and the 35B-A3B MoE near 75 to 95 tok/s on similar Pro and Max chips (see 3.3). Both are above reading speed.

The 8 GB row follows Perry's existing tone-sheet rule: say what does not work and offer what does. On 8 GB, local models answer short questions, and cloud handles actions.

### 5.1 Measuring memory from Swift

None of this was compiled in this session. The first three items were checked against the local MacOSX27.0 SDK headers.

- Total RAM: `ProcessInfo.processInfo.physicalMemory`.
- Chip: `sysctlbyname("machdep.cpu.brand_string")` and `hw.model`. Read `hw.memsize` for exact bytes.
- Free memory: `host_statistics64(mach_host_self(), HOST_VM_INFO64, …)` returns `vm_statistics64`. Free plus inactive plus purgeable plus speculative pages, times `vm_kernel_page_size` (16,384 bytes on Apple Silicon), is a usable "available" estimate. macOS has no single "available" number.
- Percent free: `sysctlbyname("kern.memorystatus_level")` returned 59 on the example Mac.
- Pressure events: `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue:)`. `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` is in `dispatch/source.h`. Unload the model on `.warning`.
- Pressure level now: `sysctl vm.memory_pressure` returned 0 on the example Mac.
- **Do not use `os_proc_available_memory()`.** The SDK header marks it `API_UNAVAILABLE(macos)`; it exists on iOS, tvOS, and watchOS only (`usr/include/os/proc.h` in MacOSX27.0.sdk).
- GPU budget: `MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize` and `currentAllocatedSize`.
- Own footprint: `task_info(…, TASK_VM_INFO, …)` field `phys_footprint`. Use this for the helper process.
- MLX: `Memory.snapshot()`, `Memory.cacheLimit`, `Memory.memoryLimit`, `Memory.clearCache()`; there is also a `WiredMemory.swift` source file in `Source/MLX` ([listing](https://api.github.com/repos/ml-explore/mlx-swift/contents/Source/MLX)).
- Foundation Models: `contextSize` and `tokenCount(for:)` ([WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/)).

---

## 6. How other apps ask about memory

| App | What the user controls | Source |
|---|---|---|
| Ollama | Keep-alive time. Default 5 min. 0 unloads now. Negative keeps forever. `OLLAMA_MAX_LOADED_MODELS`. Requests queue if memory is short. | [FAQ](https://docs.ollama.com/faq) |
| LM Studio | Idle TTL per model or request. JIT default 60 min. Auto-evict keeps one JIT model. Default load settings per model. | [TTL docs](https://lmstudio.ai/docs/developer/core/ttl-and-auto-evict), [per-model](https://www.lmstudio.ai/docs/app/advanced/per-model) |
| Jan | An "Auto-Unload Old Models" toggle in the llama.cpp engine settings. | [Jan](https://jan.ai/integrations/llamacpp) |
| Superwhisper | "Voice model active duration": a time from 10 s to 1 h with a stated trade-off between load delay and memory. | [settings](https://superwhisper.com/docs/get-started/settings-advanced), [performance tips](https://superwhisper.com/docs/common-issues/performance-tips) |
| llama.cpp server | `--sleep-idle-seconds`. | [Jan page](https://jan.ai/integrations/llamacpp) |

Not verified in this session: LM Studio's "model loading guardrails" setting (searches did not confirm it), MacWhisper, Msty, and Wispr Flow. I do not describe them here.

Pattern (inference): every app that handles this uses time, not gigabytes. None asks "how much RAM". Perry's question is new, so it must translate a time and size trade-off into plain terms.

---

## 7. Recommended onboarding screen

Place: after the first-answer beat in `OnboardingDirector`, only if the user picks "On this Mac". The first answer can use Apple Foundation Models with no question asked, which matches the current `preferOnDeviceBrain` design.

**Heading.** "How much memory can Perry keep ready?"

**Subline.** "Perry keeps a model in memory so it answers fast. When you are away, it lets go."

**Machine line.** "This Mac: M4 Pro, 48 GB." Read from `sysctl`, never typed by the user.

**Control.** One slider with snapping presets, plus a live read-out. The presets adapt to the machine's cap from section 5.

| Preset | Meaning | Shown when |
|---|---|---|
| None | Load only when you ask. Free it after the task. | always |
| 2 GB | Small model stays ready. | RAM 8 GB and up |
| 4 GB | Good everyday model stays ready. | 16 GB and up |
| 8 GB | Better model stays ready. | 24 GB and up |
| 24 GB | Best model stays ready. | 48 GB and up |

Under the slider, three lines that update as the slider moves:

- "Perry will use: Qwen3.5 9B (6 GB download)."
- "While idle: 6 GB in use. While working: about 8.5 GB."
- A bar showing current system memory in use and the band Perry would add.

**Second control.** "Let go after" with options 2 min, 10 min, 1 h, Never. Defaults: 5 min on 16 GB and below, 15 min on 24 GB and above (inference, between Ollama's 5 min and LM Studio's 60 min). Free the model at once on a memory-pressure `.warning`.

**Third control.** "When the local model cannot do a task" with "Ask me before using the cloud" (default) and "Never use the cloud".

**What happens on an 8 GB Mac.** The slider tops out at 2 GB. The default is None. The brain is Apple's built-in model. The screen says, in the tone-sheet style: "8 GB is under what a screen-reading model needs. Perry can still answer questions here. For tasks that click through apps, it will ask to use the cloud." Do not offer a screenshot-reading model on this tier.

**Load on demand versus keep warm.** Warm on wake: start loading when the hotkey goes down or the notch opens, not at launch (Apple provides `prewarm()` for this; for MLX the executor interface also has `prewarm`, per [WWDC26 339](https://developer.apple.com/videos/play/wwdc2026/339/)). Unload after the idle timer. Keep warm only when the user's budget covers the model. Never keep two large models warm.

**Download consent.** Show the size ("6 GB"), the source (Hugging Face `mlx-community`), and that it resumes. Pin the repo to a commit hash. (inference) Check disk space first.

**Copy rules.** Use the tone sheet: no em dashes, no hedging, no "AI". Say the number.

---

## 8. The honest quality gap

Evidence:

- On OSWorld-Verified, the small Qwen3.5 models score 35.6 (4B) and 41.8 (9B) (vendor, cards above). Holo3-35B-A3B reports 77.8, and it needs about 20 GB or more of weights ([card](https://huggingface.co/Hcompany/Holo3-35B-A3B)). Holo4-27B reports 85.2 on H's own harness and 61.7 on OSWorld 2.0. The harnesses differ. OSWorld 2.0 is harder.
- A web-only specialist shows the same size curve: Fara1.5-4B scores 80.8 on WebVoyager, and the 27B scores 88.6 ([HF](https://huggingface.co/microsoft/Fara1.5-4B), [Decrypt](https://decrypt.co/368807/microsoft-fara15-open-source-ai-beats-openai-gemini)). On harder Online-Mind2Web the 4B scores 57.3 and the 27B about 72.
- One aggregator lists frontier cloud models above 90% on ScreenSpot-Pro ([benchlm.ai](https://benchlm.ai/benchmarks/screenspot-pro), unverified), versus 60 to 68 for 4B to 8B open models.
- Apple's model has an 8,192-token window ([WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/)). Perry's accessibility trees and multi-turn plans can exceed that (inference).
- CUA-S1 measured success only on single-widget tasks with a step cap, and 29.3% on held-out forms.
- Vendor scores come from the vendor's harness. Perry's own cases may score lower.

Where local models will disappoint (inference): planning across several apps, long tasks that need recovery, unfamiliar or custom-drawn apps, long documents, and any task where an error is costly. They do well on questions about what is on screen, short guided steps, rewriting or summarizing short text, and form filling with an accessibility tree.

Messaging (tone-sheet style):

- Onboarding card: "On this Mac: private, free, works offline. Good for questions about your screen and short steps. Slower and less sure on long tasks across apps."
- At the moment of use, when a plan has more than N steps or the model reports low confidence: "This is a long one. The model on this Mac may miss a step. Use the cloud for this task? Use cloud / Try here."
- After a failure: "That didn't work here. Nothing changed. Want the cloud to try?"
- Keep Perry's existing confirmation tiers. A local model must not widen what it may do without approval.

---

## 9. What I could not settle, and the experiments to run

Not measured by anyone I could cite:

- Cold-load time for each model on each chip.
- Time per full GUI step (capture, prefill, decode) on M1 to M5.
- Peak RSS with a 1440×900 screenshot at 4-bit.
- Whether the CUA-S1-4B adapters load on a 4-bit MLX base.
- AFM 3 Core Advanced hardware floor. Apple does not name it.

Proposed experiment, using the Phase 9 gate already in the plan ([megaplan-iii](../../plans/megaplan-iii-painkiller.md), line 365: 200 recorded grounding cases, enable only if within 3 points of the frontier model):

1. Replay the recorded cases against Qwen3.5-4B and 9B, UI-Venus-1.5-2B and 8B, and UI-TARS-1.5-7B through `mlx-vlm` or `mlx-swift-lm`.
2. Log time to first token, total step time, and helper-process `phys_footprint` at idle, active, and peak.
3. Run the same cases with the accessibility tree only and no screenshot, to find which chips can skip vision.
4. Run on an 8 GB machine, a 16 GB machine, and this 48 GB machine. Per the memory file in this project, test on the secondary Mac, not the user's MacBook, while it is in use.
5. Compare Apple's model on the same text-only cases, with `tokenCount` logged to see how often 8K overflows.

---

## 10. Source list

Primary pages read:

- Cua: [repo](https://github.com/trycua/cua), [CUA-S1 model card](https://github.com/trycua/cua/blob/main/libs/cua-s1/MODEL_CARD.md), [perception notices](https://github.com/trycua/cua/blob/main/libs/cua-driver/docs/perception-third-party-notices.md), [cua-ai HF org API](https://huggingface.co/api/models?author=cua-ai&limit=30), [FluidUse](https://github.com/FluidInference/FluidUse).
- Model cards: [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), [Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B), [Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B), [Qwen3.6-27B](https://huggingface.co/Qwen/Qwen3.6-27B), [UI-Venus-1.5-8B](https://huggingface.co/inclusionAI/UI-Venus-1.5-8B), [Holo2-8B](https://huggingface.co/Hcompany/Holo2-8B), [Holo3-35B-A3B](https://huggingface.co/Hcompany/Holo3-35B-A3B), [Holo4-35B-A3B](https://huggingface.co/Hcompany/Holo4-35B-A3B), [UI-TARS-1.5-7B](https://huggingface.co/ByteDance-Seed/UI-TARS-1.5-7B), [Fara-7B](https://huggingface.co/microsoft/Fara-7B), [Fara1.5-4B](https://huggingface.co/microsoft/Fara1.5-4B), [Gemma 4 card](https://ai.google.dev/gemma/docs/core/model_card_4), [UI-Venus MLX 4-bit](https://huggingface.co/mlx-community/UI-Venus-1.5-8B-4bit).
- MLX listings: `mlx-community` search APIs for [UI-TARS](https://huggingface.co/api/models?author=mlx-community&search=UI-TARS&limit=20), [Holo](https://huggingface.co/api/models?author=mlx-community&search=Holo&limit=20), [UI-Venus](https://huggingface.co/api/models?author=mlx-community&search=UI-Venus&limit=20), [Qwen3.5](https://huggingface.co/api/models?author=mlx-community&search=Qwen3.5&sort=downloads&limit=40), [Qwen3.6](https://huggingface.co/api/models?author=mlx-community&search=Qwen3.6&sort=downloads&limit=30), [gemma-4](https://huggingface.co/api/models?author=mlx-community&search=gemma-4&sort=downloads&limit=30), [Fara](https://huggingface.co/api/models?author=mlx-community&search=Fara&limit=20).
- Apple: [WWDC26 241](https://developer.apple.com/videos/play/wwdc2026/241/), [WWDC26 339](https://developer.apple.com/videos/play/wwdc2026/339/), [WWDC26 macOS guide](https://developer.apple.com/wwdc26/guides/macos/), [AFM 3 announcement](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models), [MLX on M5](https://machinelearning.apple.com/research/exploring-llms-mlx-m5), local `MacOSX27.0.sdk` headers (`os/proc.h`, `dispatch/source.h`, `FoundationModels.swiftinterface`).
- Runtimes: [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm), [mlx-swift](https://github.com/ml-explore/mlx-swift), [Memory.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift/main/Source/MLX/Memory.swift), [llama.cpp](https://github.com/ggml-org/llama.cpp), [Ollama FAQ](https://docs.ollama.com/faq), [LM Studio TTL](https://lmstudio.ai/docs/developer/core/ttl-and-auto-evict), [Jan llama.cpp](https://jan.ai/integrations/llamacpp), [Superwhisper settings](https://superwhisper.com/docs/get-started/settings-advanced).

Secondary sources (lower trust): [perea.ai GUI grounding table](https://www.perea.ai/research/gui-grounding-models-2026), [InsiderLLM Mac guide](https://insiderllm.com/guides/best-local-llms-mac-2026/), [llmcheck benchmarks](https://llmcheck.net/benchmarks), [community fm CLI guide](https://github.com/emiluzelac/on-device-apple-foundation-model), [Michael Tsai](https://mjtsai.com/blog/2026/06/16/apple-foundation-models-in-appleos-27/), [aiweekly on Holo4](https://aiweekly.co/alerts/h-company-ships-holo4-agents-27b-hits-617-on-osworld-20), [Decrypt on Fara1.5](https://decrypt.co/368807/microsoft-fara15-open-source-ai-beats-openai-gemini), [Rapid-MLX](https://github.com/raullenchai/Rapid-MLX), [benchlm ScreenSpot-Pro](https://benchlm.ai/benchmarks/screenspot-pro).
