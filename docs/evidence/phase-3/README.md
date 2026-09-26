# Phase 3 — Living glass cursor and ink evidence

Date: 2026-09-26. Spec: megaplan §5 + §7 Phase 3.
Sub-plan: `docs/plans/2026-09-26-phase-3-glass-ink.md`.

Status: **foundations + morph grammar landed**; cursor-follow rewrite,
ink/caption layer integration, and live drills pending.

## Delivered this pass

### `Packages/PerryOverlay/Sources/PerryOverlay/InkStroke.swift`
- `InkStroke.sampled(through:step:jitter:seed:)` — centripetal Catmull-Rom
  resampling (α=0.5, no cusps) at ~2.5 pt steps + SplitMix64 seeded jitter
  (perpendicular, endpoints exact). Deterministic across launches.
- `InkStroke.widths(count:baseWidth:seed:)` — tapered pressure profile with
  seeded ±18% wobble.
- `InkStrokeShape: Shape` — variable-width filled outline via normal-offset
  sampling; `progress` is `animatableData` so draw-on animates by
  construction (no `trim`, which doesn't apply to fills).
- `InkStroke.point(on:progress:)` — arc-length pen-tip position.
- `InkColor` — `luminance(of:)` (Rec. 601 over an RGBA patch already in
  memory, no extra capture) + `hex`/`color(forLuminance:)`: mint `#34D399`
  below 0.45 luma, deep teal `#0B7285` at/above.

### `Packages/PerryOverlay/Sources/PerryOverlay/CaptionPlacer.swift`
- `place(size:anchor:avoiding:in:margin:gap:)` — slots below/above/right/left
  then screen corners; scored by obstacle overlap + 4× off-screen overflow;
  winner clamped into the visible frame. Multi-display safe (no (0,0)
  assumptions). `overlapArea`/`overflowArea`/`clamp` exposed for tests.

### `PerryGlassCursor.swift` — §5 morph grammar
- `PerryCursorMorph`: pointer / listening / thinking / pen / caption /
  ghost / settle / blocked (+ `init(animation:)` legacy mapping).
- `PerryGlassCursorView` gains `morph`, `micLevel`, `sessionActive` —
  all optional; `morph == nil` renders the legacy path unchanged.
- Morphs: pointer (4 s breathing edge light only while session active),
  listening (ring radius follows mic RMS — prop-driven, no timeline),
  thinking (edge-light orbit 1.2 s/rev — no spinner), pen (nib silhouette),
  caption (bubble + tail silhouette), ghost (dashed outline, never filled),
  settle (tick), blocked (static amber hold — new `Colors.amber`).
- TimelineView only runs for `.thinking` and active `.pointer` — idle cost
  stays zero.

### `OverlayWindow.swift`
- `sharingType = .none` on the cursor overlay — it was unset before, so
  Perry's overlay was capture-visible (spec item 5, partial).
- Main cursor now driven by `cursorMorph` (voiceState → listening/thinking;
  buddyState → blocked/settle/ghost; else pointer) with live `micLevel` and
  `sessionActive`. External agent cursors use `.ghost`.
- **Same-frame follow (item 1):** the 16 ms `DispatchSourceTimer` poller is
  replaced by `NSEvent` global+local `mouseMoved`/`dragged` monitors writing
  `cursorPosition` in the event's own turn — no timers tick while idle
  (the idle probe can verify). Display-link promotion is still available if
  the 120 Hz recording shows residual lag.

### `App/DebugCursorGallery.swift`
- Added morph sections (all 8 morphs, light + dark) alongside the existing
  state×variant gallery for snapshot evidence.

## Tests

`swift test --package-path Packages/PerryOverlay`: **18 tests, 0 failures**
(5 pre-existing + 13 new: InkStroke 8, InkColor 3, CaptionPlacer 6 …
InkStrokeTests 8 cases incl. determinism, jitter bounds, draw-on growth;
CaptionPlacerTests 6 incl. negative-origin multi-display + oversized clamp).

`xcodebuild build -scheme Perry -derivedDataPath build/debug-p1`: PASS.
Focused `xcodebuild test` (InkAccentSamplerTests + Talk suites): PASS.
`git diff --check`: clean.

### `OverlayWindow.swift` ink + captions
- `PerryGuidanceScribbleView` renders `InkStrokeShape` (variable-width
  filled outline, seeded wobble) instead of a uniform stroked path; the
  draw-on tip is now the `.pen` morph at the arc-length position.
- `PerryGuidanceRectangleView` strokes an inked perimeter
  (`InkStroke.rectangle`) instead of a dashed machine rect; soft fill kept.
- Guidance captions route through `guidanceCaption` → `CaptionPlacer.place`
  (AppKit→CG coordinate bridge; visibleFrame bounds so captions clear the
  menu bar / Dock / notch). Cursor captions keep `anchoredBubblePosition`.
- `App/Talk/InkAccentSampler.swift`: decodes the turn's in-memory window
  screenshot, samples a 24 pt patch at the marked element's center
  (window-bounds→pixel mapping), picks `InkColor.onDarkHex`/`onLightHex`.
  `TalkSession.draw` uses it for every mark's `accentHex`.

### 10 Hz reanchor (`App/Talk/TalkSession.swift`)
- While this turn's marks are shown, a 0.1 s timer re-reads the captured
  window's CG bounds (`CGWindowListCopyWindowInfo`/`.optionIncludingWindow`)
  and translates our overlays by the delta — marks follow a moved window.
- Ceiling (honest): element reflow inside a *static* window isn't tracked —
  `AXElement` is a cross-process snapshot value; no live AXUIElement exists
  on the Perry side. Window-delta covers user moves/resizes.
- Timer self-stops when the turn's overlay IDs leave the array (`clear`,
  expiry, or `cancel`).

### Capture invisibility decision (item 5)
`sharingType = .none` already excludes the overlay from *all* window-server
captures (screenshots, ScreenCaptureKit, recording, most screen shares), so
the spec's "hide on screenshot hotkeys" is redundant — nothing is ever
captured. Documented instead of adding a dead-key monitor; revisit only if
the sharing flag ever changes.

## Live evidence (2026-09-26)

- `perry-drive.sh launch` → `idle-probe.sh --seconds 60`:
  **avg CPU 0.000%, max CPU 0.000%, max RSS 79.1 MB — PASS** vs the §8
  budgets (0.5% / 180 MB). `max_cpu = 0` confirms the cursor tracker ticks
  zero times at idle (event-driven monitors only), and RSS improved from
  the Phase-0 310 MB sample. CSV: `docs/evidence/perf/idle-20260926T111904Z.csv`.

## Not yet done (per sub-plan)

- Live visual drills needing an active overlay: 120 Hz same-frame lag
  recording, `screencapture -w` invisibility diff, Reduce Motion/
  Transparency/Contrast pass. (Idle Perry shows zero on-screen windows —
  these need a live session, i.e. TCC-granted run.)
- Legacy buddy navigation/scribble/spinner deletion (post-migration audit).
