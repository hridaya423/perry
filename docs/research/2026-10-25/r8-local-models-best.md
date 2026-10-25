# R8: Best local models and inference engine for Perry on Apple Silicon

Date: 2026-10-25. Author: research sub-agent R8. Status: final report. Every number has a label and a source tag.

I read this example machine with `sysctl` and a Metal query on 2026-10-25. It is a Mac16,7 with an Apple M4 Pro, 14 CPU cores (10 performance, 4 efficiency), 48 GB memory (51,539,607,552 bytes), and macOS 27.0.1. Metal reports `recommendedMaxWorkingSetSize` of 40,200,896,512 bytes (37.44 GiB, 78% of RAM) and `maxBufferLength` of 30,150,672,384 bytes. `iogpu.wired_limit_mb` is 0, the default.

## Labels and tags

- VERIFIED: I read the number at the source named by the tag.
- VENDOR: the author of the model or engine published the number. No independent party checked it.
- UNVERIFIED: the number is second hand, or I calculated it. Calculations name their formula.
- Independent: a party other than the model author or engine author measured the number.
- tok/s means tokens per second.
- A tag such as [STARED] points to the source list in Appendix F. Each tag maps to one URL.
- I did not download weights, launch apps, or run builds. Speeds in this report come from sources or from calculation, never from my own run.

---

## 0. Answer

### 0.1 Default picks by memory tier

Sizes are Hugging Face file sizes (VERIFIED, [HF-API]). Planning speeds and RAM figures are in section 6.1. The interactive model is the model Perry loads on demand for normal turns. The deep model loads only when the user asks for harder work.

| Memory | Interactive model | Deep model (on request) | Helper under 2 GB |
|---|---|---|---|
| 8 GB | Qwen3.5-2B UD-Q4_K_XL, 1.34 GB, plus 0.67 GB vision file. Qwen3.5-4B UD-Q4_K_XL, 2.91 GB plus 0.67 GB, only if the fit rule in section 6.1 passes. | None. Use the cloud path for planning. | Apple Foundation Models Core; open fallback Qwen3.5-0.8B Q4_K_M, 0.53 GB |
| 16 GB | Qwen3.5-9B UD-Q4_K_XL, 5.97 GB, plus 0.92 GB vision file (M3 and newer); Qwen3.5-4B on M1 and M2 | Ternary-Bonsai-2-27B PQ2_0, 7.21 GB, M5 only, needs the Prism fork | Same as 8 GB |
| 24 GB | Qwen3.5-9B UD-Q6_K_XL, 8.76 GB, plus 0.92 GB | Ternary-Bonsai-2-27B PQ2_0 | Same |
| 32 GB | Qwen3.6-35B-A3B UD-IQ4_XS, 17.73 GB, plus 0.90 GB | Qwen3.8-27B UD-IQ4_XS, 14.25 GB, plus 0.93 GB and 1.37 GB MTP file | Same |
| 48 GB | Qwen3.6-35B-A3B UD-Q4_K_XL, 22.36 GB, plus 0.90 GB | Qwen3.8-27B UD-Q5_K_XL, 20.88 GB, plus 0.93 GB and 1.37 GB MTP file | Same |
| 64 GB | Qwen3.6-35B-A3B UD-Q6_K, 29.31 GB, plus 0.90 GB | Qwen3.8-27B UD-Q6_K, 21.98 GB, plus 0.93 GB and MTP file | Same |
| 96 to 128 GB | Qwen3.6-35B-A3B Q8_0, 36.90 GB, plus 0.90 GB | Qwen3.8-27B Q8_0, 29.05 GB, plus MTP file; both stay resident | Same |

Engine for every row: a bundled `llama-server` process from llama.cpp. Section 4 gives the reasons and the exceptions.

### 0.2 Findings

1. **One model family covers every role.** Qwen3.5, Qwen3.6, Qwen3.8, Holo-3.1, Holo4, UI-Venus-2, UI-Mate, and Ornith-1.5 all use the Qwen3.5 architecture (VERIFIED from the `config.json` files, tags [Q38], [Q36], [HOLO4-35], [ORNITH]). Perry swaps models by swapping a file. The engine needs no per-model work.
2. **Qwen3.8-27B is the best brain that fits a consumer Mac, by independent score.** Artificial Analysis gives it an Intelligence Index of 33.7 at xhigh effort, 27.6 at medium, 26.2 at low, and 20.2 with thinking off (VERIFIED, [AA]). It is dense. On this Mac its prefill is about 110 tok/s (UNVERIFIED, section 2.3), so a normal turn takes 15 seconds or more.
3. **Qwen3.6-35B-A3B is the best brain for latency.** It has 3B active parameters. Its index is 18.2 with thinking and 15.2 (estimated) without (VERIFIED, [AA]). It scores 95.3 on tau2 but only 9.3 on the harder tauBanking test, against 48.0 for Qwen3.8-27B at xhigh. Therefore use the MoE model for fast turns and escalate hard plans to the 27B.
4. **No current GUI model has an independent score.** The vendors claim OSWorld-Verified 84.3 for Qwen3.8-27B, 85.2 for Holo4-27B (non-commercial licence), and 80.8 for Holo4-35B-A3B (Apache-2.0) ([Q38], [HOLO4]). The official OSWorld sheet has older H Company rows only: Holo3-35B-A3B at 82.56 and 78.15 (VERIFIED, [OSWORLD]). It has no Qwen3.8, Holo3.1, Holo4, UI-Venus-2, or UI-Mate row. Perry has the accessibility tree, so a separate grounding model is optional. Perry-bench must decide whether Holo4-35B-A3B replaces the brain for actions.
5. **Ornith-1.5 is unproven, not disproven.** Its scores are VENDOR only and no board lists it ([ORNITH], [AA]). It uses the same architecture, so any engine runs it. Put it in Perry-bench as a challenger. Do not make it the default.
6. **The helper role belongs to Apple Foundation Models where available.** It costs no download and the system manages its memory ([AFM3], [WWDC241]). The open fallback is Qwen3.5-0.8B, or MiniCPM5-2B for text-only helper work ([MINICPM5]).
7. **llama.cpp is faster in some cases only, so Perry ships `llama-server` and tests MLX on each Mac.** On an M5 Max (run of 2026-06-14, build 9430), llama.cpp decodes 4% to 10% faster and answers short prompts 2.2 times sooner ([STARED]). MLX prefills 3% to 22% faster on the same Mac. On M2 to M4 chips the measured rows favour MLX for Qwen MoE decode by 3% to 63% ([HIESCH], [BASERT], [RAYNAR]). On hybrid models llama.cpp reuses the cached prefix, but mlx-swift-lm re-reads the whole prompt each turn (issue 660). Section 4.3 gives the full answer.
8. **Splash is the one engine that could beat both, and only its authors have measured it.** It reads the same GGUF files as llama.cpp. The authors report 2.5 to 3.2 times the llama.cpp decode speed on the 35B-A3B model and 4.5 to 5.3 times on the 27B ([SPLASH]). It runs four model families, needs an M3 or newer chip with macOS 26.4, and is five weeks old (version 1.4.0, 2026-10-20). Test it first on the 48 GB tier.
9. **Apply the win-pc settings selectively.** MTP gives a dense 27B model 1.8 times the decode speed on an M5 Max and lowers prefill by 8% to 30% ([STARED]). It adds 4% to 13% for the MoE model, and it cost 25% on an M2 Max through Ollama ([RAYNAR]). KV quantisation saves almost nothing on these hybrid models. A 16K-token thinking budget costs 15 to 25 minutes at Mac decode speeds. Section 5 maps every setting.
10. **Prefill, not decode, limits Perry.** A screenshot plus accessibility text is 1,600 to 3,000 tokens per turn. On this Mac that takes about 4 seconds with the MoE model and 15 seconds or more with the 27B (UNVERIFIED, section 6.1). Perry must cap image tokens, keep a cached prefix, and send small state diffs.
11. **The honest gap to the cloud is large.** The best local model scores 33.7 on the Artificial Analysis index at xhigh effort. Claude Opus 5.5 at max effort scores 57.6 ([AA]). Section 6.5 gives the details.
12. **SSD expert streaming could give a 16 or 24 GB Mac a 35B-A3B brain, but only its authors have measured it.** Edge0 streams the expert weights of a Qwen3.6-35B-A3B derivative from the SSD. On a 24 GB Mac mini M4 Pro, its authors report 14.9 to 17.7 tok/s decode and 113 to 140 tok/s prefill (VENDOR, [EDGE0]). They also report a 3.9-point loss on their five-benchmark average, and a 2.9 GiB peak of MLX allocator memory, which is not process memory. At that prefill rate the 1,640-token reference turn of section 2.7 takes 12 to 15 seconds (my arithmetic). Perry-bench test P8 compares it with the similar Splash `--expert-memory` option, which has no measured result.

---

## 1. Scope, method, and limits

This report answers four questions: which models fit each tier, which engine is fastest, which win-pc settings carry over, and what Perry should ship. Four sub-agents covered engine benchmarks, quantisation and KV cache, tool-call behaviour, and GUI models. I verified their highest-impact claims at the source.

Limits that affect decisions:

- No independent benchmark exists for any GUI model, for Ornith-1.5, or for the specialist engines (Splash, MTPLX, uzu, BaseRT, rec). Their numbers are VENDOR.
- I found only one independent llama.cpp versus MLX run from 2026. It used one M5 Max with 128 GB, one author, and llama.cpp build 9430 on 2026-06-14 ([STARED]). Both engines have changed since. An older run flipped the ranking within two months ([JROCKY]).
- No llama.cpp measurement exists for Qwen3.6-35B-A3B on an M4 Pro. The M4 Pro rows for MLX come from anonymous community submissions ([OMLX-BOARD]). Engine speed on M1 to M4 chips needs a fresh measurement.
- Speeds for tiers other than the M5 Max are my calculations. Section 2 shows the formulas and the anchors. The onboarding benchmark in section 6.3 replaces them with measured values on each user machine.
- Models and engines move weekly. Every version in this report is the version on 2026-10-25.

---

## 2. Hardware model for planning

### 2.1 Memory bandwidth by chip

Decode speed follows memory bandwidth. Prefill speed follows GPU compute. Apple lists bandwidth for most chips.

| Chip | Bandwidth, GB/s | Label and source |
|---|---|---|
| M1 / M2 / M3 (base) | about 68 / 100 / 100 | UNVERIFIED. Implied by Apple comparison text; M3 not read. |
| M1 Pro / M1 Max | 200 / 400 | VERIFIED [APPLE-M1PM] |
| M2 Pro / M2 Max | 200 / 400 | VERIFIED [APPLE-M2PM] |
| M3 Pro / M3 Max | 150 / 300 (30-core GPU) or 400 (40-core GPU) | VERIFIED [APPLE-SPEC] |
| M3 Ultra | over 800 | VERIFIED [APPLE-M3U] |
| M4 | 120 | VERIFIED [WIKI-M4] |
| M4 Pro | 273 | VERIFIED [WIKI-M4], [APPLE-M4PM] |
| M4 Max | 410 (binned) or 546 | VERIFIED [WIKI-M4] |
| M5 | 153 | VERIFIED [APPLE-M5] |
| M5 Pro | up to 307 | VERIFIED [APPLE-M5PM] |
| M5 Max | 460 (32-core GPU) or 614 (40-core GPU) | VERIFIED [APPLE-M5PM], [WIKI-M5] |
| M5 Ultra | About 1,200 (1.2 TB/s); Wikipedia lists 1,228.8; 80-core GPU; up to 512 GB; Mac Studio | VERIFIED [APPLE-M6], [WIKI-M5] |
| M6 | 153.6 (16 GB) or 170 (24 or 32 GB); 12 GPU cores; Mac mini only, released 2026-09-22 | VERIFIED [APPLE-M6], [WIKI-M6] |

M5-family and M6 GPUs add a Neural Accelerator to each GPU core. Software reaches it through the Metal 4 tensor API. MLX needs macOS 26.2 or newer. llama.cpp needs release b9592 or newer and a build made with a recent SDK ([MODELFIT-M5], [LMS-2040]). Apple reports that the M5 reaches first token 3.3 to 4.1 times faster than the M4 and decodes 1.19 to 1.27 times faster ([APPLE-MLX-M5]). Apple rates the M6 GPU 30% above the M5 (VENDOR, [WIKI-M6]).

### 2.2 Decode speed

Decode speed in tok/s ≈ η × bandwidth ÷ bytes read per token. For a dense model the bytes read per token equal the weight file size. The factor η is the fraction of bandwidth the engine uses.

| Anchor | Measured speed | Implied η | Label and source |
|---|---|---|---|
| M5 Max, 27B Q8_0 (29.05 GB), llama.cpp | 18.4 tok/s | 0.87 | VERIFIED, independent [STARED] |
| M5 Max, 27B 8-bit, MLX | 17.3 tok/s | 0.81 | VERIFIED, independent [STARED] |
| M5 Pro, 27B UD-Q4_K_M (16.46 GB), llama.cpp | 16 tok/s | 0.86 | VENDOR [SPLASH] |
| M3 Max 40-core, same model, llama.cpp | 17 tok/s | 0.70 | VENDOR [SPLASH] |
| M5 Pro, Bonsai-2-27B PQ2_0 (7.21 GB), Prism fork | 28.1 tok/s | 0.66 | VENDOR [BONSAI-GGUF] |
| M4 Pro, Bonsai-2-27B PQ2_0, earlier build | 18.0 tok/s | 0.48 | VENDOR [BONSAI-GGUF] |
| M4 Pro 20-core, Llama-2 7B F16 (13.48 GB), llama.cpp | 17.18 tok/s | 0.85 | VERIFIED, independent [LCPP-4167] |
| Same chip, same model, Q8_0 (7.16 GB) | 30.69 tok/s | 0.80 | VERIFIED, independent [LCPP-4167] |
| Same chip, same model, Q4_0 (3.82 GB) | 50.74 tok/s | 0.71 | VERIFIED, independent [LCPP-4167] |
| M5 Pro 20-core, same model, Q8_0 / Q4_0 | 38.92 / 66.33 tok/s | 0.91 / 0.83 | VERIFIED, independent [LCPP-4167] |

The llama-bench rows measure a 7B model with a 512-token prompt. The measured range for llama.cpp is 0.63 (M2 Max and M3 Max, Q4_0) to 0.91 (M5 Pro, Q8_0). Larger quant types waste less bandwidth on unpacking. My planning values for llama.cpp on M1 to M4 chips are 0.72 (4-bit files), 0.78 (5-bit and 6-bit files), and 0.82 (8-bit files). For M5 chips they are 0.82, 0.86, and 0.88. These are UNVERIFIED choices inside the measured range.

A mixture-of-experts model reads only its active experts. Qwen3.6-35B-A3B at 5.1 bits per weight reads about 1.9 GB per token, against 16 to 29 GB for the 27B. Measured MoE decode does not scale with bandwidth the way dense decode does. I therefore anchor MoE decode on measurements.

| MoE anchor | Measured decode | Label and source |
|---|---|---|
| M5 Max, 35B-A3B Q8_0, llama.cpp | 92.9 tok/s (89.2 at 4K context) | VERIFIED, independent [STARED] |
| M5 Max, 35B-A3B 8-bit, MLX | 84.5 tok/s (81.2 at 4K context) | VERIFIED, independent [STARED] |
| M5 Pro 20-core, 35B-A3B UD-Q4_K_M, llama.cpp | 69 tok/s | VENDOR [SPLASH] |
| M3 Max 40-core, same model, llama.cpp | 66 tok/s | VENDOR [SPLASH] |
| M4 Max, 35B-A3B OptiQ 4-bit, MLX Swift, compiled decode | 93.1 tok/s (85.6 before) | VENDOR [MLXSWLM-662] |
| M2 Max 32 GB, 35B-A3B Q4_K_M (21.7 GB), llama.cpp | 58.6 tok/s (57.3 with q8_0 KV) | VERIFIED, one author [RAYNAR] |
| M4 Pro 20-core, 35B-A3B 4-bit, MLX (oMLX) | 86.6 to 94.0 tok/s | VERIFIED as board rows, community [OMLX-BOARD] |

For this Mac (273 GB/s) I plan on 60 tok/s for the MoE model at Q4_K_XL with llama.cpp. That value sits between the M2 Max row (58.6) and the M5 Pro row (69) (UNVERIFIED, interpolated). MLX rows for the same Mac report 87 to 94 tok/s (section 4.4).

### 2.3 Prefill speed

Prefill is compute bound: tok/s ≈ T ÷ (2 × active parameters). T is the effective GPU throughput. A MoE model reaches 0.38 to about 1.0 of that rate, because routing and small matrices reduce efficiency. On the M5 Max, the MoE model prefills 4.2 times faster than the 27B model with llama.cpp and 4.9 times faster with MLX ([STARED]). It has 9 times fewer active parameters.

| Anchor | Result | Implied T | Label and source |
|---|---|---|---|
| M4 Pro 24 GB, Qwen3-14B 4-bit, 4K-token turn over 8K history | 21.8 s, so 188 tok/s | 5.3 TFLOPS | VERIFIED [MLXSWLM-717] |
| M4 Pro, Bonsai-2-27B, 512-token prompt | 125 tok/s | 6.8 TFLOPS | VENDOR [BONSAI-GGUF] |
| M5 Pro, Bonsai-2-27B, 512-token prompt | 387 to 393 tok/s | about 21 TFLOPS | VENDOR [BONSAI-GGUF] |
| M5 Max, 27B Q8_0, 4K prompt, llama.cpp | 647.7 tok/s | 35 TFLOPS | VERIFIED, independent [STARED] |
| M5 Max, Bonsai-2-27B, 512-token prompt | 765 tok/s | 41 TFLOPS | VENDOR [BONSAI-GGUF] |
| M3 Max 40-core, 27B UD-Q4_K_M, 2,048-token chunk, llama.cpp | 193 tok/s | 10.4 TFLOPS | VENDOR [SPLASH-PERF] |
| M5 Pro 20-core, same model and chunk | 374 tok/s | 20.2 TFLOPS | VENDOR [SPLASH-PERF] |
| M3 Max 40-core, 35B-A3B UD-Q4_K_M, 2,048-token chunk | 1,575 tok/s | 9.5 TFLOPS (3.0B active) | VENDOR [SPLASH-PERF] |
| M5 Pro 20-core, same model and chunk | 1,968 tok/s | 11.8 TFLOPS (3.0B active) | VENDOR [SPLASH-PERF] |
| M2 Max 32 GB, 35B-A3B Q4_K_M, 4,096-token prompt | 671 tok/s | 4.0 TFLOPS (3.0B active) | VERIFIED, one author [RAYNAR] |
| M4 Pro 20-core, 35B-A3B 4-bit, 4,096-token prompt, MLX (oMLX) | 1,050 to 1,125 tok/s | 6.3 to 6.8 TFLOPS (3.0B active) | VERIFIED as board rows [OMLX-BOARD] |

The MoE rows reach 0.38 to about 1.0 of the dense rate, so no single factor fits all chips. The llama-bench project publishes one prompt speed per chip: F16 prefill of a 7B model with a 512-token prompt. Multiplying that speed by 13.48 GFLOP per token (2 × 6.74 billion parameters) gives T (arithmetic on VERIFIED data, [LCPP-4167]).

| Chip (GPU cores) | T, TFLOPS | Chip (GPU cores) | T, TFLOPS |
|---|---|---|---|
| M1 (8) | 1.6 (Q8_0 row) | M4 Pro (16 / 20) | 5.1 / 6.3 |
| M2 (10) | 2.7 | M4 Max (40) | 12.4 |
| M2 Max (30 / 38) | 8.1 / 10.2 | M5 (10) | 9.6 (Q8_0 row) |
| M3 Max (40) | 10.5 | M5 Pro (16 / 20) | 17.7 / 21.4 |
| M4 (10) | 3.1 | M5 Max (40) | 42.6 |
| M6 (as listed) | 12.8 | M5 Ultra (80) | 70.2 |

M5 chips gain most because the Neural Accelerators serve matrix multiplication. For a chip that the table omits, scale by GPU core count within one generation. The onboarding benchmark replaces every planning value with a measured one.

### 2.4 Memory limits and the working set

Metal limits how much memory the GPU may wire. On this Mac the limit is 78% of RAM (VERIFIED, local query). Other Macs differ, so Perry must read `MTLDevice.recommendedMaxWorkingSetSize` at run time. Perry must not change `iogpu.wired_limit_mb`, because that needs administrator rights. The `llama-server` option `--fit` (default on) shrinks context or offload to fit device memory. Its margin option `--fit-target` defaults to 1024 MiB (VERIFIED, [LCPP-SRV]).

### 2.5 KV cache and recurrent state

These models are hybrids. Only about one layer in four uses full attention. The other layers keep a small fixed recurrent state. I computed the KV bytes per token below from each `config.json` (VERIFIED) at 16-bit precision.

| Model | Attention layers | KV heads × head size | KV per token | At 8K tokens | At 32K tokens | At 128K tokens |
|---|---|---|---|---|---|---|
| Qwen3.8-27B | 16 of 64 | 4 × 256 | 64 KiB | 0.5 GiB | 2.0 GiB | 8.0 GiB |
| Qwen3.6-35B-A3B | 10 of 40 | 2 × 256 | 20 KiB | 0.16 GiB | 0.63 GiB | 2.5 GiB |
| Qwen3.5-9B, Holo-3.1-9B, Ornith-1.5-9B | 8 of 32 | 4 × 256 | 32 KiB | 0.25 GiB | 1.0 GiB | 4.0 GiB |
| Qwen3.5-4B, Holo-3.1-4B | 8 of 32 | 4 × 256 | 32 KiB | 0.25 GiB | 1.0 GiB | 4.0 GiB |

Quantising the KV cache to 8 bits saves at most 1 GiB at 32K tokens for the 27B model. That does not justify the quality risk on a 24 GB or larger Mac. Appendix B gives the measured KV quality data.

### 2.6 Screenshot tokens and encoder cost

Qwen-family vision uses 16-pixel patches merged 2 by 2. One token covers 32 by 32 pixels. The default maximum is 16,384 tokens, so Perry's captures never clip.

| Capture size | Image tokens |
|---|---|
| 1440 × 900 | 1,260 |
| 1920 × 1200 | 2,280 |
| 2560 × 1600 | 4,000 |
| 3024 × 1964 | 5,734 |

The vision encoder runs before the language model and costs more than linear time. On an M2 MacBook Pro with 16 GB, llama.cpp encoded a 640 × 488 image in 1,189 ms. It encoded a 4,015-token image in 40,129 ms (VERIFIED, [LCPP-21443]). That is 34 times the time for 13 times the tokens.

For a 1,260-token capture, the same curve gives about 8 s on an M2 base chip. On this Mac it gives about 3.5 s (UNVERIFIED, scaled by T). A 640-token capture takes about 1.4 s on this Mac. The `llama-server` option `--image-max-tokens` caps the cost.

### 2.7 Reference turn

All latency figures in this report use one reference turn. It has 1,000 tokens of accessibility text and 640 image tokens, with the system prompt and tool schema already cached. The estimates cover the encoder plus the language-model prefill. They exclude the generated answer.

---

## 3. Models by role

### 3.1 What the evidence is worth

One independent source covers many models: the Artificial Analysis (AA) Intelligence Index [AA]. AA ran its own evaluations. I parsed the page data on 2026-10-25. AA marks an index with "e" when it estimated it. Model cards report numbers from the author's own harness and settings. Aggregator sites such as BenchLM copy those numbers, so I treat them as VENDOR.

| Model (AA row) | Index | tau2 | tauBanking | Terminal-Bench 2.1 | IFBench | MMMU-Pro | GPQA |
|---|---|---|---|---|---|---|---|
| Claude Opus 5.5 (Max), reference | 57.6 | - | - | - | - | 87.7 | - |
| Qwen3.8-Flash-Next (125B-A6B) | 39.8 | - | 45.4 | 86.1 | - | 79.8 | 92.3 |
| Qwen3.8-27B, xhigh effort | 33.7 | - | 48.0 | 79.8 | - | 76.3 | 90.5 |
| Qwen3.8-27B, medium | 27.6 | - | 47.4 | 65.2 | - | 74.2 | 84.5 |
| Qwen3.8-27B, low | 26.2 | - | 32.2 | 67.4 | - | 73.8 | 84.5 |
| K2 Horizon MoVA 36B-A4B | 25.3 | - | 32.0 | 56.6 | - | - | 82.2 |
| K2 Horizon 7B | 20.6 | - | 27.6 | 44.2 | - | - | 75.3 |
| Qwen3.8-27B, thinking off | 20.2 | - | 20.0 | 49.1 | - | 69.9 | 81.8 |
| Qwen3.6-35B-A3B, thinking | 18.2 | 95.3 | 9.3 | 44.9 | 64.4 | 75.0 | 84.1 |
| Muse Glimmer 30B (High) | 17.5 | - | 23.5 | 51.7 | - | 74.3 | 83.5 |
| Gemma 4 26B-A4B, thinking | 16.7e | 43.6 | 12.0 | 39.0 | 72.4 | 69.2 | 79.2 |
| Qwen3.6-35B-A3B, thinking off | 15.2e | 85.1 | 5.4 | 41.6 | 36.2 | 71.0 | 81.7 |
| Gemma 4 31B, thinking | 14.7 | 59.9 | 14.8 | 43.4 | 75.6 | 73.4 | 85.7 |
| Qwen3.5-9B, thinking off | 13.3e | 85.1 | - | 21.3 | 37.8 | 66.8 | 78.6 |
| Qwen3.5-4B, thinking | 13.1e | 92.1 | 6.8 | 25.8 | 52.0 | 65.4 | 77.1 |
| MiniCPM5-2B | 12.5 | - | 20.8 | 8.6 | - | - | 70.2 |
| Qwen3.5-9B, thinking | 11.2 | 86.8 | 7.0 | 29.2 | 66.7 | 69.2 | 80.6 |
| Qwen3.5-2B, thinking | 6.9e | 69.0 | - | 3.0 | 31.5 | 43.0 | 45.6 |
| Qwen3.5-0.8B, thinking | 6.1e | 47.7 | - | 0.0 | 21.5 | 25.8 | 11.1 |

All rows: VERIFIED, independent, [AA], parsed 2026-10-25. Scores are percent. A dash means AA shows no value.

What the table says:

- The tau2 telecom test saturates. Models from 4B to 35B score 85 to 95, so it does not separate them.
- The tauBanking and Terminal-Bench 2.1 tests do separate models. Qwen3.8-27B at xhigh scores 48.0 on tauBanking. Qwen3.6-35B-A3B scores 9.3. Qwen3.5-9B scores 7.0.
- Thinking adds 3 to 6 index points on the Qwen models. Qwen3.8-27B goes from 20.2 (off) to 26.2 (low), 27.6 (medium), and 33.7 (xhigh). Qwen3.6-35B-A3B goes from 15.2e to 18.2.
- Google reports 68.2 on tau2 for Gemma 4 26B-A4B. AA measured 43.6. I trust AA's number because AA ran the test. I found no explanation for the gap.
- MiniCPM5-2B scores 12.5, above Qwen3.5-9B with thinking (11.2), at about a quarter of the size. It has no vision input ([MINICPM5]).

### 3.2 Brain

Perry needs a model that holds a conversation, plans steps, and emits valid tool calls. These rules follow from sections 2 and 3.1.

1. The interactive lane runs with thinking off. Thinking costs tens of seconds even on provider hardware. AA records a median reasoning time of 41 s for Qwen3.6-35B-A3B and 45 s for Qwen3.8-27B at xhigh. It records 33 s for Qwen3.5-9B and 104 s for Qwen3.5-4B. The field name is `medianReasoningTimeSeconds` in the page data, and I did not verify its meaning (UNVERIFIED). A Mac decodes several times slower than a provider, so the same reasoning takes several times longer.
2. The fast lane uses the MoE model (Qwen3.6-35B-A3B). It prefills about 5 times faster than the 27B and decodes 5 times faster (section 2). Its weakness is hard multi-step work: tauBanking 9.3 against 48.0.
3. The deep lane uses Qwen3.8-27B with `reasoning_effort` set to low or medium and a hard reasoning budget. Perry escalates when a plan has more than a few steps, when an action fails twice, or when the user asks to think harder.
4. The owner's win-pc notes show why the budget matters. Stock Qwen3.8-27B can loop for 20K to 55K tokens and 45 to 80 minutes on one server. I read this in the owner's handoff, which cites Qwen discussions #76 and #178. Setting `reasoning_effort` to medium was "the loop-breaker". At 10 to 30 tok/s on a Mac, one such loop costs hours.
5. Swift-1.5-Qwen3.8-27B is a thinking-efficient derivative. The author reports 24.8% to 41.9% fewer thinking tokens at the three effort levels, with accuracy within 2 points of the base model (VENDOR, [SWIFT15]). Its licence allows free use up to US$1,000,000 of yearly revenue. Above that, Perry needs a separate licence. Test it in Perry-bench for the deep lane.

Tier logic:

- **32 GB and above:** MoE for the fast lane, 27B for the deep lane. They share one architecture. The 27B loads when needed and replaces the MoE model on 32 GB. On 64 GB and above both can stay resident.
- **16 to 24 GB:** Qwen3.5-9B is the only 9B-class brain with vision and a reasonable AA record (11.2 to 13.3e). The deep lane uses Ternary-Bonsai-2-27B (7.21 GB). The vendor reports 98.2% of FP16 quality, within 0.4 points of UD-Q4_K_XL (VENDOR, [BONSAI-GGUF]). Prefill on a 27B dense model needs an M5-class chip. Vendor prefill is 125 tok/s on an M4 Pro and 393 tok/s on an M5 Pro.
- **8 GB:** Qwen3.5-2B is the default, because the 4B model leaves too little memory for macOS (fit rule, section 6.1). It is a weak brain (index 6.9e), so Perry sends planning to the cloud. Qwen3.5-4B (tau2 92.1, index 13.1e) runs when the fit rule passes. The text-only MiniCPM5-2B is the challenger to test. It scores 12.5 and weighs 1.56 GB.

### 3.3 Operator (GUI control)

Perry gets the accessibility tree from cua-driver and a screenshot. A pure grounding model, which maps text to pixel coordinates, is a fallback for apps with poor accessibility data. A full agent model plans and acts. All GUI numbers below are VENDOR. The official boards list none of these models (Appendix D).

| Model | Base | Licence | OSWorld | OSWorld 2.0 | AndroidWorld | Source |
|---|---|---|---|---|---|---|
| Qwen3.8-27B | dense 27B | Apache-2.0 | 84.3 | 48.0 | 81.9 | [HOLO4], [Q38] |
| Holo4-27B | Qwen3.8-27B | **CC BY-NC 4.0** | 85.2 | 61.7 | 85.1 | [HOLO4], [HOLO4-27] |
| Holo4-35B-A3B | Qwen3.6-35B-A3B | Apache-2.0 | 80.8 | 30.9 | 77.6 | [HOLO4], [HOLO4-35] |
| Holo-3.1-35B-A3B | Qwen3.6-35B-A3B | Apache-2.0 | 80.0 (metric not named) | none | 79.3 | [HOLO31] |
| Holo-3.1-9B / 4B | Qwen3.5-9B / 4B | Apache-2.0 | none | none | 71 / 71 | [HOLO31] |
| UI-Venus-2-9B | Qwen3.5-9B | **pending** | 70.8 | none | none | [UIVENUS2] |
| UI-Mate-9B | Qwen3.5-9B | Apache-2.0 | 66.2 | none | none | [UIMATE] |
| Qwen3.5-9B (base) | dense 9B | Apache-2.0 | 41.8 | none | 57.8 | [UIVENUS2] |
| Fara1.5-9B | Qwen3.5-9B | MIT | browser only | none | none | [FARA] |

Cautions:

- The H Company numbers use H Company's own harness. It keeps memory over hundreds of steps and gives the model a shell. Perry's harness differs.
- The official OSWorld 2.0 board (updated 2026-10-15) lists Claude Opus 5 at max effort with 48.65% binary accuracy and a partial score of 79.2. Its best open-weight results are 4.6% for Kimi 2.6 and for MiniMax M3 (VERIFIED, [OSWORLD]). H Company reports 41.5% success and a score of 61.7 for Holo4-27B in its own harness ([HOLO4]). That is nine times the best open result on the board, so treat it as unverified until H Company submits to the board.
- Holo4-35B-A3B loses 31 points to Holo4-27B on the OSWorld 2.0 score (30.9 against 61.7) and 29 points on success (12.3% against 41.5%). Long workflows favour the dense model.
- Holo4-27B has a non-commercial licence. Perry cannot ship or default to it without a licence from H Company.
- Holo-3.1 4B and 9B have no official GGUF. Only community quantisers (mradermacher, prithivMLmods) publish them. That adds a supply-chain step.
- Grounding-only models do not earn a slot. GroundingPI carries a Kimi licence and needs SGLang on Linux. MolmoPoint-GUI-8B scores 61.1 on ScreenSpot-Pro and uses pointing tokens that stock engines do not decode. Phi-Ground-Any (MIT) is the only plain option. UI-Venus-2-9B reports ScreenSpot-Pro 73.0 and is a Qwen3.5 model, so it also grounds. 

Decision for Perry:

1. The default operator is the loaded brain plus the accessibility tree.
2. Perry-bench tests Holo4-35B-A3B as the operator on the 32 GB and larger tiers. Adopt it only if it beats the MoE brain by at least 5 points on Perry's own action tasks. It must also keep acceptable chat quality, which is an open question in section 7.
3. On 8 to 24 GB, test Holo-3.1-4B and 9B against Qwen3.5-4B and 9B in the same way.

### 3.4 Helper under 2 GB

The helper handles routing, short rewrites, titles, and structured extraction. It must start in under 300 ms and run above 100 tok/s. These are the candidates.

| Candidate | Size | Context | Licence | Evidence | Notes |
|---|---|---|---|---|---|
| Apple Foundation Models Core (AFM 3, 3B) | 0 MB added; the system holds it | 8,192 | system | VENDOR: Apple compares only with its own models ([AFM3]) | Needs Apple Intelligence on. Guided generation with `@Generable`, tool calls, `prewarm()`. Image input needs macOS 27 ([WWDC241]). |
| MiniCPM5-2B Q4_K_M | 1.56 GB | 131,072 | Apache-2.0 | AA index 12.5, tauBanking 20.8 (VERIFIED, [AA]); BFCL v4 66.6 (VENDOR, [MINICPM5]) | Text only. Standard Llama architecture, so every engine runs it. Thinking switch unconfirmed. |
| Qwen3.5-2B UD-Q4_K_XL | 1.34 GB, plus 0.67 GB vision file | 262,144 | Apache-2.0 | AA tau2 81.6 without thinking (VERIFIED, [AA]) | Vision through a separate vision file ([HF-API]). |
| Qwen3.5-0.8B Q4_K_M | 0.53 GB, plus 0.20 GB vision file | 262,144 | Apache-2.0 | AA tau2 65.2 without thinking (VERIFIED, [AA]) | Smallest option with vision. |
| MiniCPM5-1B Q4_K_M | 0.69 GB | 128,000 | Apache-2.0 | AA tau2 82.5 without thinking, estimated index (VERIFIED, [AA]) | Text only. |

Pick: Apple Foundation Models first. Where it is not available, use MiniCPM5-2B if Perry-bench confirms a working non-thinking mode, and Qwen3.5-2B otherwise.

### 3.5 One model or a pair

The question has three parts.

- **Brain plus grounder as two always-resident models:** not worth it. The accessibility tree covers most grounding. A grounder adds 1 to 2 GB and a second prefill.
- **Fast model plus deep model:** yes, on 32 GB and above. Both share one architecture, so Perry can swap them with a file load. On this Mac a 22 GB swap takes about 4 to 6 seconds from the SSD (UNVERIFIED, SSD read speed assumed 4 to 5 GB/s).
- **One model for everything:** the rule on 8 to 24 GB. Memory allows only one model plus the helper.

### 3.6 Ornith: an honest answer

The owner remembers Ornith as better than the Qwen3.5 family. The evidence supports a narrow version of that claim.

- The vendor reports MCP-Atlas 54.2 for Ornith-1.5-9B against 46.8 for Qwen3.5-9B, and Toolathlon-Verified 41.2 against 29.6 (VENDOR, [ORNITH]).
- For the 35B-A3B model the vendor reports MCP-Atlas 70.2 against 62.8 for Qwen3.6-35B-A3B, Terminal-Bench 2.1 of 67.8, and SWE-bench Verified of 79.0 (VENDOR, [ORNITH]).
- No board lists Ornith-1.5. AA has no row ([AA]). The only independent data are anecdotes. A review site reports 7 timeouts in 49 runs. One forum run has Ornith-1.5-35B behind Qwen3.8-27B (UNVERIFIED, second hand).
- Ornith opens every answer with a thinking block, and the card documents no off switch (UNVERIFIED for the interactive path).
- It uses the Qwen3.5 architecture and an MIT licence, so any engine runs it. Vision was not evaluated by the vendor.

Verdict: Ornith-1.5-9B and Ornith-1.5-35B-A3B enter Perry-bench as challengers to Qwen3.5-9B and Qwen3.6-35B-A3B. They do not become defaults without a head-to-head result.

### 3.7 Models I checked and set aside

| Model | Reason | Revisit when |
|---|---|---|
| Gemma 4 (E2B to 31B) | AA index 6.5 to 16.7e, below Qwen at equal size. Gemma 4 E4B ignores images in mlx-swift-lm (issue 374). | A Gemma 5 release |
| Qwen3.8-Flash-Next (125B-A6B) | AA 39.8, but GGUF files weigh 72.6 to 111.3 GB ([HF-API]). Licence qwen-community-1.0. New architecture. | The 128 GB tier needs a stretch model |
| GLM-5.3-Flash (320B, 18B active) | AA 41.8. Far above 128 GB at 4-bit. | Never for consumer Macs |
| K2 Horizon 7B, 3.7B, MoVA 36B-A4B | Strong tauBanking per size (27.6 for 7B). Text only. No setting turns thinking off. llama.cpp issue 30246 leaves low and medium effort tool calls inside the reasoning field. | Parser fix lands (pull request 30335) and a non-thinking mode appears |
| Flint (39.8B, 2.5B active) | Text only. Vendor-only scores. Its engine `rec` is four days old. | Vision and a board result appear |
| Spark-X2.6-4B | Text only. Custom architecture. No independent scores. Offers thinking levels none, low, and high. | A board result appears |
| Muse Glimmer 30B | AA 17.5. No gain over Qwen3.6-35B-A3B (18.2). llama.cpp support not verified. | A llama.cpp release adds it |
| LFM2.5-24B-A2B | Always thinks. Licence lfm1.0. Vendor-only scores. | A non-thinking mode appears |
| Nemotron 3.5 family | AA 12.9 to 26.5, with larger files than Qwen at the same score. | A smaller release |
| Holotron4-30B-A3B | NVIDIA Nemotron base, NVIDIA licence, no independent score. | Never needed |
| Qwen-AgentWorld-35B-A3B | A world model for environment simulation, not an agent. | Never needed |

The owner's win-pc notes also list expert-pruned MoE models (for example `Qwen3.6-35B-A3B-REAP-48-v2`, about 9.4 GB). I did not evaluate them. They could suit the 16 GB tier and belong in Perry-bench.

---

## 4. Inference engines

### 4.1 Candidates

Versions are those on 2026-10-25 ([GH-API], VERIFIED). "Tensor path" means the Metal 4 tensor API that uses the Neural Accelerators on M5-class chips.

| Engine | Licence, size | Runs the shortlist | Speculative decoding | Idle unload | Constrained output | Swift fit | Verdict |
|---|---|---|---|---|---|---|---|
| **llama.cpp** `llama-server` b11871 | MIT. macOS arm64 tarball 15 MiB; XCFramework 64 MiB | All Qwen3.5-family models, Gemma 4, K2 Horizon, MiniCPM5, with vision through `mmproj` files | `draft-mtp`, `draft-eagle3`, `draft-dflash`, `draft-dspark`, `ngram-*` ([LCPP-SPEC]) | `--sleep-idle-seconds`; router mode with `--models-max`; process exit | GBNF grammar and JSON schema | Helper process over HTTP, or C API | **Primary** |
| mlx-swift-lm 3.32.3 | MIT, Apple copyright | Qwen3.5, Qwen3.6, Qwen3.8, Gemma 4, Muse Glimmer. No K2, Flint, Spark | MTP merged (pull request 545); drafters for Gemma 4 | Release the model in process; allocator cache needs `clearCache()` | `MLXGuidedGeneration` (xgrammar) | Native Swift package | **Secondary** |
| mlx-lm 0.32.2, mlx-vlm 0.7.10 | MIT, Python | Wide; no K2 | mlx-vlm: MTP, DFlash, EAGLE-3 | Process exit | `response_format` ignored (issue 1007) | None; Python | Discover only |
| Ollama 0.40.11 | MIT, Go | Wide; own engine for Qwen3.5 | MTP | `keep_alive` per request | JSON schema | User installs it | Discover only |
| LM Studio | Proprietary app | llama.cpp and MLX runtimes | Per runtime | TTL and JIT load | Per runtime | User installs it | Discover only |
| Splash 1.4.0 (2026-10-20) | Apache-2.0, C++; created 2026-09-18; 1.8k stars, 99 open issues; arm64 tarball 76 MB ([SPLASH-REL]) | Four families: Qwen3.8-27B, Qwen3.6-35B-A3B, Ornith-1.5-122B, Qwen3.8-Flash-Next. Reads GGUF, MLX, and Ternary Bonsai PQ2_0 files, with vision | Trained DFlash2 draft per model | `--idle-release`, default 10 min; `--max-memory` cap; SSD prefix cache on by default | JSON schema, tool calls | Helper over HTTP; needs M3 or newer and macOS 26.4 | **Test first** on 36 GB and above |
| MTPLX | Apache-2.0; created 2026-05-02 | Qwen3.5 and Qwen3.8 families | MTP with exact rejection sampling | SSD session cache | Tool calling | Helper over HTTP | Discover only |
| oMLX | Apache-2.0, Python, 23k stars | MLX models | MTP, SpecPrefill | Per-model idle TTL | Via mlx-lm | Helper over HTTP | Discover only; its public board is the largest Mac dataset |
| uzu / Mirai | MIT, Rust, SwiftPM package | Qwen3.x and Llama families in Mirai formats | Speculation in vendor numbers | Not read | JSON schema, tool calls | SwiftPM | Watch; no vision found |
| BaseRT | Licence unstated | Qwen3, Gemma 4, Llama 3.2 | None | Not read | Not read | C++ | Watch |
| vllm-metal, vllm-mlx, Rapid-MLX, MLC, ExecuTorch, mistral.rs, LiteRT-LM | Mixed | Not shown to beat the rows above on these models | n/a | n/a | n/a | Python or compile-per-model | Not evaluated further |

### 4.2 Measured comparison: llama.cpp against MLX

I found no result that holds across chips. The sign of the difference changes with model, chip, build date, and quantisation. These rows compare the two engines on the same Mac.

| Chip and model | Metric | llama.cpp | MLX | Result | Label and source |
|---|---|---|---|---|---|
| M5 Max 128 GB, Qwen3.6-35B-A3B, 8-bit | Decode, 4K prompt | 89.2 tok/s | 81.2 tok/s | llama.cpp +10% | VERIFIED, independent [STARED] |
| Same | Prefill, 4K prompt | 2,725 tok/s | 3,314 tok/s | MLX +22% | VERIFIED, independent [STARED] |
| Same | Time to first token, 128-token prompt | 0.128 s | 0.287 s | llama.cpp 2.2 times lower | VERIFIED, independent [STARED] |
| M5 Max, Qwen3.6-27B, 8-bit | Decode / prefill at 4K | 17.7 tok/s / 647.7 tok/s | 17.0 tok/s / 670.3 tok/s | llama.cpp +4% decode; MLX +3.5% prefill | VERIFIED, independent [STARED] |
| M5 Max | Resident memory, 35B-A3B / 27B | 44.1 / 41.3 GB | 36.6 / 28.4 GB | MLX uses less | VERIFIED, independent [STARED] |
| M4 Pro 16-core GPU, 24 GB, Qwen3-30B-A3B, 4-bit | Decode / prefill at 2,048 tokens | 80.7 / 601 tok/s | 83.1 / 720 tok/s | MLX +3% decode, +20% prefill | VENDOR (BaseRT paper, build b9630) [BASERT] |
| Same chip, Gemma 4 26B-A4B, 4-bit | Decode / prefill at 2,048 tokens | 58.0 / 558 tok/s | 69.3 / 644 tok/s | MLX +19% decode, +15% prefill | VENDOR [BASERT] |
| M3 Max 64 GB, Qwen3.5-35B-A3B, 4-bit | Decode | 58 tok/s | 95 tok/s | MLX +63% | VERIFIED, one author [HIESCH] |
| Same, Gemma 4 26B-A4B | Decode | 64 tok/s | 29 tok/s | llama.cpp 2.2 times faster | VERIFIED, one author [HIESCH] |
| Same, Qwen3.6-27B | Decode | 17.3 tok/s | 20 tok/s | MLX +16% | VERIFIED, one author [HIESCH] |
| M2 Max 32 GB, Qwen3.6-35B-A3B, 4-bit | Decode | 57.8 tok/s | 86.9 tok/s | MLX +50% | VERIFIED, one author [RAYNAR] |
| Same | Prefill (4,096 against 2,531 tokens) | 685 tok/s | 296 tok/s | llama.cpp 2.3 times faster; lengths not matched | VERIFIED, one author [RAYNAR] |
| M4 Max, Nemotron-3 Nano 30B-A3B | Decode | 86.2 tok/s (build 8680) | 159.7 tok/s | MLX 1.9 times faster | VENDOR, one maintainer [JROCKY] |

### 4.3 Answer: when is llama.cpp faster than MLX?

llama.cpp is faster in these cases.

- **Decode on the M5 Max at 8-bit.** It leads by 4% to 10% on Qwen3.6 models ([STARED], build 9430, 2026-06-14).
- **Short prompts.** Its time to first token is 2.2 times lower at 128 tokens on the M5 Max ([STARED]). MLX matches it by 1,000 tokens (0.442 s against 0.423 s).
- **Gemma 4 decode on the M3 Max.** It is 2.2 times faster there, but MLX is 19% faster on the M4 Pro ([HIESCH], [BASERT]).
- **Multi-turn loops on hybrid models.** `llama-server` keeps recurrent-state checkpoints per slot, so a new turn reuses the cached prefix when the text matches ([LCPP-SRV]). mlx-swift-lm re-reads the whole prompt on every turn (issue 660, VERIFIED open on 2026-10-25). The fix, pull request 661, is also open.
- **A gap in llama.cpp itself.** On the Qwen3.5 architecture the server skips checkpoints after image chunks. A prompt that changes the text after an image then re-encodes the image (issue 26994, VERIFIED open on 2026-10-25). Perry puts the stable text first and the screenshot last. Each step has a new screenshot anyway, so only the text before it needs the cache.
- **MTP on M5-class chips.** Dense decode rises 1.8 times (section 5, row 3).
- **Quality per byte.** GGUF K-quants of 15.4 to 17.9 GB reach 2.4 to 3.1 times lower KL divergence than the 16.1 GB MLX 4-bit file (Appendix B.1, [KLD]).
- **Load time.** It loads 8-bit files of 29 to 37 GB in 2.1 to 2.3 s against 4.2 to 4.9 s for MLX ([STARED]).
- **Long context.** One user reports MLX decoding at half the llama.cpp speed at 146K tokens on an M3 Ultra (mlx-lm issue 763, UNVERIFIED). Perry's prompts are 4K to 12K tokens, far below that point.
- **The M5 tensor path.** A Metal 4 SDK build roughly doubles prefill on an M5 Max (877 to 1,833 tok/s for gpt-oss-120b) and leaves decode flat ([LMS-2040], VERIFIED). A build made with an old SDK silently loses it. MLX reaches the same hardware from macOS 26.2 ([APPLE-MLX-M5]).

MLX is faster in these cases.

- **Decode of Qwen MoE models on M2 to M4 chips.** It leads by 50% on the M2 Max and 63% on the M3 Max for the hybrid Qwen3.5 and Qwen3.6 MoE models. It leads by 3% on the M4 Pro for the plain-attention Qwen3-30B-A3B. The oMLX board shows 87 to 94 tok/s on the M4 Pro for the hybrid Qwen3.6 model. My estimate for llama.cpp is 60 (section 2.2).
- **Prefill on the M4 Pro.** It leads by 15% to 20% (VENDOR, [BASERT]). On the M2 Max the evidence conflicts. One author's paired run has llama.cpp prefilling 2.3 times faster, with unmatched lengths ([RAYNAR]). An oMLX board row is 19% above that author's llama.cpp figure ([OMLX-BOARD]).
- **Prefill beyond 2,000 tokens on the M5 Max.** It leads by 22% for the MoE model.
- **Memory.** It uses 7.5 to 12.9 GB less resident memory on the M5 Max.
- **MTP on the M4 Pro.** oMLX rows for Qwen3.8-27B reach 26 to 30 tok/s on MTP checkpoints, against 15 tok/s for the plain 4-bit file (Appendix A.1). The board does not show the MTP setting, so the cause is UNVERIFIED.

The sign of the difference depends on chip generation, model, and quant. For Perry's two default models I expect llama.cpp to lead on M5-class chips and MLX to lead on decode on M1 to M4 chips. Prefix reuse across turns favours llama.cpp today. The onboarding benchmark must therefore time a cached follow-up turn (the reference turn, section 6.3) as well as the cold turn.

### 4.4 Measured numbers for this Mac and its neighbours

The oMLX community board is the largest public Mac dataset: 557,605 rows on 2026-10-25 ([OMLX-BOARD], VERIFIED by reading the page header). Submitters are anonymous. The board shows neither the software version nor the MTP setting. I pulled the newest rows (2026-10-09 to 2026-10-25) for each model and chip. All rows use MLX through oMLX at a 4,096-token prompt. The table gives the range across the rows I pulled, so treat each range as a hint and not as a benchmark.

| Chip (GPU cores) | Model and quant | Prefill, tok/s | Decode, tok/s | Rows |
|---|---|---|---|---|
| M4 Pro (20) | Qwen3.5-4B 4-bit | 843 | 80.1 | 1 |
| M4 Pro (16) | Qwen3.5-4B 4-bit | 590 to 684 | 71.6 to 79.6 | 3 |
| M4 Pro (20) | Qwen3.5-9B 4-bit | 481 to 488 | 48.7 to 49.0 | 2 |
| M4 Pro (16) | Qwen3.5-9B 4-bit | 372 to 384 | 44.8 to 48.2 | 6 |
| M4 Pro (20) | Qwen3.6-35B-A3B 4-bit | 1,050 to 1,106 | 86.6 to 94.0 | 2 |
| M4 Pro (20) | Qwen3.6-35B-A3B, Unsloth UD-MLX-4bit | 115 to 303 | 9.8 to 24.7 | 3 |
| M4 Pro (20) | Qwen3.6-27B 4-bit | 132 | 14.8 | 1 |
| M4 Pro (20) | Qwen3.8-27B 4-bit | 135 to 187 | 14.8 to 15.3 | 2 |
| M4 Pro (20) | Qwen3.8-27B, oQ4e-mtp checkpoint | 127 to 131 | 20.2 to 29.7 | 4 |
| M5 Pro (20) | Qwen3.6-35B-A3B 4-bit | 2,066 to 3,465 | 107 to 109 | 3 |
| M2 Max (30) | Qwen3.6-35B-A3B, Unsloth UD-MLX-4bit | 799 | 78.3 | 1 |
| M4 (10) | Qwen3.5-9B 4-bit, 16 to 24 GB | 241 to 310 | 18.3 to 21.3 | 5 |
| M5 (10) | Qwen3.5-9B 4-bit, 16 to 24 GB | 737 to 770 | 23.4 to 25.8 | 3 |
| M2 (10) | Qwen3.5-4B 4-bit | 237 to 238 | 30.6 to 30.8 | 2 |

Sources: [OMLX-BOARD], full rows in Appendix A.1 ([OMLX-A]). The label is VERIFIED as board rows. They are community submissions, and no one has reproduced them independently.

What the rows show:

- The MoE model prefills about twice as fast as the 9B model on the same chip (1,050 against 480 tok/s). It decodes at nearly twice the speed (90 against 49 tok/s). It also scores higher (section 3.1). On a Pro or Max chip with 32 GB or more, the MoE model wins on both speed and quality.
- Three rows for the Unsloth UD-MLX-4bit file of the MoE model report 9.8 to 24.7 tok/s on the M4 Pro. One row reports 78.3 on the M2 Max. The cause is unknown. A different quant of the same model avoids the problem.
- Checkpoints with the MTP head decode the dense 27B model at 20 to 30 tok/s on the M4 Pro. The plain file decodes at 15. They add nothing for the MoE model (53.5 to 91.1 against 86.6 to 94.0).
- The M5 Pro decodes the MoE model 1.2 times faster than the M4 Pro and prefills 2 to 3 times faster.

No llama.cpp row exists for this chip. My planning values for the MoE model with llama.cpp on the M4 Pro 48 GB are 60 tok/s decode and 650 tok/s prefill. They are UNVERIFIED (section 6.1). The gap to the MLX rows is the reason for the engine test in section 6.3.

### 4.5 Specialist engines: vendor claims against independent checks

| Engine | Claim | Label | Independent check |
|---|---|---|---|
| Splash 1.4.0 | Same UD-Q4_K_M weights. M5 Pro 20-core: Qwen3.6-35B-A3B 175 tok/s against 69 for llama.cpp, and Qwen3.8-27B 74 against 16 (27 with MTP). M3 Max 40-core: 209 against 66, and 92 against 17 (20 with MTP). Prefill of a 2,048-token chunk is 1.2 to 1.9 times faster. Cached 32K replay answers in 123 ms. ([SPLASH], [SPLASH-PERF]) | VENDOR | None found. LM Studio lists Splash as an experimental backend and repeats the 74 tok/s figure ([SPLASH-LMS]). A community run on an M4 Max measured prefill only: 1.77 times faster with the Neural Engine split ([SPLASH-REL]). |
| MTPLX | Qwen3.8-27B 58.7 to 87.6 tok/s on an M5 Max; 14.4 to 23.0 tok/s for Qwen3.5-9B on a 16 GB M4 Mac mini ([MTPLX]) | VENDOR | None found. |
| uzu / Mirai | Qwen3.8-27B 123 tok/s on an M5 Max with speculation, 15.6 GB ([UZU]) | VENDOR | The BaseRT paper shows uzu ahead of BaseRT on small-model prefill. |
| BaseRT | Up to 6.4 times llama.cpp prefill on an M5 Pro | VENDOR | The paper's own M4 Pro tables show +4% decode on Qwen3-30B-A3B ([BASERT]). |
| rec (Flint only) | Over 125 tok/s on an M4 Pro | VENDOR | None. Repository is four days old. |

Read the Splash numbers with three cautions.

- The prompts are coding prompts from SPEED-Bench. A draft model accepts many tokens on code. On prose on an M2 Max, the same DFlash2 draft in llama.cpp accepted 0.28 to 0.35 of tokens. Decode fell to 0.60 of the baseline ([RAYNAR]). Perry output is short JSON actions and short answers, so the real gain lies between the two.
- The release notes show fast change: ten releases in five weeks, a breaking change to the model package format in 1.3.1, and 99 open issues. LM Studio's first Splash build (0.0.5) returned gibberish and no native tool calls ([LMS-2478]). The standalone 1.3.0 build worked.
- Splash needs an M3 or newer chip and macOS 26.4. It serves four model families. It does not serve the 4B and 9B models of the smaller tiers.

An independent M2 Max run found the DFlash2 drafter, which Splash uses, to be a net loss in llama.cpp. Decode ran at 0.95 to 0.97 times the baseline on code and math, and at 0.60 times on prose ([RAYNAR]). That run used llama.cpp kernels, not Splash kernels, so it does not refute Splash. It shows that a good draft does not guarantee a gain on older chips.

### 4.6 Verdict

1. **Ship `llama-server` as the default engine.** The reasons are model coverage, prefix reuse on hybrid models, GGUF quality per byte, grammar-constrained output, idle sleep, process isolation, and the M5 tensor path. On the M4 Pro it probably costs 31% to 36% of MoE decode speed against MLX. The planning value is 60 tok/s for llama.cpp (UNVERIFIED) against 87 to 94 tok/s in the MLX rows. The cost is smaller than it looks, because a typical Perry turn waits on prefill and on a short answer.
2. **Keep the engine behind an OpenAI-compatible boundary.** The onboarding benchmark (section 6.3) compares `llama-server` with each other local server the Mac can run. Those are Splash on 36 GB and larger Macs, and an MLX server when one exists. A challenger replaces the default for that Mac if it passes the 25% rule of section 6.3 with matched answers.
3. **Treat mlx-swift-lm as the secondary path.** It is the right tool for the macOS 27 FoundationModels bridge and it is in-process Swift. It re-reads the whole prompt on hybrid models (issue 660, fix pull request 661 open). Gemma 4 E4B ignores images (issue 374). These two open issues keep it off the default path. Re-check after pull request 661 merges, because MLX is faster on M1 to M4 chips.
4. **Do not bundle MTPLX, uzu, or BaseRT.** Their claims are VENDOR only. Splash is the exception worth testing, because it targets the two default models, reads the same GGUF files, and has a cached-prefix design.

---

## 5. Applying the win-pc tricks on the Mac

The owner's win-pc stack runs NInfer, a custom CUDA engine, with the flags in `start-ninfer.cmd` (read from the owner's handoff). NInfer has no Metal build. The table maps each setting to its Mac equivalent, the evidence, and the default for Perry.

| # | win-pc setting | Mac equivalent | Evidence | Perry default |
|---|---|---|---|---|
| 1 | NInfer engine (CUDA, `.ninfer` files) | llama.cpp Metal (`llama-server`), then mlx-swift-lm | Section 4 | `llama-server` |
| 2 | `--kv-dtype rk4v4-e8` (rotated 4-bit K and V, cosine 98.7%, +0.4% perplexity on win-pc) | llama.cpp `-ctk q8_0 -ctv q8_0`. No rotation option exists in the server ([LCPP-SRV]). Rotated 4-bit KV (TurboQuant) exists only in mlx-swift-lm. | q8_0 KV costs 2% of decode speed on an M2 Max (58.55 against 57.25 tok/s, [RAYNAR]). KL divergence 0.024 (27B) and 0.039 (35B-A3B) ([LOCALBENCH-KV]). `q4_0` keys broke Qwen2.5-7B ([LCPP-23470]). TurboQuant slows decode 19% to 32% and prefill 4 to 9 times until pull request 717 merges ([MLXSWLM-717]). | f16 KV. Hybrid KV is tiny: 0.63 GiB at 32K tokens for the MoE model. Use `q8_0` on 8 to 16 GB Macs. |
| 3 | `--spec mtp --draft-tokens 3 --lm-head-draft` (about 40% acceptance on win-pc) | `--spec-type draft-mtp --spec-draft-n-max 2` (the Unsloth setting). The owner uses 3. The 35B-A3B model needs the files from the repo `unsloth/Qwen3.6-35B-A3B-MTP-GGUF`, which are 0.5 to 0.9 GB larger than the plain files. The 27B model uses a separate 1.37 GB head file, `MTP/mtp-Qwen3.8-27B-Q4_0.gguf` ([HF-API], VERIFIED). The sources I read do not say how `llama-server` loads that file (UNVERIFIED). Image input works with MTP since llama.cpp pull request 30257 (merged 2026-10-10). | M5 Max, 4K prompt, dense model: decode 17.7 to 31.5 tok/s (+78%), first token 6.35 to 7.61 s. MoE model: decode 89.2 to 97.1 tok/s (+9%), first token 1.51 to 1.93 s ([STARED]). Break-even output length: 51 tokens (dense) and 460 tokens (MoE), by arithmetic on those rows. M2 Max, MoE model, Ollama `draft-mtp` with 2 draft tokens: 46.2 to 34.6 tok/s (-25%), and worse with more draft tokens ([RAYNAR]). Vendor, 27B: +18% on an M3 Max and +69% on an M5 Pro ([SPLASH-PERF]). oMLX rows for the 27B on an M4 Pro: 15 tok/s plain against 20 to 30 tok/s with MTP checkpoints ([OMLX-BOARD]). | **MoE lane: off.** Dense deep lane: on if the onboarding benchmark shows a 15% gain or more on a 150-token answer. The llama.cpp gain on an M4 Pro is untested. |
| 4 | `--ngram chain` (removed on win-pc: it repeated earlier errors) | Keep `ngram-*` types off. A small same-family draft model (`draft-simple`) is the only other option. | Gemma 4 26B-A4B with an E2B draft: 63.9 to 206.5 tok/s on an M3 Max with a code prompt, and 9 GB more memory ([HIESCH]). DFlash2 on an M2 Max in llama.cpp: 0.60 to 0.97 times the baseline ([RAYNAR]). | Off. Test a Qwen3.5-0.8B draft for the dense 27B in Perry-bench. |
| 5 | `--auto-long-anchors 4`, `--max-long-anchors-per-continuation 4` | None. These options are NInfer-specific, and the handoff does not define them (UNVERIFIED). | The 56 of 56 long-session test ran to about 107K tokens on win-pc. Perry sessions are short. The server defaults are 32 checkpoints per slot, a minimum spacing of 8,192 tokens, and an 8,192 MiB RAM cache ([LCPP-SRV]). | A stable cached prefix, `--ctx-checkpoints 8`, `--checkpoint-min-step 1024`, `--cache-ram 1024`. The spacing value is UNVERIFIED. The benchmark times the reference turn with and without it. |
| 6 | `--preserve-thinking` | `--reasoning-preserve`. Qwen3.8 sets `preserve_thinking` true by default ([Q38], [LCPP-SRV]). | Issue 30357 (open): changed whitespace in reasoning forces a full re-prefill on hybrid models. | On in the deep lane. Resend reasoning text byte for byte. |
| 7 | `--default-thinking-budget 16384`, `--default-max-tokens 24576` | `--reasoning-budget N`, `--reasoning-budget-message`, request `max_tokens` ([LCPP-SRV]) | 16,384 tokens take 15 minutes at 18 tok/s (27B) and 4.6 minutes at 60 tok/s (MoE). The win-pc bug: a default output cap of 8,192 ended long thinks with no answer. | Fast lane: thinking off. Deep lane: budget 2,048 (low) or 4,096 (medium). `max_tokens` above budget plus answer. |
| 8 | `reasoning_effort: medium` ("the loop-breaker") | Request field, or `--reasoning-effort medium`. Valid levels for Qwen3.8: xhigh, medium, low. | AA index: off 20.2, low 26.2, medium 27.6, xhigh 33.7 ([AA]). | Deep lane: medium. Off switch: `--chat-template-kwargs '{"enable_thinking":false}'`. |
| 9 | Sampling: temperature 1.0, top_p 0.95, top_k 20, min_p 0.05 | Same flags. Vendor thinking mode: min_p 0.0, presence penalty 0.0. Non-thinking: temperature 0.7, top_p 0.8, top_k 20, min_p 0.0, presence penalty 1.5 ([Q38]). | llama.cpp applies min_p 0.05 by default unless set. | Per lane. For action JSON use a grammar and temperature 0.3 or lower (UNVERIFIED value). |
| 10 | `--host-kv-mib 2048`, `--host-state-slots 12`, `--device-state-slots 0` | Not needed. Unified memory has no separate VRAM. Related: `--cache-ram`, `--cache-idle-slots`, `--slot-save-path`. | Default `--cache-ram` is 8,192 MiB ([LCPP-SRV]). | `--cache-ram 1024` on 8 to 24 GB; 2048 above. |
| 11 | `--max-context 131072` | `-c`. Hybrid KV is small, and `--fit` shrinks the context if memory is short. | KV at 32K tokens: 0.63 GiB (MoE), 2 GiB (27B). | `-c 16384`; `-c 32768` on 32 GB and above. |
| 12 | Swift-Bonsai-2 ternary, 6.4 GB, 117 tok/s on an RTX 4070 Ti | Ternary-Bonsai-2-27B PQ2_0, 7.21 GB, on the Prism llama.cpp fork. Stock llama.cpp rejects the file type (upstream issue 29058 is open). | Vendor decode: 47.0 (M5 Max), 28.1 to 28.7 (M5 Pro), 18.0 (M4 Pro) tok/s. Vendor quality: 84.78 against 86.32 for FP16 ([BONSAI-GGUF]). | Deep lane on 16 to 32 GB. Needs owner approval for the fork. |
| 13 | `--max-concurrency 2` | `--parallel 1` | The M5 Max benchmark used one slot ([STARED]). | One slot. A second slot only for a resident helper. |
| 14 | `nvidia-smi -pl 245` (power cap) | None. Read `ProcessInfo.thermalState` and Low Power Mode. | Local API behaviour (UNVERIFIED). | Skip the benchmark in Low Power Mode. |
| 15 | Vision enabled | `--mmproj` file and `--image-max-tokens` ([LCPP-SRV]) | Section 2.6. | Cap at 640 image tokens. |
| 16 | NInfer rejects `response_format` json_schema (known issue in handoff) | `llama-server` accepts JSON schema and grammar. | [LCPP-SRV] | Use it for every action step. |

What carries over unchanged: sampling, effort levels, and budget logic. What does not carry over: KV rotation, long anchors, host offload, and NInfer's ternary kernels. The ternary kernels live in a third-party llama.cpp fork on the Mac.

Settings that exist only on the Mac, and that Perry should use:

1. `--sleep-idle-seconds 300` drops the model and KV cache after five idle minutes. Perry exits the process after 30 idle minutes.
2. `--fit on` (default) with `--fit-target 2048` keeps the model inside the working set ([LCPP-SRV]).
3. A Metal 4 SDK build keeps the M5 tensor path. The official release workflow builds on a `macos-26` runner with deployment target 13.3 and does not sign or notarise the tarball ([LCPP-REL], VERIFIED). Perry must re-sign the binary. Whether the shipped binary has the tensor path is UNVERIFIED. The benchmark must test it on M5 Macs with `GGML_METAL_TENSOR_DISABLE=1`.
4. `-lm mmap` (default) shortens load time, and the file stays in the page cache after unload.
5. Prewarm on hotkey-down: wake the server and send a one-token request before the user finishes speaking.
6. Free the model on a memory-pressure warning, using `DispatchSource.makeMemoryPressureSource` (from [R3]).

---

## 6. Plan per tier, default for this Mac, and the onboarding test

### 6.1 Per-tier table

The table uses one example Mac per tier. Speeds are for `llama-server` with the flags in section 6.2. They are UNVERIFIED planning values from section 2, unless the Label column says otherwise. Section 2.7 defines the reference turn.

Terms in the tables:

- "First token" is the time to the first output token for the reference turn.
- In the memory table, "Warm" is the memory after the model loads.
- "Active" adds a 16K-token context, compute buffers, and a 1 GB RAM cache to "Warm".
- "Peak" adds the vision-encoder spike to "Active".

The idle memory of the server process is under 0.2 GB because `--sleep-idle-seconds` unloads the model (UNVERIFIED).

| Tier | Example Mac | Lane | Model and quant | Decode, tok/s | First token, s | Label |
|---|---|---|---|---|---|---|
| 8 GB | M2, 8 GB | Interactive | Qwen3.5-2B UD-Q4_K_XL, 320 image tokens | 55 | 2.6 | UNVERIFIED |
| 8 GB | M2, 8 GB | Only if the fit rule passes | Qwen3.5-4B UD-Q4_K_XL, 320 image tokens | 27 | 4.9 | UNVERIFIED |
| 16 GB | M4, 16 GB | Interactive | Qwen3.5-4B UD-Q4_K_XL | 32 | 6.4 | UNVERIFIED |
| 16 GB | M4, 16 GB | Quality rung | Qwen3.5-9B UD-Q4_K_XL | 16 | 12 | UNVERIFIED. MLX board rows give 18 to 21 tok/s and about 9 s. |
| 16 GB | M5, 16 GB | Interactive | Qwen3.5-9B UD-Q4_K_XL | 22 | 4.0 | UNVERIFIED |
| 16 GB | M5, 16 GB | Deep | Ternary-Bonsai-2-27B PQ2_0 | 12 | 10 | UNVERIFIED |
| 24 GB | M4 Pro (16-core GPU), 24 GB | Fast | Qwen3.5-4B UD-Q4_K_XL | 73 | 3.9 | UNVERIFIED. MLX board rows give 72 to 80 tok/s. |
| 24 GB | M4 Pro (16-core GPU), 24 GB | Interactive | Qwen3.5-9B UD-Q6_K_XL | 26 | 7.5 | UNVERIFIED |
| 24 GB | M4 Pro (16-core GPU), 24 GB | Deep | Ternary-Bonsai-2-27B PQ2_0 | 18 | 15 | VENDOR decode and prefill on an M4 Pro ([BONSAI-GGUF]) |
| 32 GB | M2 Max (30-core GPU), 32 GB | Interactive | Qwen3.6-35B-A3B UD-IQ4_XS | 60 | 3.6 | UNVERIFIED. Q4_K_M measured 58.6 tok/s and 671 tok/s prefill ([RAYNAR]). |
| 32 GB | M2 Max (30-core GPU), 32 GB | Deep | Qwen3.8-27B UD-IQ4_XS | 20 | 12 | UNVERIFIED |
| 48 GB | M4 Pro (20-core GPU), 48 GB | Interactive | Qwen3.6-35B-A3B UD-Q4_K_XL | 60 | 4.0 | UNVERIFIED. MLX board rows give 87 to 94 tok/s and about 1,100 tok/s prefill. |
| 48 GB | M4 Pro (20-core GPU), 48 GB | Deep | Qwen3.8-27B UD-Q5_K_XL | 10 (15 with MTP) | 15 | UNVERIFIED. MLX board rows give 15 tok/s, and 20 to 30 with MTP. |
| 64 GB | M5 Pro (20-core GPU), 64 GB | Interactive | Qwen3.6-35B-A3B UD-Q6_K | 50 | 1.2 | UNVERIFIED. Q4_K_M measured 69 tok/s (VENDOR, [SPLASH-PERF]). |
| 64 GB | M5 Pro (20-core GPU), 64 GB | Deep | Qwen3.8-27B UD-Q6_K | 12 (20 with MTP) | 4.6 | UNVERIFIED |
| 96 to 128 GB | M5 Max (40-core GPU), 128 GB | Interactive | Qwen3.6-35B-A3B Q8_0 | 92.9 | 0.8 | VERIFIED, independent decode ([STARED]). First token follows from its measured prefill. |
| 96 to 128 GB | M5 Max (40-core GPU), 128 GB | Deep | Qwen3.8-27B Q8_0 | 18.4 (31.5 with MTP) | 2.7 (3.2) | VERIFIED, independent decode ([STARED]) |

| Tier | Lane | Model | Download, GB | Warm, GB | Active, GB | Peak, GB |
|---|---|---|---|---|---|---|
| 8 GB | Interactive | Qwen3.5-2B UD-Q4_K_XL (with `-c 6144` and `--cache-ram 256`) | 2.0 | 2.0 | 3.0 | 3.5 |
| 8 GB | Only if the fit rule passes | Qwen3.5-4B UD-Q4_K_XL (same flags) | 3.6 | 3.6 | 4.6 | 5.1 |
| 16 GB | Interactive | Qwen3.5-4B UD-Q4_K_XL | 3.6 | 3.6 | 5.9 | 6.4 |
| 16 GB | Quality rung | Qwen3.5-9B UD-Q4_K_XL | 6.9 | 6.9 | 9.2 | 9.7 |
| 16 GB | Deep | Ternary-Bonsai-2-27B PQ2_0 | 7.8 | 7.8 | 10.7 | 11.2 |
| 24 GB | Interactive | Qwen3.5-9B UD-Q6_K_XL | 9.7 | 9.7 | 12.0 | 12.5 |
| 32 GB | Interactive | Qwen3.6-35B-A3B UD-IQ4_XS | 18.6 | 18.6 | 20.8 | 21.3 |
| 32 GB | Deep | Qwen3.8-27B UD-IQ4_XS | 15.2 (16.6 with MTP) | 15.2 | 18.1 | 18.6 |
| 48 GB | Interactive | Qwen3.6-35B-A3B UD-Q4_K_XL | 23.3 | 23.3 | 25.4 | 25.9 |
| 48 GB | Deep | Qwen3.8-27B UD-Q5_K_XL | 21.8 (23.2 with MTP) | 21.8 | 24.7 | 25.2 |
| 64 GB | Interactive | Qwen3.6-35B-A3B UD-Q6_K | 30.2 | 30.2 | 32.3 | 32.8 |
| 64 GB | Deep | Qwen3.8-27B UD-Q6_K | 22.9 (24.3 with MTP) | 22.9 | 25.8 | 26.3 |
| 96 to 128 GB | Interactive | Qwen3.6-35B-A3B Q8_0 | 37.8 | 37.8 | 39.9 | 40.4 |
| 96 to 128 GB | Deep | Qwen3.8-27B Q8_0 | 30.0 (31.4 with MTP) | 30.0 | 32.9 | 33.4 |

Download sizes are the sum of the weight file and the vision file from the Hugging Face API (VERIFIED, [HF-API]). Warm, Active, and Peak are UNVERIFIED calculations. On the M5 Max, `llama-server` held 44.1 GB resident for the 36.9 GB MoE file (VERIFIED, [STARED]). That run used a 65,536-token context and the default 8,192 MiB RAM cache. The Active column assumes a 16,384-token context and a 1 GiB cache, so it sits below that figure.

Three rules follow from the tables.

1. **Fit rule.** Perry reads `recommendedMaxWorkingSetSize` at run time. Active memory must stay below 75% of that value (UNVERIFIED threshold). On an 8 GB Mac this rule rejects the 4B model at the default context and selects the 2B model.
2. **Latency rule.** The interactive lane needs a first token under 6 s and decode above 15 tok/s on the reference turn. The 9B model fails the first test on an M4 base chip (12 s), so that Mac gets the 4B model.
3. **Chip class beats RAM.** A 24 GB M4 Pro prefills 1.6 times faster and decodes 2.3 times faster than a 24 GB M4 base. Section 2.3 and the board rows in section 4.4 give the evidence. The onboarding test (section 6.3) chooses the rung. The table gives only the starting point.

### 6.2 Default for this Mac (M4 Pro, 48 GB)

Files to download (sizes VERIFIED, [HF-API]):

| Lane | Repository and file | Size, GB |
|---|---|---|
| Interactive | `unsloth/Qwen3.6-35B-A3B-GGUF`: `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` | 22.36 |
| Interactive | same repository: `mmproj-F16.gguf` | 0.90 |
| Deep | `unsloth/Qwen3.8-27B-GGUF`: `Qwen3.8-27B-UD-Q5_K_XL.gguf` | 20.88 |
| Deep | same repository: `mmproj-F16.gguf` | 0.93 |
| Deep, optional | same repository: `MTP/mtp-Qwen3.8-27B-Q4_0.gguf` | 1.37 |
| Helper | Apple Foundation Models (system); fallback `Qwen3.5-0.8B-Q4_K_M.gguf` and its vision file | 0 (0.73) |

The disk total is 46.4 GB. Both lanes cannot stay resident together. The Metal working set is 37.4 GiB (40.2 GB) and the two lanes need 50 GB. Perry therefore loads one lane at a time. A swap reads about 21 GB from the SSD and takes about 4 to 6 s (UNVERIFIED, assumes 4 to 5 GB/s).

Interactive lane command. The flags are VERIFIED against the server README ([LCPP-SRV]). The values are my choices:

```sh
llama-server \
  --model Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf --mmproj mmproj-F16.gguf \
  --host 127.0.0.1 --port <free port> --api-key-file <key file, mode 0600> \
  -ngl all -fa on -c 32768 -np 1 \
  --image-max-tokens 640 \
  --cache-ram 2048 --ctx-checkpoints 8 --checkpoint-min-step 1024 \
  --sleep-idle-seconds 300 \
  --chat-template-kwargs '{"enable_thinking":false}' \
  --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0
```

Deep lane command. Change the model, then set thinking to medium effort with a hard fuse:

```sh
  --model Qwen3.8-27B-UD-Q5_K_XL.gguf --mmproj mmproj-F16.gguf \
  --reasoning-effort medium --reasoning-budget 4096 \
  --reasoning-budget-message "I must answer now." --reasoning-preserve \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0
  # request max_tokens: 6144 (above the budget plus the answer)
  # only if the onboarding test shows a gain: --spec-type draft-mtp --spec-draft-n-max 2
```

Notes on the flags:

- Do not send `presence_penalty` 1.5 with a JSON grammar. The vendor sets it to reduce loops in plain text, and JSON repeats quote and brace tokens (UNVERIFIED reasoning). Use 0 for action calls.
- The server keeps `/health`, `/props`, `/models`, and `/metrics` out of the idle timer ([LCPP-SRV]). Perry may poll them without waking the model.
- Perry starts and stops the process itself. It passes a random API key through a file and listens on loopback only.
- Prompt layout: system prompt and tool schema first, then history, then the accessibility text, then the screenshot, then the instruction. Do not keep old screenshots in the history. On these models the server cannot place a checkpoint after an image chunk (issue 26994). The cache can reuse only the text before the image.

On this Mac, the interactive lane should decode at 60 tok/s (UNVERIFIED, section 6.1). The first token should arrive near 4 s for a screenshot turn and near 1.6 s for a text-only turn. The turn after that reuses the cached prefix, so only the new tokens need prefill. Warm memory is 23.3 GB and the peak is 25.9 GB.

Idle-memory policy. The user picks a budget. Perry applies the first matching row.

| Budget | What stays in RAM when idle | Wake cost |
|---|---|---|
| Off | Nothing. The server exits after 30 idle minutes. | Process start plus model load: 2 to 6 s (UNVERIFIED) |
| Up to 2 GB | The helper only. | Same as Off for the main model |
| Warm lane | The interactive model stays loaded. Sleep is off. | None, but macOS may still evict pages |

Perry also frees the model when macOS reports memory pressure ([R3]). On a hotkey press, Perry sends a one-token request to wake the server while the capture runs.

Challengers to test on this Mac before the default is final:

1. MLX 4-bit through oMLX or the `mlx-lm` server: 87 to 94 tok/s and about 1,100 tok/s prefill on the board. Compare at equal quality, because MLX 4-bit has about three times the KL divergence of UD-Q4_K_XL. MLX 6-bit (22.8 GB for the 27B) matches or beats UD-Q4_K_XL ([KLD]).
2. Splash 1.4.0 with the same GGUF files (VENDOR claim: 2.5 to 3.2 times the llama.cpp decode speed).
3. `llama-server` with the MTP file set for the 27B model.

### 6.3 Onboarding benchmark

The test runs once, in the background, after the download. It lasts about 60 to 90 seconds for the interactive lane and about 3 minutes for the deep lane. It keeps the results on the Mac. The test uses the same reference turn as this report, so the results compare with section 6.1.

1. **Fingerprint.** Read the chip name, GPU core count, memory size, and `recommendedMaxWorkingSetSize`. Read the macOS build, power source, Low Power Mode, thermal state, free disk space, and Apple Intelligence availability. Postpone the test on battery power, in Low Power Mode, or at a thermal state above "fair".
2. **Pick the start rung.** Use the tier table and the fit rule. Skip rungs whose Active memory is above 75% of the working set.
3. **Download.** Resume interrupted downloads. Check each file against the SHA-256 value in the Hugging Face file metadata. Do not start the test with an unverified file.
4. **Run five measurements.**
   - Load time: process start to a healthy `/health`, cold and then warm.
   - Cold turn: send a bundled system prompt and tool schema (2,000 tokens). Add 1,000 tokens of bundled accessibility text and a bundled screenshot capped at 640 image tokens. Start from an empty cache. Record the first-token time and peak memory. Take the median of three runs, with a cache reset before each run.
   - Reference turn: send the same system prompt and tool schema, then different accessibility text and a different screenshot. The server caches the prefix, so this turn matches the reference turn of section 2.7. Its first-token time must be at most 70% of the cold turn. If it is higher, the prefix cache is not working. Report the fault and try `--checkpoint-min-step` 512.
   - Decode: 128 tokens with thinking off, median of three runs.
   - Tool-call check: five bundled prompts that need a schema-valid call. All five must pass. A failure removes that quant or engine from the choice.
5. **Decide.** Accept the rung if all four conditions hold. Otherwise step down one rung and repeat, at most three times.
   - The reference turn takes at most 6 s.
   - Decode runs at 15 tok/s or more.
   - Peak memory stays under the fit rule.
   - The system shows no new page-outs.
6. **Deep lane.** Use the limits 20 s, 8 tok/s, and the same memory rule. For a dense model, run a 150-token answer with and without MTP. Keep MTP if the full answer finishes 15% faster.
7. **Engine test.** If another local server exists, run steps 4 and 5 on it with the same rung and a quality-matched quant. Define the total time as the cold turn plus the reference turn plus a 150-token answer. Switch the Mac to that engine if its total time is at least 25% lower and the tool-call check passes.
8. **Save.** Write `bench.json` with the fingerprint, engine version, model hash, and results. Run the test again when the macOS build, engine, or model changes. Show the user one plain sentence, for example "Perry answers screen questions in about 4 seconds on this Mac."

### 6.4 New dependencies that need owner approval

AGENTS.md requires approval for new third-party dependencies. The list below separates what the default path needs from what only the benchmark needs.

| # | Dependency | Licence | Size | Role | Request |
|---|---|---|---|---|---|
| 1 | llama.cpp `llama-server` binary, release b11871 or newer | MIT | 15 MiB tarball | Default engine, run as a helper process | **Approve.** Perry must sign and notarise it, because the release is unsigned ([LCPP-REL]). |
| 2 | Model files from Hugging Face: Unsloth GGUF builds of Qwen3.5, Qwen3.6, and Qwen3.8 | Apache-2.0 (base models) | 3.6 to 47 GB per tier | Weights, downloaded after user consent | **Approve.** |
| 3 | Apple FoundationModels framework | System | 0 | Helper model | No approval needed. |
| 4 | Splash 1.4.0 | Apache-2.0 | 76 MB | Opt-in accelerator on M3 or newer with 36 GB or more | **Approve for Perry-bench only.** Decide on shipping after the test. |
| 5 | An MLX server for the engine test (oMLX, Apache-2.0, or `mlx-lm`, MIT) | Apache-2.0 or MIT | Python | Challenger in Perry-bench | **Approve for Perry-bench only.** Do not ship. |
| 6 | mlx-swift-lm | MIT | Swift package | Secondary engine and FoundationModels bridge | **Defer** until pull request 661 merges. |
| 7 | PrismML-Eng llama.cpp fork (release prism-b10822, which trails upstream by about 1,000 builds) | MIT | Prebuilt binaries | Ternary Bonsai deep lane on 16 to 32 GB | **Defer.** Ask again after Perry-bench shows a gain. |

No Swift package links against llama.cpp. Perry runs the binary as a helper process, so a licence notice file is enough and a crash cannot take down the app.

### 6.5 Honest gap to the cloud

All numbers in this section come from section 3.1 unless the text names a source.

| Measure | Best local | Cloud reference | Source and label |
|---|---|---|---|
| Intelligence Index | 33.7 (Qwen3.8-27B, xhigh); 27.6 at medium; 15.2e for the MoE model with thinking off | 57.6 (Claude Opus 5.5, max effort) | VERIFIED, independent [AA] |
| tauBanking (tool use over many steps) | 48.0 (27B, xhigh); 9.3 (MoE); 7.0 (9B) | not listed | VERIFIED, independent [AA] |
| OSWorld 2.0 (computer use) | 61.7 (Holo4-27B, H Company harness) | 81.8 (Opus 5.5) | VENDOR [HOLO4] |
| Decode speed | 10 to 93 tok/s by tier | not measured | Section 6.1 |
| Time to first token for a screenshot turn | 0.8 to 15 s by tier | not measured | Section 6.1 |

What the gap means for Perry:

1. **Local handles:** questions about the screen, summaries, explanations of a menu or setting, single-step actions that the accessibility tree grounds, dictation clean-up, routing, and titles.
2. **Local struggles:** plans with many steps across several apps, long documents, code-heavy work, and any task where the first attempt fails. The MoE model scores 9.3 on tauBanking and the 27B model scores 48.0 only at xhigh effort. At xhigh effort a Mac needs minutes per answer.
3. **Escalate to the cloud when the user allows it.** Escalate after two failed local attempts, on request for "think harder", and for tasks over about 12K context tokens. An 8 GB Mac should use the cloud path for the brain and keep the 4B model as an offline mode.
4. **The 27B deep lane closes part of the gap at a cost in time.** It moves the index from 15.2e to 27.6 at medium effort. It also takes 15 s for a screenshot turn on this Mac, and its answer may need 20 to 60 s more.
5. **Local keeps what the cloud cannot:** screen content stays on the Mac, there is no per-turn cost, and the model works offline.


---

## 7. Open items and the Perry-bench plan

These tests close the gaps that the sources could not close. Run them on mac-tailscale and not on the owner's MacBook, as the project memory requires. Record the chip and memory of mac-tailscale first. A machine other than an M4 Pro with 48 GB gives anchors for the scaling rules in section 2, not results for this Mac.

| ID | Question | Method | Pass rule |
|---|---|---|---|
| P1 | Which engine is fastest on an M4 Pro 48 GB at equal quality? | Run `llama-server` b11871 (UD-Q4_K_XL), an MLX server (6-bit and 4-bit), and Splash 1.4.0 (same GGUF). Time the cold turn and the reference turn (section 6.3), decode, memory, page-outs, and Splash SSD writes per hour. | Apply the 25% rule from section 6.3. Match quality by KL divergence (0.02 or lower). |
| P2 | Does prefix reuse work on the Qwen3.5 hybrid models with images? | Time the cold turn and the reference turn (section 6.3) with the default and with `--checkpoint-min-step` 1024 and 512. Resend reasoning text byte for byte. Repeat with the screenshot placed last. | The reference turn takes at most 70% of the cold turn (issues 26994 and 30357). |
| P3 | Does MTP pay on an M4 Pro with llama.cpp? | Use `--spec-draft-n-max` 2 and 3. Test the 27B model (separate head file) and the MoE model (MTP repository), with `--mmproj`. Record the acceptance rate and the 150-token answer time. | Gain of 15% or more on the full answer. |
| P4 | Do the challenger models beat the defaults? | Run 50 Perry tasks (screen questions, one-step actions, five-step plans). Compare Ornith-1.5-9B with Qwen3.5-9B, Ornith-1.5-35B-A3B and Holo4-35B-A3B with Qwen3.6-35B-A3B, Holo-3.1-4B and 9B with Qwen3.5-4B and 9B, and Swift-1.5-27B with Qwen3.8-27B. | Plus 5 points of task success, equal chat quality, and no more invalid calls. |
| P5 | What does the image-token cap cost in accuracy? | Time the vision encoder at 320, 640, and 1,260 tokens on M1, M2, M4 base, and M4 Pro chips. Score 30 click-target tasks at each cap. | Encoder time within 30% of the curve in section 2.6. Choose the cap where accuracy loses 3 points or less. |
| P6 | Do `q8_0` KV and the chosen weight quant keep tool calls valid? | Compare f16 and `q8_0` KV, and UD-Q4_K_XL against UD-Q6_K, over 100 tool calls each. Tool calls are the worst category for weight quantisation on the 35B-A3B model ([LOCALBENCH-35]). | No rise in invalid calls. |
| P7 | Does Ternary Bonsai beat the 9B model on an M5 with 16 to 24 GB? | Use the Prism fork. Match memory, and run the P4 tasks. | Plus 5 points of task success at equal first-token time. |
| P8 | Can SSD expert streaming give a 16 or 24 GB Mac a 35B-A3B brain? | Test Edge0 (Python and MLX) and Splash `--expert-memory` against the 9B model in llama.cpp. | Higher task success and a first token under 12 s for the deep lane. |
| P9 | How does unload behave? | Measure resident memory after `--sleep-idle-seconds`. Time reload with a cold and a warm page cache. Test `--slot-save-path` across sleep for hybrid state. Provoke memory pressure. | Resident memory under 0.3 GB after sleep. Reload under 6 s on the M4 Pro. |
| P10 | Which helper is best? | Compare Apple Foundation Models, Qwen3.5-0.8B, Qwen3.5-2B, MiniCPM5-2B, and Intern-Decision-4B on 50 routing and extraction prompts. | Highest valid-output rate at a first token under 300 ms. |
| P11 | Does the release binary keep the M5 tensor path? | On an M5 Mac, compare the release binary with a source build made with the Metal 4 SDK. Set `GGML_METAL_TENSOR_DISABLE=1` for the control. | Prefill at least 1.5 times higher with the tensor path on. |
| P12 | Which thinking setting is best for the deep lane? | Compare off, low, and medium effort with budgets of 2,048 and 4,096 tokens. Count loops and score five-step plans. | No loops in 100 runs. Medium beats off by 5 points. |
| P13 | Does a text-only 2B model beat a vision 2B model on 8 GB? | Compare MiniCPM5-2B on accessibility text with Qwen3.5-2B on screenshots. | Higher task success. |
| P14 | Does the repeated-token corruption of issue 23577 appear on Metal? | Soak for two hours. Use multi-turn chats, prefix-sharing follow-ups, four parallel requests, mid-stream cancels, and a fixed canary prompt every minute. Run with and without MTP. | The canary answer never changes. |

Decisions that only the owner can make:

1. Approve the dependencies in section 6.4.
2. Accept a cloud-first product on 8 GB Macs.
3. Approve Splash for Perry-bench, and decide on shipping it after P1.
4. Pick a licence path for three restricted models. Holo4-27B is non-commercial, UI-Venus-2 has a licence pending, and Swift-1.5 has a revenue limit of US$1,000,000 a year.


---

## Appendix A. Raw benchmark tables

These tables hold the source rows behind sections 2 and 4. I copied each row as published. The table notes say where I dropped a column or changed a label.

### A.1 oMLX board rows pulled on 2026-10-25

Source: [OMLX-BOARD]. Each query used the filters model, device, and 4,096-token context, sorted by newest. Columns: chip (GPU cores), memory, model file, quant, prefill tok/s, decode tok/s, date (month-day, 2026). The page shows a check mark on some rows without explaining it, so I omit it.

| Chip | Memory | Model file | Quant | Prefill | Decode | Date |
|---|---|---|---|---:|---:|---|
| M4 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-4bit` | 4bit | 1,106 | 86.6 | 10-25 |
| M4 Pro (20c) | 48 GB | `Qwen3.6-35B-A3B-Abliterated-Heretic-MLX-4bit` | 4bit | 978.0 | 80.0 | 10-24 |
| M4 Pro (20c) | 48 GB | `Qwen3.6-35B-A3B-oQ4e-mtp` | 4bit | 955.0 | 91.1 | 10-24 |
| M4 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-UD-MLX-4bit` | 4bit | 303.3 | 24.7 | 10-24 |
| M4 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit` | 4bit | 1,125 | 90.3 | 10-24 |
| M4 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-UD-MLX-4bit` | 4bit | 115.0 | 9.8 | 10-23 |
| M4 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-UD-MLX-4bit` | 4bit | 208.2 | 14.9 | 10-23 |
| M4 Pro (20c) | 48 GB | `Qwen3.6-35B-A3B-oQ4e-mtp` | 4bit | 891.4 | 53.5 | 10-23 |
| M4 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-4bit` | 4bit | 1,050 | 94.0 | 10-23 |
| M4 Pro (16c) | 64 GB | `Qwen3.6-35B-A3B-4bit` | 4bit | 899.2 | 91.4 | 10-23 |
| M4 Pro (20c) | 24 GB | `Qwen3.5-9B-MLX-8bit` | 8bit | 470.0 | 27.6 | 10-22 |
| M4 Pro (20c) | 64 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 488.4 | 48.7 | 10-21 |
| M4 Pro (20c) | 48 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 481.0 | 49.0 | 10-20 |
| M4 Pro (16c) | 24 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 383.9 | 48.2 | 10-19 |
| M4 Pro (20c) | 24 GB | `DeepSeek-V4-Pro-Qwen3.5-9B-4bit` | 4bit | 469.0 | 47.8 | 10-18 |
| M4 Pro (16c) | 48 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 379.9 | 47.3 | 10-16 |
| M4 Pro (16c) | 48 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 376.1 | 45.7 | 10-16 |
| M4 Pro (16c) | 48 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 371.7 | 44.8 | 10-16 |
| M4 Pro (16c) | 48 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 375.9 | 46.2 | 10-16 |
| M4 Pro (16c) | 48 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 375.9 | 46.8 | 10-16 |
| M4 Pro (16c) | 24 GB | `Qwen3.5-4B-OptiQ-4bit` | 4bit | 624.6 | 41.1 | 10-20 |
| M4 Pro (16c) | 24 GB | `Qwen3.5-4B-OptiQ-4bit` | 4bit | 662.3 | 57.7 | 10-20 |
| M4 Pro (16c) | 24 GB | `Qwen3.5-4B-MLX-4bit` | 4bit | 683.9 | 79.6 | 10-19 |
| M4 Pro (16c) | 24 GB | `Rapid42--Qwen3.5-4B-MXFP4` | 4bit | 689.2 | 83.9 | 10-19 |
| M4 Pro (16c) | 24 GB | `Qwen3.5-4B-oQ6` | 6bit | 690.1 | 58.8 | 10-19 |
| M4 Pro (16c) | 24 GB | `Qwen3.5-4B-oQ6` | 6bit | 687.3 | 58.7 | 10-19 |
| M4 Pro (16c) | 48 GB | `Qwen3.5-4B-oQ4e-mtp` | 4bit | 687.7 | 75.0 | 10-15 |
| M4 Pro (16c) | 24 GB | `Qwen3.5-4B-MLX-4bit` | 4bit | 589.6 | 71.6 | 10-11 |
| M4 Pro (20c) | 48 GB | `Qwen3.5-4B-4bit` | 4bit | 843.0 | 80.1 | 10-10 |
| M4 Pro (16c) | 48 GB | `Qwen3.5-4B-MLX-4bit` | 4bit | 653.1 | 72.4 | 10-09 |
| M4 Pro (20c) | 48 GB | `mlx-community--Qwen3.6-27B-OptiQ-4bit` | 4bit | 131.3 | 12.9 | 10-12 |
| M4 Pro (20c) | 48 GB | `mlx-community--Qwen3.6-27B-OptiQ-4bit` | 4bit | 132.3 | 12.8 | 10-12 |
| M4 Pro (16c) | 48 GB | `Qwen3.6-27B-8bit` | 8bit | 106.0 | 8.6 | 10-07 |
| M4 Pro (20c) | 64 GB | `Qwen3.6-27B-oQ4e-mtp` | 4bit | 109.1 | 25.1 | 10-01 |
| M4 Pro (20c) | 48 GB | `Qwen3.6-27B-MLX-4bit` | 4bit | 131.8 | 14.8 | 09-28 |
| M4 Pro (20c) | 48 GB | `Qwen3.6-27B-oQ4e-mtp` | 4bit | 129.9 | 27.3 | 09-27 |
| M4 Pro (20c) | 48 GB | `Qwen3.6-27B-oQ4e-mtp` | 4bit | 134.8 | 14.4 | 09-27 |
| M4 Pro (16c) | 48 GB | `Qwen3.6-27B-oQ4e-mtp` | 4bit | 105.6 | 13.6 | 09-25 |
| M4 Pro (16c) | 48 GB | `Qwen3.6-27B-oQ4e-mtp` | 4bit | 108.8 | 14.7 | 09-25 |
| M4 Pro (16c) | 48 GB | `Qwen3.6-27B-oQ4e-mtp` | 4bit | 105.5 | 13.6 | 09-25 |
| M4 Pro (20c) | 48 GB | `mlx-community--Qwen3.8-27B-Uncensored-OptiQ-4bit` | 4bit | 132.6 | 12.4 | 10-25 |
| M4 Pro (20c) | 48 GB | `mlx-community--Qwen3.8-27B-Uncensored-OptiQ-4bit` | 4bit | 131.9 | 12.3 | 10-25 |
| M4 Pro (20c) | 48 GB | `Qwen3.8-27B-oQ4e-mtp` | 4bit | 131.1 | 29.7 | 10-25 |
| M4 Pro (20c) | 48 GB | `Qwen3.8-27B-4bit` | 4bit | 134.7 | 15.3 | 10-25 |
| M4 Pro (16c) | 48 GB | `Qwen3.8-27B-oQ4e-mtp` | 4bit | 106.7 | 26.7 | 10-24 |
| M4 Pro (20c) | 48 GB | `Qwen3.8-27B-oQ4e-mtp` | 4bit | 130.5 | 20.2 | 10-24 |
| M4 Pro (20c) | 48 GB | `Qwen3.8-27B-oQ4e-mtp` | 4bit | 127.3 | 27.5 | 10-24 |
| M4 Pro (20c) | 64 GB | `Qwen3.8-27B-Uncensored-OptiQ-4bit` | 4bit | 129.1 | 11.9 | 10-23 |
| M4 Pro (20c) | 48 GB | `Qwen3.8-27B-oQ4e-mtp` | 4bit | 127.2 | 26.0 | 10-23 |
| M4 Pro (20c) | 48 GB | `Qwen3.8-27B-MLX-4bit` | 4bit | 187.4 | 14.8 | 10-23 |
| M5 Pro (16c) | 48 GB | `Qwen3.6-35B-A3B-Claude-4.7-Opus-Reasoning-Distilled-MLX-oQ4-MTP` | 4bit | 1,528 | 92.8 | 10-25 |
| M5 Pro (20c) | 64 GB | `Huihui-Qwen3.6-35B-A3B-abliterated-4.4bit-msq` | 4bit | 1,953 | 77.1 | 10-25 |
| M5 Pro (20c) | 64 GB | `Huihui-Qwen3.6-35B-A3B-abliterated-oQ4e-mtp` | 4bit | 3,226 | 111.5 | 10-25 |
| M5 Pro (16c) | 64 GB | `Qwen3.6-35B-A3B-oQ8e-mtp` | 8bit | 1,756 | 82.0 | 10-25 |
| M5 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-4bit` | 4bit | 3,465 | 108.2 | 10-24 |
| M5 Pro (20c) | 64 GB | `Jundot--Qwen3.6-35B-A3B-oQ4e-mtp` | 4bit | 1,753 | 59.3 | 10-24 |
| M5 Pro (20c) | 64 GB | `Jundot--Qwen3.6-35B-A3B-oQ4e-mtp` | 4bit | 829.0 | 53.5 | 10-24 |
| M5 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-4bit` | 4bit | 2,126 | 108.6 | 10-24 |
| M5 Pro (20c) | 48 GB | `Qwen3.6-35B-A3B-4bit` | 4bit | 2,066 | 107.2 | 10-24 |
| M5 Pro (20c) | 64 GB | `Qwen3.6-35B-A3B-oQ8e-mtp` | 8bit | 1,740 | 87.0 | 10-23 |
| M2 Max (38c) | 96 GB | `Qwen3.6-35B-A3B-oQ8e-mtp` | 8bit | 889.2 | 60.4 | 10-25 |
| M2 Max (38c) | 96 GB | `Qwen3.6-35B-A3B-oQ8e-mtp` | 8bit | 842.4 | 60.8 | 10-25 |
| M2 Max (30c) | 64 GB | `Qwen3.6-35B-A3B-oQ5e-fp16-mtp` | 5bit | 1,096 | 80.7 | 10-24 |
| M2 Max (30c) | 64 GB | `Qwen3.6-35B-A3B-refusal-ablated-MLX-oQ6-fp16-mtp` | 6bit | 1,157 | 76.3 | 10-24 |
| M2 Max (30c) | 64 GB | `Qwen3.6-35B-A3B-refusal-ablated-MLX-oQ6-fp16-mtp` | 6bit | 1,139 | 81.4 | 10-24 |
| M2 Max (38c) | 96 GB | `Qwen3.6-35B-A3B-Uncensored-Genesis-Final-dequantized-oQ8e-fp16-mtp` | 8bit | 944.4 | 56.9 | 10-24 |
| M2 Max (30c) | 64 GB | `Qwen3.6-35B-A3B-uncensored-heretic-oQ8-fp16-mtp` | 8bit | 1,160 | 77.5 | 10-23 |
| M2 Max (30c) | 64 GB | `Qwen3.6-35B-A3B-uncensored-heretic-oQ8-fp16-mtp` | 8bit | 1,117 | 86.2 | 10-23 |
| M2 Max (38c) | 64 GB | `Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit` | 4bit | 623.5 | 73.2 | 10-23 |
| M2 Max (30c) | 64 GB | `Qwen3.6-35B-A3B-UD-MLX-4bit` | 4bit | 798.7 | 78.3 | 10-23 |
| M4 (10c) | 16 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 309.8 | 19.3 | 10-23 |
| M4 (10c) | 24 GB | `Qwen3.5-9B-OptiQ-4bit` | 4bit | 226.1 | 14.9 | 10-23 |
| M4 (10c) | 16 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 250.5 | 18.3 | 10-22 |
| M4 (10c) | 16 GB | `Qwen3.5-9B-MLX-8bit` | 8bit | 235.1 | 12.0 | 10-21 |
| M4 (10c) | 16 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 240.5 | 20.7 | 10-20 |
| M4 (10c) | 32 GB | `Qwen3.5-9B-MLX-8bit` | 8bit | 234.9 | 10.8 | 10-20 |
| M4 (10c) | 24 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 241.6 | 21.3 | 10-19 |
| M4 (10c) | 24 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 241.1 | 21.2 | 10-19 |
| M4 (10c) | 24 GB | `Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-MLX-4bit` | 4bit | 199.8 | 16.5 | 10-19 |
| M4 (10c) | 24 GB | `Qwen3.5-9B-oQ4e-mtp` | 4bit | 191.8 | 28.8 | 10-19 |
| M5 (10c) | 32 GB | `Qwen3.5-9B-4bit` | 4bit | 340.7 | 13.9 | 10-24 |
| M5 (10c) | 24 GB | `Qwen3.5-9B-OptiQ-4bit` | 4bit | 859.4 | 19.7 | 10-23 |
| M5 (10c) | 16 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 737.0 | 23.4 | 10-23 |
| M5 (10c) | 24 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 754.7 | 25.8 | 10-22 |
| M5 (8c) | 16 GB | `Qwen3.5-9B-oQ4e-mtp` | 4bit | 639.1 | 29.0 | 10-21 |
| M5 (10c) | 24 GB | `Qwen3.5-9B-MLX-4bit` | 4bit | 770.4 | 24.6 | 10-21 |
| M5 (10c) | 24 GB | `Qwen3.5-9B-oQ4e-mtp` | 4bit | 971.6 | 45.9 | 10-21 |
| M5 (10c) | 24 GB | `Qwen3.5-9B-OptiQ-4bit` | 4bit | 872.7 | 19.7 | 10-20 |
| M5 (10c) | 24 GB | `Qwen3.5-9B-MLX-8bit` | 8bit | 670.9 | 13.1 | 10-20 |
| M5 (10c) | 24 GB | `Qwen3.5-9B-MLX-8bit` | 8bit | 707.7 | 13.6 | 10-20 |
| M2 (10c) | 16 GB | `MLX-Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled-4bit` | 4bit | 241.9 | 27.6 | 10-19 |
| M2 (10c) | 16 GB | `MLX-Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled-4bit` | 4bit | 264.0 | 30.6 | 10-19 |
| M2 (10c) | 16 GB | `MLX-Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled-4bit` | 4bit | 235.5 | 30.1 | 10-12 |
| M2 (10c) | 16 GB | `Qwen3.5-4B-MLX-4bit` | 4bit | 237.1 | 30.8 | 09-28 |
| M2 (10c) | 24 GB | `Qwen3.5-4B-MLX-4bit` | 4bit | 238.1 | 30.6 | 09-25 |
| M2 (10c) | 24 GB | `semif-qwen3.5-4b-mlx-4bit` | 4bit | 210.4 | 29.5 | 09-23 |
| M2 (10c) | 24 GB | `Qwen3.5-4B-oQ6` | 6bit | 197.4 | 20.4 | 09-19 |
| M2 (8c) | 16 GB | `Qwen3.5-4B-Instruct-MLX-Q6` | 6bit | 166.3 | 22.1 | 08-27 |
| M2 (10c) | 16 GB | `Qwen3.5-4B-MTPLX-Optimized-Quality` | 8bit | 198.5 | 17.8 | 08-21 |
| M2 (10c) | 16 GB | `Qwen3.5-4B-MTPLX-Optimized-Quality` | 8bit | 200.0 | 17.9 | 08-19 |

### A.2 llama-bench results for a 7B model (Llama-2 7B, 512-token prompt, 128 generated tokens)

Source: [LCPP-4167] (VERIFIED, community-submitted, one commit per generation: 8e672ef for M1 to M4, c1d0e7a for M5 and M6). PP is prompt speed and TG is generation speed, both in tok/s. Sizes: F16 12.55 GiB, Q8_0 6.67 GiB, Q4_0 3.56 GiB. An empty cell means the page shows no value. The M6 row lists 8 GPU cores, while [WIKI-M6] and [APPLE-M6] state 12. I did not resolve the difference.

| Chip | GB/s | GPU cores | F16 PP | F16 TG | Q8_0 PP | Q8_0 TG | Q4_0 PP | Q4_0 TG |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| M1 | 68 | 7 |  |  | 108.21 | 7.92 | 107.81 | 14.19 |
| M1 | 68 | 8 |  |  | 117.25 | 7.91 | 117.96 | 14.15 |
| M1 Pro | 200 | 14 | 262.65 | 12.75 | 235.16 | 21.95 | 232.55 | 35.52 |
| M1 Pro | 200 | 16 | 302.14 | 12.75 | 270.37 | 22.34 | 266.25 | 36.41 |
| M1 Max | 400 | 24 | 453.03 | 22.55 | 405.87 | 37.81 | 400.26 | 54.61 |
| M1 Max | 400 | 32 | 599.53 | 23.03 | 537.37 | 40.2 | 530.06 | 61.19 |
| M1 Ultra | 800 | 48 | 875.81 | 33.92 | 783.45 | 55.69 | 772.24 | 74.93 |
| M1 Ultra | 800 | 64 | 1168.89 | 37.01 | 1042.95 | 59.87 | 1030.04 | 83.73 |
| M2 | 100 | 8 |  |  | 147.27 | 12.18 | 145.91 | 21.7 |
| M2 | 100 | 10 | 201.34 | 6.72 | 181.4 | 12.21 | 179.57 | 21.91 |
| M2 Pro | 200 | 16 | 312.65 | 12.47 | 288.46 | 22.7 | 294.24 | 37.87 |
| M2 Pro | 200 | 19 | 384.38 | 13.06 | 344.5 | 23.01 | 341.19 | 38.86 |
| M2 Max | 400 | 30 | 600.46 | 24.16 | 540.15 | 39.97 | 537.6 | 60.99 |
| M2 Max | 400 | 38 | 755.67 | 24.65 | 677.91 | 41.83 | 671.31 | 65.95 |
| M2 Ultra | 800 | 60 | 1128.59 | 39.86 | 1003.16 | 62.14 | 1013.81 | 88.64 |
| M2 Ultra | 800 | 76 | 1401.85 | 41.02 | 1248.59 | 66.64 | 1238.48 | 94.27 |
| M3 | 100 | 10 |  |  | 187.52 | 12.27 | 186.75 | 21.34 |
| M3 Pro | 150 | 14 |  |  | 272.11 | 17.44 | 269.49 | 30.65 |
| M3 Pro | 150 | 18 | 357.45 | 9.89 | 344.66 | 17.53 | 341.67 | 30.74 |
| M3 Max | 300 | 30 | 589.41 | 19.54 | 566.4 | 34.3 | 567.59 | 56.58 |
| M3 Max | 400 | 40 | 779.17 | 25.09 | 757.64 | 42.75 | 759.7 | 66.31 |
| M3 Ultra | 800 | 60 | 1121.80 | 42.24 | 1085.76 | 63.55 | 1073.09 | 88.40 |
| M3 Ultra | 800 | 80 | 1538.34 | 39.78 | 1487.51 | 63.93 | 1471.24 | 92.14 |
| M4 | 120 | 10 | 230.18 | 7.43 | 223.64 | 13.54 | 221.29 | 24.11 |
| M4 Pro | 273 | 16 | 381.14 | 17.19 | 367.13 | 30.54 | 364.06 | 49.64 |
| M4 Pro | 273 | 20 | 464.48 | 17.18 | 449.62 | 30.69 | 439.78 | 50.74 |
| M4 Max | 410 | 32 | 736.25 | 24.29 | 718.56 | 43.87 | 713.93 | 69.95 |
| M4 Max | 546 | 40 | 922.83 | 31.64 | 891.94 | 54.05 | 885.68 | 83.06 |
| M5 | 154 | 10 |  |  | 715.42 | 18.42 | 722.79 | 31.88 |
| M5 Pro | 307 | 16 | 1310.78 | 21.39 | 1302.59 | 38.94 | 1340.44 | 67.59 |
| M5 Pro | 307 | 20 | 1588.78 | 21.55 | 1553.86 | 38.92 | 1620.64 | 66.33 |
| M5 Max | 614 | 40 | 3158.49 | 37.11 | 3143.81 | 72.42 | 3219.99 | 119.92 |
| M5 Ultra | 1228 | 80 | 5207.14 | 73.60 | 4910.55 | 119.01 | 4944.66 | 179.10 |
| M6 | 170 | 8 | 952.53 | 11.59 | 970.46 | 21.01 | 988.93 | 35.74 |

### A.3 M5 Max 128 GB: llama.cpp against MLX (one author, 2026-06-14, llama.cpp build 9430)

Source: [STARED] (VERIFIED, independent). The run used 400 generated tokens, the median of several trials, and Qwen3.6 models at 8-bit. TTFT is time to first token. RSS is resident memory.

| Setup | Prompt | Prefill tok/s | Decode tok/s | TTFT s | RSS GB | Load s |
|---|---|---:|---:|---:|---:|---:|
| llama.cpp 35B-A3B Q8_0 | 128tok (142 tok) | 1113.0 | 92.9 | 0.128 | 44.1 | 2.1 |
| llama.cpp 35B-A3B Q8_0 | 1k (1038 tok) | 2455.1 | 91.6 | 0.423 | 44.1 | 2.1 |
| llama.cpp 35B-A3B Q8_0 | 4k (4112 tok) | 2725.5 | 89.2 | 1.509 | 44.1 | 2.1 |
| llama.cpp 35B-A3B Q8_0 | 8k (8207 tok) | 2461.9 | 86.9 | 3.334 | 44.1 | 2.1 |
| llama.cpp 27B Q8_0 | 128tok (143 tok) | 355.0 | 18.4 | 0.403 | 41.3 | 2.2 |
| llama.cpp 27B Q8_0 | 1k (1039 tok) | 627.8 | 18.3 | 1.655 | 41.3 | 2.2 |
| llama.cpp 27B Q8_0 | 4k (4112 tok) | 647.7 | 17.7 | 6.348 | 41.3 | 2.2 |
| llama.cpp 27B Q8_0 | 8k (8207 tok) | 567.3 | 17.0 | 14.467 | 41.3 | 2.2 |
| llama.cpp 35B-A3B Q8_0 +MTP | 128tok (143 tok) | 929.9 | 104.6 | 0.154 | 45.0 | 3.2 |
| llama.cpp 35B-A3B Q8_0 +MTP | 1k (1039 tok) | 2050.0 | 95.0 | 0.507 | 45.0 | 3.2 |
| llama.cpp 35B-A3B Q8_0 +MTP | 4k (4112 tok) | 2129.5 | 97.1 | 1.931 | 45.0 | 3.2 |
| llama.cpp 35B-A3B Q8_0 +MTP | 8k (8207 tok) | 1989.8 | 96.8 | 4.124 | 45.0 | 3.2 |
| llama.cpp 27B Q8_0 +MTP | 128tok (143 tok) | 248.1 | 31.7 | 0.576 | 42.5 | 2.3 |
| llama.cpp 27B Q8_0 +MTP | 1k (1039 tok) | 469.7 | 30.8 | 2.212 | 42.5 | 2.3 |
| llama.cpp 27B Q8_0 +MTP | 4k (4112 tok) | 540.6 | 31.5 | 7.607 | 42.5 | 2.3 |
| llama.cpp 27B Q8_0 +MTP | 8k (8207 tok) | 520.8 | 29.9 | 15.76 | 42.5 | 2.3 |
| MLX 35B-A3B 8bit | 128tok (144 tok) | 502.0 | 84.5 | 0.287 | 36.6 | 4.9 |
| MLX 35B-A3B 8bit | 1k (1040 tok) | 2350.9 | 83.5 | 0.442 | 36.6 | 4.9 |
| MLX 35B-A3B 8bit | 4k (4113 tok) | 3314.1 | 81.2 | 1.241 | 36.6 | 4.9 |
| MLX 35B-A3B 8bit | 8k (8208 tok) | 3092.7 | 79.4 | 2.654 | 36.6 | 4.9 |
| MLX 27B 8bit | 128tok (144 tok) | 252.5 | 17.3 | 0.57 | 28.4 | 4.2 |
| MLX 27B 8bit | 1k (1040 tok) | 641.3 | 17.2 | 1.622 | 28.4 | 4.2 |
| MLX 27B 8bit | 4k (4113 tok) | 670.3 | 17.0 | 6.136 | 28.4 | 4.2 |
| MLX 27B 8bit | 8k (8208 tok) | 637.1 | 17.1 | 12.883 | 28.4 | 4.2 |

### A.4 M2 Max 32 GB: one author's runs (RaynarDM)

Source: [RAYNAR] (VERIFIED, one author, 1 to 5 runs per row). Models are Qwen3.6-35B-A3B (MoE) and Qwen3.8-27B (dense). Engine names are as the author wrote them.

| Test | Model | Quant | Engine and setting | Metric | Value |
|---|---|---|---|---|---|
| arch_compare | Qwen3.6-35B-A3B | Q4_K_M | llama.cpp, default | pp4096 | 671.40 tok/s |
| arch_compare | Qwen3.6-35B-A3B | Q4_K_M | llama.cpp, default | tg128 | 58.56 tok/s |
| arch_compare | Qwen3.8-27B | IQ3_S | llama.cpp, default | pp4096 | 106.78 tok/s |
| arch_compare | Qwen3.8-27B | IQ3_S | llama.cpp, default | tg128 | 10.82 tok/s |
| quant_sweep | Qwen3.8-27B | IQ4_XS | ollama, 32k ctx q8_0 kv | generation | 10.5 tok/s |
| quant_sweep | Qwen3.8-27B | IQ2_S | ollama, 32k ctx q8_0 kv | generation | 11.9 tok/s |
| mtp_cost | Qwen3.6-35B-A3B | Q4_K_M | ollama, 32k ctx q8_0 kv draft-mtp n=2 | generation | 34.6 tok/s |
| mtp_cost | Qwen3.6-35B-A3B | Q4_K_M | ollama, 32k ctx q8_0 kv no draft | generation | 46.2 tok/s |
| mtp_depth | Qwen3.6-35B-A3B | Q4_K_M | ollama, draft-mtp n=2 | generation | 42.0 tok/s |
| mtp_depth | Qwen3.6-35B-A3B | Q4_K_M | ollama, draft-mtp n=4 | generation | 29.4 tok/s |
| mtp_depth | Qwen3.6-35B-A3B | Q4_K_M | ollama, draft-mtp n=6 | generation | 20.1 tok/s |
| mtp_depth | Qwen3.6-35B-A3B | Q4_K_M | ollama, draft-mtp n=8 | generation | 17.1 tok/s |
| kv_cache | Qwen3.6-35B-A3B | Q4_K_M | llama.cpp, f16 kv | tg128 | 58.55 tok/s |
| kv_cache | Qwen3.6-35B-A3B | Q4_K_M | llama.cpp, q8_0 kv | tg128 | 57.25 tok/s |
| engine_compare | Qwen3.6-35B-A3B | 4bit | mlx-lm, alone on gpu | prefill | 296 tok/s |
| engine_compare | Qwen3.6-35B-A3B | 4bit | mlx-lm, alone on gpu | generation | 86.9 tok/s |
| engine_compare | Qwen3.6-35B-A3B | Q4_K_M | llama.cpp, alone on gpu | prefill | 685 tok/s |
| engine_compare | Qwen3.6-35B-A3B | Q4_K_M | llama.cpp, alone on gpu | generation | 57.8 tok/s |
| sample_length | Qwen3.6-35B-A3B | Q4_K_M | ollama, 24-token sample | generation | 56.5 tok/s |
| sample_length | Qwen3.6-35B-A3B | Q4_K_M | ollama, 700-token sample | generation | 41.0 tok/s |
| quant_sweep | Qwen3.8-27B | 4bit | oMLX, 8k ctx, MLX affine (not GGUF), balanced guard, ssd cache on | pp8192 | 84 tok/s |
| quant_sweep | Qwen3.8-27B | 4bit | oMLX, 8k ctx, MLX affine (not GGUF), balanced guard, ssd cache on | generation | 13.7 tok/s |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, code prompt, 256 tok, no spec decoding | generation | 10.53 tok/s |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, code prompt, 256 tok, draft-dflash n-max 7 | generation | 10.18 tok/s |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, math prompt, 256 tok, no spec decoding | generation | 10.30 tok/s |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, math prompt, 256 tok, draft-dflash n-max 7 | generation | 9.81 tok/s |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, prose prompt, 256 tok, no spec decoding | generation | 10.29 tok/s |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, prose prompt, 256 tok, draft-dflash n-max 7 | generation | 6.13 tok/s |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, code prompt, draft-dflash n-max 7 | draft_acceptance | 0.76 ratio |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, math prompt, draft-dflash n-max 7 | draft_acceptance | 0.72 ratio |
| dflash2 | Qwen3.8-27B | IQ3_S | llama.cpp, prose prompt, draft-dflash n-max 7 | draft_acceptance | 0.35 ratio |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, code prompt 256 tok no spec | generation | 55.28 tok/s |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, code prompt 256 tok draft-dflash n-max 7 | generation | 49.26 tok/s |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, math prompt 256 tok no spec | generation | 52.09 tok/s |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, math prompt 256 tok draft-dflash n-max 7 | generation | 48.50 tok/s |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, prose prompt 256 tok no spec | generation | 51.02 tok/s |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, prose prompt 256 tok draft-dflash n-max 7 | generation | 30.79 tok/s |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, code prompt draft-dflash n-max 7 | draft_acceptance | 0.60 ratio |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, math prompt draft-dflash n-max 7 | draft_acceptance | 0.59 ratio |
| dflash2 | Qwen3.6-35B-A3B | IQ3_S | llama.cpp, prose prompt draft-dflash n-max 7 | draft_acceptance | 0.28 ratio |

### A.5 Splash vendor tables

Source: [SPLASH-PERF] (VENDOR). No independent run exists. Every table uses selected SPEED-Bench coding prompts over HTTP and a 1,024-token output limit. The page names llama.cpp commit e6ab7c1 on Metal for the comparison. The llama.cpp server ran with default settings, so it did not speculate, except in the rows marked MTP.

Table 1: Splash 1.0 launch run on an M5 Pro (16-core GPU, 48 GB). The ratio is against the next-fastest engine that the authors measured.

| Metric | Qwen3.6-35B-A3B | Qwen3.8-27B |
|---|---:|---:|
| Decode, short prompt | 210 tok/s (1.7 times) | 74 tok/s (2.0 times) |
| Prefill, 32K prompt | 2,011 tok/s (1.3 times) | 363 tok/s (1.2 times) |
| Cached time to first token, 32K replay | 123 ms (6.6 times) | 282 ms (7.3 times) |
| Aggregate decode, 4 concurrent short prompts | 357 tok/s (2.0 times) | 170 tok/s (3.9 times) |

Table 2: Splash against llama.cpp on the same Unsloth UD-Q4_K_M files. Decode in tok/s.

| Model and engine | M5 Pro, 20-core GPU | M3 Max, 40-core GPU |
|---|---:|---:|
| Qwen3.6-35B-A3B, Splash | 175 | 209 |
| Qwen3.6-35B-A3B, llama.cpp | 69 | 66 |
| Qwen3.8-27B, Splash | 74 | 92 |
| Qwen3.8-27B, llama.cpp | 16 | 17 |
| Qwen3.8-27B, llama.cpp with MTP | 27 | 20 |

On an M5 Pro, prefill of a 2,048-token chunk runs at 559 tok/s in Splash against 374 in llama.cpp on the 27B model. On the 35B model it runs at 3,662 against 1,968. On the M3 Max the pairs are 245 against 193 and 1,814 against 1,575.

Table 3: agreement of Splash with llama.cpp over 16,384 text positions. A cell gives the share of positions where both engines rank the same token first.

| Comparison | Qwen3.8-27B | Qwen3.6-35B-A3B |
|---|---:|---:|
| Splash and llama.cpp | 99.30 to 99.45% | 97.83 to 98.14% |
| llama.cpp on the CPU and on Metal | 97.8% | 96.5 to 96.9% |
| llama.cpp one token at a time and batched | 99.65 to 99.75% | 97.95% |

Table 4: smaller GGUF files on a 24 GB M6 (12-core GPU) with the DFlash2 draft.

| Unsloth file | Code decode | Advertised context |
|---|---:|---:|
| Qwen3.8-27B UD-IQ3_XXS | 43.5 tok/s | 53,241 tokens (81,913 with `--language-only`) |
| Qwen3.6-35B-A3B UD-Q2_K_XL | 145 tok/s | 256K tokens |

The page also states that the SSD cache wrote 26 GB in 30 minutes (about 50 GB an hour). This happened with a 16 GiB cache on the M6 that served six clients with Ternary-Bonsai-2-27B PQ2_0. A write budget (`--max-cache-disk-writes`) limits that wear. Perry must set a write budget if it ships Splash.

---

## Appendix B. Quantisation and KV cache data

### B.1 KL divergence of Qwen3.6-27B quants against the bf16 model

Source: [KLD] (VERIFIED, generated 2026-07-26, 15 of the 26 rows). Every row uses wikitext-103 text, 512 samples of 512 tokens, and the same settings. Lower KL divergence is better. The bf16 row is the measurement floor, not zero. The model is Qwen3.6-27B, not Qwen3.8-27B. I found no KL data for Qwen3.8-27B or Qwen3.5-9B.

| Quant | Publisher | Format | Size, GB | Bits per weight | Mean KL divergence | Top-1 match |
|---|---|---|---:|---:|---:|---:|
| bf16 (floor) | mlx-community | MLX | 54.71 | 16.00 | 0.0018 | 100.00% |
| UD-Q6_K_XL | unsloth | GGUF | 26.02 | 7.62 | 0.0048 | 98.01% |
| Q6_K | unsloth | GGUF | 22.88 | 6.70 | 0.0065 | 97.52% |
| oQ6 | deepsweet | MLX | 22.49 | 6.69 | 0.0087 | 97.16% |
| 6-bit | mlx-community | MLX | 22.78 | 6.66 | 0.0091 | 96.89% |
| UD-Q5_K_XL | unsloth | GGUF | 20.35 | 5.96 | 0.0094 | 96.86% |
| UD-Q4_K_XL | unsloth | GGUF | 17.91 | 5.24 | 0.0182 | 95.27% |
| Q4_K_M | unsloth | GGUF | 17.11 | 5.01 | 0.0204 | 94.86% |
| 5-bit | mlx-community | MLX | 19.42 | 5.68 | 0.0218 | 94.57% |
| IQ4_XS | unsloth | GGUF | 15.44 | 4.59 | 0.0242 | 94.36% |
| oQ4e-mtp | Jundot | MLX | 17.01 | 4.90 | 0.0397 | 91.69% |
| UD-Q3_K_XL | unsloth | GGUF | 14.47 | 4.30 | 0.0474 | 91.94% |
| 4-bit | mlx-community | MLX | 16.05 | 4.70 | 0.0573 | 89.96% |
| Q3_K_S | unsloth | GGUF | 12.36 | 3.67 | 0.0927 | 88.07% |
| 3-bit | NexVeridian | MLX | 11.77 | 3.50 | 0.2154 | 79.66% |

What the table shows:

1. The IQ4_XS GGUF file is smaller than the MLX 4-bit file (15.44 GB against 16.05 GB) and has 2.4 times lower KL divergence.
2. The UD-Q4_K_XL file has 3.1 times lower KL divergence than the MLX 4-bit file and costs 1.12 times the size.
3. MLX 6-bit (0.0091) beats GGUF UD-Q4_K_XL (0.0182) and costs 1.27 times the size.
4. The oQ4e-mtp build that many oMLX rows use (0.0397) sits between the two.
5. Quality falls fast below 4 bits. Perry should not ship 3-bit builds.
6. Speed rows for MLX 4-bit and GGUF Q4 files therefore do not compare at equal quality.

### B.2 Quantisation of the 35B-A3B model

Source: [LOCALBENCH-35] (VERIFIED, independent, 2026-04-20). The page asks readers not to copy its plots and tables, so I quote its text findings only. The test compared 64 GGUF quants against a bf16 reference on about 250,000 tokens.

- Q8_0 has a mean KL divergence of 0.069. Qwen3.5-35B-A3B has 0.121.
- The UD-Q8_K_XL file (38.4 GB, 0.073) is larger and worse than the ggml-org Q8_0 file (36.9 GB, 0.069).
- Unsloth quants hold 14 of the 26 positions on the size-against-quality frontier. lmstudio-community and mudler never appear on it.
- Tool calling is the worst category at Q8_0 (0.177). Long documents follow (0.121). Coding and science stay at or below 0.010.
- Even the 10.0 GB UD-IQ1_M file keeps 86.9% top-1 match.

Perry uses Unsloth UD files for this reason. Perry-bench test P6 checks whether the chosen quant keeps tool calls valid.

### B.3 KV cache quantisation

Sources: [LOCALBENCH-KV], [LCPP-23470], and [LLMKUBE]. All rows are VERIFIED as published. Rows from one commenter's harness carry the note "one author".

| Setting | Model and test | Result |
|---|---|---|
| `q8_0` for K and V | Qwen3.6-27B (dense) and 35B-A3B (MoE), KL against f16 KV, llama.cpp with attention rotation ([LOCALBENCH-KV]) | 0.024 and 0.039 |
| `q4_0` for K and V | same | 0.087 to 0.117 overall; 0.581 on long documents; 0.086 on tool calling |
| `q8_0` and `q4_0` | Gemma 4 31B and 26B-A4B ([LOCALBENCH-KV]) | `q8_0`: 0.108 and 0.377. `q4_0` on the 26B-A4B: 1.088 with 68.0% top-1 match. |
| K and V pairs | Qwen2.5-7B with Q4_0 weights, wikitext-2, 512 context ([LCPP-23470], opening post) | `q8_0` with `q8_0`: 0.0018. `q8_0` K with `q4_0` V: 0.0048. `f16` K with `q4_0` V: 0.0040. `q4_0` K with `f16` V: 5.49. `q4_0` with `q4_0`: 5.51. |
| K and V pairs, 99th-percentile KL | Qwen3.8-27B UD-Q6_K, wikitext-2, 65,536 context ([LCPP-23470], comment of 2026-09-12) | `q8_0` with `q8_0`: 0.0064. `q8_0` K with `q5_1` V: 0.0076. `q8_0` K with `q4_0` V: 0.0123. `q4_0` with `q4_0`: 0.0221. |
| Changed answers out of 500 against an f16 KV run (one author) | ARC-Challenge questions, grammar-constrained decode, fixed seed, four models ([LCPP-23470], comments of 2026-08-16 and 2026-09-12) | `q8_0` K and V: at most 4 on any model, and none in 1,600 deep-context comparisons to 41K tokens. `q4_0` K and V: Qwen3.6-27B 2, Qwen3.8-27B 3, Mistral-7B 34, Qwen2.5-7B 375. `q4_0` on K alone reproduces the Qwen2.5-7B collapse. `q4_0` on V alone changed 1 answer. |
| Decode speed at depth 0 and at 128K tokens | Qwen3.6-35B-A3B Q8_0 on an M5 Max, llama.cpp fork ([LLMKUBE]) | f16: 89.4 and 44.4 tok/s. `q8_0`: 87.4 and 40.7. TurboQuant 3-bit: 79.5 and 36.0. TurboQuant 4-bit: 79.7 and 37.7. |

Policy for Perry:

1. Use f16 KV on 24 GB and above.
2. Use `q8_0` for both K and V on 8 and 16 GB. It saves 47% of the KV memory in the attention layers.
3. Do not set `q4_0` on K without a Perry-bench run. It broke Qwen2.5-7B and changed 2 to 3 of 500 answers on the 27B models.
4. Do not use TurboQuant types. The upstream `llama-server` accepts only f32, f16, bf16, q8_0, q4_0, q4_1, iq4_nl, q5_0, and q5_1 ([LCPP-SRV]).

### B.4 File sizes of the quant ladder

Source: Hugging Face file listings on 2026-10-25 ([HF-API], VERIFIED). A dash means the repository has no such file. Sizes are decimal GB. The vision column gives the F16 `mmproj` file.

| Model | UD-Q3_K_XL | UD-IQ4_XS | UD-Q4_K_XL | UD-Q5_K_XL | UD-Q6_K | UD-Q6_K_XL | Q8_0 | Vision file |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Qwen3.5-0.8B | 0.49 | - | 0.56 | 0.61 | - | 0.77 | 0.81 | 0.20 |
| Qwen3.5-2B | 1.16 | - | 1.34 | 1.47 | - | 1.86 | 2.01 | 0.67 |
| Qwen3.5-4B | 2.44 | - | 2.91 | 3.25 | - | 4.15 | 4.48 | 0.67 |
| Qwen3.5-9B | 5.05 | - | 5.97 | 6.74 | - | 8.76 | 9.53 | 0.92 |
| Qwen3.6-35B-A3B | 16.85 | 17.73 | 22.36 | 26.59 | 29.31 | 31.84 | 36.90 | 0.90 |
| Qwen3.6-35B-A3B, MTP repository | 17.23 | 18.21 | 22.85 | 27.16 | 30.01 | 32.61 | 37.80 | 0.90 |
| Qwen3.8-27B | 13.15 | 14.25 | 17.56 | 20.88 | 21.98 | 25.30 | 29.05 | 0.93 |

The 27B repository holds a separate MTP head file of 1.37 GB (`MTP/mtp-Qwen3.8-27B-Q4_0.gguf`). Its UD-Q4_K_M file is 16.46 GB and its UD-Q6_K_L file is 24.19 GB.

---

## Appendix C. Tool-call bugs and thinking control

### C.1 Open and recent bugs on the Qwen3.5-family path

I read each page through the GitHub API on 2026-10-25 and checked the state, the date, and the facts below. The date is the day the issue opened. "PR" marks a pull request. A claim that comes only from a sub-agent's reading of code carries the label UNVERIFIED.

| Engine | Item | Effect | State |
|---|---|---|---|
| llama.cpp | [30118](https://github.com/ggml-org/llama.cpp/issues/30118) | Qwen3.6 tool calls leak into `content` when the model omits `<tool_call>`. In 100 requests per build, 9 leaked on build 11382 and none on build 10433 (two machines). A maintainer says the fix waits on PR 29307. | Open, 2026-10-07 |
| llama.cpp | [20837](https://github.com/ggml-org/llama.cpp/issues/20837) | Qwen3.5-9B prints a tool call as XML inside the thinking block and stops. Reported on build 8461 with ROCm. It has 60 comments. I found no confirmed fix. | Open, 2026-03-21 |
| llama.cpp | [29295](https://github.com/ggml-org/llama.cpp/issues/29295) | `tool_choice: "required"` is not enforced by a grammar. With the prompt cache off, 2 of 10 requests answered in plain text (Qwen3-8B, M4 Pro). A warm KV prefix repeats the failure at temperature 0. | Open, 2026-09-23 |
| llama.cpp | [30357](https://github.com/ggml-org/llama.cpp/issues/30357) | Reasoning whitespace does not round-trip through Qwen3.5+ chat templates. Unusual whitespace forces a full re-prefill on hybrid models (Qwen3.8-27B and Qwen3.6-35B-A3B, M2 Ultra, Metal). | Open, 2026-10-11 |
| llama.cpp | [26994](https://github.com/ggml-org/llama.cpp/issues/26994) | The server skips checkpoints after image chunks on hybrid models. The server encodes the image prefix again when only the text after it changes (Qwen3.6 27B and 35B-A3B, M1 Max). Qwen3-VL is not affected. H Company states the same limit in a chart footnote ([HOLO31]). | Open, 2026-08-13 |
| llama.cpp | [23577](https://github.com/ggml-org/llama.cpp/issues/23577) | The server repeats one token (`////`) for every request after a long session. Reporters see it on CUDA, ROCm, and Vulkan, with and without MTP, and on a non-hybrid model. One reporter ties it to re-prefill of a partly matched cached prompt. I found no Metal report in 34 comments. | Open, 2026-05-23 |
| llama.cpp | [PR 30257](https://github.com/ggml-org/llama.cpp/pull/30257) | MTP heads now decode image input. The author's acceptance rate on Qwen3.5-4B-MTP with an image rose from 64 to 78% before the change to 78 to 83% after it. | Merged, 2026-10-10 |
| llama.cpp | [30698](https://github.com/ggml-org/llama.cpp/issues/30698) | Gemma 4 with `--mmproj` and MTP aborts at start-up. A regression from PR 30257. Gemma only. | Open, 2026-10-17 |
| llama.cpp | [23335](https://github.com/ggml-org/llama.cpp/issues/23335) | `draft-mtp` changed deterministic output on Qwen3.6 (M4 Pro, Metal). | Closed, 2026-05-19 |
| llama.cpp | [27023](https://github.com/ggml-org/llama.cpp/issues/27023) | The top-level request field `reasoning_effort` had no effect on Qwen3.8-27B. A maintainer says master fixes it, and a user confirmed it on 0.5.0 on 2026-09-24. The field `chat_template_kwargs.reasoning_effort` worked throughout. | Open, 2026-08-13; fixed |
| llama.cpp | [26781](https://github.com/ggml-org/llama.cpp/issues/26781) | The capability probe forced `enable_thinking` on. | Closed, 2026-09-06 |
| llama.cpp | [30246](https://github.com/ggml-org/llama.cpp/issues/30246) | K2 Horizon at low and medium effort leaves answers and tool calls in `reasoning_content`. PR 30335 is open. | Open, 2026-10-09 |
| llama.cpp | [31000](https://github.com/ggml-org/llama.cpp/issues/31000) | Flint NVFP4 leaves tool-call XML in the reasoning field. | Open, 2026-10-22 |
| llama.cpp | [28675](https://github.com/ggml-org/llama.cpp/issues/28675) | Think tags appear in `content` for LFM2.5-1.2B-Thinking. | Open, 2026-09-09 |
| mlx-lm | [1992](https://github.com/ml-explore/mlx-lm/issues/1992) | The `qwen3_coder` parser cuts a parameter value at the first `</parameter>`. Seen in oMLX and on the current mlx-lm main. | Open, 2026-10-18 |
| mlx-lm | [1946](https://github.com/ml-explore/mlx-lm/issues/1946) | The server omits `tool_calls` from the message but reports `finish_reason` "tool_calls" (mlx-lm 0.32.0 on Linux with CUDA). | Open, 2026-10-04 |
| mlx-lm | [1907](https://github.com/ml-explore/mlx-lm/issues/1907) | The `qwen3_coder` parser returns a raw string for a parameter whose schema has no top-level `type`, for example `oneOf`. Seen in oMLX with Qwen3.6-35B-A3B. | Open, 2026-09-21 |
| mlx-lm | [905](https://github.com/ml-explore/mlx-lm/issues/905) | The `qwen3_coder` parser raised "No function provided" and the request handler printed a traceback (Qwen3.5, February 2026). | Open, 2026-02-18 |
| mlx-lm | [1627](https://github.com/ml-explore/mlx-lm/issues/1627) | The parser rejected float-formatted integers such as "140.0" and dropped the call. | Closed, 2026-08-22 |
| mlx-lm | [1007](https://github.com/ml-explore/mlx-lm/issues/1007) | The server ignores `response_format`. | Open, 2026-03-15 |
| mlx-lm | [1807](https://github.com/ml-explore/mlx-lm/issues/1807) | Memory grows past the prompt-cache cap in multi-day serving (Qwen3.8-27B 4-bit on an M1 Ultra). The reporter killed the server above 30 GB for a 16 GB model with an 8 GB cap. | Open, 2026-08-30 |
| mlx-lm | [1803](https://github.com/ml-explore/mlx-lm/issues/1803) | A per-request `chat_template_kwargs` may bypass the prompt cache (about 23 s of prefill for a 10K-token prefix). Another user could not reproduce it. | Open, 2026-08-29 |
| mlx-lm | [1293](https://github.com/ml-explore/mlx-lm/issues/1293) | A request for a Qwen3.5 and Qwen3.6 tool parser. A sub-agent reports that mlx-lm already maps templates with `<tool_call>` and `<function=` to `qwen3_coder` (UNVERIFIED). | Open, 2026-05-21 |
| mlx-vlm | [2201](https://github.com/Blaizzy/mlx-vlm/issues/2201) | Prompt normalisation drops assistant `reasoning_content` for the Qwen3.5 model types. | Open, 2026-09-09 |
| mlx-vlm | [2532](https://github.com/Blaizzy/mlx-vlm/issues/2532), [2518](https://github.com/Blaizzy/mlx-vlm/issues/2518) | Batched MTP decoding uses stale M-RoPE position deltas (2532). Batched greedy output differs from single-request output (2518). | Open, 2026-10-16 and 2026-10-14 |
| mlx-vlm | [2451](https://github.com/Blaizzy/mlx-vlm/issues/2451) | The prefix cache never reuses the text before the first image. On Gemma 4 26B-A4B (M4 Pro) the first token took 6.9 s, and 2.2 s with the reporter's patch. | Open, 2026-10-06 |
| mlx-vlm | [1925](https://github.com/Blaizzy/mlx-vlm/issues/1925) | Qwen3.8 fails on a base64 image URL but works from a file path. Filed on 0.6.13. I did not retest on 0.7.10. | Open, 2026-08-16 |
| mlx-swift-lm | [660](https://github.com/ml-explore/mlx-swift-lm/issues/660) | `ChatSession` re-reads the whole prompt every turn on hybrid models. A 4-bit 27B model on an M5 Max with 36 GB read 3,979 of 3,979 prompt tokens and took about 6 s per turn. | Open, 2026-10-01 |
| mlx-swift-lm | [PR 661](https://github.com/ml-explore/mlx-swift-lm/pull/661) | Resumes a hybrid model's cache from a checkpoint. The author reports 0.38 s for turns 2 and 3. | Open, 2026-10-01 |
| mlx-swift-lm | [PR 662](https://github.com/ml-explore/mlx-swift-lm/pull/662) | Adds compiled decode for Qwen3.5 vision-language models. | Merged, 2026-10-09 |
| mlx-swift-lm | [374](https://github.com/ml-explore/mlx-swift-lm/issues/374) | Gemma 4 E4B loads and generates but silently ignores image input. | Open, 2026-06-26 |
| Ollama | [17778](https://github.com/ollama/ollama/issues/17778) | Qwen3.8 chat fails with HTTP 500 "no user query found in messages" after a large tool result. A maintainer suspects that context pruning removed the user message. The Qwen3.8 template raises the same error when no user turn exists. | Open, 2026-08-15 |
| Ollama | [18131](https://github.com/ollama/ollama/issues/18131) | The MLX prefix cache has a fixed 8 GiB budget. On a 32 GB M1 Max with `qwen3.8:27b-mlx`, swap reached about 10 GB. | Open, 2026-08-30 |
| LM Studio | [2040](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2040) | The llama.cpp runtime 2.21 failed the Metal tensor-API check on an M5 Max, so the Neural Accelerators stayed unused. Upstream b9592 gave 2 to 3 times the prompt speed. MLX was not affected. | Open, 2026-06-11 |
| LM Studio | [2284](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2284) | A Qwen3.8 GGUF offers only on and off for reasoning. The level "high" falls back to on. | Open, 2026-08-16 |
| LM Studio | [2478](https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2478) | Splash 0.0.5 inside LM Studio returns corrupted text and no native tool calls on Qwen3.8-27B-Splash. Standalone Splash 1.3.0 works on the same Mac (M3 Mac Studio). | Open, 2026-10-07 |

Rule for Perry: validate every tool call against its schema, retry once with a grammar, and then escalate. Never trust `finish_reason` alone.

### C.2 Independent tool-call evidence

| Evidence | Value | Label |
|---|---|---|
| tau2 telecom for Qwen3.6-35B-A3B, Qwen3.6-27B, Qwen3.5-27B, and Qwen3.5-35B-A3B (BenchLM aggregator, 2026-10-23, https://benchlm.ai/benchmarks/tau2Bench) | 95.3, 94.2, 93.9, 89.2 | UNVERIFIED. The page does not name the set-up of each row. |
| tau2 for Gemma 4 31B, 26B-A4B, 12B, and E4B: BenchLM against Google (https://huggingface.co/google/gemma-4-12B-it) | 59.9, 43.6, 36.3, 20.8 against 76.9, 68.2, 69.0, 42.2 | The two sources differ by 17 to 33 points. Google's figures are VENDOR. |
| Toolathlon for Qwen3.6-35B-A3B (BenchLM, https://benchlm.ai/md/benchmarks/toolathlon.md) | 26.9%, last of 22 models | UNVERIFIED (aggregator) |
| MCP-Atlas for Ornith-1.5-9B, Qwen3.5-9B, Qwen3.6-35B-A3B, and Gemma-4-31B ([ORNITH]) | 54.2, 46.8, 62.8, 55 | VENDOR |
| Toolathlon-Verified for the same four ([ORNITH]) | 41.2, 29.6, 41.7, 52.8 | VENDOR |
| MCP-Atlas for Muse Glimmer 30B, Qwen3.6-27B, and Gemma 4 31B (Meta, quoted by https://mcpplaygroundonline.com/blog/test-mcp-server-with-meta-muse-models) | 75.5, 62.5, 54.2 | VENDOR, second hand |
| BFCL v4 for K2-Horizon-7B before and after training (https://huggingface.co/IFM/K2-Horizon-7B) | 62.3, 67.0 | VENDOR |
| Terminal-Bench 2.1 and ClawEval-MM Pass@3 for Qwen3.8-27B ([Q38]) | 73.0 and 57.4 | VENDOR. The card has no BFCL or tau score. |
| Official BFCL v4 (https://gorilla.cs.berkeley.edu/data_overall.csv) | The page says "Last Updated 2026-04-12". The best Qwen row is Qwen3-235B-A22B-Instruct-2507 at 52.15%. The file ranks Claude-Opus-4-5 first at 77.47%. It has no Qwen3.5+, Gemma 4, K2, Flint, Ornith, or Spark row. | VERIFIED by a sub-agent; stale |

Not found: tau3-bench, a per-model MCP-Atlas table for these models, tauBanking numbers outside [AA], and any independent tool-call test on a Mac.

### C.3 Structured output by engine

| Engine | JSON schema or grammar | With thinking | With speculation |
|---|---|---|---|
| llama.cpp `--jinja` | Grammar through `--grammar`. `response_format` becomes a grammar. `tool_choice: "required"` is advisory (issue 29295). | A fix for issue 20345 landed in March 2026. A later comment reported a raw grammar leaking into reasoning (Qwen3.6, build 8981) and a crash with `--reasoning-budget 0`. I found no retest. Safest: turn thinking off for schema calls. | I found no grammar and speculation bug. I did not test them together. |
| mlx-lm server | The server ignores `response_format` and `grammar` (issue 1007). | Not found | A draft model disables batching. |
| mlx-swift-lm | `MLXGuidedGeneration` takes a JSON schema, EBNF, or an XGrammar structural tag. A cold compile can block for hundreds of milliseconds, so warm it off the main actor. | Not found | The README is silent. |
| mlx-vlm | Not found | Not found | `--draft-kind dflash`, `eagle3`, or `mtp` |
| Splash | The README lists tool calls and JSON Schema output ([SPLASH]). Release 1.4.0 shares decode batches between schema and ordinary requests. | `thinking_token_budget` since 1.3.2 ([SPLASH-REL]) | The DFlash2 draft is part of the engine. |
| Ollama | Not verified | Not found | Not found |
| LM Studio | GGUF uses llama.cpp grammars. MLX uses Outlines. | Not found | Not found |

### C.4 Thinking-control cheat sheet

Engine switches. I checked the llama.cpp names against its server README ([LCPP-SRV]) and the Splash names against its release notes ([SPLASH-REL]).

- **llama.cpp:** `--chat-template-kwargs '{"enable_thinking":false}'`, `--reasoning on|off|auto`, `--reasoning-effort default|minimal|low|medium|high|xhigh|max`, `--reasoning-budget N` (-1 unlimited, 0 ends thinking at once), `--reasoning-budget-message`, `--reasoning-format none|deepseek|deepseek-legacy`, and `--reasoning-preserve`. The request field `reasoning_effort` works from version 0.5.0. A per-request `chat_template_kwargs` always worked.
- **mlx-lm server:** `--chat-template-args '{"enable_thinking":false}'` or a per-request `chat_template_kwargs`. It has no effort or budget flag.
- **mlx-vlm server:** thinking is off by default. Flags: `--enable-thinking` and `--thinking-budget N`. Requests accept `enable_thinking` and `thinking_budget`.
- **Ollama:** `think` takes true, false, or a level string. On `/v1`, use `reasoning_effort`. The value "none" means false for models with a boolean switch.
- **Splash:** `"reasoning_effort": "none"` turns thinking off in Chat. `thinking_token_budget` or `--thinking-token-budget N` caps it. `--thinking-end-text` steers the model to its answer when the budget ends.
- **LM Studio:** a Qwen3.8 GGUF shows only on and off (issue 2284).

Model families.

- **Qwen3.8-27B, template:** I read the chat template on 2026-10-25. It defaults to thinking on with effort xhigh. `enable_thinking:false` emits an empty thinking block. With thinking on, the effort must be xhigh, medium, or low, and any other value raises an exception. `preserve_thinking` defaults to true. The template raises the error "No user query found in messages" when the history has no user turn.
- **Qwen3.8-27B, card and discussions:** The non-thinking sampling values are temperature 0.7, top_p 0.8, top_k 20, and presence penalty 1.5. The card warns that lower effort can raise total latency in multi-turn agent runs. A Hugging Face discussion reports about 50 tool calls and 85,000 tokens on one query at default effort (https://huggingface.co/Qwen/Qwen3.8-27B/discussions/82).
- **Qwen3.5 and Qwen3.6:** no effort levels. Their cards show only `enable_thinking:false`.
- **Ornith:** the card says the turn opens with a thinking block and documents no off switch. Whether `enable_thinking:false` works is not confirmed.
- **Gemma 4:** the `<|think|>` token at the start of the system prompt turns thinking on. Larger models still emit an empty thought block when it is off. Do not feed prior thoughts back, except for tool calls.
- **K2-Horizon:** `reasoning_effort` high, medium, or low, and `tool_call_format`. The card says to use high effort and lists no off switch. Low and medium are broken in llama.cpp (issue 30246).
- **Spark-X2.6:** levels none, low, and high. It needs llama.cpp build 10828 or newer.
- **Flint:** a reasoning model. The template needs the returned `reasoning_content` preserved. The card lists no off switch.

Parser coverage. mlx-lm ships parsers for `function_gemma`, `gemma4`, `glm47`, `json_tools`, `kimi_k2`, `kimi_k3`, `laguna`, `longcat`, `minicpm5`, `minimax_m2`, `mistral`, `muse_spark`, `pythonic`, and `qwen3_coder`. It has none for K2 Horizon, Flint, Spark, or Nemotron. mlx-swift-lm has `json`, `lfm2`, `xml_function`, `qwen3_5`, `glm4`, `gemma`, `gemma4`, `kimi_k2`, `minimax_m2`, `atem`, `mistral`, `llama3`, and `gpt_oss`, and none for K2, Flint, or Spark. A sub-agent listed both sets from the source trees (UNVERIFIED by me).

---

## Appendix D. GUI model evidence

### D.1 Scores

All rows are VENDOR unless the Label column says otherwise. A sub-agent collected the rows and I re-read the Holo4 blog, the Holo3.1 blog, and the model cards for the key numbers.

| Model | Role and licence | Benchmark | Score | Measured by and date | Label |
|---|---|---|---|---|---|
| Holo3-35B-A3B | Full agent | OSWorld-Verified, 100 steps | 82.56 and 78.15 | Official sheet, submitted by H Company, 2026-04-20 | VERIFIED as a listing ([OSWORLD]). The vendor submitted both rows. |
| Qwen 3.7 Plus (closed) | General model | OSWorld-Verified | 73.3 | Official sheet, 2026-05-25 | VERIFIED ([OSWORLD]) |
| GUI-Owl-1.5 32B and EvoCUA-8B | Full agents | OSWorld-Verified | 55.44 and 46.06 | Official sheet, 2026 | VERIFIED ([OSWORLD]) |
| claude-fable-5 and claude-opus-5 (closed) | General models | OSWorld-Verified, 100 steps | 85.96 and 83.39 | Official sheet, Anthropic, 2026-08-01 | VERIFIED ([OSWORLD]) |
| Intelligence-Indeed Agent (top row) | Agentic framework | OSWorld-Verified, 100 steps | 90.19 | Official sheet, 2026-07-25 | VERIFIED ([OSWORLD]) |
| Claude Opus 5 (max effort), MuseSpark 1.3, GPT-5.6 Sol | General models | OSWorld 2.0 official, binary accuracy at 500 steps | 48.65, 39.25, 28.10 (partial scores 79.2, 69.56, 64.13) | Official board, updated 2026-10-15 | VERIFIED ([OSWORLD]) |
| Kimi 2.6, MiniMax M3, Qwen 3.7-Plus | Open-weight and closed general models | OSWorld 2.0 official, binary accuracy at 500 steps | 4.6, 4.6, 2.8 (partial scores 22.1, 22.3, 21.5) | Official board, updated 2026-10-15 | VERIFIED ([OSWORLD]) |
| Qwen3.8-27B | Full agent, Apache-2.0 | OSWorld-Verified, AndroidWorld, WebArena-Verified | 84.3, 81.9, 64.8 | Author, 2026-08 | VENDOR ([Q38]) |
| Qwen3.8-27B | same | OSWorld 2.0 score and success | 48.0 and 19.4 | H Company harness, 2026-09-28 | VENDOR ([HOLO4]) |
| Holo4-27B | Full agent, CC BY-NC 4.0 | OSWorld, AndroidWorld | 85.2, 85.1 | H Company harness, 2026-09-28 | VENDOR ([HOLO4]) |
| Holo4-27B | same | OSWorld 2.0 score and success | 61.7 and 41.5 | H Company harness | VENDOR. Nine times the best open-weight result on the official board (4.6%). |
| Holo4-35B-A3B | Full agent, Apache-2.0 | OSWorld, AndroidWorld, OSWorld 2.0 score | 80.8, 77.6, 30.9 | H Company harness, 2026-09-28 | VENDOR ([HOLO4]) |
| Holo3.1-35B-A3B | Full agent, Apache-2.0 | OSWorld (H Company implementation), AndroidWorld | 80.0, 79.3 | Author, 2026-06-01 | VENDOR ([HOLO31]) |
| Holo3.1 4B and 9B | Full agents, Apache-2.0 | AndroidWorld | 71 (up from 58 for Holo3) | Author blog, 2026-06-01 | VENDOR ([HOLO31]). The blog gives no per-size table. |
| UI-Venus-2-9B | Full agent, licence pending | OSWorld-V, ScreenSpot-Pro, OSWorld-G-R, UI-Vision | 70.8, 73.0, 78.5, 53.2 | Author, 2026-08-26 | VENDOR ([UIVENUS2]) |
| UI-Venus-2-9B | same | AndroidWorld, WebVoyager, Online-Mind2Web | 80.2, 90.8, 74.0 | Author | VENDOR ([UIVENUS2]) |
| UI-Venus-2 9B and 27B | same | OSWorld 2.0 binary and partial, 150 steps | 0.0 and 7.5; 2.8 and 13.2 | Author | VENDOR ([UIVENUS2]) |
| UI-Mate-9B | Full agent, Apache-2.0 | OSWorld-Verified, WindowsAgentArena | 66.2, 61.7 | Author, 2026-08-14 | VENDOR ([UIMATE]) |
| Fara1.5-4B, 9B, 27B | Browser agents, MIT | WebVoyager | 80.8, 86.6, 89.3 | Author, 2026 | VENDOR ([FARA]) |
| Northstar-CUA-Fast | Full agent, Apache-2.0, 4B | OSWorld, 50 steps | 37.01 | Author | VENDOR ([NORTHSTAR]) |
| MolmoPoint-GUI-8B | Grounding only, Apache-2.0 | ScreenSpot-Pro | 61.1 | Author, 2026-03 | VENDOR (https://huggingface.co/allenai/MolmoPoint-GUI-8B) |
| GroundAnything 4B | Grounding only, Kimi licence | 30-benchmark average | 72.42 | Author, 2026-09-30 | VENDOR (https://huggingface.co/GroundingPI/GroundAnything). It needs SGLang on Linux. |
| KV-Ground-GuiOwl1.5-0315-8B and Indeed-UI-8B | Grounding only | ScreenSpot-Pro, plain and with zoom-in | 73.2 and 80.5; 73.4 and 81.0 | Self-submitted to the grounding leaderboard (https://gui-agent.github.io/grounding-leaderboard/) | Listing VERIFIED; scores self-reported |
| Holotron4 Nano (30B-A3B) | Full agent, NVIDIA licence | OSWorld | 76.3 | Blog, 2026-09-28 | VENDOR ([HOLO4]). A Nemotron model, not a Qwen3.5 model. |

Notes:

- The official OSWorld-Verified sheet has no Qwen3.8, Holo3.1, Holo4, UI-Venus-2, UI-Mate, or Fara row. Its newest row has the date 2026-08-01.
- The grounding leaderboard (updated 2026-09-10) has no row for these models. Its top entries are ensembles or two-step zoom methods, so they do not compare with one-pass scores.
- UI-Venus-2 says its weight licence "is pending final confirmation". Its GitHub README says "research and educational purposes only" next to an Apache badge.
- In H Company's own table, Holo4-35B-A3B scores below Qwen3.8-27B on OSWorld (80.8 against 84.3), AndroidWorld (77.6 against 81.9), and OSWorld 2.0 (30.9 against 48.0). The MoE operator is faster, not better.
- Gemma 4 and Hobbylm-1B-computer-use have no GUI benchmark. Hobbylm is a text-only LoRA that writes one of ten fixed Mac actions. Its author reports 90 of 125 sealed requests completed (72%).

### D.2 Cost of image input on Apple Silicon

All items are VERIFIED at the source unless marked.

- M2 MacBook Pro 16 GB, llama.cpp, Qwen3.5-9B Q4_K_XL: a 640 by 488 image took 1,189 ms to encode. A 4,015-token image took 40,129 ms ([LCPP-21443]).
- On an M2 Mac mini with 16 GB (build 8190), about 4,025 image tokens took 43.5 s to encode. The first decode batch took 11.6 s (https://github.com/ggml-org/llama.cpp/issues/20704, closed as stale).
- On an M4 Pro with 24 GB and mlx-vlm 0.6.14, Qwen3.5-9B 4-bit took 8.8 s per photo at 1536 pixels on the long edge. Decode ran at about 50 tok/s. This is wall time and not time to first token (https://github.com/Iito/spindll/issues/75).
- On an M4 Pro with mlx-vlm, Gemma 4 26B-A4B 4-bit took 6.9 s to the first token on a cache miss. A patch that is not upstream cut this to 2.2 s (mlx-vlm issue 2451, Appendix C).
- An H Company chart shows Holo3.1-35B-A3B Q4 through llama.cpp on a MacBook M4 Pro. It reports 3.6 model requests per minute with the default harness and 5.5 with the fast harness (VENDOR, [HOLO31]). The chart footnote says llama.cpp has no prefix or image caching for the Qwen architecture. The page does not state the request size for this chart.
- No independent encoder time exists for an M4 Max or any M5 chip.

Controls: llama.cpp has `--image-min-tokens`, `--image-max-tokens`, and `--mtmd-batch-max-tokens` (default 1,024). mlx-vlm has `--min-pixels`, `--max-pixels`, and a vision-feature cache (`--vision-cache-size`, default 20). I did not verify that the cache skips the encoder for an unchanged screenshot. mlx-swift-lm handles `maxPixels` but has no vision cache that I found.

---

## Appendix E. Lead ledger

Leads that I found and did not pursue, with the reason. "Revisit" names the Perry-bench test or event that would reopen the lead.

| Lead | What I found | Why I did not pursue it | Revisit |
|---|---|---|---|
| Edge0 35B-A3B and 8B-A1B (Apache-2.0, 7,150 stars, created 2026-09-08) | SSD expert streaming on a Qwen3.6-35B-A3B base with Recover-LoRA and a trained prerouter. VENDOR numbers on a 24 GB Mac mini M4 Pro: 14.9 to 17.7 tok/s decode and 113 to 140 tok/s prefill. The peak MLX allocator memory is 2.9 GiB, and the average score is 3.9 points below the fp16 base ([EDGE0]). | The README pins `mlx` 0.30.6 and makes no vision claim. The checkpoint takes 23 GB on disk. | P8 |
| Splash `--expert-memory` | Added in 1.4.0. The release notes give relative gains only: 6.5 to 42% decode on an M6 with 24 GB, with a 4 GB expert store ([SPLASH-REL]). | No absolute speed or quality number. | P8 |
| REAP-pruned Qwen3.6-35B-A3B, about 9.4 GB | Named as a speed challenger in the owner's model-stack notes (`/Users/hridyaagrawal/model-stack-HANDOFF.md`). | I did not evaluate it. It may fit a 16 GB Mac. | P4 |
| [Intern-Decision-4B](https://huggingface.co/internlm/Intern-Decision-4B) (Apache-2.0, Qwen3.5-4B base) | A multimodal model that scores a schema of named questions in one forward pass and returns an answer distribution for each question. | It needs logits at placeholder positions, so it needs a custom inference path. | P10 |
| [Northstar-CUA-Fast](https://huggingface.co/Tzafon/Northstar-CUA-Fast) (Apache-2.0, 4B, Qwen3-VL architecture, 9.7 GB in bf16) | VENDOR OSWorld 37.01% at 50 steps. The card lists UI-TARS 2 at 53.1% and Qwen3 Flash at 41.6% in the same table ([NORTHSTAR]). | Below the Qwen3.5-family claims, for example UI-Mate-9B at 66.2. Its non-hybrid architecture would avoid the image-cache gap, but the score is too low. | A board result appears |
| [LensVLM-9B](https://huggingface.co/apple/LensVLM-9B) (Apple, Qwen3.5-9B base, Apple research licence) | Reads compressed images of text and expands pages with learned tools. | It is not a GUI model. | Never needed |
| [Raon-1-mini-preview](https://huggingface.co/KRAFTON/Raon-1-mini-preview) (KRAFTON, Apache-2.0) | A text-generation model with access gated on request. | Text only and gated. | Access opens and vision appears |
| Nemotron 3.5 Bolt 74B-A9B (OpenMDW 1.1, 24 GB build) | Artificial Analysis index 21.4 ([AA]). The E4B model has no index in the board data that I read. | Below Qwen3.8-27B with thinking (26.2 to 33.7) at a similar file size. | A smaller release |
| [GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) (MIT, 320B total, 18B active) | A natively multimodal model. | At 4 bits it needs about 160 GB (320B parameters at half a byte, my arithmetic). That exceeds 128 GB. | Never for consumer Macs |
| ds4 with DeepSeek-V4-Flash (91 GB file) | 33 tok/s at 128 tokens of context and 28 tok/s at 8K on an M5 Max with 128 GB. It uses 103 GB of memory ([STARED]). | It exceeds every tier below 128 GB and leaves no headroom at 128 GB. | A 128 GB tier needs a stretch model |
| Splish (community fork of Splash) | A second-hand report claims a 25% gain on an M5 Max (UNVERIFIED). | I found no repository. | A repository appears |
| [dflash-mlx](https://github.com/bstnxbt/dflash-mlx) (790 stars) and [mlx-dspark](https://github.com/ARahim3/mlx-dspark) (726 stars) | Independent MLX ports of DFlash and DSpark speculative decoding ([GH-API], VERIFIED on 2026-10-25). | No measured comparison with Splash or llama.cpp on a Qwen3.5-family model. | P1 |
| Strata | Splash 1.4.0 credits it for design ideas ([SPLASH-REL]). | I did not read it. | P1 |
| vllm-metal, vllm-mlx, Rapid-MLX, MLC, ExecuTorch, mistral.rs, LiteRT-LM | Listed in section 4.1. | No evidence that they beat the engines in section 4 on these models. | A Qwen3.5-family benchmark appears |
| Prism MLX and mlx-swift forks | Needed to run Ternary Bonsai on MLX. | Fork maintenance risk. | P7 |
| Qwen3.5-9B fine-tunes on the oMLX board (distills and uncensored builds) | They appear on the board next to the base file (Appendix A.1). | Unknown training data and licence. | Never for the default |

---

## Appendix F. Source tags

Each tag in this report maps to the sources below. I read each source on 2026-10-25 unless the row says otherwise.

| Tag | Source |
|---|---|
| AA | Artificial Analysis model leaderboard and model pages: https://artificialanalysis.ai/leaderboards/models |
| AFM3 | https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models |
| APPLE-M1PM | https://www.apple.com/newsroom/2021/10/introducing-m1-pro-and-m1-max-the-most-powerful-chips-apple-has-ever-built/ |
| APPLE-M2PM | https://www.apple.com/newsroom/2023/01/apple-unveils-macbook-pro-featuring-m2-pro-and-m2-max/ |
| APPLE-M3U | https://www.apple.com/newsroom/2025/03/apple-reveals-m3-ultra-taking-apple-silicon-to-a-new-extreme/ |
| APPLE-M4PM | https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/ |
| APPLE-M5 | https://www.apple.com/newsroom/2025/10/apple-unleashes-m5-the-next-big-leap-in-ai-performance-for-apple-silicon/ |
| APPLE-M5PM | https://www.apple.com/newsroom/2026/03/apple-debuts-m5-pro-and-m5-max-to-supercharge-the-most-demanding-pro-workflows/ |
| APPLE-M6 | https://www.apple.com/newsroom/2026/08/apple-introduces-m6-and-m5-ultra-for-a-big-leap-in-performance-and-ai-compute/ |
| APPLE-MLX-M5 | https://machinelearning.apple.com/research/exploring-llms-mlx-m5 |
| APPLE-SPEC | https://support.apple.com/117736 |
| BASERT | https://arxiv.org/abs/2607.19438 |
| BONSAI-GGUF | https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf |
| EDGE0 | https://github.com/Edge0-AI/Edge0 |
| FARA | https://huggingface.co/microsoft/Fara1.5-9B |
| GH-API | https://api.github.com/repos/OWNER/REPO for each repository named in the text |
| HF-API | https://huggingface.co/api/models/OWNER/REPO/tree/main?recursive=true for each repository named in the text |
| HIESCH | https://hiesch.eu/blog/llamacpp-benchmarks-speculative-decoding/ |
| HOLO31 | https://www.hcompany.ai/holo3.1 (the speed chart is the image `fig-5.png` on that page) and https://huggingface.co/Hcompany/Holo-3.1-35B-A3B |
| HOLO4 | https://hcompany.ai/newsroom/holo4 |
| HOLO4-27 | https://huggingface.co/Hcompany/Holo4-27B |
| HOLO4-35 | https://huggingface.co/Hcompany/Holo4-35B-A3B |
| JROCKY | https://github.com/john-rocky/apple-silicon-llm-bench |
| KLD | https://github.com/asher/mlx-kld/blob/main/examples/qwen3.6-27b/comparison.md |
| LCPP-21443 | https://github.com/ggml-org/llama.cpp/pull/21443 |
| LCPP-23470 | https://github.com/ggml-org/llama.cpp/discussions/23470 |
| LCPP-4167 | https://github.com/ggml-org/llama.cpp/discussions/4167 |
| LCPP-REL | https://github.com/ggml-org/llama.cpp/blob/master/.github/workflows/release.yml |
| LCPP-SPEC | https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md |
| LCPP-SRV | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md |
| LLMKUBE | https://llmkube.com/blog/turboquant-m5-max-long-context |
| LMS-2040 | https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2040 |
| LMS-2478 | https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues/2478 |
| LOCALBENCH-35 | https://localbench.substack.com/p/qwen-36-35b-a3b-gguf-quality-benchmark |
| LOCALBENCH-KV | https://localbench.substack.com/p/kv-cache-quantization-benchmark |
| MINICPM5 | https://huggingface.co/openbmb/MiniCPM5-2B |
| MLXSWLM-662 | https://github.com/ml-explore/mlx-swift-lm/pull/662 |
| MLXSWLM-717 | https://github.com/ml-explore/mlx-swift-lm/pull/717 |
| MODELFIT-M5 | https://modelfit.io/blog/m5-mac-metal-tensor-api-llama-cpp-fix/ |
| MTPLX | https://github.com/youssofal/MTPLX |
| NORTHSTAR | https://huggingface.co/Tzafon/Northstar-CUA-Fast |
| OMLX-A | Appendix A.1 of this report |
| OMLX-BOARD | https://omlx.ai/benchmarks/performance, with the filters model, device, and context |
| ORNITH | https://huggingface.co/ornith-ai/Ornith-1.5-9B and https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B |
| OSWORLD | https://os-world.github.io/ ; official OSWorld-Verified sheet http://osworld-v1.xlang.ai/static/data/osworld_verified_results.xlsx ; OSWorld 2.0 board https://osworld-v2.xlang.ai/static/data/leaderboard/official-results.json |
| Q36 | https://huggingface.co/Qwen/Qwen3.6-35B-A3B |
| Q38 | https://huggingface.co/Qwen/Qwen3.8-27B |
| R3 | `docs/research/2026-10-25/r3-local-models.md` in this repository |
| RAYNAR | https://huggingface.co/datasets/RaynarDM/apple-silicon-llm-benchmarks |
| SPLASH | https://github.com/incoai/splash and https://inco.ai/blog/splash/ |
| SPLASH-LMS | https://lmstudio.ai/blog/splash-engine |
| SPLASH-PERF | https://github.com/incoai/splash/blob/main/docs/performance.md |
| SPLASH-REL | https://github.com/incoai/splash/releases |
| STARED | https://github.com/stared/benching-local-llms-on-apple-silicon |
| SWIFT15 | https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-27B-GGUF |
| UIMATE | https://huggingface.co/tencent/UI-Mate-9B |
| UIVENUS2 | https://huggingface.co/inclusionAI/UI-Venus-2-9B |
| UZU | https://github.com/trymirai/uzu |
| WIKI-M4 | https://en.wikipedia.org/wiki/Apple_M4 |
| WIKI-M5 | https://en.wikipedia.org/wiki/Apple_M5 |
| WIKI-M6 | https://en.wikipedia.org/wiki/Apple_M6 |
| WWDC241 | https://developer.apple.com/videos/play/wwdc2026/241 |
