# Engines deep hunt: Holo-3.1-4B and GUI-Owl-1.5-2B on Apple Silicon

Researched 2026-10-27. No models run, no benchmarks. Facts come from GitHub API, HF API, repo trees and arXiv abstracts. Anything I did not read at the source is marked **unverified**.

**Bottom line.** Nobody publishes vision-tower or image-prefill numbers for a Qwen3.5-VL or Qwen3-VL model on Apple Silicon. One new engine is worth timing: MNN. It ships official Qwen3.5-4B and Qwen3-VL MNN checkpoints with a separate `visual.mnn`, has Metal kernels for linear attention, and its Python API reports `vision_us` and `prefill_us` per request. Everything else is MLX again, text-only, or not running these models.

## Corrections to the previous sweep
- MLX conversions of both targets exist. [pipenetwork/Holo-3.1-4B-MLX-4bit](https://huggingface.co/pipenetwork/Holo-3.1-4B-MLX-4bit) (3.97 GB, Apache-2.0) and [clinan/GUI-Owl-1.5-2B-Instruct-MLX-4bit](https://huggingface.co/clinan/GUI-Owl-1.5-2B-Instruct-MLX-4bit) (1.78 GB, MIT). No `mlx_vlm.convert` step needed. Third-party uploads, so check output against the BF16 model.
- `taobao-mnn/GUI-Owl-1.5-{2B,4B}-Instruct-MNN` are still empty (only `.gitattributes`, last modified 2026-03-09). But [taobao-mnn/Qwen3.5-4B-MNN](https://huggingface.co/taobao-mnn/Qwen3.5-4B-MNN) (`llm.mnn`, `visual.mnn`, 4-bit) and [Qwen3-VL-2B-Instruct-MNN](https://huggingface.co/taobao-mnn/Qwen3-VL-2B-Instruct-MNN) exist, and MNN's exporter has `Qwen3_5Vision` and `Qwen3Vision` classes ([utils/vision.py](https://github.com/alibaba/MNN/blob/master/transformers/llm/export/utils/vision.py)). Both targets are exportable.

## Engine verdicts

| Engine | Runs these models with image input on macOS? | Evidence | Verdict |
|---|---|---|---|
| **MNN** (Apache-2.0, C++ with Python API) | **Partial, likely.** Exporters for `qwen3_5` and `qwen3_vl`. Prebuilt Qwen3.5-4B and Qwen3-VL-2B/4B. Metal `MetalLinearAttention` and `MetalAttention` in the tree. Nobody has reported it on a Mac | [repo tree](https://github.com/alibaba/MNN/tree/master/source/backend/metal), [pymnn vlm_example.py](https://github.com/alibaba/MNN/blob/master/pymnn/examples/MNNLlm/vlm_example.py) | **Time it** |
| CoreML-LLM (john-rocky, MIT, 201 stars) | **Partial.** Qwen3-VL 2B/4B/8B stateful builds with the vision encoder on ANE. Qwen3.5 is text-only there. Vision is fixed at **196 image tokens** | [README](https://github.com/john-rocky/CoreML-LLM). Numbers are iPhone 17 Pro, decode only: 24 tok/s. v1.6 notes say the first Qwen3-VL turn TTFT was about 4 s and the cached 2nd turn 125 ms (vendor numbers, iPhone) | Probe only. See below |
| vllm-metal (Apache-2.0, 1.9k stars) | **Yes, experimental.** Qwen3-VL and Qwen3.5 dense, image input, on MLX. No numbers | [supported models](https://docs.vllm.ai/projects/vllm-metal/en/latest/supported_models/) | Redundant with MLX |
| mlx-serve (Zig, MIT, no Python) | **Unverified.** `vision_splice.zig` exists on the MLX engine. No Qwen VL claim read | [repo](https://github.com/ddalcu/mlx-serve) | Skip until proven |
| MLC-LLM / WebLLM / TVM | **No.** Qwen3-VL exists only on an unmerged `qwen3-vl` branch, with a segfault report ([#3444](https://github.com/mlc-ai/mlc-llm/issues/3444), ROCm). Qwen3.5 only in a third-party Jetson fork ([#3492](https://github.com/mlc-ai/mlc-llm/issues/3492)) | | Out |
| ONNX Runtime GenAI | **No.** Qwen3-VL not native ([#1989](https://github.com/microsoft/onnxruntime-genai/issues/1989) open). DeepStack PR [#2513](https://github.com/microsoft/onnxruntime-genai/pull/2513) open, unmerged. Qwen3.5 builder is text-only ([#2780](https://github.com/microsoft/onnxruntime-genai/pull/2780), open). Only Qwen2.5-VL is documented | | Out |
| ExecuTorch | **No.** `examples/models/qwen3_5` has 0.8B/2B/4B configs with an XNNPACK fp32 recipe only. Qwen3-VL appears only as an Arm backend test model. MPS backend was deprecated in 1.2.0 (secondary source), and `backends/` has no `mps` dir | [tree](https://github.com/pytorch/executorch/tree/main/examples/models/qwen3_5) | Out |
| Candle | **No.** `qwen3_vl` module exists but has open correctness PRs (prefill mask [#3518](https://github.com/huggingface/candle/pull/3518), M-RoPE [#3551](https://github.com/huggingface/candle/pull/3551)) and no way to reset the KV cache ([#3901](https://github.com/huggingface/candle/issues/3901)). No Qwen3.5 found | | Out |
| LiteRT-LM | **No vision.** Qwen3.5 text export is in flux (many open PRs). iOS Metal cache bug ([#4178](https://github.com/google-ai-edge/LiteRT-LM/issues/4178)) | | Out |
| ik_llama.cpp | **No Metal evidence.** Open Qwen3.5 convert PR ([#1654](https://github.com/ikawrakow/ik_llama.cpp/pull/1654)) says "not e2e-verified". Its mtmd work is CUDA/CPU-oriented (unverified for Metal) | | Out |
| Ollama Go engine | Qwen3-VL since 0.12.7. It reuses ggml Metal kernels, so no new engine to time. No numbers | | Skip |
| apple/ml-fastvlm | Its own FastViTHD tower. Would need retraining. Not these models (from memory, unverified) | | Out |
| Burn, ratchet, Kompute, PowerInfer, SGLang on macOS | Nothing found for Qwen VL | | Out |
| H Company, GUI-Owl, UI-TARS, Fara local runtimes | No on-device runtime found. Holo-3.1 card points to GGUF/MLX and NVIDIA. GUI-Owl's "deploy on own devices" item was unchecked in a README snapshot (secondhand). UI-TARS desktop and Fara were **not checked** | | None |

**Decisive llama.cpp fact.** PR [#16837](https://github.com/ggml-org/llama.cpp/pull/16837) (merged 2025-11) enables flash attention in the CLIP graph and prints a warmup warning for any op the backend lacks. It named Metal missing `UPSCALE` for Qwen3-VL back then. Current master accepts `UPSCALE` on Metal for F32 ([ggml-metal-device.m](https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-metal/ggml-metal-device.m)). So the vision graph should now run entirely on GPU. Check the `llama-server` warmup log for `graph splits = 1` on the mini. If it says more, the vision tower is partly on CPU and that is a cheap win.

## (a) Engines worth timing against llama.cpp

### 1. MNN, via Python (best new lead)
`mnncli serve` is text-only (the code reads `content` as a plain string, no `image_url`). Use the Python API and time inside it. The default config uses the **CPU backend**; set Metal for both LLM and vision.

```sh
python3.12 -m venv ~/mnn-env && source ~/mnn-env/bin/activate
pip install -U MNN huggingface_hub numpy        # 3.6.1 has macOS arm64 wheels
python -c "import MNN.llm"                      # unverified that the wheel includes it and Metal
# if that fails: git clone https://github.com/alibaba/MNN; cd MNN/pymnn/pip_package
#   python3 build_deps.py llm && python3 setup.py install --deps llm   # Metal flag unverified
hf download taobao-mnn/Qwen3.5-4B-MNN --local-dir ~/models/qwen3.5-4b-mnn      # smoke test, same architecture as Holo
# Holo and GUI-Owl need an export:
git clone https://github.com/alibaba/MNN ~/src/MNN && pip install -r ~/src/MNN/transformers/llm/export/requirements.txt
hf download Hcompany/Holo-3.1-4B --local-dir ~/models/holo-3.1-4b
python ~/src/MNN/transformers/llm/export/llmexport.py --path ~/models/holo-3.1-4b \
  --dst_path ~/models/holo-3.1-4b-mnn --export mnn --quant_bit 4 --quant_block 64
# edit <dst>/config.json: "backend_type": "metal" and "mllm": {"backend_type": "metal"}
```
Timing script, adapted from `vlm_example.py`:
```python
import MNN.llm as llm, MNN.cv as cv
m = llm.create("/path/config.json"); m.load()
img = cv.imread("shot.png")
p = {"text": m.apply_chat_template("<img>image_0</img>Click Save. Reply as JSON."),
     "images": [{"data": img, "height": 1008, "width": 1792}]}
m.response(p, False)                       # warm up once
m.response(p, False)
c = m.context
print("TTFT ms", (c.vision_us + c.prefill_us) / 1000, "vision ms", c.vision_us / 1000, "prompt_len", c.prompt_len)
```
The `height`/`width` keys come from the example. Whether they cap visual tokens exactly like `max_pixels` is unverified. Check `prompt_len`.
Risks: first time anyone reports this on a Mac, so quality parity with llama.cpp is unknown. Maturity is high for the project (16k stars, push today) but low for Qwen3.5 on Metal. Issue [#4883](https://github.com/alibaba/MNN/issues/4883) (Qwen3.5 on GPU) is open and about CUDA.

### 2. mlx-vlm as the MLX control (already queued, only the new fact)
Ready checkpoints now exist (see corrections). Server has `--min-pixels`/`--max-pixels` and live `PATCH /v1/settings` ([PR #2529](https://github.com/Blaizzy/mlx-vlm/pull/2529); flag names from the PR text, unverified on a release).
```sh
pip install -U mlx-vlm
python -m mlx_vlm.server --model pipenetwork/Holo-3.1-4B-MLX-4bit --port 8080 --max-pixels 2088960
```
`--max-pixels 2088960` is 2040 tokens at 32 px per token (patch 16, merge 2). Use 921600 for ~900.

### 3. CoreML-LLM ANE probe (GUI-Owl-2B only, expect to lose)
Not a drop-in. Vision is fixed at 196 tokens, which is 4 to 10 times smaller than the workload, so a 900 to 2040 token screenshot would need tiling and a new graph. No OpenAI endpoint (Swift package). Conversion scripts are in [docs/CONVERSION.md](https://github.com/john-rocky/CoreML-LLM/blob/main/docs/CONVERSION.md) and `ADDING_MODELS.md`. I would not spend mini time on it unless Perry wants a GPU-free path.

The fourth slot stays empty. I found no other engine that clears the gate.

## (b) Engine-independent speedups, ranked by gain per effort

1. **Cap pixels hard.** Tokens are pixels / 1024. Qwen-family ViTs attend across all patches, so ViT cost grows faster than linearly with tokens (architecture reasoning, not measured here). Time 900 vs 1500 vs 2040 tokens and keep the smallest that holds grounding accuracy. Expected gain: the largest of any option, no new code. Evidence is indirect: [AQuaUI](https://arxiv.org/abs/2605.19260) cuts 29.5% of tokens for only 13% speedup on a 32B model (LLM-dominated), so on a 2B to 4B model with a heavy ViT the effect should differ. Measure.
2. **Crop to the active window or region, or go coarse-to-fine.** Pixels scale with area. Two-pass designs: [FastFocus, IJCAI-26](https://www.ijcai.org/proceedings/2026/49), [GUI-AIMA](https://arxiv.org/abs/2511.00810). Their latency numbers I did not verify. A second pass costs another TTFT, so only pay it when the first pass is low-confidence.
3. **Lossless duplicate-patch removal before the ViT: [PixelPrune](https://github.com/OPPO-Mente-Lab/PixelPrune)** (Apache-2.0, training-free, `apply_pixelprune(model="qwen3_vl" or "qwen3_5")`). Abstract: 22 to 71% of patches are pixel-unique on document and GUI sets, up to 4.2x inference speedup, pruning happens pre-ViT. HF and vLLM only (tested on CUDA-era stacks). Needs an engine that takes a patch subset with explicit position ids. Neither llama.cpp nor MNN does. Realistic only on a path Perry controls (mlx-swift-lm). Highest ceiling, highest effort. Unverified on Apple Silicon.
4. **Reuse state across steps.** [GUIFlow](https://arxiv.org/abs/2610.34959) reports 3.39x (offline) and 3.49x (OSWorld online) from change-driven partial re-encoding of the ViT and deeper LLM layers, training-free. Hardware and models not stated, no code link found. Cheap cousin: cache ViT features for byte-identical frames (mlx-vlm's vision cache measured 2.07x on repeated identical images, [PR #1933](https://github.com/Blaizzy/mlx-vlm/pull/1933)). That only helps retries and re-asks.
5. **Learned pruning post-ViT** ([GUIPruner](https://arxiv.org/abs/2602.23235): 3.3x vision-encoding speedup on Qwen2-VL-2B, >94% accuracy kept; [ShowUI](https://arxiv.org/abs/2411.17465) token selection: 1.4x measured for training only). Skip: no code found for GUIPruner, and post-ViT pruning leaves the ViT cost untouched, which is your bottleneck.

Not worth it: speculative decoding and early exit for coordinates. At ~15 output tokens, decode is not the cost. I found no GUI-specific evidence either way.

## Unverified and gaps
- Whether the PyPI `MNN` wheel includes `MNN.llm` with Metal, and the `height`/`width` image keys' effect on token count.
- Any real Mac number for MNN, vllm-metal or CoreML-LLM on a Qwen VL model. None found. CoreML-LLM's are iPhone decode.
- GUIFlow and AQuaUI details come from abstracts only. GUIPruner and AQuaUI have no code link.
- MLX conversions are third-party and I did not check their quality against BF16.
- ExecuTorch MPS removal status, Optimum-ONNX VLM export status ([#122](https://github.com/huggingface/optimum-onnx/pull/122), closed, outcome not read).
- UI-TARS desktop, Fara, PowerInfer, ratchet, Kompute: no repo-level check beyond search.
