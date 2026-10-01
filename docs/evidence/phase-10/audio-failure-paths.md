# Audio + failure-path live evidence (2026-10-01, iteration 12)

Instance: debug build, pid 61273, lab log
`docs/evidence/lab/perf-20261001T163730Z.jsonl.markers.jsonl`.
System output was **muted** throughout, which turned this into a real
failure-path drill.

## New markers (this iteration)

- `ptt.capture.eventtap` / `ptt.capture.fallback` — which key-listener
  path `PushToTalkController.start()` actually captured.
- `sound.cue.<cue>` — emitted after `NSSound.play()` returns (proves the
  cue loaded and was played, not just dispatched).
- `talk.speak.start` / `talk.speak.end` — synthesizer queued / finished.
- `talk.speak.muted` — `speak()` saw muted output and stayed off the
  clipboard (ephemeral announcements).
- `talk.muted_clipboard` — reply content copied to clipboard on muted
  output (deliverVoiceReply path).
- `PerfMark.markDynamic(_:)` — marker-only overload for runtime-composed
  names (the signposter API requires `StaticString`).

## Verified live

```
ptt.capture.fallback      16:37:30  tapCreate returned nil — Input
                                    Monitoring not granted to the
                                    adhoc-signed build; PTT dead by
                                    permission, previously invisible.
invoke.keydown …          16:37:39  wake hotkey works (global_input
panel.visible                     route via cua-driver)
sound.cue.wake            16:37:39  wake chime loaded + played
talk.speak.muted          16:37:39  "Perry here." hit the muted path…
```

…and the user's clipboard (`TESTCLIPBOARD` seeded via `pbcopy`) was
**preserved** — before the fix, the wake greeting overwrote the
clipboard (`pbpaste` had shown `Perry here.` on the prior build).

## Fix shipped this iteration

`VoiceController.speak()` gains `copiesReplyWhenMuted:` defaulting to
false; `deliverVoiceReply` passes true. Greetings/prompts/errors never
touch the clipboard on muted output; answer content still does.

## Not yet verified

- `talk.muted_clipboard` on a real reply — needs a completed foreground
  turn; the composer keeps refusing background focus (AX unresolved on
  the adhoc build), and MCP on this instance accepted-then-closed the
  socket (investigate next iteration — was functional on the earlier
  instance).
- `talk.speak.start`/`end` — needs unmuted output (user action: unmute).

## Input Monitoring chain (the PTT blocker, now precise)

- Probe binary (AX-trusted terminal identity): `tapCreate` **succeeds**,
  yet receives zero events from raw `CGEvent.post(.cghidEventTap)`,
  `osascript key code`, and cua-driver `global_input` — lab injection
  cannot exercise hold-to-talk at all on this machine.
- Perry itself: `ptt.capture.fallback` proves its tap never created.
  The NSEvent fallback cannot see other apps' keys, so ⌥⌘Space is dead
  until the user grants **Settings → Permissions → Input Monitoring**
  (new row this iteration) *and* the check is done on a physical
  keyboard.
