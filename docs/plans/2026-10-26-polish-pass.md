# Perry polish pass: voice, privacy, onboarding, native finish

**Goal:** Perry sounds like a person, speaks names correctly, keeps the user's data private by default, and every surface looks designed. Each item names its root cause, the fix and the evidence that proves it.

Owner feedback, 2026-10-26:
- The voice is "the most horror thing". The stop-listening sound is cringy. Perry does not talk well and gets names wrong.
- The text near the cursor never goes away.
- The settings icons look chopped. The expanded notch's sidebar line and footer stop short of the bottom.
- Titles should come from Apple's on-device model.
- Only capable models should be recommended. Otherwise offer cloud with PII redaction (Rampart or better).
- The "get to know you" step needs work.

---

## 1. Voice output (TTS)

**Root cause.** `VoiceController.resolveSpeakingVoice` picks the first `.premium` English voice, else the first `.enhanced` one. This Mac has no premium voices. Its enhanced voices are `com.apple.siri.natural.Simone` ("Voice 2"), `Aman.premium` and `Tara.premium` (both en-IN). A Siri voice played through `AVSpeechSynthesizer` sounds broken. Without an enhanced voice, the fallback is compact Samantha. Novelty and eloquence voices (Grandpa, Rocko) are also installed.

**Plan.**
1. Add a `SpeechEngine` protocol with one call: stream sentences in, audio out, barge-in stop under 150 ms. It has three engines, and one owner (`VoiceController`) picks among them:
   - **System:** `AVSpeechSynthesizer`, restricted to premium or enhanced voices in the user's locale. Never Siri, eloquence or novelty voices. If no good voice is installed, Settings > Voice says so and offers the download (System Settings > Accessibility > Spoken Content). Perry does not quietly use compact Samantha.
   - **ElevenLabs:** WebSocket `stream-input` with `eleven_flash_v2_5` for latency (reported at about 75 ms to first audio). The user picks a voice from their library. The key lives in the Keychain. Pronunciation dictionaries are supported (see §3).
   - **OpenAI** (`gpt-4o-mini-tts`) and **Cartesia Sonic**: same streaming contract, behind the same key UI. Cartesia has the lowest reported first-audio time; OpenAI is the cheapest.
2. **Speakable text.** One `SpeechText.prepare(_:)` step runs before every engine:
   - strips Markdown;
   - turns symbols, URLs, file paths and ⌘⌥ glyphs into words;
   - expands numbers and dates;
   - splits text at sentence boundaries for streaming.
   Today raw answer text goes straight to the synthesizer.
3. **Spoken register.** Talk mode gets its own prompt line: spoken sentences, no lists, under 12 words where possible, and a contraction-friendly voice. (This prompt rule is about Perry's voice, not our chat copy.)
4. **Settings > Voice** is redesigned:
   - Engine (System, ElevenLabs, OpenAI, Cartesia).
   - Voice picker with a 3-second preview of a fixed sentence that includes the user's name.
   - Speed.
   - "Speak replies" (on, short replies only, or off).
   - Pronunciations (§3).
5. **Verify.** Unit tests for voice ranking (Siri and eloquence voices are never chosen) and for `SpeechText`. A fixture test of each cloud engine against a recorded WebSocket transcript; no live keys. The owner listens and chooses the default voice. I cannot judge audio myself, and the `earshot` tool failed to connect.

## 2. Voice input (STT) and sounds

1. **Speech-to-text engines.** Add the same kind of protocol:
   - **Apple `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26) as the new default.** A third-party benchmark reports 2.1% WER against 3.7% for Whisper Small. It replaces the legacy `SFSpeechRecognizer` path, which scored 9.0% in the same test.
   - `SFSpeechRecognizer` stays as the fallback on macOS 14 and 15.
   - **Cloud:** ElevenLabs Scribe, OpenAI `gpt-4o-transcribe`, Deepgram Nova. The user opts in, with their own key.
   - Custom vocabulary is fed from the pronunciation list and the user's apps, so names transcribe correctly.
2. **The mic fix from 9.3 gets proof.** A lab drill on the mini plays a recorded WAV through a virtual loopback device (BlackHole-style; this needs approval because it is a dependency) into the real capture path. That proves the engine hears audio end to end, with no human needed.
3. **Earcons.** Today's `send.caf` (the stop-listening cue) and its siblings are synthesized chimes from August.
   - Replace them with short, soft, real recordings, under 120 ms and under −24 LUFS: a soft tick for start, nothing or a breath-quiet tick for stop, and a warm two-note sound for done.
   - Source them from a licensed library through the `real-sound` workflow and offer the owner three sets.
   - Add a "Sounds: Subtle / Off" setting. With no cue on stop, the face changing to "thinking" is enough.

## 3. Names and pronunciation

- A `PronunciationStore` holds entries: written form, spoken respelling ("Hrid-yah"), optional IPA, and source (user, contact, learned).
- Each engine applies the entries its own way:
  - **ElevenLabs:** a pronunciation dictionary, synced via API (alias rules; phoneme rules where the model supports them; check per model).
  - **System voice:** `AVSpeechSynthesisIPANotationAttribute` on the attributed utterance.
  - **OpenAI and Cartesia:** respelling substitution before sending.
- **Learning.**
  - Onboarding asks how to say the user's name (§6).
  - Perry gets a `remember_pronunciation` tool, so "it's pronounced …" in conversation updates the store.
  - Settings > Voice > Pronunciations lists the entries, with play and edit.
- The same entries feed STT custom vocabulary (§2.1), so Perry also hears names correctly.

## 4. The text near the cursor never goes away

**Root cause.**
- `TaskBubbleLayer` shows `taskBubbleText`.
- `VoiceController.speak` and `enqueueSpeech` set it to every spoken sentence. `presentConversationVoice(.idle)` sets it to "Answer ready".
- Nothing clears it when speech ends: `speechSynthesizer(_:didFinish:)` only resets `voiceState`.

**Fix.**
- The bubble gets one owner with a lifetime. It is replaced by a `CursorStatus` value: text, kind (working, speaking or done) and an expiry.
- "Speaking" clears 1.5 s after the last utterance finishes. "Done" shows for 2.5 s. "Working" lasts while the task runs.
- Answer text is never mirrored at the cursor while the notch already shows it.
- Tests drive speak → finish → expire with a fake clock.

## 5. Brain choice, model capability and PII redaction

1. **Only recommend capable models.**
   - Build a small capability eval: about 40 fixtures covering Perry's tool schemas, JSON validity, a screen question with an image, and a three-step task plan.
   - Each local rung in `ModelFit` gets a measured pass rate. A rung is "Recommended" only above a floor, e.g. 90% tool-call validity.
   - On this M4 with 16 GB, if no local rung passes, the Brain page recommends cloud. Local becomes "Private chat only (can't use your apps)", in plain words.
   - Raw names like "Qwen3.5-9B UD-Q4_K_XL" move into a details disclosure.
2. **Cloud with PII redaction.** When the user picks a cloud brain, Perry asks once: "Hide personal details before they leave this Mac? Perry swaps names, emails, numbers and addresses for placeholders, and puts them back in the reply. On this Mac, ~15 MB."
3. **Redactor design ("better Rampart").** Layers:
   - **Rampart's model:** a 14.7 MB MiniLM token classifier, 17 entity types, CC BY 4.0, a reported 98.4% recall. Convert it to Core ML at build time with coremltools, so there is no ONNX runtime dependency. An MLX conversion also exists.
   - **Deterministic recognizers:** email, phone, card number with a Luhn check, IBAN, address patterns, API-key shapes.
   - **Apple `NLTagger`:** person, place and organization names, as a second opinion.
   - **The user's known entities:** their name, contacts they have mentioned, and pronunciation entries, so they are always caught.
   - Reversible placeholders (`⟨PERSON_1⟩`) per conversation, restored on the client before display and speech.
   - Applies to: prompt text, screen text taken from Accessibility, and app-connector results.
   - Screenshots: optional Vision OCR, then black boxes over detected PII text before upload. Off by default; it is slower.
   - Settings > Privacy shows "Redacted this week: 42 items" and a per-message "what was hidden" view.
4. **Titles from Apple Intelligence.** `ThreadStore.derivedTitle` truncates the first message today ("I want to learn figma. Give me a three-line starter plan…"). Generate a two-to-five-word title with `SystemLanguageModel` after the first answer, and fall back to the truncation when Apple Intelligence is off. The same on-device model takes over profile extraction (§6) and other small jobs, so they never touch the cloud.

## 6. Get to know you, rebuilt

The current step has three typed questions (work, apps, learning goal) and one cloud reaction per answer.

- **Voice first, typing allowed.** Perry asks; the user can hold ⌃⌥ or type.
- **Questions, in order:**
  1. "What should I call you?" Then: "How do you say it?" Perry plays back its attempt, and the user can say it again or fix the spelling. This saves to the `PronunciationStore`.
  2. "What do you do most days?"
  3. "What should I take off your plate first?"
- **Apps come from the Mac**, not from a question: running and recently used apps, confirmed as a row of icons the user can deselect.
- **Style preference** as one tap: "Short and direct" or "More detail". This feeds the prompt.
- Reactions and extraction run on Apple's on-device model where available, so nothing leaves the Mac during onboarding.
- **The end card is "What I know about you"**, editable, with name, pronunciation (play), work, apps, focus and style. The same card lives in Settings > You.

## 7. Native finish

1. **Expanded notch bottom.** `CompactConversationView` pads the whole workspace by `NotchLayout.bottomInset` (16). Because of that, the sidebar divider and the Apps/Settings footer stop 16 pt above the panel's edge. Fix:
   - The workspace fills to the bottom edge.
   - The sidebar gets its own full-height surface (`Colors.surface`), with the divider running edge to edge.
   - The footer is pinned to the bottom with 14 pt inner padding.
   - Corner radii follow concentric rules (outer = inner + padding).
2. **Chopped settings icons.** `SettingsSidebar` draws each symbol in a fixed 18 pt frame (`SettingsPage.swift:159`), so wide glyphs (waveform, gearshape, command) get clipped. Use the same `SymbolTile` as the main sidebar: filled symbol, tinted tile, one size. These are the macOS System Settings conventions.
3. **One visual system pass.** Audit every surface (card, panel, settings pages, onboarding, helper, task view) against one token sheet:
   - spacing scale 4/8/12/16/24;
   - three text styles per surface;
   - one radius family;
   - hit targets of 28 pt or more;
   - focus rings;
   - hover and press states (scale 0.97);
   - reduced motion.
   Produce a before/after contact sheet.
4. **Motion.** Notch open and close as a spring (response 0.35, damping 0.86). Rows press-scale. The card grows in place when a chat opens. Nothing animates when the keyboard drives it.
5. **Copy pass with `prose`.** One voice, laypeople's words, and no model jargon outside "details".

## 8. Order and evidence

| Phase | Work | Proof |
|---|---|---|
| A | §4 cursor bubble, §7.1 bottom edge, §7.2 icons | unit tests, renders |
| B | §1 speech engines + `SpeechText`, system voice ranking | tests, owner listens to 3 candidates |
| C | §3 pronunciation, §6 onboarding | renders, tests, owner run-through |
| D | §2 SpeechAnalyzer STT, earcons, loopback drill | WAV drill transcript on the mini |
| E | §5 eval, Brain page, redactor, Apple titles | eval table, redaction fixtures, renders |
| F | §7.3–7.5 system pass | contact sheet, full suite, install |

Each phase is a separate commit with renders inspected. The full suite runs on the mini, then the app is installed for the owner.

## Owner decisions needed

1. **Default spoken voice.** Recommendation: ElevenLabs when a key is present, otherwise the best installed premium system voice, with a prompt to download one. The owner picks the voice after hearing three.
2. **Approval for a loopback audio device on the mini,** for the STT drill. It is a test-only dependency.
3. **Rampart weights** (CC BY 4.0, ~15 MB) bundled in the app, converted to Core ML. No runtime dependency.
4. **Earcon set,** chosen from three candidates.
