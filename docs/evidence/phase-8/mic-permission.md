# Microphone controls — live drill (2026-10-01)

Debug build, pid 69178. Settings → Voice & Input (opened via
`perry.settings.open` on the MCP socket).

## What ran

- Voice & Input page rendered live: Voice out card (Speak replies
  toggle on, Voice picker "Best available", Speed slider 1.0×,
  Preview voice) and Dictation card (Language "Automatic (detect each
  utterance)", Microphone "Automatic", Test microphone).
- "Preview voice" → `VoiceController.previewSpeechVoice` ran the real
  AVSpeechSynthesizer path (audio-route guard passed; no error state).
- "Test microphone" → real macOS TCC prompt appeared:
  *"Allow Perry to access your microphone? Perry hears you only while
  you hold the talk key — it never listens in the background."*
  with Don't Allow / Allow.

## Verified

- The mic control path is real: pressing Test microphone reaches the
  system permission request, not a no-op.
- Perry's prompt copy is honest — hold-to-talk, no background listen.
- Voice settings surface renders and its controls are live.

## Not claimed

- Granting/denying is the user's decision; the prompt was left pending
  on screen (screenshot `mic-permission-prompt.png`).
- Actual capture quality / dictation accuracy needs the grant.
