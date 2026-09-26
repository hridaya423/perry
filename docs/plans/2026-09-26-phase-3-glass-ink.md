# Phase 3: Living glass cursor and ink — sub-plan

Spec: megaplan `plan-c221ed45bb308d87.md` §5 (design system) + §7 Phase 3.
Budgets (§8): cursor follow lag ≤1 display frame; idle CPU ≤0.5%; overlays
invisible to capture; Reduce Motion/Transparency/Contrast respected.

## Current state (surveyed 2026-09-26)

- `PerryGlassCursorView` exists (`PerryGlassCursor.swift`): faceted/lens
  variants, tint + dash overlays per `PerryBuddyAnimationState`, TimelineView
  only for animated states. No morph grammar (ring/pen/caption/ghost/
  settle/amber), no mic-RMS drive, no breathing edge light.
- `OverlayWindow.swift` (1692 lines): one `NSWindow` per screen + a single
  SwiftUI root doing cursor-follow, buddy navigation, task bubbles,
  captions, circle-select, calibration, overlays. Cursor follow runs on a
  16 ms `DispatchSourceTimer` → main-hop — NOT same-frame; also the timer
  runs always (idle cost).
- Scribble ink = `PerrySmoothScribblePath` (midpoint quad curves) stroked
  with uniform width + `trim` draw-on. Spec wants centripetal Catmull-Rom,
  seeded jitter, variable width, luminance-adaptive color.
- **`sharingType` is never set** — overlay windows are capture-visible.
  Spec requires `.none` + hide-on-screenshot/share.
- Caption anchoring is `overlay.bounds.midX/maxY` — no collision solving.

## Deliverables in order

### A. Pure pieces (this commit) — `Packages/PerryOverlay`

1. `InkStroke.swift` — pure geometry, unit-testable:
   - `InkStroke.sampled(points:jitter:seed:step:) -> [CGPoint]` — centripetal
     Catmull-Rom resample (~2.5 pt step) + deterministic SplitMix64 jitter.
   - `InkStroke.widths(count:baseWidth:seed:) -> [CGFloat]` — hand-drawn
     pressure profile (±35%).
   - `InkStrokeShape: Shape` — variable-width outline built by offsetting
     sampled points along local normals, both sides joined into a closed
     path; `progress` truncates the sample window (draw-on without `trim`,
     which doesn't apply to fills).
   - `InkStroke.point(on:progress:)` — arc-length position for the pen tip.
   - `InkColor`: `luminance(rgbaData:bytesPerRow:)` (Rec. 601 over a patch)
     and `color(forLuminance:) -> (hex, Color)` — mint `#34D399` on dark,
     deep teal `#0B7285`-family on light; midpoint ≈ 0.45.
2. `CaptionPlacer.swift` — pure placement solver:
   - `place(size:anchor:avoiding:in:margin:) -> CGRect` — candidate slots
     (below, above, right, left, then inset corners) scored by overlap area
     with avoid-rects (target, caret, other marks, menu bar, Dock) +
     off-screen overflow; works in screen coords incl. negative origins.
   - 10 Hz reanchor polling lives in the app layer, only while marks show.

### B. OverlayWindow work (next commits)

3. `sharingType = .none` on every overlay window (this commit — one line).
   Hide-on-screenshot-hotkey + screen-share detection: CGWindowList scan for
   share indicators at 1 Hz while overlay visible; `SCShareableContent`
   fallback evaluation on 14+.
4. `CursorFollower` — replace the 16 ms dispatch timer with an
   `NSEvent` mouse-moved/leftDragged global+local monitor writing position
   directly (no animation on the follow write; springs only for morph
   transitions). Timer count at idle must be zero (idle probe).
5. Morph grammar in `PerryGlassCursorView`: pointer → listening ring (mic RMS
   via `currentAudioPowerLevel` already published), thinking orbit (1.2 s),
   pen, caption bubble, ghost (dashed outline), settle tick, amber hold.
   Interruptible springs (`Motion.travel` 0.32/0.86); Reduce Motion keeps
   opacity/color cues only.
6. `InkLayer` — reroute `visualGuidanceScribble`/`rectangle` through
   `InkStrokeShape` with luminance color (sample a 24×24 patch from the
   observation's screenshotData held in memory — never a fresh capture).
7. `CaptionLayer` — `CaptionPlacer` for `externalCaption` + deixis binding
   dots (a bind tick per §5 sound list lands in Phase 10 audio pass).
8. `GhostCursor` — `PerryExternalCursor` already renders glass cursors;
   convert to dashed-outline ghost per §5.
9. `DebugCursorGallery.swift` (DEBUG) — every state on light/dark/busy at
   1×/2× for snapshot evidence.

## Acceptance (from spec)

Snapshots of all states; 120 Hz recording shows zero lag; idle CPU ≤0.5%;
`screencapture -w` shows no Perry pixels; Reduce Motion/Transparency/
Contrast pass; `swift test --package-path Packages/PerryOverlay` green;
app build green; evidence in `docs/evidence/phase-3/`.

## Defer / decisions

- `OverlayWindow` file split (hosting/InkLayer/CaptionLayer/GhostCursor
  files) is mechanical — do it in the same commit as the rendering change
  to keep the diff reviewable.
- Legacy buddy navigation/scribble/spinner deletion happens after the new
  layers are live (spec: "delete after migration").
- DESIGN.md update accompanies the code so `PerryTheme`/`PerryOverlayTheme`
  stay the source of truth.
