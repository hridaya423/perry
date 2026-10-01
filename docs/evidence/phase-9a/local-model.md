# Local model live verification (Phase 9)

Environment: Ollama already installed and serving at `http://127.0.0.1:11434`.
Two models pulled locally (no user action needed):

- `qwen2.5vl:latest` (~5.7 GB) — the plan's named local-vision model.
- `qwen3:4b` (~2.5 GB) — tools-capable text model, pulled to exercise the
  grounded-turn path while Codex is quota-capped.

## Discovery + capability probes (live, Settings → Models & Advanced → "On this Mac")

Release build, driven via cua-driver (`local-model-probe.png`,
`qwen3-capabilities.png`):

- `qwen2.5vl`: **Text ✓, Images ✓, Tools ✗** — ollama reports the model
  does not support tools (HTTP 400). Correct scope: local text+vision.
- `qwen3:4b`: **Text ✓, Tools ✓, Images ✗** — text-only model; honest
  negative on vision.

Probe fix required and landed: `ModelCapabilityProbe` capped probes at
64/128 `maxOutputTokens`, which reasoning models (qwen3) exhaust on
`reasoning` before emitting content — text check returned empty and the
tool check never saw the call. Caps raised to 512 (text/vision) and 2048
(tools round-trip). Verified against ollama directly: qwen3 needs ~900
reasoning tokens before emitting the call; the full two-step flow
(call → UUID tool result → verbatim echo, no extra call) passes at 2048.

## Live grounded agent turn on local model (`local-agent-turn.png`)

With "On this Mac" selected and qwen3:4b checked (tools ✓):

- Goal typed into the invoke panel composer: "list the files in my perry
  workspace".
- AgentLoop routed to the local provider (`.local` requirement —
  Codex untouched, quota-capped at the time anyway), qwen3:4b emitted a
  `files.list` tool call, the tool executed against
  `~/Library/Application Support/Perry/workspace`, and the model composed
  the answer: "No files were listed." — factually correct (dir is empty).
- Thread `6B9FCFC4-…json` persisted: question, rendered tool call, answer,
  `outcome: completed`.

This is the first **successful** end-to-end grounded agent turn on this
machine: submit → agent loop → provider tool call → real tool execution →
persisted answer — fully local, no remote quota.

Restored afterward: `perry.brain.modelChoice` → `chatGPT`,
`perry.settings.tab` → `general`.
