# Mac inference engines for a Qwen3.5-VL / Qwen3-VL grounding model

Researched 2026-10-27. Stars, dates and licences come from the GitHub API. Everything else is from READMEs, docs and repo file trees. I ran no benchmarks.

**Main finding.** No custom engine publishes image-prefill or TTFT numbers for a Qwen VL model on Apple Silicon. The fast text-only engines all fail the gate. mistral.rs is the one non-llama.cpp, non-MLX engine I could confirm runs Qwen3.5 and Qwen3-VL image input on Metal.

Holo-3.1-4B facts that matter. `Qwen3_5ForConditionalGeneration`, hidden 2560, 32 layers, mostly linear-attention (Gated DeltaNet) layers. A 24-layer ViT (hidden 1024). The weights are on HF as safetensors. Community GGUFs exist (`mradermacher/Holo-3.1-4B-GGUF`, `ijohn07/Holo-3.1-4B-Q4_K_M-GGUF`). I found no MLX conversion of the 4B. An engine needs Gated DeltaNet kernels, not only a ViT.

## Gate results

| Engine | Qwen3.5 / Qwen3-VL image input? | Verdict |
|---|---|---|
| mistral.rs | Yes. Source has `vision_models/qwen3_5` and `qwen3_vl`. Docs list GGUF arch `qwen35` and `qwen3vl` as multimodal with a companion projector | **Candidate** |
| mlx-swift-lm (MLXVLM) | Yes. `qwen3_vl`, `qwen3_5`, `qwen3_5_moe` are in `VLMModelFactory`. `Qwen35.swift` is a port of mlx-vlm | **Candidate** (MLX kernels) |
| Ollama MLX runner | `mlxrunner/model/qwen3_5/process_image.go` exists, so likely yes | Same MLX kernels as mlx-vlm. Skip unless Perry wants Ollama |
| vllm-mlx, oMLX, LM Studio mlx-engine, vMLX | Yes (README: "Qwen3-VL", "Qwen3.5 ... VLM"), but built on MLX / mlx-vlm | Redundant with the mlx-vlm benchmark |
| uzu | **No evidence.** README and file tree show text models only (Qwen3.5 0.8B text). Code search for "vision" returned only visionOS and package files | Out (text-only) |
| BaseRT | **Unconfirmed.** README says "vision ... on supported models". Docs and examples show Qwen3 text and Gemma-4-E2B. No Qwen VL | Out until proven |
| RunAnywhere MetalRT | **No.** Proprietary engine. A competing founder on HN describes it as LLM/STT/TTS. The SDK's VLM path is its llama.cpp or MLX backend | Out |
| saragossa | **No.** Pure-Rust Metal. Lists Qwen3.5/3.6/3.8 LLM, Gemma 4, Qwen3-TTS. No vision. 8 stars | Out |
| Cactus | **Not Qwen.** Its VLMs are Gemma-4 and LFM2.5-VL. No Qwen3-VL in the tree | Out |
| Nexa SDK | **Qualcomm-only now.** README is now "GenieX": Hexagon NPU, Adreno, CPU | Out |
| ANEMLL (Neural Engine) | Text LLM converter and chat app. No VLM path found | Out |
| Apple Core AI / Core ML | Core AI is announced as the Core ML successor for generative models. I found no Qwen3.5-VL recipe and only secondary-source coverage | Unverified, out for now |
| exo | Distributed MLX/llama.cpp runner. Wrong shape for one Mac | Out |
| MNN (Alibaba) | Has `omni.cpp` and `export/utils/vision.py`, and a Metal backend. `taobao-mnn/GUI-Owl-1.5-2B-Instruct-MNN` exists on HF but listed only `.gitattributes` (placeholder) | **Unverified lead** |

Other engine names appear in uzu's benchmark scripts: mlx-serve, mldrift, mtplx, splash, magnitude, tensorfold. I did not check them. They are benchmarked as text engines.

## Detail on the candidates

### mistral.rs
- URL: https://github.com/EricLBuehler/mistral.rs
- **Licence:** MIT, open source. 7,780 stars. v0.9.5 released 2026-10-19. Last push 2026-10-24.
- **Vision:** `examples/server/qwen3_5.py` sends an `image_url` through the OpenAI API. Qwen3.5 and Qwen3.6 multimodal take image and video, not audio. Images are resized to the model's input resolution with aspect ratio kept. I found no `max_pixels` knob. Token count control is unverified.
- **Format:** loads HF safetensors with in-situ quant (`--quant 4`). Also loads GGUF plus a companion projector. Per `docs/.../reference/gguf-support.md`, a projector beside the model is picked up for `-f /path/model.gguf`. That could let it reuse the llama.cpp Q4_K_M and mmproj files.
- **Embedding:** server binary (`mistralrs serve`), OpenAI-compatible, no Python. Release asset `mistralrs-metal-aarch64-apple-darwin.tar.gz` is 50 MB. It also has Rust and Python SDKs.
- **Numbers:** none for Apple. The published prefill table is CUDA only (Gemma 4 E4B, GB10: 7396 vs 3974 tok/s for llama.cpp, mistral.rs's own run). No Apple VLM prefill figure.
- **Risks:**
  - Open issue #2125, "Unknown GGUF architecture qwen35" (Aug 2026). The docs now list `qwen35`, so it may be fixed. Unverified.
  - Open issue #2032, Qwen3.5 MoE Metal shader bugs. The 4B is dense, so it may not apply.
  - Our 4B uses the same Metal path for the GDN layers, so check output matches llama.cpp.

### mlx-swift-lm
- URL: https://github.com/ml-explore/mlx-swift-lm
- **Licence:** MIT. 848 stars. 3.32.3 released 2026-09-30. Last push 2026-10-26.
- **Embedding:** SwiftPM package, in-process, no Python, no server. `MLXVLM` plus `VLMModelFactory`. Its registry includes `qwen3_vl`, `qwen3_5` and `Qwen3_5VLProcessor`.
- **Format:** needs an MLX-format checkpoint. No `Holo-3.1-4B` MLX conversion exists on HF, so convert once with `mlx_vlm.convert` (Python, at build time only).
- **Numbers:** none. It shares MLX kernels with mlx-vlm, so expect similar prefill. The benefit is the embedding model and no spawned process.
- **Gotcha (from memory, unverified here):** MLX Swift needs the Metal shader library built by `xcodebuild`. Plain `swift build` or `swift run` fails at runtime.

### MNN (probe only)
- URL: https://github.com/alibaba/MNN
- Apache-2.0. 16,297 stars. 3.6.1 released 2026-07-23. Last push 2026-10-27.
- C++ LLM engine with a Metal backend (`-DMNN_METAL=ON`) and an omni/VLM path. Linear-attention ops have Metal implementations (the export docs mention it).
- It needs its own `llmexport.py` conversion. I could not confirm Qwen3.5-VL or Qwen3-VL runs on macOS Metal. The GUI-Owl MNN repos looked empty.

## Prefill and vision-encoder numbers found

None for Qwen VL on Apple Silicon. What exists:
- BaseRT blog (Base Compute, M4 Pro 24 GB, text only): on small dense models, BaseRT, llama.cpp and MLX are "within a few percent". uzu leads by 4–13% on Qwen3-0.6B in the prefill comparison. Source: https://huggingface.co/blog/basecompute/basert-release. Hardware for the uzu comparison was not stated on the page. This is the vendor's own test.
- Cactus README (vendor): Gemma-4-E2B 256 px image encode 0.25 s on M4 Pro, 0.09 s on M5 Max. Not a Qwen model, and the image is far smaller than 900–2040 tokens.
- MetalRT and uzu headline numbers are decode tok/s, which we do not care about.

## Ranked shortlist

1. **mistral.rs.** The only fresh engine that covers the whole gate on Metal, with HTTP and GGUF reuse.
2. **mlx-swift-lm.** It matters if mlx-vlm wins, because it gives an in-process Swift path. Do not benchmark it separately for speed. Reuse the mlx-vlm result and check only the Swift overhead and image preprocessing.
3. **MNN.** Probe only. A short check of whether it loads Qwen3.5-VL at all.

I would not benchmark uzu, BaseRT or MetalRT until one of them ships image input for Qwen VL.

## Commands (M4 Mac, run on the mini)

### 1. mistral.rs
```sh
curl -fsSL https://mistralrs.dev/install.sh | sh -s -- --backend metal --yes
# A) safetensors, in-situ 4-bit
mistralrs serve -p 1234 -m Hcompany/Holo-3.1-4B --quant 4
# B) same GGUF + mmproj files llama-server uses (put the mmproj beside the .gguf)
mistralrs serve -p 1234 -f /path/Holo-3.1-4B-Q4_K_M.gguf
```
Python client:
```python
import base64, time
from openai import OpenAI
c = OpenAI(api_key="x", base_url="http://localhost:1234/v1")
b64 = base64.b64encode(open("shot.png", "rb").read()).decode()
t = time.perf_counter()
r = c.chat.completions.create(model="default", max_tokens=32, temperature=0, stream=True,
    messages=[{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
        {"type": "text", "text": "Click the Save button. Reply as JSON."}]}])
for ch in r:
    if ch.choices and ch.choices[0].delta.content:
        print("TTFT", time.perf_counter() - t); break
```
Confirm the server is in the Metal build with `mistralrs --help`, and warm up once before timing. The `model="default"` value comes from the repo's own example.

### 2. mlx-swift-lm (only if mlx-vlm wins)
```sh
pip install mlx-vlm
python -m mlx_vlm.convert --hf-path Hcompany/Holo-3.1-4B -q --q-bits 4 --mlx-path ~/models/holo-3.1-4b-mlx4
```
Then add `https://github.com/ml-explore/mlx-swift-lm` (from 3.32.3) to a small Swift CLI target, load with `VLMModelFactory`, and build with `xcodebuild`. I did not verify the CLI flags for the conversion or a ready-made example in the repo.

### 3. MNN (probe)
```sh
git clone https://github.com/alibaba/MNN && cd MNN && mkdir build && cd build
cmake .. -DMNN_BUILD_LLM=ON -DMNN_METAL=ON -DMNN_LOW_MEMORY=ON -DMNN_SUPPORT_TRANSFORMER_FUSE=ON && make -j8
# export (see transformers/llm/export/README): python llmexport.py --path Hcompany/Holo-3.1-4B --export mnn
```
The cmake flags and export options are from memory and the docs I skimmed. Treat them as unverified. There is no OpenAI server in this recipe; MNN's `llm_demo` is a CLI that takes a prompt file, so a Python client would need a wrapper.

## Unverified / gaps
- Whether mistral.rs actually runs Holo-3.1-4B on Metal at correct quality (issues #2125 and #2032 are open). Whether its image token count follows the 900 / 2040 budget.
- BaseRT image support, and any Qwen VL support in uzu. The BaseRT engine binary is proprietary (Apache-2.0 applies to the CLI, format and bindings only).
- Core AI details came only from secondary news. No primary Apple doc read.
- The web search tool returned thin results. Most facts above come from reading the GitHub repos directly, not from HN or Reddit threads. I did not find a Reddit or HN report of any engine beating llama.cpp on VLM prefill.
- llama.cpp and mlx-vlm tuning notes (`-ub`, image token min/max, mmproj offload) were out of scope.
