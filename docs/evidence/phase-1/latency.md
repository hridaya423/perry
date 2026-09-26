# Phase 1 — PerryBrain live latency

Date: 2026-09-26. M4 Pro, macOS 27. Bundled `codex` 0.132.0 via `CodexAppServerProvider`
(confined: shell/exec/browser/computer-use/apps/plugins/hooks/multi-agent/web-search disabled —
see `CodexAppServerConfiguration.defaultConfinementArguments`). ChatGPT auth: `auth.json`
copied into a fresh temp `CODEX_HOME` (the user's `~/.codex` was never written).

Command: `Packages/PerryBrain/.build/debug/perry-brain-smoke --provider codex --codex-home <tmp> --tier <t> [--image <jpg>] "<prompt>"`

| run | tier | input | first_delta_ms | total_ms |
|---|---|---|---|---|
| 1 | fast (effort low) | "Say hi in 3 words" | 4046 | 4205 |
| 2 | fast | same | 3662 | 3825 |
| 3 | fast | same | 3099 | 3245 |
| 4 | fast | 1024px JPEG + "Describe this image in one sentence." | 3248 | 3803 |
| 5 | fast | same image | 4167 | 4974 |
| 6 | deep (default effort) | "In two sentences, why is the sky blue?" | 2918 | 3705 |

Text-only p50 first delta ≈ 3.7 s; vision ≈ 3.2–4.2 s. The Phase 0 spike measured 6–34 s with
built-in tools attached; disabling Codex's own tools cut first delta by roughly 2–8×.
Baseline prompt cost is ~13.7k input tokens per turn (Codex's own instructions).

Decision stands (plan §7.0.4): >1.5 s, so Codex is the substance/deep brain and the Talk fast
path must acknowledge + draw from a faster provider (BYOK fast model, local, or Apple FM).
The router's `.fast` order puts Codex last for this reason.

Image screenshot via `screencapture` failed from the agent shell ("could not create image from
display" — no Screen Recording grant for this process), so a system desktop picture converted
to JPEG was used as the vision input. The temp image dir (`$TMPDIR/perry-brain`) was empty after
every run (deleted on each exit path).

Local servers: neither Ollama (`127.0.0.1:11434`) nor LM Studio (`:1234`) is running on this
machine, so the offline acceptance item is **blocked on the user installing a local vision model**
(e.g. `ollama pull qwen2.5vl`). Discovery + chat-compatible streaming are covered by offline tests.

Network-drop acceptance: `OpenAIResponsesProviderTests.testStalledStreamSettlesAfterCancelWithinTwoSeconds`
(transport stops producing mid-stream; cancel settles the stream and tears down the transport
in < 2 s).
