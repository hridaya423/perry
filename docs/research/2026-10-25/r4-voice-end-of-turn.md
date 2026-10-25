# R4: Voice end-of-turn detection for Perry

Date: 2026-10-25. Method: code reading plus web research. I did not launch Perry, build, run tests or use the microphone. Anything about runtime behaviour is therefore **inference from code** and is marked `(inference)`. Web facts carry a URL. Facts I could not confirm are marked `(unverified)`.

User complaint: "the talk to me, like mic, it should auto detect when im done talking no? like why would i have to go to the notch and then click done talking?"

## 0. Summary

- Perry has **four separate voice-turn paths**. Only one of them (hold-to-talk) ends a turn deterministically. The click-the-mic path has an auto-end heuristic, but it is weak and its UI contradicts it.
- The click-the-mic path (`VoiceConversationController`) ends a turn 1.5 s after the **last partial-transcript change**, not after audio silence (`App/VoiceConversationController.swift:41`, `:163-168`, `:282-290`). It never arms until the first non-empty partial arrives. If no partial arrives, it waits 20 s and fails (`:42`, `:292-300`).
- The UI shows a manual button as the primary control: **"I'm done"** (`App/Home/HomeOnboardingView.swift:281`). The notch workspace shows **"Stop"**, which *cancels* and discards (`App/Home/NotchWorkspaceView.swift:594`). When listening starts, the presenter hides the notch panel (`App/SessionPanelPresenter.swift:214-221`, `:283-288`), so the Stop row is hidden too. That fits "go to the notch and click" `(inference)`.
- No code path measures audio energy or runs a VAD. No path uses Apple `SpeechAnalyzer`. All local STT is `SFSpeechRecognizer` on-device.
- Realtime voice sets `turn_detection` to `null` (`App/RealtimeVoiceSession.swift:1279`, `:1309`), so the server never ends a turn either.
- Apple `SpeechAnalyzer` and `SpeechDetector` give **no end-of-utterance signal**. `SpeechDetector` only gates transcription, and its results only report errors today. Perry must supply its own endpointer.
- Recommended design: one pure, testable `EndOfTurnDetector` state machine fed by an energy VAD (built in) plus transcript and word-timing cues (built in). Optional upgrades: Silero VAD via FluidAudio, then Smart Turn. These need approval as new dependencies.
- Hands-free base silence is about 700 ms, stretched to about 1.2 s after a trailing filler or conjunction, capped at 2.5 s. Hold-to-talk stays "release = send".
- The notch shows listening, then a shrinking "sending" arc during the last silence, then thinking. Tap, hotkey or Return sends now. Speaking again extends. Esc cancels.
- Test with recorded or `say`-synthesised audio fixtures and a virtual clock. No live mic.

## 1. Audit of Perry's current voice flow

### 1.1 Every way a turn starts and ends

| # | Path | Starts | Ends | Engine | Code |
|---|---|---|---|---|---|
| A | **Talk** (hold ⌃⌥) | Modifier held past 120 ms commit delay | **Key release** | `SFSpeechRecognizer` on-device via `DictationController`, or OpenAI realtime if configured | `App/Talk/ModifierHoldMonitor.swift:19-23,58`, `App/Talk/TalkSession.swift:92-176` |
| B | **Steering hold** (hold ⌃⌥ while a task runs) | Same chord | Key release | `DictationController` or realtime | `App/AppSubsystems.swift:299-312`, `App/VoiceController.swift:469-592` |
| C | **Push-to-talk dictation** (fn, ⌥⌘Space, ⌃⌥⌘ hold; Caps double-tap) | Chord down | Release, or second Caps tap | `DictationController` or realtime | `App/PushToTalkController.swift:3-37,195-236`, `App/VoiceController.swift:123-127` |
| D | **Click the mic** (notch composer, conversation composer, onboarding "Talk to Perry") | Button click | **Heuristic: 1.5 s since last partial change**, or the user clicks a button | `SFSpeechRecognizer` on-device via `DictationController` | `App/VoiceConversationController.swift`, `App/Home/WorkspaceComponents.swift:68-81`, `App/Home/NotchWorkspaceView.swift:321`, `App/Home/HomeConversationView.swift:111-115` |
| E | **Mic in the session panel** ("Start dictation") | Click | Never ends by itself. The panel has no end control, so it relies on the shortcut release hint | `DictationController` via `VoiceController` | `App/SessionPanelView.swift:136-149` |
| F | **Wake word** ("hey perry") | Always-on recognizer matches the phrase | See 1.4. No endpoint exists | Second `SFSpeechRecognizer`, en-US only | `App/WakeWordListener.swift`, `App/VoiceController.swift:1024-1033` |
| G | **Realtime voice** (BYOK, any of the above when configured) | Same triggers | Same as the trigger. Server VAD is off, so the client commits | OpenAI-style realtime WebSocket | `App/RealtimeVoiceSession.swift:1255-1310`, `App/Talk/RealtimeTalkVoice.swift` |

Related audits already in the repo: `docs/audits/2026-10-24/ux.md` item 13 ("three overlapping voice loops") and `docs/audits/2026-10-24/voice-latency.md:69`. This report goes further on the end-of-turn mechanism only.

### 1.2 Speech engines in use

- **`SFSpeechRecognizer`, on-device, forced.** `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true` (`App/DictationController.swift:562-572`). Used by A, B, C, D, E and the wake word. `supportsOnDeviceRecognition` must be true or start throws (`:247-249`).
- **No `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber` or `SpeechDetector`.** A repo-wide grep over `App/` and `Packages/` returns no match.
- **Voice processing is on** for the dictation engine input node (`App/DictationController.swift:321`) and for realtime (`App/RealtimeVoiceSession.swift:1849`). That gives echo cancellation. It is not used for VAD.
- **Realtime:** `session.update` sets `turn_detection: NSNull()` for GA, beta and compatible modes (`App/RealtimeVoiceSession.swift:1279,1309`). Transcription model is `gpt-4o-transcribe` (`:1265`). The client commits with `input_audio_buffer.commit` on key-up (`:1051-1060`, `:1680-1740`). The parser already decodes `speech_started` and `speech_stopped` events (`:1171-1175`), but with VAD off I expect the server never sends them `(inference)`.
- **Deployment target is macOS 14.0** (`project.yml:4-5`). `SpeechAnalyzer` is macOS 26+, so any use needs `#available(macOS 26, *)` and the `SFSpeechRecognizer` path as the fallback.

### 1.3 Why the user must click "done talking" (path D)

Exact strings:

| String | Where |
|---|---|
| "I’m done" (primary button while listening) | `App/Home/HomeOnboardingView.swift:281` (action: `voice.finishListening()` at `:299`) |
| "Talk normally. I’ll answer when you pause." | `App/Home/HomeOnboardingView.swift:146` |
| "I’m listening." (title) | `App/Home/HomeOnboardingView.swift:131` |
| "Listening…" / "Thinking…" / "Speaking…" status row | `App/Home/NotchWorkspaceView.swift:568,570,572` |
| "Stop" (calls `voice.cancel()`, discards the turn) | `App/Home/NotchWorkspaceView.swift:594` |
| "I didn’t hear anything. Check that your microphone is on, then try again." | `App/VoiceConversationController.swift:298` |
| "I didn’t catch that. Try again." | `App/VoiceConversationController.swift:178,191` |
| "Working on your request" (thinking bubble) | `App/SessionPanelPresenter.swift:225` |
| "Talk to Perry" (mic button label) | `App/Home/WorkspaceComponents.swift:77` |

Mechanism, in order:

1. Click the mic. `start()` requests permission, starts `DictationController`, sets `.listening`, arms a 20 s silence timeout (`App/VoiceConversationController.swift:67-103`).
2. Each partial transcript calls `handlePartial`, which re-arms `armFinalize` (1.5 s) and the 20 s timeout (`:163-168`). When the finalize timer fires it calls `finishListening()` (`:282-290`).
3. `finishListening()` sets `.thinking`, calls `input.finish()` (stops the engine, `endAudio()`), and starts a 2 s fallback submit timer (`:106-121`, `App/DictationController.swift:266-272`). `DictationController` adds its own 2.5 s abort (`:274-284`).

Problems, each tied to the code:

1. **The endpoint is text-change based, not audio based.** `SFSpeechRecognizer` emits partials only when the hypothesis changes. Silence produces no event. Background speech, TV, keyboard noise that yields words, or late re-ranking all reset the 1.5 s timer `(inference)`. A user in a noisy room may never auto-end.
2. **It never arms before the first partial.** If the recognizer is slow to produce a first hypothesis, or the user speaks softly, no timer runs. The only exit is the 20 s no-speech failure (`:42`, `:292-300`) or a manual click.
3. **Fixed 1.5 s for every utterance.** It cannot tell a finished question from "I want to… um…". Short commands wait 1.5 s plus finalize time. Thoughtful pauses over 1.5 s cut the user off.
4. **Dead wait after the decision.** 1.5 s, then `endAudio`, then wait for the recognizer's final result, with 2 s and 2.5 s fallbacks. Worst case from last word to submit is about 4 s `(inference; no measurement taken)`.
5. **The UI teaches the user to click.** The onboarding primary button is "I’m done". There is no level meter, no countdown and no "sending in…" cue. The user cannot see whether Perry heard the pause.
6. **The cancel button is the only control in the workspace.** "Stop" discards (`NotchWorkspaceView.swift:594`). There is no "send now".
7. **The panel hides on listen.** The `.listening` branch calls `NotchPresentation.shared.dismissCurrent()` and `hideSurfaces()` (`App/SessionPanelPresenter.swift:214-221`), which calls `sessionPanel.hide()` (`:283-288`). The status row with "Stop" lives inside that panel. To end or cancel, the user must reopen the notch `(inference)`. This matches the complaint wording.
8. **Hold-to-talk is by design manual.** Path A ends on release (`TalkSession.swift:163-176`) and path C says "Release … when you’re done" (`PushToTalkController.swift:30-37`, `VoiceController.swift:566`). The Caps Lock double-tap shortcut is a toggle that needs a second tap (`PushToTalkController.swift:24,215-230`). That is a latch with no auto-end.

### 1.4 Other defects found on the way

- **Wake word dispatches on the first matching partial.** `WakeWordListener.inspect` runs on every partial (`App/WakeWordListener.swift:97-105,114-119`) and `WakeWordGate.match` returns whatever follows "hey perry" at that moment (`Packages/PerryGuide/Sources/PerryGuide/WakeWordGate.swift:19-24`). "Hey Perry, what’s the weather in Paris" can dispatch as "what’s" `(inference)`. No endpointing happens before `onWake(command)` runs `hooks.dispatch(trimmed, nil)` (`VoiceController.swift:1024-1033`).
- **"Hey Perry" alone opens the panel and speaks "I’m listening." but starts no capture** (`VoiceController.swift:1024-1030`). Nothing calls `beginDictation`. The listener stopped itself (`WakeWordListener.swift:117`). The user must then hold a key or type `(inference)`.
- **Realtime with VAD off means the server cannot tell us when the user stopped.** Hands-free realtime therefore has no endpoint at all today.
- **Talk's own finalize is already tuned for release:** 200 ms poll, 600 ms unchanged-since-release (`App/Talk/TalkSpeech.swift:113-147`). Keep it.
- **Wake word is en-US only** (`WakeWordListener.swift:36`).

### 1.5 What already exists and can be reused

- Partial and segment callbacks with word timestamps: `onPartial`, `onSegments` (`App/DictationController.swift:104-111,374-413`). Segment `timestamp + duration` gives the audio-clock end of the last recognised word.
- Audio tap on the input node, plus a retained buffer: `retainAudio` (`:333-336,518-525`). An energy meter can ride the same tap.
- Injectable timings and a fake input for tests: `Services.finalizeDelay`, `silenceTimeout`, `finalTranscriptTimeout` (`VoiceConversationController.swift:41-43`, `AppTests/VoiceConversationControllerTests.swift:80-82`).
- Earcons: `SoundPlayer.Cue` has `wake`, `send`, `receive`, `done`, `fail` (`App/SoundPlayer.swift:8-14`).
- Character moods `.listening`, `.thinking`, `.speaking` (`HomeOnboardingView.swift:115-124`) and an overlay `voiceState` (`SessionPanelPresenter.swift:209-241`).
- The repo already says "no fake wave animation" in a design brief (`.devin/ui-redesign/paper-views-task.md:7`). Use a real RMS signal or nothing.

## 2. Research: end-of-turn options on macOS in 2026

### 2.1 Apple Speech framework

| Item | Finding | Source |
|---|---|---|
| `SpeechAnalyzer` + `SpeechTranscriber` | macOS 26+. On-device. Results are *volatile* (fast rough guesses, enabled with `reportingOptions: [.volatileResults]`) or *final* (settled range). By default only final results arrive. | https://developer.apple.com/videos/play/wwdc2025/277/ , https://developer.apple.com/documentation/speech/speechtranscriber.md |
| Timing | `attributeOptions: [.audioTimeRange]` puts a `CMTimeRange` on each text run, precise to the sample. Useful to compute "silence since last word". | https://developer.apple.com/videos/play/wwdc2025/277/ |
| End-of-utterance signal | **None documented.** The session only shows `finalizeAndFinishThroughEndOfInput()` to settle volatile results when the app stops input. | same |
| `DictationTranscriber` | Same languages, model and devices as the old on-device `SFSpeechRecognizer`. No Siri or dictation setting required. | same |
| `SpeechDetector` | A VAD module that *gates transcription to save power*. Works only together with a `SpeechTranscriber` or `DictationTranscriber`. Sensitivity `.medium` is recommended. **Its `Result` "currently only support[s] error handling from the VAD model"**, so it does not give a speech-ended event. | https://developer.apple.com/documentation/speech/speechdetector.md |
| `SpeechDetector` bug | It did not conform to `SpeechModule`, so it would not compile in the `modules:` array. An Apple reply said a fix would ship "in the next point update to Tahoe". I could not confirm which release fixed it. | https://developer.apple.com/forums/thread/797544 |
| Model assets | Downloaded via `AssetInventory`, stored in system storage, not in the app's footprint. | https://developer.apple.com/videos/play/wwdc2025/277/ |
| `SFSpeechRecognitionMetadata` | `averagePauseDuration`, `speakingRate`, `speechDuration` exist (macOS 11.3+). Apple does not say they arrive on partials. `(unverified)` | https://developer.apple.com/documentation/speech/sfspeechrecognitionmetadata.md |

Conclusion: moving to `SpeechAnalyzer` may improve accuracy and latency of volatile results, but **does not solve end-of-turn**. It gives sample-accurate word end times, which feed our own detector.

### 2.2 Energy and VAD approaches

| Option | Facts | Source |
|---|---|---|
| Plain energy VAD (`vDSP` RMS on the tap) | Built in, about 0 cost. A forum answer suggests this as the workaround for `SpeechDetector`. Sensitive to noise unless it tracks a noise floor. | https://developer.apple.com/forums/thread/797544 |
| Silero VAD | About 2 MB JIT model, under 1 ms per 30+ ms chunk on one CPU thread, MIT licence (a badge alt text says CC BY-NC; check the LICENSE file). ONNX shipped, CoreML not in the main repo. | https://github.com/snakers4/silero-vad |
| FluidAudio (Swift SDK) | Apache-2.0. Silero VAD on CoreML, streaming via `processStreamingChunk`, 256 ms hop for offline probabilities. SwiftPM `https://github.com/FluidInference/FluidAudio.git`. **Models auto-download from Hugging Face at first use**; an offline mode exists. Also bundles ASR, diarization and TTS, which Perry does not need. | https://github.com/FluidInference/FluidAudio , https://docs.fluidinference.com/vad/getting-started.md |
| WebRTC VAD | Not researched in this pass. Older GMM-based design, no Swift package I verified. `(unverified)` Not recommended over Silero. | none |
| HAL voice-activity property | macOS: set `kAudioDevicePropertyVoiceActivityDetectionEnable` on the input device and listen to `kAudioDevicePropertyVoiceActivityDetectionState` (1 = voice). Device support varies. `(unverified on the built-in mic)` | https://wwdcnotes.com/documentation/wwdc23-10235-whats-new-in-voice-processing/ |
| AVAudioEngine "muted talker" | `inputNode.setMutedSpeechActivityEventListener` gives `.started` / `.ended`, but **only while the input is muted** with voice processing. Not an endpoint source when the user is being recorded. macOS 14+. | https://wwdcnotes.com/documentation/wwdc23-10235-whats-new-in-voice-processing/ |
| Voice processing IO (AEC) | Already on in Perry. Needed for barge-in without self-trigger. | `App/DictationController.swift:321` |

### 2.3 Semantic turn detection

| Option | Facts | Source |
|---|---|---|
| OpenAI Realtime `server_vad` | `threshold`, `prefix_padding_ms`, `silence_duration_ms`. Example config on the page: 0.5 / 300 / 500 ms (an example, not a stated default). Path: `session.audio.input.turn_detection`. | https://developers.openai.com/api/docs/guides/realtime-vad |
| OpenAI Realtime `semantic_vad` | Model judges whether the user finished. `eagerness`: `low` (user takes their time), `medium`/`auto` (default), `high` (chunk as soon as possible). Page gives no millisecond limits. | same |
| Transcription-only sessions | `gpt-live-transcribe` does **not** support `server_vad` or `semantic_vad`; set `turn_detection` to null and "use client-side VAD to detect the end of speech", then send `input_audio_buffer.commit`. | https://developers.openai.com/api/docs/guides/realtime-transcription |
| LiveKit turn detector | Audio model (`v1`, `v1-mini`) over audio plus meaning; needs VAD with `min_silence_duration` ≥ 0.25 s. Endpointing `min_delay` 0.5 s / `max_delay` 3.0 s (0.3 / 2.5 with the audio detector). Old text model: 396 MB (Qwen2.5-0.5B), 50-160 ms on CPU. Python / agents stack, not a Swift package. | https://docs.livekit.io/agents/logic/turns/turn-detector/ |
| Pipecat Smart Turn v3 | About 8M params. 8 MB int8 / 32 MB fp32 (ONNX). 12 ms CPU on modern CPUs. 23 languages. English accuracy 94.3% on their test set. Input: up to 8 s of 16 kHz mono. Runs *after* a VAD sees silence. BSD-2. Weights, data and training script are open. | https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/ , https://github.com/pipecat-ai/smart-turn |
| Smart Turn on Apple | Third-party CoreML port of v3.2: 16.8 MB, 3.5 ms per 8 s window on an M5 Pro, BSD-2, Swift `SpeechVAD` module in the `speech-swift` repo. Third-party and one-machine numbers. | https://soniqo.audio/guides/turn , https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML |
| Pipecat defaults | VAD `stop_secs` 0.2 recommended with Smart Turn; Smart Turn `stop_secs` 3.0 fallback (turn forced complete); `max_duration_secs` 8. Docs and source disagree on `pre_speech_ms`. | https://docs.pipecat.ai/server/utilities/turn-detection/smart-turn-overview |
| Deepgram Flux | `eot_threshold` 0.5-1.0 (default 0.7); `eager_eot_threshold` 0.3-0.9 (off by default); `eot_timeout_ms` 500-60000 (default 5000). Events `EagerEndOfTurn`, `TurnResumed`, `EndOfTurn`. Docs advise 7-10 s timeout for users who pause often. A cloud service and a new vendor. | https://developers.deepgram.com/docs/flux/configuration |
| AssemblyAI streaming | `end_of_turn_confidence_threshold` 0.4, `min_turn_silence` 400 ms, `max_turn_silence` 1280 ms (page says "Universal Streaming" defaults). Semantic first, acoustic fallback. A cloud service and a new vendor. | https://www.assemblyai.com/docs/streaming/universal-streaming/turn-detection |

### 2.4 What other products do

Evidence here is thin.

- **Superwhisper:** push-to-talk (hold) with a quick tap acting as toggle; docs describe no silence auto-stop. https://superwhisper.com/docs/get-started/essential-settings
- **Wispr Flow:** hands-free mode starts by hotkey (Fn + Space on Mac) or from the Flow bar. A third-party cheat sheet lists it as a toggle. I found no silence auto-stop claim. https://wispr.notion.site/My-finger-is-tired-Is-there-a-hands-free-mode-1992ebdc733481cfae2bd3a0128052af (page body did not load; the start method comes from search snippets), https://video.pie-menu.com/wispr-flow-cheat-sheet.pdf
- **HeyClicky / Clicky:** hold ⌃⌥ to talk. The open-source Clicky repo streams audio to AssemblyAI over a WebSocket. I found no source on whether release or silence sends. https://github.com/farzaa/clicky , https://creatorstoolbox.beehiiv.com/p/a-free-ai-buddy-for-any-mac-app
- **ChatGPT for Mac voice:** I found no source describing its end-of-speech or barge-in behaviour. `(unverified)`.

Takeaway: dictation tools stay manual (hold or toggle) because dictation has long thinking pauses. Conversational assistants (OpenAI, LiveKit, Pipecat) use VAD plus a semantic layer. Perry's "talk to me" click-mic is conversational, so it should auto-end.

### 2.5 Timing practice

- Vendor guidance converges on 300-500 ms of silence for fast agents, with an asymmetric cost: cutting someone off hurts more than waiting. One guide calls 700 ms "safe in testing" and still slow on real calls; another advises aggressive thresholds plus a cancel path. These are vendor blogs, so treat the numbers as starting points. https://www.callmissed.com/blog/vad-and-endpointing-why-your-voice-agent-feels-slow-and-how-to-fix-it , https://www.uniphore.com/blog/part-2-knowing-when-to-speak/
- Semantic layers shorten the average wait and stretch it only when the utterance looks unfinished (LiveKit, AssemblyAI, Deepgram above).
- Max silence caps in shipping stacks: AssemblyAI 1.28 s, LiveKit 2.5-3.0 s, Deepgram 5 s default, Pipecat 3 s fallback.
- Eager mode (speculate at a low confidence, cancel if speech resumes) saves roughly 150-250 ms at the cost of extra work. https://developers.telnyx.com/docs/voice/stt/websocket-streaming/parameters/end-of-turn (third-party description of Deepgram's mode).
- I found no source on handling "um" pauses. The filler rule in section 3 is my own design `(inference)`.

## 3. Recommendation

### 3.1 One shared component

Add one pure type, `EndOfTurnDetector`, owned by neither STT engine. It takes frames and events with timestamps and returns decisions. It has no clock of its own, so tests drive it with a virtual clock.

```
inputs  : frame(t, rms, vadProb?)        // from the existing audio tap
          transcript(t, text, lastWordEnd?)   // partials / segments
          userAction(sendNow | cancel)
outputs : .speechStarted(t)
          .silence(since: t, progress: 0...1)   // drives the UI arc
          .commit(reason)                       // .silence | .semantic | .cap | .user
          .abort(reason)                        // .noSpeech | .cancel
state   : waitingForSpeech → speaking → trailingSilence → committed
```

Engines stay as they are. `DictationController` gains one tap callback that forwards RMS. `VoiceConversationController` replaces `armFinalize` with the detector. Then `commit` calls the existing `finishListening()`.

Rules (parameters are my judgment, anchored on the vendor ranges in 2.5):

| Parameter | Hands-free question or command | Hands-free dictation-style | Why |
|---|---|---|---|
| No speech at all | abort after **8 s** (today 20 s) | 10 s | 20 s feels broken |
| Speech onset | RMS > noise floor + 9 dB for **≥ 120 ms** | same | ignores clicks and coughs |
| Noise floor | track a low percentile over the first 300 ms before onset, then slow EMA | same | works in fans and music |
| Silence to commit (base) | **700 ms** | 1500 ms | question vs thinking pauses |
| Silence if transcript ends in a continuation cue (and, but, so, because, um, uh, like, "the", trailing comma, or fewer than 3 words after a verb) | **1200 ms** | 2000 ms | the "um" pause |
| Silence if transcript ends with a question mark or period and ≥ 4 words | **500 ms** | 1200 ms | clearly finished |
| Hard cap on trailing silence | **2500 ms** | 4000 ms | never wait forever |
| Max turn length | **60 s**, then commit | 120 s | runaway protection |
| Adaptive widening | +300 ms (max 3 times) after each "speech resumed within 1 s of the commit warning" | same | learns a slow talker |
| Min speech for a valid turn | 300 ms of voiced audio and at least 1 recognised word | same | avoids empty submits |

Eager step: at 450 ms of silence, only *prewarm* (start screen capture, wake the brain provider). Do not stop the mic. `SFSpeechRecognizer` cannot resume after `endAudio()`, so the real finalize waits for the commit.

Barge-in during Perry's reply (phase 2): with voice processing (AEC) on, if RMS stays above floor + 12 dB for 300 ms while speaking, call `shutUp()` and start a new turn. Keep hold/tap barge-in as is (`TalkSession.swift:179-183`).

### 3.2 Per mode

**1. Hold-to-talk (⌃⌥, fn, ⌥⌘Space, ⌃⌥⌘): keep release = send.**
- No auto-end while the key is held. The user's hand is the signal.
- Add a 250 ms audio tail after release so the last word is not clipped. Talk's stability poll already runs (`TalkSpeech.swift:113-147`).
- Add **tap-to-latch**: a press shorter than 250 ms switches to hands-free (mode 2). Superwhisper uses the same hold-or-tap idea. https://superwhisper.com/docs/get-started/essential-settings
- Level meter and start earcon (`SoundPlayer.Cue.wake`) at commit; `send` at release (already `TalkSession.swift:167`).

**2. Tap-to-talk / hands-free (the mic button, Caps double-tap, latched hold): auto-end with the detector above.**
- Use the "question or command" column by default.
- Switch to the "dictation" column when the frontmost field is a text field and the intent is typing (the same signal `VoiceController.handleTranscript` uses for insertion, `:805-817`).
- Remove "I’m done" as the primary button. Replace it with a small up-arrow "send now" icon beside a separate "cancel" icon.
- The Caps Lock "tap again to stop" (`PushToTalkController.swift:24`) stays as an override but is no longer required.

**3. Wake word.**
- On match, **do not dispatch the partial.** Start a hands-free turn with the same detector. Seed it with the text after the phrase.
- Keep a 1.5 s ring buffer so words spoken right after "hey perry" survive the listener-to-dictation handoff (`DictationController` already retains buffers, `:518-525`).
- "Hey Perry" alone: open the turn, play the `wake` earcon, 8 s no-speech abort. This fixes the dead "I’m listening." state (`VoiceController.swift:1029`).
- Add a 700 ms silence requirement before dispatching an inline command.

**4. Realtime (BYOK).**
- **Default: client-side detector plus manual commit.** It matches `turn_detection: null` and OpenAI's own advice for transcription sessions (https://developers.openai.com/api/docs/guides/realtime-transcription). One code path for all endpoints (`protocolMode: compatible`). Fully testable offline. The existing `finishInputTranscribing()` is the commit call.
- **Optional, `api.openai.com` conversation models only:** set `turn_detection` to `semantic_vad` with `eagerness: "low"` for dictation, `"medium"` for questions, and `create_response: false` because Perry's brain answers (`RealtimeTalkVoice.swift:11-20`). When server VAD is on, the client detector only drives the UI, otherwise both would commit. For `compatible` endpoints use `server_vad` with `silence_duration_ms` 700 and `threshold` 0.5, the shape in OpenAI's example.
- Do not add Deepgram Flux or AssemblyAI. They add a vendor, a key and an upload path for a problem the local detector already solves.

### 3.3 Detector choice

| Situation | Detector | New dependency? |
|---|---|---|
| Default, no cloud | Energy VAD (`vDSP_measqv` on the tap) + word-end timing from `SFSpeechRecognizer` segments (`lastWord.timestamp + duration`) + the continuation-cue rule | **No.** All built in. |
| Better noise robustness | Silero VAD probability instead of raw energy, via FluidAudio streaming VAD | **Yes, needs approval.** FluidAudio is Apache-2.0 but large (ASR, TTS, diarization) and downloads models from Hugging Face at first run. Prefer bundling the VAD model and using its offline mode, or porting only the Silero CoreML file. |
| Smarter "is this finished?" | Smart Turn v3.2 CoreML (16.8 MB, about 3.5 ms) on the whole turn after VAD silence | **Yes, needs approval.** BSD-2 weights; the CoreML packaging and Swift wrapper are third-party. Phase 3, only if the heuristic cut-off rate is still too high. |
| macOS 26 only, later | `SpeechAnalyzer` volatile results with `audioTimeRange` as the word-timing source | No new dependency, but `#available(macOS 26, *)` and a model download via `AssetInventory`. Does not remove the need for our detector. |
| With cloud realtime | Local detector + manual commit (default) or `semantic_vad` (optional, see mode 4) | No |
| HAL voice-activity property | Optional hardware-assisted hint | No, but device support is unverified. Do not rely on it. |

### 3.4 Notch UI: listening → thinking with no button

Reuse the existing states (`VoiceConversationController.State`, `PerryCharacter` moods, `overlayState.voiceState`).

1. **Listening.** The panel stays visible (stop hiding it on `.listening`, `SessionPanelPresenter.swift:214-221`). Character in `.listening`. A small ring around it scales with **real RMS** at about 20 Hz. The live partial transcript shows beneath it. First three uses only: a quiet hint, "Pause when you’re done." No fake waveform.
2. **Ending.** When silence passes the "warning" point (the shorter of 400 ms or half the threshold), a thin arc around the ring drains toward the commit time. The arc is the only countdown. No numbers. If speech resumes, the arc refills and the hint is hidden. A short `send` earcon plays at commit.
3. **Thinking.** The ring turns into the existing thinking mood. The bubble reads "Working on your request" (`SessionPanelPresenter.swift:225`). The transcript freezes as the user’s question card.
4. **Speaking.** Unchanged.
5. **Reduced Motion.** Replace the draining arc with a plain opacity step on the ring; no scale animation.
6. **Accessibility.** Post a VoiceOver announcement at each state change ("Listening", "Sending", "Thinking").

### 3.5 Overrides

| Intent | Gesture |
|---|---|
| End now | Click the notch pill or the small up-arrow; press the same hotkey; press Return |
| Cancel | Esc, or the small ✕ (today's "Stop" meaning, now separate from send) |
| Keep talking | Just speak; the detector resets and the arc refills |
| Needs more time | Say "hold on" or "one sec" (text rule, optional): extends the cap to 5 s once |

### 3.6 Which parts need approval

- **Built in, no approval:** energy VAD, noise floor tracking, continuation-cue rule, segment word timing, UI changes, wake-word handoff fix, `semantic_vad`/`server_vad` payload change, earcons, `#available` gating for `SpeechAnalyzer`.
- **New third-party dependency (user approval required by `AGENTS.md`):** FluidAudio (Silero VAD CoreML); Smart Turn CoreML via `speech-swift` or our own conversion of the BSD-2 weights; any Deepgram or AssemblyAI SDK (not recommended).

### 3.7 Suggested order

1. Detector + RMS tap + virtual-clock tests (no UI change). Wire into `VoiceConversationController`. Cut no-speech timeout to 8 s.
2. UI: keep panel visible, ring + arc, send-now and cancel as separate controls, remove "I’m done" as primary.
3. Wake-word endpointing and handoff fix. Tap-to-latch for hold shortcuts.
4. Realtime payload option.
5. Optional Silero, then Smart Turn, if the fixture metrics below are not met.

## 4. Test plan (fixtures only, no live mic)

**Harness.** `EndOfTurnDetector` is pure and takes timestamps. A test reads a 16 kHz mono WAV/CAF, chops it into 20 ms frames, feeds RMS (and later VAD probability) with a virtual clock, and records commit times. Runs in milliseconds, in `swift test` style like `AppTests/VoiceConversationControllerTests.swift`. Add a `FixtureAudioInput` that conforms to `VoiceConversationInput` (`VoiceConversationController.swift:6-10`) so the controller-level behaviour (state changes, submit) is also tested.

**Fixture sources.**
- Synthesised speech with macOS `say -o file.aiff --data-format=LEF32@16000`. It writes a file and does not use the mic or speakers.
- Silence and pause control by concatenating segments with `sox`/`ffmpeg` or a small Swift script, so ground-truth times are exact.
- Noise beds (fan, pink noise, keyboard clicks, music) mixed at 5, 15 and 25 dB SNR.
- Optionally the open Smart Turn training and test data that Daily says it released (https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/), after checking its licence.
- A JSON label per file: `speechStart`, `speechEnd`, `mustNotCommitBefore`, `expectedCommitWindow`.

**Cases.**

| Case | Expectation |
|---|---|
| Short command, 0.6 s tail | commit at about base + 150 ms |
| Question ending in "?" | commit near 500 ms |
| Mid-sentence 1.0 s pause ("I want to… book a flight") | **no commit during the pause** |
| Trailing filler ("so, um…") then 1.5 s | no commit before 1200 ms, commit before 2500 ms |
| Long dictation, 40 s, 0.9 s thinking gaps | no commit in dictation mode |
| Room tone only | abort at 8 s, no submit |
| Cough or click under 120 ms | no onset |
| Noise at 5 dB SNR before and after speech | no early commit; commit within cap |
| Speech resumes 400 ms after the warning | arc refills, no commit |
| Speech resumes after the commit | new turn, no duplicate submit |
| TTS reference mixed with user speech (barge-in) | barge-in fires within 400 ms; no self-trigger with AEC fixture |
| Non-English (es, fr, hi) | same timing behaviour; filler list is locale-aware or disabled |

**Metrics and gates** (initial targets, tune after the first run):
- Cut-off rate on "pause" fixtures: **0**.
- Commit latency p50 ≤ base threshold + 150 ms; p95 ≤ base + 400 ms.
- False commit on noise-only fixtures: **0**. No-speech abort at 8 s ± 0.3 s.
- Duplicate submits: **0** (`submitted` flag in `VoiceConversationController.swift:61,188`).

**STT integration without a mic.**
- Recognition from files: run `SFSpeechURLRecognitionRequest` on the same WAVs (on-device) to check the transcript-driven rules. With macOS 26, `SpeechAnalyzer.analyzeSequence(from:)` does the same (https://developer.apple.com/videos/play/wwdc2025/277/).
- The existing debug seam `DictationController.beginRecognitionFixture()` (`App/DictationController.swift:290-296`) can inject recognition events.

**Lab check later, on the user's go-ahead only.** Use `scripts/lab/perry-drive.sh` with a speaker playing a fixture into the room, and add `PerfMark` names `talk.eot.speech_end`, `talk.eot.commit`. `latency-report.py --pair talk.eot.speech_end:talk.eot.commit` gives the real-world gap. `idle-probe.sh` must stay within its budgets (CPU ≤ 0.5%, RSS ≤ 180 MB, `AGENTS.md`); the detector only runs while listening.

## 5. Open questions and risks

- I did not reproduce the user's bug; the cause list in 1.3 comes from reading code. Capture one `PerfMark` trace of a mic-click turn before and after to confirm which of items 1, 2 and 7 dominates.
- `SpeechDetector` fix version is unknown (section 2.1). Retest on the user's macOS before any use.
- HAL VAD and `SFSpeechRecognitionMetadata` partial availability are unverified.
- FluidAudio downloads models at runtime; Perry's privacy posture (on-device, `NetworkEndpointPolicy`) may need bundled models.
- Hold-to-talk users keep a fully manual end. If the user also dislikes holding, mode 2 (latch) addresses it.
- Wake word dispatches inline commands on partials today; fixing it changes latency for "Hey Perry <command>" by about 700 ms. That is the price of not truncating commands.
