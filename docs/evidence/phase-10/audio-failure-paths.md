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
- ~~`talk.speak.start`/`end`~~ **verified iter-15** — instance 11222
  markers: `talk.speak.start` 17:31:16.387 → `talk.speak.end`
  17:31:18.094 (1.7 s wake greeting, output unmuted).
- `talk.bargein`/`bargein.silence` — fired live on instance-61273
  termination at 17:15:30Z (SIGTERM cancelled the in-flight greeting);
  a user-initiated barge still needs the physical PTT path.

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

## Iteration 13 additions

- **MCP socket was never broken** — the accept-then-close was wrong
  client framing. `PerryMCPSocket.serve(client:)` consumes the *first
  line* as a bare `{"token":"…"}` auth hello; token-in-`initialize.params`
  fails auth and closes. Correctly framed against instance 61273:
  `initialize` + `tools/list` succeeded; `perry.settings.open` drove the
  Settings window live.
- **Input Monitoring row verified live** — Settings → General →
  Permissions renders the new row with `Enable…`, matching
  `ptt.capture.fallback` on the running instance.
- **Bluetooth pre-roll shipped** — `AudioRouteMonitor.defaultOutputIsBluetooth()`
  reads `kAudioDevicePropertyTransportType`; a route switch onto a BT
  output defers the "I switched the reply to …" announcement by 600 ms
  (`audio.preroll.bt` marker) so the A2DP profile ramp doesn't clip it.
  Non-BT routes announce immediately. Decision + probe unit-tested;
  hardware AirPods drill remains user-owned.
- **Diagnostics** — `PermissionInfo` now serializes `inputMonitoring`
  alongside accessibility/screenRecording/microphone, so exported
  reports show the PTT-blocking grant.

## Iteration 15 — cursor-follow starvation fallback

Same invisible-failure class as PTT: `PerryBuddyView` tracks the pointer
via `NSEvent` global `.mouseMoved`/drag monitors, which install fine but
deliver zero events without Input Monitoring or Accessibility trust —
the living cursor froze silently on untrusted identities (the running
adhoc build shows both grants ungranted, and no windows/peek respond).

Fix (`PerryOverlay`): a 0.5 s watchdog compares `NSEvent.mouseLocation`
(permission-free) against the monitor event count. Movement without
events → `cursor.follow.fallback` marker + `OverlayPerfProbe.
cursorTrackingDegraded`, and follow switches to a 30 Hz poll that parks
itself after ~1.5 s of no motion. First real monitor event permanently
stands the watchdog down, so a granted Perry keeps the zero-timer
event-driven design. Probe hook + degraded flag unit-tested
(`PerryOverlaySmokeTests`).

Empirical check this machine: a probe binary under Terminal's identity
(`axTrusted=true`) received 275 global monitor events in ~7 s of
synthetic pointer moves — delivery works when trusted; Perry's own
identity is untrusted (Settings rows show Enable…), so the fallback
path is the operative one on this host until the grants land.

Live confirmation deferred: `cursor.follow.fallback` will appear in the
markers log on the next Perry launch (the 8-h soak pins pid 11222).
