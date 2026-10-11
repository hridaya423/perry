# Talk brain decision — Phase 1.1

Measured 2026-10-11 against `codex app-server` (bundled v0.22.1), ChatGPT
account `hridyaagrawal4@gmail.com` (plan `free`). Harness:
`scripts/lab/codex-appserver-spike.swift` — real spawn, real `thread/start` /
`turn/start` JSON-RPC, Calculator window PNG (600×801) as the vision input,
prompt "what does this do".

## Models available on this account

`gpt-6-luna` (server default), `gpt-5.6-terra`, `gpt-5.6-luna`.
Supported `reasoning.effort` values: none, low, medium, high, xhigh, max
(`minimal` is rejected with a 400).

## Results — turn/start → first text delta

| Config | Model | Effort | Thread | Cold turn | Warm turns |
|---|---|---|---|---|---|
| 1. Current behavior | gpt-6-luna | default | fresh per turn | — | 17.5s / 18.5s / 23.6s / 43.7s |
| 2. Small model, fresh threads | gpt-5.6-terra | low | fresh per turn | — | 5.4s / 5.9s / 3.3s / 8.7s |
| 3a. Persistent thread | gpt-5.6-terra | low | persistent | 8.5s | 5.1s / 1.6s / 3.6s / 2.2s / 3.4s / 1.4s / 1.8s |
| 3b. Persistent thread | gpt-5.6-luna | low | persistent | 4.9s | 2.1s / 2.0s / 1.3s |
| 3c. Persistent thread | gpt-5.6-terra | **none** | persistent | 3.5s | 1.46s / 1.47s / 1.55s |

Warm `thread/start` costs 52–380ms (p50 ~65ms); `turn/start` acknowledgement
(`item/started`) arrives in ~150ms on a warm thread. Process spawn →
initialized is ~2.5s cold, ~40ms warm. The dominant cost is model-side
reasoning before the first token, not transport.

Image transport: `{"type":"localImage","path":…}` works.
`{"type":"inputImage","imageUrl":"data:…"}` produces a turn that never emits
an item or an error — do not use data URLs for turn input. Keep the
file-based path (per-launch 0700 image directory, wiped at launch and quit).

## Unmeasurable configs

- **OpenAI Responses (small vision model), OpenAI Realtime**: no BYOK keys on
  this machine (`byok.vision`, `openai`, `anthropic`, `gemini`, `openrouter`
  all absent from Keychain). Deferred until a key exists.
- **Apple Foundation Models**: available on this machine. Not needed for the
  decision — the Codex path clears the gate — but it remains the right tool
  for a ≤1-sentence spoken acknowledgement if perceived latency still lags.

## Decision

The plan's rule: *(2)/(3) reaching ≤2.5 s p50 keeps Codex as the zero-key
default.* Config 3c — `gpt-5.6-terra`, `effort=none`, one persistent thread
per Perry conversation — lands at ~1.5 s p50 on warm turns and ~3.5 s on a
conversation's first turn. **Codex stays.**

Production changes — landed 2026-10-11 (`CodexAppServerProvider` +
`AgentCoordinator` + `TalkPrompt` + `AgentLoop`, verified by
`CodexAppServerProviderTests` 24/24):

1. `ModelRequest` gains `conversationKey: String?`; the provider keeps
   `[key: codexThreadID]` and reuses it while `system` and the tool set are
   unchanged. `model`/`effort` are turn-level params, so fast and deep turns
   share one thread.
2. `.fast` tier maps to model `gpt-5.6-terra` + `effort=none`; `.deep` keeps
   the server default (`gpt-6-luna`, default effort) for agent/planning work.
3. The JSON envelope is removed: the turn input carries the new user message
   natively (text + `localImage`). Prior history lives server-side; on a
   fresh/recovered thread the earlier messages go in as a compact transcript
   block, and a `turn/start` failure on a reused thread drops the record and
   retries once on a new thread.
4. Talk's per-turn spatial payload (element index, deixis bindings, window
   metadata, skill) moves out of `system` into the user message — it is turn
   data, and keeping it in `developerInstructions` would pin turn-1's index
   or force a new thread every turn.

## Risks

- `gpt-5.6-terra`/`gpt-5.6-luna` may not exist on every account tier. If the
  account lacks them, `turn/start` fails with a model error; the error
  surfaces honestly through the existing provider-error path.
- First turn of a new conversation still costs ~3.5 s to first text; the
  listening/thinking affordance must hold that gap.
