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

- ~~`talk.muted_clipboard` on a real reply~~ **verified iter-16** —
  see "Iteration 16" below.
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

## Iteration 15 — cursor-follow starvation watchdog (belt + suspenders)

`PerryBuddyView` tracks the pointer via `NSEvent` global `.mouseMoved`/
drag monitors. A 0.5 s watchdog now compares `NSEvent.mouseLocation`
(permission-free) against the monitor event count: movement without
events → `cursor.follow.fallback` marker + `cursorTrackingDegraded`,
and follow switches to a 30 Hz poll that self-parks after ~1.5 s of
stillness. The first real monitor event retires the watchdog
permanently — a healthy Perry keeps the zero-timer event design.
Unit-tested via `OverlayPerfProbe.markCursorTrackingDegraded`
(transition-only hook).

**Premise correction:** initially assumed mouseMoved monitors starve
without IM like keyboard taps do (`ptt.capture.fallback`). Live evidence
says otherwise — `home.hover_start` (emitted only from `pointerMoved`,
which only the mouseMoved monitors call) fired three times on instance
61273, whose Settings show both Accessibility and Input Monitoring
ungranted. Global *mouse* monitors deliver on untrusted identities;
only keyboard input is IM-gated. The watchdog therefore guards an
unproven edge (future macOS policy tightening, partial trust states)
at ~zero steady-state cost — honest detection + degrade, not a fix for
an observed failure.

Live `cursor.follow.fallback` marker expected only if the edge ever
fires; on this machine it should stay silent.

## Iteration 16 — synthetic-input drive path + full muted-reply chain

Instance: pid 97513, log `perf-20261001T174941Z.jsonl.markers.jsonl`,
system output muted for the drill, restored after.

**Lab capability finding:** `CGEvent.post(tap: .cgSessionEventTap)`
reaches another process's global `NSEvent` monitors (earlier
`cghidEventTap` posting did not reach session taps). A signed probe
binary received a complete cross-process ⌥⌘ gesture
(`down:1 flagged:1 drag:27 up:1`), and a synthetic `mouseMoved` burst
fired Perry's own `home.hover_start`. This gives the lab a real drive
path for mouse-gesture flows without HID trust.

**New markers:** `spatial.down` (⌥⌘ lasso gesture accepted),
`spatial.select` (closed loop → selection), `spatial.cancel` (released
or Esc without a valid selection). The spatial gesture had zero
observability before — same silent-death class as PTT/cursor.

**Verified live, single sequence:**

```
invoke.keydown        17:50:08.335  wake chord (perry-drive hotkey)
panel.visible         17:50:08.366
sound.cue.wake        17:50:08.591
talk.speak.muted      17:50:08.591  greeting on muted output —
                                    ephemeral, clipboard untouched
spatial.down          17:50:10.937  synthetic ⌥⌘ lasso accepted
spatial.select        17:50:11.794  closed 110×110 loop → selection
talk.muted_clipboard  17:50:11.955  reply copied (161 ms after select)
```

Clipboard after: `I have the area you circled.` — reply content
copied on muted output while the ephemeral greeting 3.4 s earlier
left the seeded clipboard intact. Both halves of the
`copiesReplyWhenMuted:` contract verified in one pass. The AX-capture
leg of `describeSpatialSelection` failed fast (no runtime/worker),
producing the label-less reply — the graceful-degradation path itself
also verified.

`sound.warmup` fired at launch 17:49:41.822 — prewarm ordering now
observable.

Note: two earlier lasso attempts on instance 11222 produced no markers
because the panel had been dismissed (monitor only runs while invoked)
— diagnosed via the window list; new markers make this a one-grep
check next time.
