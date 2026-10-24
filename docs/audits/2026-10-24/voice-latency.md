# Perry push-to-talk latency audit

Date: 2026-10-24. Read-only audit of the working tree on `codex/living-ink-redesign`. Nothing was built, run, or edited.
Legend: **[V]** verified in code or in a marker file. **[I]** inferred, not measured.

## 1. Headline

The 2026-10-22 "live pass" number (key-up → first text p50 1.9 s) **leaves out two stages** and hides one tail:

1. The drill uses `ScriptedSpeechInput` (App/Talk/TalkSpeech.swift:181-200). Its `finalize()` returns at once. **Real STT finalization after key-up has never been measured** on the Talk path. [V]
2. `output` was muted, so `talk.first_audio` is only the moment a sentence is queued. It is not audible speech. `enqueueSpeech` writes no `talk.speak.start` mark. [V]
3. The drill question ("what does this do") classifies as `.fast`. Any question containing "how", "why", "explain", "step" or "write" (or with more than 400 elements, or more than 160 characters) goes to the **deep** tier. On Codex that means `gpt-6-luna` at default effort, which `docs/evidence/phase-1/talk-brain-decision.md` measured at 17-44 s. [V code, V doc]

**The default brain cannot reach the target.** The default brain is Codex (ChatGPT sign-in), model `gpt-5.6-terra`, effort `none`. The Phase-1 spike measured 1.46 s p50 to first token on a warm thread, and the 2026-10-22 run measured 1.2-1.8 s from `talk.saved` to first text. That is model time on the server. Transport and Perry code are not the main cost. Fixing Perry-side overhead can remove about 0.3-0.5 s. First text under 500 ms needs a different route for simple questions: a BYOK fast model, or a realtime model, with the prefix warmed during the hold.

## 2. Measured critical path (scripted STT, Codex terra, n=5)

Source: `docs/evidence/lab/perf-20261022T143752Z.jsonl.markers.jsonl`, summarized with `scripts/lab/latency-report.py`. Times are ms after `talk.keyup` unless noted.

| Stage | Marks | p50 | range | On key-up path? |
|---|---|---|---|---|
| Hold start → commit | `talk.keydown` → `talk.hold_commit` | 131 | 131-137 | No (during hold) |
| Capture (AX + SCK screenshot) | `hold_commit` → `capture.done` | 88 | 88-164 | No. It finishes 1.2-1.5 s before key-up. |
| Key-up → ack sound | `talk.keyup` → `sound.cue.send` | **66** | 43-80 | Yes. It blocks the turn start. |
| Persist input | `home.question.sent` → `talk.saved` | **127** | 125-186 | Yes |
| Persist → first text | `talk.saved` → `answer.first_text` | **1742** | 1223-3260 | Yes. This is model plus brain plumbing. |
| Provider → TalkSession hop | `home.answer.first_text` → `answer.first_text` | 36 | 34-37 | Yes |
| Key-up → first text | `talk.keyup` → `answer.first_text` | 1939 | 1418-3529 | n=5, so p95 is the max |
| First text → sentence queued | `answer.first_text` → `talk.first_audio` | **416** | 381-2346 | Yes |
| Real STT finalize | none | unknown | unknown | Yes. Estimated 250-700 ms [I]. |
| Audible TTS start | none | unknown | unknown | Yes |

The first run of the 2026-10-22 batch was 3529 ms (cold thread). A fresh conversation adds a Codex `thread/start` (52-380 ms warm, ~3.5 s first turn per the Phase-1 doc).

## 3. Stage-by-stage trace (key-down → first spoken audio)

| # | Stage | What runs | Serial / parallel | File:line | Cost | Can start earlier? |
|---|---|---|---|---|---|---|
| 1 | Event tap | Listen-only CGEvent tap; callback hops through `Task { @MainActor }` | Serial, main | App/Talk/ModifierHoldMonitor.swift:93-117 | <1 ms unless main is busy [I] | Take a raw timestamp in the callback. The mark is taken after the hop. |
| 2 | Key-down | `keyDown()`: wake session, set listening state, show overlay | Main | App/Talk/TalkSession.swift:90-123 | ≤50 ms budget | Already early |
| 3 | Commit gate | Fixed 120 ms delay to filter chords. Mic, trace, capture and warm start only after it. | Serial after key-down | ModifierHoldMonitor.swift:49,171-188; TalkSession.swift:127-153 | 131 ms | Start mic and capture at key-down, and cancel on chord. This cuts clipped leading words. |
| 4 | Mic start | `SFSpeechInput.startIfReady` → `DictationController.start` → `startEngine`: builds request, `setVoiceProcessingEnabled(true)` on **every** start, installs tap, `audioEngine.prepare/start` | Main, sync | App/DictationController.swift:240-262, 300-345 (VP at 321) | Unmeasured. Voice processing plus engine start is typically 100-300 ms [I]. | Yes. Start at key-down. VP stays set between holds. |
| 5 | Warm | `warm()` → `brain.route(fast).provider.warm()` | Parallel task, **only at commit** | App/AppSubsystems.swift:258-260; TalkSession.swift:152 | Codex: process spawn ~2.5 s cold, ~40 ms warm [V doc]. OpenAI, Anthropic, Gemini and OpenAI-compatible providers have an **empty** `warm()`. Apple FM only reads availability. [V] | Warm at launch and re-warm at key-down. |
| 6 | Capture | CGWindowList + AX hit test + ≤42 batched describes + SCK frame (≤1600 px, JPEG q0.75) | Parallel, at commit | App/Talk/TalkObservationCapture.swift:27-62; LocalTalkObserver.swift:33-77, 261-277 | 88 ms p50 | Already off the key-up path. Do the PNG encode here (see fix F6). |
| 7 | Key-up | `keyUp()`: `guidePlay(.send)` is the **first** statement, then phase change and `turnTask` creation | Main, serial | TalkSession.swift:156-169 (cue at 160) | **66 ms p50** | `SoundPlayer.play` calls `QuietHours.isActive` (App/SoundPlayer.swift:29), a synchronous `INFocusStatusCenter.focusStatus` XPC read on main. The attribution is [I]. The gap is [V]. |
| 8 | STT finalize | `dictation.finish()` → `endAudio` → wait for `isFinal`. Partials are stored but never used as the answer. Watchdog 2.5 s. | Serial | TalkSpeech.swift:105-121; DictationController.swift:266-284, 377-410 | Unmeasured [I] 250-700 ms. A language-detect reroute (line 422) replays the buffer through a second recognizer. | Speculate with the last partial (F5). |
| 9 | Accept and persist input | `acceptInput` → `saveInput` → `ThreadStore.stageInput` (atomic JSON rewrite plus backup copy of the whole thread) → `refreshThreads()` (full list, sort, main-actor publish) | **Serial, awaited before anything else** | App/Home/HomeController.swift:602-656, 780; TalkSession.swift:264-267 | **127 ms p50** | Merge with `beginTurn` and drop the `refreshThreads` wait (F2). |
| 10 | Observation join | `await captureTask.value`, deixis resolve | Serial, already done | TalkSession.swift:270-291 | ~0 | n/a |
| 11 | Previous-turn join | `await presentationTask?.value` | Serial | TalkSession.swift:295 | ~0 normally | n/a |
| 12 | Run setup | `AgentCoordinator.execute`: `beginTurn` (second full-thread persist) → `provider(route)` → `systemPrompt` (`perrys.list()` re-reads and decodes every Perry JSON, plus memory read) → build context → `prepareConversation` (awaits `contextWindow` twice) → `workerLease.withRun` (takes a `.background` worker for Codex, which has `.tools`) | **Serial awaits, no marks** | App/Tools/AgentCoordinator.swift:196, 228, 230, 284, 298; ConversationContext.swift:74 | Unmeasured. Disk-bound steps likely 20-100 ms [I]. | Pre-compute system prompt at hold commit. Persist `beginTurn` off the critical path. |
| 13 | Codex thread | Reuse thread for the same `conversationKey` only if `system` and `tools` are identical, else `thread/start` | Serial | Codex/CodexAppServerProvider.swift:227-250 (reuse check ~171) | 52-380 ms warm; ~3.5 s on a conversation's first turn [V doc] | Pre-create at key-down (the window key is known from the hint). |
| 14 | Image encode | `pngWireData`: JPEG → CGImage → PNG on every turn, then write the file | Serial, in request build | CodexAppServerProvider.swift:584-600 | 60-150 ms for 1600 px [I]. PNG is 5-10× the JPEG size, so the upload is bigger too. | Do it in the capture task during the hold. |
| 15 | Model | `turn/start` → server. Fast tier = `gpt-5.6-terra`, `effort=none` | Serial | CodexAppServerProvider.swift:296-302 | **1.2-1.8 s** (Phase-1 doc: 1.46 s p50) | Cannot be fixed inside Codex. See F3 and F4. |
| 16 | Stream hops | Codex notification → JSONRPC → `HealthReportingStream` Task → `AgentLoop` actor → AsyncStream → `consume` (MainActor) → HomeController loop → homeModel publish → AsyncStream → `TalkSession.stream` | 6 hops, main-actor contention | AgentCoordinator.swift:331-379; HomeController.swift:695-711; TalkSession.swift:355-367 | **36 ms** | The consumer is delayed by the SwiftUI update for `onPartial`. Yield first, update the UI second. |
| 17 | Chunker | `SentenceChunker` emits only at `.?!…` plus whitespace, or a newline | Serial | Packages/PerryBrain/Sources/PerryBrain/Talk/SentenceChunker.swift; TalkSession.swift:365-367 | **416 ms p50** after first token, 2.3 s worst | Flush the first clause early (F7). |
| 18 | TTS | `AVSpeechSynthesizer.speak` per sentence. Per sentence: route-mute CoreAudio queries, voice lookup (cached) | Main | App/VoiceController.swift:358-378 (synthesizer at 36) | **Audible start unmeasured.** No warm-up utterance. No `didStart` delegate or mark. [V] | Warm at launch (F8). |

## 4. Answers to the specific questions

- **STT**: Apple SFSpeech, on-device (`requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`). DictationController.swift:568-570. Partials are collected (`latestTranscript`, `latestWords`) and not used for the early answer. Key-up waits for `isFinal`. [V]
- **Capture timing**: after the 120 ms commit gate, during the hold. It is not a key-up cost for holds longer than about 0.4 s. The typed Ask path is different: `runAsk` does save → `presentationTask` → **capture** serially (TalkSession+Ask.swift:116-135), and speaks only after the whole answer finishes (line 173). [V]
- **Provider connection / session**: Codex warms at commit only. The JSON-RPC process is persistent. Spawn is ~2.5 s cold, ~40 ms warm. BYOK providers use `URLSession.shared` (HTTPStreaming.swift:12-14) with **no pre-connect**: every cold TCP+TLS+HTTP/2 setup (~100-300 ms [I]) lands on the first request of each idle period. `warm()` is empty on OpenAI, Anthropic, Gemini and the OpenAI-compatible provider. [V]
- **Router**: `TierClassifier` exists and **does** apply to Talk (AgentCoordinator.swift:224-228). It is crude: "how", "why", "explain", "step" and "write" all route to deep. More than 400 elements, more than 160 characters, or more than 2 deixis bindings also route to deep. Deep on Codex means `gpt-6-luna` at default effort. The user's own phrasing ("how do I…") hits this often. [V code]
- **Default route**: `modelChoice` defaults to ChatGPT (`BrainController.swift:~78`) → `providerID = .codex` (`route()`). `fastOrder` and `deepOrder` are bypassed for the ChatGPT choice. [V]
- **Prompt size**: system rules are small. The element index is capped at ~42 entries. The cost is the screenshot: up to 1600 px on the long edge, JPEG q0.75, attached to every turn. Anthropic has no `cache_control`. OpenAI Responses sets no `reasoning.effort`, so `gpt-5-mini` reasons at default (medium). Gemini sets no `thinkingBudget`. `max_output_tokens` is 4096 for a spoken reply. Image parts carry no `detail` hint. [V absent; effect size [I]]
- **Streaming**: yes. Tokens are shown and chunked as they arrive. The delay is chunking (stage 17) and the 36 ms hop (stage 16).
- **Transport detail**: `URLSessionLineStreaming` iterates `AsyncBytes` one byte at a time with an `await` per byte (HTTPStreaming.swift:24-40). This is a few ms of CPU per turn. It is not a top cost. [V code, I effect]
- **Codex process**: persistent. One `thread/start` is reused per `conversationKey` (per window) only while `system` and the tool list stay byte-identical. Any memory edit or Perry change starts a new thread. [V]
- **Debounces and sleeps**: Talk has the 120 ms commit gate. `stream()` polls `isSpeaking` every 25 ms (TalkSession.swift:398-401), which is after the answer, not on the path. The wake-word conversation controller (`VoiceConversationController`) has a **1.5 s `finalizeDelay`** endpoint wait (line 41, `armFinalize` 281). That path is separate from Talk. [V]
- **Realtime**: `RealtimeTalkVoice` exists (BYOK key plus realtime config). It is used as **STT and TTS only**; Perry's brain still answers (RealtimeTalkVoice.swift:6-12). The first spoken sentence goes through `speakText`, which costs a model response per sentence. It is not a duplex brain. [V]

## 5. Ranked fix list

Savings are per turn on the key-up → first-text or key-up → first-audio path. "Eff" is effort. Risk is regression risk.

| Rank | Fix | Saving | Eff | Risk | Files |
|---|---|---|---|---|---|
| **F1** | **Keep deep-tier reasoning out of Talk.** Talk never uses `gpt-6-luna` at default effort. Either pin Talk to `.fast` and set `effort` to `low` for deep-worthy questions, or answer fast first and offer "think harder" as a follow-up. Drop "how", "why", "step", "write" from `deepSignals` for the Talk surface. Raise the 400-element and 160-character limits. | **15-40 s on affected questions** (p95/p99 tail). 0 on easy ones. | S | Low. Quality drop on hard questions is the trade-off. | TierClassifier.swift:4-14; AgentCoordinator.swift:224-226; CodexAppServerProvider.swift:296-302 |
| **F2** | **Take the persistence off the key-up path.** `acceptInput` followed by `await saved` plus `refreshThreads` costs 127 ms; `beginTurn` then does a second full-thread rewrite. Write once (stage and begin in one `upsert`), and run `refreshThreads` after the model call starts. | **~110-130 ms** [V for 127 ms] | S-M | Medium. Crash-durability of "waiting input" (restore on interrupt, HomeController.swift:712) must keep working. | HomeController.swift:602-656, 687, 780; ThreadStore.swift:223-270; TalkSession.swift:264-267; AgentCoordinator.swift:196 |
| **F3** | **Add a fast Talk route: speculative direct call.** Add a Talk-only route to a streaming BYOK fast model (e.g. Haiku-class, Flash-Lite-class, `gpt-5-mini` with `reasoning.effort=minimal`) when a key exists. Set `max_output_tokens` ~300, `detail: "low"` on the image, `thinkingBudget: 0` (Gemini), `cache_control` on the system block (Anthropic). Send the request at key-down with the screenshot and context. Append the transcript at key-up. | **~0.8-1.2 s** vs Codex terra (model TTFT 350-700 ms with a warm connection [I, vendor-typical, unmeasured here]) | M | Medium. Needs the key. Tool and draw tags must work on the new route. | New route in BrainController.swift (route()); OpenAIResponsesProvider.swift:142-146; AnthropicMessagesProvider.swift:145-150; GeminiProvider.swift:131; AgentCoordinator.swift:224-228 |
| **F4** | **Realtime duplex brain for simple questions.** Reuse `RealtimeVoiceSession`: push the screenshot as an input image at key-down, stream mic audio during the hold, `commit` plus `response.create` on key-up, use transcript deltas as text and audio deltas as speech. | **First text ~300-500 ms, first audio ~400-700 ms** [I, public realtime numbers] | L | Medium-high. Draw tools need function calls. Deixis gets only evenly spread word times (RealtimeTalkInput.words). | RealtimeTalkVoice.swift; RealtimeVoiceSession.swift; TalkSession.swift:127-169 |
| **F5** | **Do not wait for `isFinal`.** After `endAudio`, return when the last partial has been stable for ~120-150 ms, or when `isFinal` arrives, whichever is first. Keep the 2.5 s watchdog. Skip the language-detect reroute for holds under ~3 s, or run it only if the partial is empty. Longer term: `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+) with volatile results and `audioTimeRange` word timing. | **150-500 ms** [I]. Measure with F-M1 first. | M (partial) / L (SpeechAnalyzer) | Medium. Wrong word at the end of an utterance. The final result can replace it (cancel and re-run is safe because Talk never acts). | TalkSpeech.swift:105-121; DictationController.swift:266-284, 377-410, 422 |
| **F6** | **Move the image work into the hold.** Encode the PNG (and optionally downscale to ~1024 px for the fast tier) inside the capture task so the key-up path writes bytes only. Send JPEG to BYOK providers unchanged. | **60-150 ms** [I] plus a smaller upload and fewer vision tokens (~0.5-1.0 s TTFT on BYOK at 1024 vs 1600 px [I]) | S | Low. Check the deixis element crops still sit inside the smaller frame (`InkAccentSampler` uses the JPEG). | CodexAppServerProvider.swift:584-600; LocalTalkObserver.swift:28-31, 261-277; TalkSession.swift:440-448 |
| **F7** | **Flush the first clause early.** For the first chunk of a turn, emit at a clause boundary (`, ; : —`) after ≥ ~28 characters or ≥ 6 words; keep sentence boundaries afterwards. | **~200-400 ms to first audio** (p50 delay today is 416 ms; worst 2.3 s) | S | Low. Prosody on a short first chunk. | Packages/PerryBrain/.../Talk/SentenceChunker.swift; TalkSession.swift:365-367 |
| **F8** | **Pre-warm everything at launch and key-down.** (a) Brain: call the routed provider's `warm()` at launch and again at key-down. Give the BYOK providers a real `warm()` (open TCP+TLS+HTTP/2 with a cheap `GET /v1/models`, or a dedicated `URLSession` with `assumesHTTP3Capable`). (b) Codex: `thread/start` at key-down for the hinted window, with the system prompt built at commit. (c) TTS: speak a zero-volume utterance once at launch and after a voice change. (d) STT: run one short silent buffer through the recognizer at launch to load the on-device model. | Cold TLS 100-300 ms; first-hold Codex spawn ~2.5 s; new-thread 65-380 ms (~3.5 s on first turn); cold TTS 150-600 ms [I]; cold STT model 300-1000 ms [I] | S-M | Low. Idle power: check `idle-probe.sh` budgets (≤0.5% CPU, ≤180 MB). | AppSubsystems.swift:258; AppController.swift:332-335; Providers/*.swift warm(); VoiceController.swift:36; TalkSpeech.swift:74 |
| **F9** | **Take the Focus query off the ack path.** Cache `QuietHours.isActive` (refresh at key-down in the background, or observe focus changes). Play the cue after `turnTask` creation. | **44-80 ms** [V gap; cause [I]] | S | Low. | SoundPlayer.swift:29; TalkSession.swift:156-169 |
| **F10** | **Deliver the first token to Talk before updating the UI.** In the `runSpokenTurn` loop, `continuation.yield(event)` first, then `onPartial`. Throttle `homeModel` partial publishes to ~15 Hz for the talk surface. Drop the per-delta `updateTalk` publish or coalesce it. | **~30 ms** [V gap] | S | Low. | HomeController.swift:695-711, 733-745; TalkSession.swift:358-367 |
| **F11** | **Serial awaits in `execute`.** Build the system prompt (`perrys.list()` decode of every Perry file, memory read) at commit, not after key-up. Cache the `contextWindow` result per provider (it is awaited twice per turn). Take the worker lease lazily (Talk only needs it if a tool actually runs); a full `.background` capacity throws `capacityReached` and fails the turn. | 20-100 ms [I] | M | Medium. | AgentCoordinator.swift:196-305, 381-395; ConversationContext.swift:74; AgentLoop.swift:~139 |
| **F12** | **Start the mic at key-down.** Move `speech.startIfReady()` ahead of the 120 ms commit gate; cancel on chord. Keep voice processing on the node between holds. | 0 ms to first text. Stops clipped leading words and saves ~130 ms of lost speech. | S | Low-medium. The mic indicator lights for stray chords. | TalkSession.swift:90-153; ModifierHoldMonitor.swift |
| **F13** | **Typed Ask: speak as it streams, capture early.** Ask captures after the save and speaks only the full answer. Reuse the Talk chunker and capture at composer open. | 1-several s on Ask; not the push-to-talk path | M | Low | TalkSession+Ask.swift:116-176 |
| **F14** | **SSE reader.** Replace the per-byte `AsyncBytes` loop with chunked delegate delivery. | ≤5-20 ms/turn [I] | M | Low | HTTPStreaming.swift:21-44 |
| **F15** | Wake-word conversation uses a 1.5 s endpoint delay. Lower to ~700 ms with partial-stability gating. | ~0.8 s (not Talk) | S | Medium (cuts off pauses) | VoiceConversationController.swift:41, 281-290 |

### What a realistic plan buys

- **Codex only** (F1, F2, F5, F6, F7, F8, F9, F10, F12): about 1.9 s → ~1.2-1.4 s to first text (model floor ~1.2 s), plus a much better p95 and first-audio. **It will not reach 500 ms.**
- **BYOK fast route + warm prefix + speculation** (adds F3): ~0.5-0.8 s to first text [I]. Reaches the target only with the request already in flight at key-up and the transcript as a short tail.
- **Realtime brain** (F4): the only option that plausibly meets both targets (500 ms text, 800 ms audio) for simple screen questions [I].

## 6. Instrumentation to add (so the user can prove each gain)

`PerfMark` lives in `App/PerformanceSampleLog.swift:4`. `Packages/PerryBrain` has **no** marks [V], so provider timings need an injected hook (for example a `ProviderTrace` closure on `ModelRequest` or the transport).

| Mark (proposed) | Where | Proves |
|---|---|---|
| `talk.keyup.raw` | Event-tap callback (ModifierHoldMonitor.swift:~93), before the `Task` hop | Tap-to-main hop (stage 1) |
| `talk.keyup.handled` | First line of `TalkSession.keyUp` | F9: ack/Focus cost |
| `talk.mic.ready`, `talk.mic.first_buffer` | After `audioEngine.start`; first tap buffer | Mic start cost (stage 4), F12 |
| `talk.stt.partial.first`, `talk.stt.partial.last`, `talk.stt.end_audio`, `talk.stt.final`, `talk.stt.reroute` | DictationController `handleRecognition` / `finish` | **F5: the missing STT finalize number** |
| `talk.finalize.done` | After `speech.finalize()` in `run` | Key-up → transcript |
| `home.input.save_begin/end`, `thread.begin_turn.begin/end` | HomeController.saveInput; AgentCoordinator.swift:196 | F2 split of the two persists |
| `brain.route.done`, `brain.system_prompt.done`, `brain.context.prepared`, `brain.lease.acquired`, `brain.request.sent` | AgentCoordinator.execute | F11: the unmarked gap between `talk.saved` and the wire |
| `brain.image.encoded` | `pngWireData` / capture | F6 |
| `codex.thread_start.begin/end`, `codex.turn_start.sent`, `codex.turn_start.ack`, `codex.first_delta` | CodexAppServerProvider | F3/F8: server vs plumbing |
| `http.connect`, `http.request_sent`, `http.headers`, `http.first_event`, `http.first_delta` | BYOK providers via hook | F8 warm connection, F3 TTFT |
| `warm.codex.ready`, `warm.http.ready`, `warm.tts.done`, `warm.stt.primed` | Launch and key-down warm tasks | F8 |
| `talk.first_clause_flush` | New chunker path | F7 |
| `talk.speak.enqueue` (rename today's `talk.first_audio`) and `talk.speak.start` in `enqueueSpeech`; **`talk.speak.audible`** from `AVSpeechSynthesizerDelegate.didStart` | VoiceController.swift:358, 1040 | **True first audible speech.** Today it is unmeasured. |
| `ui.first_text_rendered` | After the SwiftUI commit of the first `answerText` | First displayed text (today `answer.first_text` is only the model event) |
| `talk.turn.tier.fast/deep` | AgentCoordinator.swift:224 | F1: how often Talk lands on deep |

Also change the lab tooling:

- Add to `latency-report.py` `DEFAULT_PAIRS`: `talk.keyup:talk.stt.final`, `talk.keyup:talk.speak.audible`, `talk.saved:brain.request.sent`, `brain.request.sent:answer.first_text`.
- Make `scripts/lab/talk-drill.sh` run with `TALK_WAV` (real STT) and unmuted output, and add `ASSERT_AUDIBLE_P50`. The scripted path hides the STT finalize stage.
- Report n≥30 per run set. The current n=5 makes "p95" equal the maximum.

## 7. Verified vs inferred summary

- **Verified in code**: empty `warm()` on all HTTP providers; JPEG→PNG transcode per turn; no `reasoning` / `thinkingBudget` / `cache_control` in request bodies; `TierClassifier` keywords and Talk's use of it; stage/begin double persist plus `refreshThreads` before the model call; STT waits for `isFinal`; chunker waits for a sentence boundary; `enqueueSpeech` has no mark; no TTS or STT warm; the typed Ask path serial order; realtime used for STT/TTS only; wake-word 1.5 s delay.
- **Verified in markers**: 66 ms ack gap; 127 ms persist; 1.74 s save→first text; 36 ms hop; 416 ms first-text→sentence; capture 88 ms during the hold.
- **Inferred (needs the new marks)**: real STT finalize cost, mic/VP start cost, cold TLS and cold TTS cost, PNG encode cost, the 20-100 ms in `execute`, the Focus-query attribution, BYOK and realtime TTFT numbers.
