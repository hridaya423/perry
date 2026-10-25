# R9: Realtime voice providers for Perry (2026-10-25)

Method: code reading plus web research. I did not launch Perry, build, run tests, use the microphone, or call any API with a key. Runtime behaviour is therefore **inference from code** and is marked `(inference)`. Facts I could not confirm are marked `(unverified)`. Web claims carry a URL. Prices from blogs are marked "secondary".

Scope note: the `prose` skill could not be loaded in this session (`Unknown skill: prose`). I wrote in plain short sentences instead.

## 0. Summary

1. **Names are real.** `gpt-live-1` is OpenAI's full-duplex voice model, in the API since 2026-09-10. It is a separate **Live API** (`wss://api.openai.com/v1/live/sessions`), not the Realtime API. "Gemini Live" is `gemini-3.8-live` (GA 2026-09-15 per secondary sources). OpenAI's current Realtime models are `gpt-realtime-2.1` and `gpt-realtime-2.1-mini`.
2. **The "other one" is most likely xAI Grok Voice** (`grok-voice-latest`). It speaks the OpenAI Realtime wire protocol, tops the Artificial Analysis speech-to-speech index, and costs about $0.08/min. Runner-up: **ElevenLabs Eleven Realtime** (launched 2026-10-20, also OpenAI-compatible). The owner should confirm.
3. **Perry already has the right seam.** `protocol RealtimeVoiceTransport` (`App/RealtimeVoiceSession.swift:589-602`) isolates the wire. The 2,400-line session does not know the vendor. Only one transport exists today (`:1010-1316`).
4. **Three Perry defects found, all unrun:** the `OpenAI-Beta` header is sent in GA mode (`:1021-1023`); the default model `gpt-realtime` and transcription model `gpt-4o-transcribe` are on OpenAI's deprecation list; the dictation path may make the realtime model and Perry's brain both answer (section 1.4).
5. **Two roles, not one.** Today realtime is "ears and mouth": it transcribes and speaks text Perry's brain wrote. Only OpenAI and xAI fit that role natively (commit without a reply). Gemini, GPT-Live and ElevenLabs always answer on their own, so they fit a second role, "conversational front", where the model talks and calls one tool, `ask_perry`, for anything real.
6. **Billing trap.** Perry warms one session at launch (`App/Talk/RealtimeTalkVoice.swift:95-98`). GPT-Live and ElevenLabs bill per connected time. An app-lifetime session would cost money while idle.
7. **No new dependency is needed** for OpenAI, xAI, Gemini, GPT-Live or ElevenLabs. `URLSessionWebSocketTask` is enough. WebRTC, Nova Sonic (AWS SigV4 over HTTP/2), Silero, Kokoro and Moshi would each need approval.
8. **Turn detection:** keep the local `EndOfTurnDetector` (r4) plus a manual commit as the default for every provider. Provider VAD is an opt-in extra. GPT-Live has no commit at all, so it is model-owned turns only.

## 1. Part 1: Perry today

### 1.1 Protocol modes

`enum RealtimeVoiceProtocolMode` has four cases (`App/RealtimeVoiceSession.swift:5-19`): `automatic`, `openAIGA` ("OpenAI current"), `openAIBeta`, `compatible`.

| Mode | How it resolves | Session payload | Response payload |
|---|---|---|---|
| `automatic` | Host contains `api.openai.com` gives `openAIGA`, else `compatible` (`:1026-1031`) | per resolved mode | per resolved mode |
| `openAIGA` | explicit | Nested: `type: "realtime"`, `audio.input.format/transcription/noise_reduction/turn_detection`, `audio.output.format/voice/speed`, `output_modalities` (`:1274-1297`) | `output_modalities: ["audio"]` (`:1063-1070`) |
| `openAIBeta` | explicit | Flat: `modalities`, `voice`, `input_audio_format: pcm16`, `turn_detection` (`:1298-1311`) | `modalities: ["audio","text"]` (`:1071-1078`) |
| `compatible` | explicit | Same flat shape as beta | Same as beta |

Observations:

- `turn_detection` is `NSNull()` in all modes (`:1279`, `:1309`). Perry commits by hand.
- Input transcription model is hard-coded to `gpt-4o-transcribe` (`:1269`). OpenAI lists that model as **Deprecated** ([models page](https://developers.openai.com/api/docs/models)).
- The default model is `gpt-realtime` (`App/VoiceController.swift:334`; `App/SettingsView.swift:375`). OpenAI's deprecation page puts `gpt-realtime` shutdown at **2027-01-20**, replacement `gpt-realtime-2.1` ([deprecations](https://developers.openai.com/api/docs/deprecations)).
- **Beta header in GA mode.** `OpenAI-Beta: realtime=v1` is added when mode is `openAIBeta`, or `automatic` on an `api.openai.com` host (`:1021-1023`). In `automatic` the mode then resolves to `openAIGA` (`:1028`), so Perry sends the beta header and a GA-shaped `session.update` together. OpenAI removed the beta interface on **2026-05-12** ([deprecations](https://developers.openai.com/api/docs/deprecations)). I expect this to fail or misbehave against today's API `(inference; not run)`.
- The endpoint has no `?model=` query. The Live doc shows a `?model=` URL for the Realtime WebSocket ([voice-websockets](https://developers.openai.com/api/docs/guides/voice-websockets.md)). Perry sends the model in `session.update` only (`:1285`). Whether GA accepts that is `(unverified)`.

### 1.2 Providers Perry can reach today

Only one transport: `actor OpenAICompatibleRealtimeVoiceTransport` (`:1010`). It reaches:

| Provider | Reachable today? | Why |
|---|---|---|
| OpenAI Realtime (`gpt-realtime-2.1`) | Yes, subject to the beta-header issue | Native target of the code |
| Azure OpenAI Realtime | Likely, with an endpoint and header change `(inference)` | Azure's GA path is `/openai/v1/realtime` ([Azure docs](https://learn.microsoft.com/en-my/Azure/foundry-classic/openai/how-to/realtime-audio)). Perry only sends `Authorization: Bearer` (`:1020`); Azure's `api-key` header is `(unverified)` |
| xAI Grok Voice | Mostly. Needs three small dialect changes | Wire-compatible at `wss://api.x.ai/v1/realtime`. Differences: the transcription event is `conversation.item.input_audio_transcription.updated` with a cumulative transcript; `conversation.item.done` and `rate_limits.updated` are not emitted; the transcription model must be `grok-transcribe` ([xAI docs](https://docs.x.ai/docs/guides/voice/agent)). Perry's decoder knows only `.delta` and `.completed` (`:1210-1225`) |
| ElevenLabs Eleven Realtime | Partly | `wss://api.elevenlabs.io/v1/convai/realtime`, `xi-api-key` header, model in `session.update`, **semantic VAD only**, server rejects `server_vad`, no truncation, no image input ([Pydantic AI reference](https://pydantic.dev/docs/ai/api/realtime/elevenlabs/), [ElevenLabs](https://elevenlabs.io/realtime)). The header differs from Perry's `Authorization` (`:1020`) |
| Gemini Live | No | Different protocol (section 2.2) |
| GPT-Live | No | Different endpoint and events (section 2.1) |
| Amazon Nova Sonic, Hume, Deepgram | No | Other protocols |

### 1.3 Audio in and out

- **Echo cancellation:** `AVAudioEngine` input node with `setVoiceProcessingEnabled(true)`. Failure throws `echoCancellationUnavailable` (`:1849-1856`). Same approach HeyClicky calls a "duplex AEC engine" (r1 section D).
- **Input:** tap on bus 0, buffer size 1024 (`:1910`). `AVAudioConverter` converts the device format to **24 kHz mono Int16** (`:1892-1900`, encoder at `:2377-2401`). Packets go through a bounded `RealtimeVoiceAudioIngress` stream, then the ordered `RealtimeVoicePipeline` (`:609-1000`), then `sendAudio` base64 JSON (`:1042-1049`).
- **Output:** the provider's base64 PCM16 24 kHz is copied into `AVAudioPCMBuffer` and scheduled on one `AVAudioPlayerNode` (`:2196-2258`). The player connects to the main mixer at 24 kHz Int16 (`:1861-1868`).
- **Reservations:** each scheduled buffer takes a reservation so a barge-in can invalidate stale audio (`:239-298`, `:2204-2211`).
- **Latency probe:** `RealtimeFirstAudioTimer` marks speech end in `finishInput` (`:1696`) and first scheduled audio in `scheduleAudio` (`:2255`). Metric `voice.realtime_first_audio` (`:45-62`). Barge-in marker `voice.barge_in_requested` (`:1570`).
- The 24 kHz rate is a Perry choice, not a provider limit. Gemini takes 16 kHz or any rate you declare in the MIME type ([Live API guide](https://ai.google.dev/gemini-api/docs/live-api/capabilities)). GPT-Live takes 16 or 24 kHz ([voice-websockets](https://developers.openai.com/api/docs/guides/voice-websockets.md)). xAI takes 8 to 48 kHz ([xAI docs](https://docs.x.ai/docs/guides/voice/agent)). **No session change is needed for any of them.**

### 1.4 How the brain and realtime voice interact

Two code paths. They behave differently.

**Talk path (hold-to-talk): realtime is ears and mouth.** `RealtimeTalkVoice` sets instructions "Repeat each message you receive verbatim … no answers" (`App/Talk/RealtimeTalkVoice.swift:15-18`).
1. Hold: `RealtimeTalkInput.start()` calls `session.beginInput()` (`:174-183`).
2. Release: `finalize()` calls `finishInputTranscribing()`, which sends `input_audio_buffer.commit` and **no** `response.create` (`:193-205`; `RealtimeVoiceSession.swift:1092-1104`). The provider transcribes and stays silent.
3. The transcript goes to Perry's brain (`TalkSession`). The brain streams text. A chunker splits it into sentences (`App/Talk/TalkSession.swift:386-396`).
4. Each sentence calls `services.output.speak` (`:436-444`). The router sends it to `RealtimeTalkOutput.speak`, then `session.speakText` (`RealtimeTalkVoice.swift:276-282`, `RealtimeVoiceSession.swift:1797-1843`).
5. `speakText` sends `conversation.item.create` (a user text message) then `response.create` (`:1115-1146`). So **every sentence is one model response** that the model must read back verbatim. It can paraphrase `(inference)`. The 2026-10-24 latency audit already flags this cost (`docs/audits/2026-10-24/voice-latency.md:70`).
6. Barge-in: `shutUp` calls `cancelCurrentResponse` (`:284-287`; `RealtimeVoiceSession.swift:1776-1795`).
7. If the session cannot reach `.listening` within 2 s, Talk falls back to `SFSpeechRecognizer` plus `AVSpeechSynthesizer` (`:103-111`, `:174-179`).

**Dictation/steering path (`VoiceController`): possible double answer `(inference)`.** `finishDictation()` calls `realtimeVoiceSession.finishInput()` (`App/VoiceController.swift:578-584`). That variant **does** send `response.create` (`RealtimeVoiceSession.swift:1680-1682`, `:1724-1732`). The model then answers on its own with the default "You are Perry…" instructions (`:162`). At the same time `transcriptFinal` goes to the brain (`VoiceController.swift:635-644`), and the brain's reply calls `speakText`, which cancels the model's own reply (`:433`; `RealtimeVoiceSession.swift:1805-1823`). I expect the user to hear a short start of the model's own answer before the brain's. Not run.

**What realtime never does today:** call tools, take screenshots, or hold Perry's conversation. There is no function-call event in `RealtimeVoiceTransportEvent` (`:305-318`) and no image send.

### 1.5 The settings (SettingsView.swift:344-387)

Seven data fields plus two buttons. `inputLanguage` exists on the config (`:155`) but has no setting.

| # | Control | Preference key | Default | Code |
|---|---|---|---|---|
| 1 | WebSocket endpoint | `perry.realtimeVoice.endpoint` | none | `SettingsView.swift:346`; `PerryPreferences.swift:71` |
| 2 | Realtime voice model | `…model` | none (`gpt-realtime` if OpenAI host) | `:348`; `PerryPreferences.swift:72`; `VoiceController.swift:334` |
| 3 | Voice name | `…voice` | `marin` | `:351`; `PerryPreferences.swift:73` |
| 4 | Protocol picker | `…protocol` | `automatic` | `:353`; `PerryPreferences.swift:76` |
| 5 | Response speed 0.25-1.5 | `…speed` | 1.0 | `:362`; `PerryPreferences.swift:74` |
| 6 | Voice instructions | `…instructions` | "concise… desktop voice assistant" | `:367`; `PerryPreferences.swift:75` |
| 7 | API key (Keychain account `realtime.voice`) | n/a | none | `:370`; `VoiceController.swift:28` |
| – | Button "Use OpenAI Realtime defaults" | sets 1, 2, 4 | | `:373-377` |
| – | Button "Save realtime voice API key" | | | `:378-382` |

Surprises:
- Instructions (6) are overridden by Talk with the verbatim-reader text (`RealtimeTalkVoice.swift:46`). The field only affects the dictation path.
- Speed (5) is sent only in `openAIGA` (`:1293`). Beta and compatible ignore it.
- One Keychain account serves all providers. Switching provider means re-pasting a key.
- All configuration is raw. A user must know a WebSocket URL and a model string.

### 1.6 What adding a provider takes

For a provider with the OpenAI wire (xAI, Azure, ElevenLabs): about 40 lines. Add a dialect value for header name, transcription model, transcription event names, and fields to omit.

For a different protocol (Gemini, GPT-Live): one new `actor` conforming to `RealtimeVoiceTransport`, roughly 300-450 lines `(estimate)`, plus its decoder tests.

**Real coupling to fix, not in the transport protocol:** response correlation. `RealtimeVoiceResponseTracker.admit` rejects a response unless the provider echoes the `perry_response_request_nonce` metadata in `response.created` (`:223-237`, `:402-433`; handler `:2091-2112`). Gemini and GPT-Live have no response ids and no metadata. xAI and ElevenLabs echo is `(unverified)`.

**Fix without touching the session:** the transport remembers `request.metadata` from `sendText/finishInput` and emits a synthesized `.responseStarted(id, metadata:)` carrying it. The session sees the contract it expects.

Second coupling: `transcriptFinal` is dropped unless `.matched` to a client commit tag (`:2042-2050`; `:1177-1185`, `:353`). Server-side turn detection creates items Perry never committed, so those transcripts would be dropped. Hands-free provider VAD therefore needs new session code `(inference from code)`. Local detection plus manual commit avoids it.

### 1.7 The narrowest seam

Keep `RealtimeVoiceTransport` as is. Add three things:

1. A **provider descriptor** that builds the transport (section 3.3).
2. A **capabilities** value the session and settings read (turn control, billing, idle timeout, image input).
3. Per-provider Keychain accounts.

`RealtimeVoiceSession.init` already takes an optional `transport` (`:1422`, default built at `:1430`). `RealtimeTalkVoice` already passes `makeTransport` (`:29`, `:54`). The factory and tests need no new injection point.

## 2. Part 2: Options in late 2026

All price and latency figures are per the cited page. Artificial Analysis (AA) "TTFA" is server-measured time to first audio on its Big Bench Audio set. It is not Perry's end-to-end number.

### 2.1 OpenAI

**Names and versions** ([models page](https://developers.openai.com/api/docs/models)):
- `gpt-realtime-2.1`, `gpt-realtime-2.1-mini`, `gpt-realtime-2`: reasoning speech-to-speech with tools.
- `gpt-live-1`: full-duplex voice model with delegation.
- `gpt-live-transcribe`, `gpt-realtime-whisper`: streaming transcription. `gpt-realtime-translate`: speech translation.
- Deprecated: `gpt-realtime-mini`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`. `gpt-realtime` and `gpt-4o-realtime` shut down 2027-01-20 ([deprecations](https://developers.openai.com/api/docs/deprecations)).

**Realtime API (`gpt-realtime-2.1`)**

| Item | Fact | Source |
|---|---|---|
| Transport | WebRTC (browser, `/v1/realtime/calls`), WebSocket (server), SIP | [guide](https://developers.openai.com/api/docs/guides/realtime) |
| Auth | Bearer key; ephemeral client secrets via `POST /v1/realtime/client_secrets` for browsers. Not needed for a native BYOK app | same |
| Audio | `audio/pcm` 24 kHz; also G.711 | [conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations) |
| Turn detection | `server_vad` (`threshold`, `prefix_padding_ms`, `silence_duration_ms`) or `semantic_vad` (`eagerness` low/medium/high/auto) under `session.audio.input.turn_detection`; `null` for manual commit | [VAD guide](https://developers.openai.com/api/docs/guides/realtime-vad) |
| Barge-in | With VAD the server cancels on `speech_started`. On WebSocket the client must stop playback and send `conversation.item.truncate` with `audio_end_ms`. WebRTC and SIP do it server-side | [conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations) |
| Tools | Function calling: `response.done` carries a `function_call` item; reply with `conversation.item.create` `function_call_output`, then `response.create` | same |
| Vision | `conversation.item.create` with an `input_image` part (base64 data URI). Page names `gpt-realtime-2` and `gpt-realtime`; 2.1 lists image input on its model page | same; [2.1 page](https://developers.openai.com/api/docs/models/gpt-realtime-2.1) |
| Voices, languages | `marin` default; language list not on pages fetched `(unverified)` | |
| Price | Audio $32 in / $64 out per 1M tokens, cached $0.40; text $4 / $24; image $5. Context 128k. Third-party estimates $0.06-$0.11/min flagship (secondary) | [2.1 page](https://developers.openai.com/api/docs/models/gpt-realtime-2.1), [Forasoft](https://www.forasoft.com/blog/article/openai-realtime-api-pricing) |
| Session limit | 60 minutes | [conversations guide](https://developers.openai.com/api/docs/guides/realtime-conversations) |
| 2.1 vs 2 | Better alphanumerics, silence/noise handling, interruptions; same price | [2.1 page](https://developers.openai.com/api/docs/models/gpt-realtime-2.1) |
| Latency (AA) | 2.1 High TTFA 1.21 s, STS index 75.2; Minimal 0.97 s, 70.7 | [AA](https://artificialanalysis.ai/speech-to-speech) |
| Billing | Per token. An idle connection costs nothing `(inference from token pricing)` | |

**Live API (`gpt-live-1`).** New product. API launch 2026-09-10 per secondary sources; OpenAI's own post returned HTTP 403, so the date is `(unverified)` ([OpenAI post](https://openai.com/index/introducing-gpt-live-1-in-the-api/), [community thread](https://community.openai.com/t/introducing-gpt-live-1-in-the-api/1396471)).

| Item | Fact | Source |
|---|---|---|
| Endpoint | `wss://api.openai.com/v1/live/sessions`. `v1/realtime` is **not** supported for this model | [model page](https://developers.openai.com/api/docs/models/gpt-live-1), [voice-websockets](https://developers.openai.com/api/docs/guides/voice-websockets.md) |
| Handshake | First message `session.start`, wait for `session.started` | same |
| Transport | WebRTC (recommended), WebSocket, SIP, plus a "sideband" attach socket | [Live guide](https://developers.openai.com/api/docs/guides/live) |
| Auth | Server-side project key. Ephemeral tokens not mentioned | same |
| Audio | `audio/pcm` 24 kHz or 16 kHz; G.711 8 kHz. Fixed at start | [voice-websockets](https://developers.openai.com/api/docs/guides/voice-websockets.md) |
| Events | In: `session.input_audio.append`, `.mute/.unmute`, `session.update`, `session.instructions.append`, `session.thinking.append`, `session.commentary.append`, `response.create`, `session.close`. Out: `session.started`, `session.output_audio.delta`, `session.input_transcript.delta`, `session.output_transcript.delta`, `session.delegation.created`, `error`, `session.closed` (with usage) | [reference](https://developers.openai.com/api/reference/resources/live/primary-websocket) |
| Turn detection | **None to configure.** The model decides when to listen and speak. No commit event is documented | [voice-websockets](https://developers.openai.com/api/docs/guides/voice-websockets.md) |
| Barge-in | Full duplex. No interruption events documented; client tracks its own playback. Output has no timing and no "audio done" event. LiveKit notes truncation is not supported | same; [LiveKit](https://docs.livekit.io/agents/models/realtime/plugins/gpt-live/) |
| Delegation | `delegation.type`: `responses` (OpenAI backend), **`client`** (your code), `decisions`. In `client` mode the model emits `session.delegation.created` with a `delegation.id` and **no task text**; the app rebuilds the request from the transcript deltas, then returns progress with `session.thinking.append` (silent) or `session.commentary.append` (spoken, **paraphrased**, 500 tokens max per append) | [delegation guide](https://developers.openai.com/api/docs/guides/live-delegation) |
| Cancel | No cancel event. Interrupting leaves backend work running; the app must stop it | same |
| Tools | App runs function tools; the voice model cannot see them. Voice model requests backend work itself | [prompting](https://developers.openai.com/api/docs/guides/live-prompting) |
| Vision | **None.** Audio and text only | [model page](https://developers.openai.com/api/docs/models/gpt-live-1) |
| Voices | Default `marin`; 12 other names in secondary sources (unverified) | [cellcog](https://cellcog.ai/blog/gpt-live-1/) |
| Languages | No list `(unverified)` | |
| Price | **$0.05/min of session, billed per second**, plus backend model and tool usage. Not on the Free tier. Concurrency: Build 50, Launch 300, Grow 500 | [model page](https://developers.openai.com/api/docs/models/gpt-live-1) |
| Session limit | Not stated. LiveKit's plugin reconnects and resends history on a timer | [LiveKit](https://docs.livekit.io/agents/models/realtime/plugins/gpt-live/) |
| Latency (AA) | Astra/medium TTFA 1.34 s (STS 83.2, tau-voice 74.5); Sol/low 1.24 s (80.1). "Astra" and "Sol" are not defined on the OpenAI pages I read | [AA](https://artificialanalysis.ai/speech-to-speech) |

Fit for Perry: **client delegation is the same architecture Perry wants** (voice model for ears and mouth, Perry's brain for thinking). The costs are: paraphrased speech (no verbatim mode), no commit-and-stay-silent, no images, billed while connected.

**Azure OpenAI.** Same realtime models and wire. GA WebSocket path `/openai/v1/realtime`, preview path `/openai/realtime`; mixing them gives 404. Listed models were `gpt-realtime`, `gpt-realtime-mini`, `gpt-realtime-1.5` ([Azure docs](https://dotnet.territoriali.olinfo.it/en-us/azure/foundry/openai/how-to/realtime-audio-websockets), a mirror of Learn). Whether Azure already has 2.1 and `gpt-live-1` is `(unverified)`. Treat as a "Custom (OpenAI-compatible)" preset. Microsoft's separate Voice Live API pricing is `(unverified)` for 2026.

### 2.2 Google Gemini Live

| Item | Fact | Source |
|---|---|---|
| Models | `gemini-3.8-live` (default), `gemini-3.8-live-extended-thinking`; legacy `gemini-3.1-flash-live-preview`; older `gemini-2.5-flash-native-audio-preview-12-2025`. Also `gemini-3.5-transcribe-live` (transcription only) and `gemini-3.5-live-translate-preview` | [Live guide](https://ai.google.dev/gemini-api/docs/live-api/capabilities), [pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| GA date | 2026-09-15 per secondary sources `(unverified)` | [projedefteri](https://projedefteri.com/en/blog/gemini-3-8-live-api/) |
| Transport | WebSocket `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent` | [API reference](https://ai.google.dev/api/live) |
| Auth | API key (server-to-server). Ephemeral tokens for client apps via `AuthTokenService.CreateToken` and `BidiGenerateContentConstrained` | same |
| Messages | Client: `setup`, `clientContent`, `realtimeInput` (`audio`, `video`, `text`, `activityStart`, `activityEnd`, `audioStreamEnd`), `toolResponse`. Server: `setupComplete`, `serverContent` (`interrupted`, `turnComplete`, `generationComplete`, transcriptions), `toolCall`, `toolCallCancellation`, `goAway`, `sessionResumptionUpdate`, `usageMetadata` | same |
| Audio | In: PCM16 16 kHz (other rates if the MIME type says so). Out: always 24 kHz | [Live guide](https://ai.google.dev/gemini-api/docs/live-api/capabilities) |
| Turn detection | Automatic VAD on by default (`startOfSpeechSensitivity`, `endOfSpeechSensitivity`, `prefixPaddingMs`, `silenceDurationMs` 500-800 ms, default about 800 ms). Disable with `disabled: true` and send `activityStart`/`activityEnd` yourself (use at least 500 ms end silence). Hybrid: keep VAD, send `audioStreamEnd` when your own detector decides | same |
| Barge-in | VAD-detected speech cancels generation; server sends `interrupted`; client clears playback. Pending function calls are dropped | same |
| Proactive audio, affective dialog | Need `v1beta`. Not supported on 3.1 Flash Live. Support on 3.8 Live not stated on the page `(unverified)` | same |
| Tools | 3.8 Live: async `NON_BLOCKING` calls with scheduling `SILENT`, `WHEN_IDLE`, `INTERRUPTED`; also search grounding | same; [pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| Vision | JPEG/PNG frames, at most 1 fps. Audio plus video sessions max 2 minutes | [Live guide](https://ai.google.dev/gemini-api/docs/live-api/capabilities) |
| Languages, voices | 99 languages, automatic switching; voices match Gemini TTS | same |
| Price | Audio in $3.00, out $12.00 per 1M tokens; about $0.005/min in and $0.018/min out. Free tier exists. 3.8 Live and Extended Thinking priced the same | [pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| Limits | Audio-only 15 min without compression. Connection about 10 min; `goAway` warns with `timeLeft`; resumption token valid 2 h; sliding-window context compression extends sessions. Context 128k | [session management](https://ai.google.dev/gemini-api/docs/live-api/session-management) |
| Latency (AA) | 3.8 Live TTFA 1.18 s (STS 74.5); Extended Thinking High 1.35 s (STS 82.6). 3.1 Flash Live High 2.99 s | [AA](https://artificialanalysis.ai/speech-to-speech), [AA post](https://x.com/ArtificialAnlys/status/2099977688991838597) |

Fit for Perry: cheapest big option, images, large context, 99 languages. **It always replies when a turn ends.** There is no commit-and-stay-silent. For ears-only you would need the separate `gemini-3.5-transcribe-live` model, which means a second session `(inference)`. So Gemini belongs in the conversational-front role.

### 2.3 The likely "other one": ranked

The owner wrote "gpt-live/gemini-live … and whats the other one?". The natural third in the same naming style is **Grok Voice**. Ranking for Perry, by fit (wire compatibility, role fit, price, quality, Swift effort):

| Rank | Option | Why | Risk |
|---|---|---|---|
| 1 | **xAI Grok Voice** (`grok-voice-latest` = `grok-voice-3.0`; `grok-voice-think-fast-2.0` is the July 2026 release) | OpenAI wire at `wss://api.x.ai/v1/realtime`. Manual turns (`turn_detection: null`) work. Has `force_message` (looks like verbatim speech; meaning `(unverified)`). Index leader. About $0.08/min flat (secondary: [eesel](https://www.eesel.ai/blog/grok-voice-think-fast-2)). No image input, no truncation ([Pydantic AI](https://pydantic.dev/docs/ai/api/realtime/xai/)) | Pricing not on the xAI pages I fetched. Alias moved to 2.0 on 2026-08-05 (60% price rise for alias users, per eesel) |
| 2 | **ElevenLabs Eleven Realtime** (`eleven_realtime_v1_mini`, `_max`; launched 2026-10-20) | OpenAI-compatible at `wss://api.elevenlabs.io/v1/convai/realtime`. Fast: TTFA 570-620 ms vendor, 0.57-0.62 s AA. 90+ languages, 17,500+ voices ([ElevenLabs](https://elevenlabs.io/realtime)) | WebSocket only. Semantic VAD only. 600 s default max session, 60 s idle limit ([Pydantic AI](https://pydantic.dev/docs/ai/api/realtime/elevenlabs/)). Bills per connected minute. Pricing `(unverified)`. Days old |
| 3 | Amazon Nova 2 Sonic (`amazon.nova-2-sonic-v1:0`) | Cheap (speech $3/$12 per 1M tokens, about $0.015/min estimate), TTFA 1.14 s, Big Bench Audio 88 ([AA](https://artificialanalysis.ai/speech-to-speech), [AWS card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-amazon-nova-2-sonic.md)) | HTTP/2 bidirectional stream with AWS auth. Needs the AWS SDK or hand-rolled signing. 7 languages. Skip |
| 4 | Hume EVI 4 | Emotion-aware voice. EVI 4-mini needs a supplemental LLM ([Hume FAQ](https://dev.hume.ai/docs/speech-to-speech-evi/faq)). Pricing conflicts in secondary sources ($0.02-$0.04/min). Not on the AA board | Smaller language set, separate vendor `(unverified)` |
| 5 | Deepgram Voice Agent API | Cascaded STT+LLM+TTS, $0.056-$0.075/min, BYO LLM ([secondary](https://diyai.io/ai-tools/speech-to-text/deepgram-pricing-2026/)). Bills connection time | Not speech-to-speech. Another vendor |
| 6 | Ultravox | Acquired by Inworld, announced 2026-09-30 ([Inworld](https://inworld.ai/blog/inworld-acquires-ultravox), [GeekWire](https://www.geekwire.com/2026/seattle-voice-ai-startup-ultravox-formerly-known-as-fixie-acquired-by-inworld/)) | Product in transition |
| 7 | Alibaba Qwen Audio 3.0 Realtime Plus | AA index #1 in a September post (84.1), but TTFA 1.54-4.02 s (sources conflict) and China-hosted endpoint ([AA post](https://x.com/ArtificialAnlys/status/2082179251407917475)) | Data residency; skip |
| 8 | Sesame | Open 1B CSM weights since 2025. No verified public API ([Sacra](https://sacra.com/research/sesame-ai)) | Not offerable |
| 9 | Cartesia | TTS only (40 ms claimed, secondary) | Not speech-to-speech |
| – | Microsoft Voice Live | Azure wrapper over realtime models | Details `(unverified)`; use Azure preset |

**Artificial Analysis snapshot** ([board](https://artificialanalysis.ai/speech-to-speech); the page date is unclear: it says "As of July 2026" but lists September models):

| Model | STS index | Big Bench Audio % | Full Duplex % | tau-voice % | TTFA s |
|---|---|---|---|---|---|
| Grok Voice 3.0 | 86.9 | 99 | 97.0 | 71.6 | 0.81 |
| GPT-Live-1 (Astra, medium) | 83.2 | 90 | 94.9 | 74.5 | 1.34 |
| Gemini 3.8 Live ET (High) | 82.6 | 98 | 91.9 | 68.6 | 1.35 |
| Eleven Realtime v1 Max | 77.3 | 99 | 94.1 | 47.6 | 0.57 |
| GPT-Realtime-2.1 High | 75.2 | 96 | 95.7 | 45.7 | 1.21 |
| Gemini 3.8 Live | 74.5 | 92 | 96.1 | 30.1 | 1.18 |
| Nova 2.0 Sonic | – | 88 | – | – | 1.14 |

I found no independent end-to-end latency measurement on a Mac over a home network. These are server-side numbers.

### 2.4 Local and on-device options (Apple Silicon)

| Option | What it is | Latency / quality | Swift fit | Verdict |
|---|---|---|---|---|
| **Apple SpeechAnalyzer** (macOS 26+) + `AVSpeechSynthesizer` | Fully local ears and mouth. Perry already uses `AVSpeechSynthesizer` (`VoiceController.swift` `synthesizer`) and Apple Foundation Models as a brain | WER 1.98% vs whisper.cpp 4.28% on 40 clips; median post-speech latency about equal to whisper ([IraVoice](https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4)). First volatile result 0.3-0.5 s on an iPhone 16e; speech-end to final 1.45-2.2 s in a forum thread of 11 runs ([DEV](https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5), [Apple forum](https://developer.apple.com/forums/thread/794720)). **No end-of-utterance signal** (r4 section 2.1). Deployment target is macOS 14 (`project.yml`, per r4), so it needs `#available(macOS 26)` | Native, no dependency | Keep as the offline fallback. Not a realtime option |
| **Personal Voice** via `AVSpeechSynthesizer` | User's own voice for output. Needs user authorization | Not measured `(unverified)`; I did not find a source | Native | Optional later; not researched here |
| **Kokoro-82M** (Core ML or MLX) | Small local TTS | Core ML port 379 ms for 30 s of audio on an M2 Studio (self-reported, [HF](https://huggingface.co/mattmireles/kokoro-coreml)); about 100 ms to first audio on an M4 in one informal write-up ([dTelecom](https://blog.dtelecom.org/we-replaced-elevenlabs-with-kokoro-tts-on-an-m4-gpu-latency-fell-to-100-ms-and-tts-cost-nearly-68bcc3313cdd)) | Needs `mlx-audio`, FluidAudio or a Core ML port: **new dependency** | Best local mouth if approved. Not now |
| **Orpheus, Qwen3-TTS on MLX** | Larger local TTS | No Apple Silicon latency found | Python-first | Skip |
| **Kyutai Moshi (MLX)** | Local speech-to-speech | Theory 160 ms, 200 ms on an L4 GPU; no function calling mentioned; weights CC-BY 4.0 ([GitHub](https://github.com/kyutai-labs/moshi)). MLX runner is Python (`python -m moshi_mlx.local`). I found no Swift package and no Mac round-trip number | No Swift path | Do not offer |
| **Kyutai Unmute / STT** | STT 1B model, 500 ms delay, MLX build for Mac and iPhone ([Kyutai](https://kyutai.org/stt)); Unmute is a GPU server stack | Mac numbers missing | New dependency | Skip |

## 3. Part 3: Recommendation

### 3.1 Providers to offer, in order

Two roles (my framing):
- **Ears and mouth.** Provider transcribes on commit and speaks text Perry hands it. Brain owns answer, tools, screen, ink. Needs "commit and stay silent". Fits: OpenAI, xAI, Azure/custom OpenAI wire.
- **Conversational front.** Provider converses itself and calls one tool `ask_perry(request)` for anything touching the screen, tools or ink. Fits: GPT-Live (native `client` delegation), Gemini 3.8 Live, Eleven Realtime v1 Max, also OpenAI and xAI.

| Order in the picker | Provider | Role first shipped | Effort | New dependency |
|---|---|---|---|---|
| 1 | **OpenAI Realtime** (`gpt-realtime-2.1`) | Ears and mouth (exists) | Fix defaults (below) | None |
| 2 | **Grok Voice** (`grok-voice-latest`) | Ears and mouth | About 40 lines dialect | None |
| 3 | **Gemini Live** (`gemini-3.8-live`) | Conversational front | New transport | None |
| 4 | **GPT-Live** (`gpt-live-1`), labelled Beta | Conversational front | New transport + delegation | None |
| 5 | **ElevenLabs** (`eleven_realtime_v1_mini`) | Conversational front, later | Dialect + idle policy | None |
| 6 | **Custom (OpenAI-compatible)**, under Advanced | Ears and mouth | Exists | None |
| – | Local (SpeechAnalyzer + system voice) | Default when no key | Exists | None |

Why this order: the owner named GPT-Live and Gemini, so both are in the picker. Order of **delivery** differs: OpenAI and Grok first (cheap, same code path), then the two new transports.

First fixes regardless of provider (small, high value):
1. Default model to `gpt-realtime-2.1`. Stop hard-coding `gpt-4o-transcribe`; use `gpt-live-transcribe` or `gpt-realtime-whisper` for OpenAI and `grok-transcribe` for xAI. (Today's `RealtimeVoiceSession.swift:1269`.)
2. Drop the `OpenAI-Beta` header unless mode is explicitly `openAIBeta` (`:1021-1023`). Remove or hide `openAIBeta`; OpenAI removed it 2026-05-12.
3. Add `?model=` to the OpenAI URL `(unverified need)`.
4. In the dictation path, call `finishInputTranscribing()` rather than `finishInput()` (`VoiceController.swift:583`) so the model does not also answer `(inference)`.

### 3.2 How the user picks one

- **Onboarding: do not ask.** Local voice works with no key (r7 puts realtime BYOK under "Advanced", see `docs/plans/2026-10-25-perry-first-impressions.md:1025`). After the first successful spoken turn, show one optional card: "Make Perry's voice faster. Add a key." It opens Settings.
- **Settings → Voice** replaces the seven raw fields:
  - **Provider** picker (section 3.1 order) with the provider's name and a one-line note ("About $0.08 per minute talking").
  - **Key** field and Save, stored under `realtime.voice.<provider>` (today one shared account, `VoiceController.swift:28`).
  - **Voice** picker per provider (free text for Custom).
  - **Turn-taking:** "Perry decides when I'm done (recommended)" or "Hold to talk only".
  - **Advanced** disclosure: endpoint, model, protocol dialect, instructions, speed. This is today's UI, kept intact.
- Show cost wording only where it is true. For per-connected-minute providers (GPT-Live, ElevenLabs), add: "Perry connects only while you talk."
- Keep the existing note that audio streams to the provider under its data policy (`SettingsView.swift:385`).

### 3.3 Provider abstraction in Swift (signatures only)

No change to `RealtimeVoiceSession` internals. New files go under the `App/Realtime/` folder that plan Task 4.7 creates.

```swift
enum RealtimeProviderID: String, CaseIterable, Sendable {
    case openAI, grok, gemini, gptLive, elevenLabs, custom
}

struct RealtimeProviderCapabilities: Equatable, Sendable {
    enum TurnControl: Sendable { case clientCommit, providerOnly }   // GPT-Live: providerOnly
    enum Billing: Sendable { case perToken, perConnectedTime }
    let turnControl: TurnControl
    let silentCommit: Bool           // can transcribe without replying
    let verbatimSpeech: Bool         // can be told to speak exact text
    let acceptsImages: Bool
    let billing: Billing
    let idleTimeout: Duration?       // ElevenLabs 60 s; Gemini connection about 10 min
    let maxSession: Duration?        // OpenAI 60 min; Gemini 15 min; ElevenLabs 600 s default
}

struct RealtimeProvider: Sendable {
    let id: RealtimeProviderID
    let title: String
    let defaultEndpoint: URL
    let defaultModel: String
    let capabilities: RealtimeProviderCapabilities
    let keychainAccount: String                       // "realtime.voice.<id>"
    let makeTransport: @Sendable (RealtimeVoiceConfiguration, _ apiKey: String)
        -> any RealtimeVoiceTransport
}

enum RealtimeProviders {
    static let all: [RealtimeProvider]
    static func provider(_ id: RealtimeProviderID) -> RealtimeProvider
}

// Config gains one field; protocolMode stays for .custom only.
struct RealtimeVoiceConfiguration { let provider: RealtimeProviderID /* + existing */ }

// New transports. Same protocol, same events.
actor GeminiLiveTransport: RealtimeVoiceTransport {}
actor GPTLiveTransport: RealtimeVoiceTransport {}

// OpenAI-wire differences as data, not as a mode switch.
struct OpenAIWireDialect: Sendable {
    let authHeader: (name: String, valuePrefix: String)        // Authorization/Bearer; xi-api-key/""
    let transcriptionModel: String?
    let transcriptEventNames: Set<String>                      // adds ".updated" for xAI
    let omitFields: Set<String>                                // noise_reduction, speed, …
    let echoesResponseMetadata: Bool
}
```

Phase B (front role) adds two members to the existing types, not new protocols:

```swift
enum RealtimeVoiceTransportEvent { case toolCall(id: String, name: String, arguments: String) }
protocol RealtimeVoiceTransport { func sendToolResult(id: String, output: String) async throws }  // default no-op
```

Transport rules:
- A non-OpenAI transport **synthesizes** `.responseStarted(id, metadata:)` from the last request's `metadata`, so `RealtimeVoiceResponseTracker` (`:402-433`) keeps working.
- GPT-Live: `sendText` maps to `session.commentary.append`; document that speech is paraphrased.
- Gemini: map `activityStart`/`activityEnd` to `beginInput`/`commitInput` with automatic VAD disabled; map `interrupted` to `.responseInterrupted`; `serverContent` audio parts to `.audio`.
- `NetworkEndpointPolicy.requireSafe` stays on every `connect()` (`:1036`).
- Gemini key: header or query is `(unverified)`. Do not log URLs that carry a key.

### 3.4 How realtime coexists with Perry's brain

**Phase A (now): ears and mouth.** Keep the current design (section 1.4). Cost: first audio is the sum of transcript finalization, brain first token (1.2-1.8 s p50 in the audit, `docs/audits/2026-10-24/voice-latency.md:14`), sentence boundary, and a `response.create` round trip per sentence. I estimate 2.5-3.5 s from release to first audio `(inference; no measurement)`. That matches HeyClicky's own stated "a couple of seconds" (r1 section D).

**Phase B: conversational front, with one tool.** The realtime model chats and answers simple things directly (target about 1 s, AA TTFA 0.6-1.3 s). For anything about the screen, apps, drawing or tasks, it calls `ask_perry(request)`. Perry's brain runs exactly as today and its text goes back as the tool result (OpenAI flow: `function_call_output` then `response.create`; GPT-Live: `delegation.created` then `thinking.append`/`commentary.append`; Gemini: `toolResponse`).

Why one tool and not a mirror of Perry's tools:
- Perry's tools, safety gate and ink (`ToolGate`, `draw` events in `TalkSession.swift:398-408`) live in the brain. Duplicating them in a vendor schema adds three schemas to keep in step.
- Screen context: images go to the brain, not the voice model. That also removes the vision gap for GPT-Live, xAI and ElevenLabs.
- Filler while the brain works ("One sec") comes from the front model, as HeyClicky does (r1 section D).

Risks to test: paraphrase breaks word-to-ink sync (Perry spreads word times evenly already, `RealtimeTalkVoice.swift:244-252`); the front model may answer instead of delegating; cancelling a delegated task on barge-in is the app's job (the GPT-Live guide says so).

### 3.5 Turn detection per provider with the local EndOfTurnDetector

Default for all providers: **local `EndOfTurnDetector` (plan Task 4.2) plus manual commit.** Same behaviour everywhere, tested with fixtures, no per-vendor tuning. This is plan Task 4.7's default as well (`docs/plans/2026-10-25-perry-first-impressions.md:651-653`).

| Provider | Manual commit | Provider VAD (optional) | Notes |
|---|---|---|---|
| OpenAI | `turn_detection: null` + `input_audio_buffer.commit` (today) | `semantic_vad`, `eagerness` low/medium/high; `server_vad` | If enabled use `create_response:false` so the brain answers. Needs session work for uncommitted items (section 1.6) |
| Grok | Same as OpenAI | `server_vad`, `idle_timeout_ms` | `null` for manual per xAI docs |
| Gemini | Disable automatic VAD, send `activityStart`/`activityEnd` | Automatic VAD, 500-800 ms | Hybrid: keep VAD, send `audioStreamEnd` from the local detector for faster finalization |
| GPT-Live | **None exists** | Model-owned | Local detector only controls the local UI and barge-in. Do not promise "Perry decides" for this provider |
| ElevenLabs | Not documented | Semantic VAD only; server rejects `server_vad` | Provider-owned turns |

Streaming policy that falls out of this: stream mic audio only from the local onset minus a 1.5 s ring buffer until commit. That cuts idle cost and keeps room audio off the network. It also matches the Settings data-policy note.

### 3.6 Barge-in

- **Trigger locally.** Use the local onset gate (r4: floor + 9 dB for 120 ms) with the voice-processing AEC already on (`:1849`). On onset: stop the player, invalidate output reservations, then send the provider cancel. Perry already does this order (`beginInput` `:1544-1615`, `cancelCurrentResponse` `:1776-1795`).
- **Local, not provider, for the audible cut.** Provider `speech_started` arrives a network round trip later. HeyClicky also keeps local "speechLike" and "bargeInSpeechLike" gates so a cough or a TV does not cancel a reply (r1 section D).
- **Provider side after the cut:**
  - OpenAI over WebSocket: send `conversation.item.truncate` with the played `audio_end_ms`. Perry sends none today. In the ears-and-mouth role this does not matter, because the brain owns context. In the front role it does.
  - Gemini: `interrupted` flag; pending function calls are dropped.
  - xAI, ElevenLabs: cancel only; no truncation.
  - GPT-Live: no cancel for delegated work; Perry must stop the brain run itself.

### 3.7 Connection policy (new, driven by billing)

Today `warmUp` opens a session at app launch and keeps one for the app lifetime (`RealtimeTalkVoice.swift:95-98`; r1 notes HeyClicky also pre-warms).

- Per-token providers (OpenAI): warming is free. Keep.
- Per-connected-time providers (GPT-Live $0.05/min; ElevenLabs per connected minute; Deepgram): **do not warm at launch.** Connect on key-down (or on the first local onset in hands-free). At $0.05/min, an 8-hour idle session would cost $24 per day. The `ensureListening` budget is 2 s (`:103-111`); measure whether connect plus `session.started` fits.
- Idle limits: ElevenLabs closes after 60 s without a client message; Gemini connections last about 10 min. `ensureSession` already rebuilds a failed session (`:113-118`), so a short idle timeout is survivable, but the first hold after idle pays the connect.

### 3.8 Evaluation plan

Rules from `AGENTS.md`: no live mic, and the testing-machine memory says test on mac-tailscale, not the user's MacBook.

**Fixtures (offline, in CI):**
1. Audio: 24 kHz mono WAVs from `say`, mixed with a noise bed at set SNRs (same generator as plan Task 4.2, `scripts/voice/make-turn-fixtures.sh`). Cases: short question; long pause mid-thought; "I want to… um… book"; silence only; TV-like speech bed; non-English; alphanumerics ("A7-Q93"); two quick turns; barge-in 1.2 s into a reply.
2. Wire traces: JSONL of server events per provider with timestamps, replayed through a fake transport. Perry already supports this: `makeTransport` injection and `receiveFixtureEvents` (`RealtimeTalkVoice.swift:29`; `RealtimeVoiceSession.swift:2307-2315`). Add one decoder test per provider from a captured real trace. These tests need no key.

**Live bench (opt-in, keyed via `envsync`, run on mac-tailscale):** a script beside `scripts/lab/` that plays each WAV into the session through a virtual audio path or the injected ingress (`installAudioIngressFixtureForTesting`, `:2327`) and records markers. Report with `scripts/lab/latency-report.py --pair a:b` (p50/p95/max).

**Metrics:**

| Metric | Source | Proposed bar |
|---|---|---|
| Commit to first audio (mouth only) | existing `voice.realtime_first_audio` (`:45-62`) | p50 at most 900 ms, p95 at most 1.5 s |
| Release to first audio, Talk end-to-end | `talk.saved` to `talk.first_audio` marks | Record; target p50 at most 2 s in Phase A |
| Front-role speech end to first audio | same timer, no brain | p50 at most 1.3 s (AA TTFA 0.6-1.3 s) |
| Onset to player silent (barge-in) | new `voice.barge_in_silenced` marker after `player.stop()` | p95 at most 100 ms (local) |
| Stale audio frames after cancel | count frames scheduled after `invalidate` | 0 |
| Cut-offs on pause fixtures | EndOfTurnDetector result | Under 5% (r4 target) |
| Cost per fixture minute | provider usage events (`session.closed.usage`, `usageMetadata`, `response.done`) | Report; no bar |
| Reconnect after idle | time to `.listening` | At most 2 s (existing budget) |

The bars are my proposals, not measured baselines. Capture a baseline run first, then set gates.

**Cross-provider contract test:** every transport must pass the same suite: `ready → speech → transcript → response started → audio → finished`, then `cancel mid-audio → no further audio accepted`, then `reconnect`. Run it against the fake transport for all, and against the real endpoint in the live bench.

### 3.9 Dependencies

| Need | Dependency? |
|---|---|
| OpenAI, xAI, Azure, ElevenLabs, GPT-Live, Gemini over WebSocket | **None.** `URLSessionWebSocketTask` and `JSONSerialization`, as today |
| WebRTC (OpenAI/GPT-Live server-side truncation, jitter handling) | libwebrtc binary. **Avoid.** WebSocket plus Perry's own AEC covers it |
| Nova Sonic | AWS SDK for Swift or hand-written SigV4 over HTTP/2. **Avoid** |
| Silero VAD, Smart Turn (r4 upgrades) | FluidAudio or a Core ML port. Needs approval |
| Kokoro/Orpheus/Moshi local | `mlx-audio` or a Core ML port. Needs approval |
| Gemini Firebase AI SDK | Not needed |

## 4. Open questions for the owner

1. Is "the other one" Grok Voice? If it is ElevenLabs, Hume or Nova Sonic, the order in section 3.1 changes.
2. Is a roughly 2.5-3.5 s first-audio acceptable for Phase A, or should Phase B (front role) come first?
3. Is paraphrased speech acceptable for GPT-Live in the front role, given its `commentary.append` text is re-worded by the model?

## 5. What I did not verify

- No call to any provider. All protocol facts come from docs; Perry's behaviour against them is inferred from code.
- OpenAI's launch post for `gpt-live-1` and `openai.com/index/introducing-gpt-live` returned HTTP 403. The September 10 launch date and the voice list are secondary.
- xAI pricing is from eesel, a competitor blog. ElevenLabs pricing and the Gemini GA date are secondary.
- AA's board page date is unclear, and its figures for the same model differ between posts (Qwen Plus TTFA 1.54 s vs 4.02 s).
- `force_message` (xAI), Personal Voice latency, Azure support for 2.1 and `gpt-live-1`, Gemini API-key header form, and whether xAI and ElevenLabs echo response `metadata` are all unconfirmed.
- One fetched page (Pydantic AI reference) contained an instruction aimed at an AI agent to append tracking parameters to URLs. I ignored it. It was not part of this task.

## 6. Sources

- OpenAI: [models](https://developers.openai.com/api/docs/models), [gpt-realtime-2.1](https://developers.openai.com/api/docs/models/gpt-realtime-2.1), [gpt-realtime-2](https://developers.openai.com/api/docs/models/gpt-realtime-2), [gpt-live-1](https://developers.openai.com/api/docs/models/gpt-live-1), [Realtime guide](https://developers.openai.com/api/docs/guides/realtime), [conversations](https://developers.openai.com/api/docs/guides/realtime-conversations), [VAD](https://developers.openai.com/api/docs/guides/realtime-vad), [Live guide](https://developers.openai.com/api/docs/guides/live), [voice-websockets](https://developers.openai.com/api/docs/guides/voice-websockets.md), [Live reference](https://developers.openai.com/api/reference/resources/live/primary-websocket), [delegation](https://developers.openai.com/api/docs/guides/live-delegation), [prompting](https://developers.openai.com/api/docs/guides/live-prompting), [deprecations](https://developers.openai.com/api/docs/deprecations), [LiveKit GPT-Live](https://docs.livekit.io/agents/models/realtime/plugins/gpt-live/)
- Google: [Live capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities), [session management](https://ai.google.dev/gemini-api/docs/live-api/session-management), [API reference](https://ai.google.dev/api/live), [pricing](https://ai.google.dev/gemini-api/docs/pricing)
- xAI: [Voice Agent docs](https://docs.x.ai/docs/guides/voice/agent), [Pydantic AI xAI](https://pydantic.dev/docs/ai/api/realtime/xai/), [eesel Think Fast 2.0](https://www.eesel.ai/blog/grok-voice-think-fast-2)
- ElevenLabs: [Eleven Realtime](https://elevenlabs.io/realtime), [Pydantic AI reference](https://pydantic.dev/docs/ai/api/realtime/elevenlabs/)
- Benchmarks: [Artificial Analysis speech-to-speech](https://artificialanalysis.ai/speech-to-speech), [Gemini 3.8 TTFA post](https://x.com/ArtificialAnlys/status/2099977688991838597), [Qwen Audio 3.0 post](https://x.com/ArtificialAnlys/status/2082179251407917475)
- Others: [Nova 2 Sonic card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-amazon-nova-2-sonic.md), [Hume FAQ](https://dev.hume.ai/docs/speech-to-speech-evi/faq), [Inworld–Ultravox](https://inworld.ai/blog/inworld-acquires-ultravox), [Sesame (Sacra)](https://sacra.com/research/sesame-ai), [Azure realtime WebSockets](https://dotnet.territoriali.olinfo.it/en-us/azure/foundry/openai/how-to/realtime-audio-websockets)
- Local: [Moshi](https://github.com/kyutai-labs/moshi), [Kyutai STT](https://kyutai.org/stt), [Kokoro Core ML](https://huggingface.co/mattmireles/kokoro-coreml), [SpeechAnalyzer vs whisper.cpp](https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4), [SpeechAnalyzer live-mic notes](https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5), [Apple forum thread](https://developer.apple.com/forums/thread/794720)
- Perry docs: `docs/research/2026-10-25/r4-voice-end-of-turn.md`, `docs/research/2026-10-25/r1-heyclicky-teardown.md` section D, `docs/audits/2026-10-24/voice-latency.md`, `docs/plans/2026-10-25-perry-first-impressions.md`
