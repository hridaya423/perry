# R6: Notch design research and spec

Date: 2026-10-25. Scope: closed state, eyes, hover, open state, shape, motion, type, icons, color.
No app was launched. No build or test ran. All numbers are points (pt) unless marked px.
`[inference]` marks a conclusion I drew. Everything else comes from a cited source or a measurement.

## 0. Verdict in six lines

1. Perry's open notch is 2.6× to 4.5× the area of HeyClicky's (section 2). Size is the main defect.
2. The "black bar beneath" has a code cause: fixed heights plus a resizing `NSPanel` plus a hard `clipShape` (section 3).
3. The eyes are 3.5 × 9 pt, one pixel-thin pair in one ear. Raise them to 7 × 12 pt, warm white, with a soft glow (section 5).
4. Every open-source notch app that looks good sizes the shape in SwiftUI inside a fixed-size window. Perry resizes the window.
5. HeyClicky's body is a black crown that fades to warm charcoal `#252523`. It is not flat black.
6. Hover: instant swell feedback at 0 ms, open at about 180 ms dwell, close after about 350 ms. Perry's 110 ms dwell opens too eagerly (section 6).

## 1. What Perry does today (repo evidence)

| Topic | Code | Value |
|---|---|---|
| Open size, focused | `App/SessionPanelPresenter.swift:195-198` | 592 wide; height = measured content + 136, else 460; plus `max(24, safeAreaInsets.top)` |
| Open size, workspace | same lines | 892 wide; height 520 + inset |
| Window resize | `App/SessionPanelPresenter.swift:99-109` | `panel.animator().setFrame`, 0.22 s |
| Open morph | `App/SessionPanelPresenter.swift:67-76` | `CAShapeLayer` mask, rounded rect radius 10, 0.34 s open, 0.22 s close |
| Final silhouette | `App/NotchPresentation.swift:90-107` | shoulder 16, bottom radius 30, one quad curve each |
| Content clip | `App/CompactConversationView.swift:29,52-53` | `Color.black.frame(height: cameraInset)`, `.background(Color.black)`, `.clipShape(NotchSilhouette())` |
| Hover intent | `App/Home/HomeHoverIntent.swift:23-24` | dwell 0.110 s, tuck 0.250 s |
| Hover zone | `App/Home/HomeController.swift:219-231` | notch width + 2 × 26 + 12, height `safeAreaInsets.top + 8` |
| Eyes | `App/Home/HomeController.swift:363-411` | two layers 3.5 × 9 pt, gap 4, tint `PerryTheme.Colors.accent` (`#9CCBB6`), blink every 7 s (`:357`) |
| Eye panel | same | black plate, `notchEar` 26 pt on each side of the notch, top corners radius 9 |
| Palette | `App/PerryTheme.swift:6-20` | canvas `#0C0D0E`, surface `#18191B`, text `#F3F0E8`, accent `#9CCBB6` |
| Notch status icons | `App/NotchStatusController.swift:190-198` | 10 pt, mixed weights, `waveform`, `gearshape.2`, `exclamationmark.circle` |
| Spring in house motion | `Packages/PerryOverlay/.../PerryTypes.swift:21-23` | `travel` response 0.2 damping 0.6 (bouncy) |

Surprises worth knowing:

- The open morph mask uses radius 10 but the final clip uses radius 30. The corner jumps when the mask is removed at the end of the open. [inference: visible pop at the end of the grow; not verified on screen]
- `docs/plans/2026-10-03-notch-acceptance.md:39` records an `_NSDetectedLayoutRecursion` caused by resizing the panel from a content-height task. Window resizing from SwiftUI measurement is already a known hazard here.

## 2. Measured comparison with HeyClicky

Source: `/Users/hridyaagrawal/.t3/userdata/attachments/58557fdf-…-b7e37725-….png`, 2000 × 1293 px.
I measured edges and colors with a small Swift pixel probe (scratch file in `/tmp`, not in the repo).

Measured in px:

- Panel x from 745 to 1255, so 510 px wide. It is centered on 1000.
- Panel bottom edge at y = 289 px. The top is the screen top, so the panel is 289 px tall.
- Colors on the right margin at x = 1240: `#000000` for y 0 to 55, `#040404` at 70, `#131212` at 85, `#232322` at 100, `#252523` from 115 to 287.
- So the top 55 px is pure black (the crown beside the camera) and it fades to `#252523` within about 50 px. The fade hides the join to the hardware notch.
- Rows: avatar circles 54 px; row pitch 73 px; hairline separator at y = 125; left content inset 33 px.
- Header controls (Update app, info, gear) sit in the black crown, level with the camera. They flank the notch.
- Footer chips ("Apps +", "Invite & Earn") are 37 px tall pills, then about 23 px to the panel bottom.
- Bottom corner radius is about 19 px.
- Chip fill about `#363635`. Primary footer chip is pale mint `#D1F1D8`.

Scale. You said divide by 2. The screenshot does not support 2 px/pt:

- Menu bar words "Window" and "Help" measure 56 px and 32 px. At 13 pt SF they are about 50 pt and 27.5 pt wide. That gives about 1.12 to 1.16 px/pt.
- 2000 px / 1728 pt is 1.157 px/pt. 1728 × 1117 pt is the default logical size of a 16-inch MacBook Pro. [inference: the capture is a 16-inch at default scaling, downscaled to 2000 px]
- The menu bar is 38 px tall, which is 33 pt at 1.157. That is consistent with a notched menu bar.

| | px | pt at 1.157 px/pt (my calibration) | pt at 2.0 px/pt (your rule) |
|---|---|---|---|
| HeyClicky open width | 510 | **441** | 255 |
| HeyClicky open height | 289 | **250** | 145 |
| Perry focused | | 592 × 492 | 592 × 492 |
| Perry workspace | | 892 × 552 | 892 × 552 |
| Perry/HC width | | 1.34× focused, 2.02× workspace | 2.3×, 3.5× |
| Perry/HC height | | 1.97×, 2.21× | 3.4×, 3.8× |
| Perry/HC area | | **2.6×, 4.5×** | 7.9×, 13.3× |

Under either scale the conclusion holds. I use the 1.157 calibration below because it matches the font evidence.

Reference sizes from other products:

| Product | Open size (pt) | Source |
|---|---|---|
| HeyClicky | 441 × 250 [inference from calibration] | screenshot |
| Apple Dynamic Island, expanded | 371 × 84 to 160 on a 393-pt screen; 408 × 84–160 on 430 | Apple HIG, Live Activities, Specifications |
| boring.notch | 640 × 190 (+20 shadow padding) | `boringNotch/sizing/matters.swift` |
| NotchDrop | 600 × 160 | `NotchDrop/NotchViewModel.swift` |
| Cyclop | 620 × 208; tall body 400 | `Sources/Cyclop/Notch/NotchGeometry.swift` |
| MioIsland | min(0.4 × screen, 480) × 200–580 by content | `ClaudeIsland/Core/NotchViewModel.swift:105-180` |
| AgentNotch (local) | 440 × 450 default, user-adjustable | `notchi/notchi/Core/AppSettings.swift:173-174` |
| Perry now | 592 × 492 and 892 × 552 | section 1 |

Pattern: the apps that feel premium are wide and short (aspect 1.8:1 to 3.8:1). The two near-square ones (AgentNotch, MioIsland chat) are the ones you call big. HeyClicky is 1.76:1. [inference]

## 3. Why the black bar and clipping appear

All of this is code reading, not a live observation. [inference]

1. Height is not content-driven for the workspace. `SessionPanelPresenter.swift:195` uses a fixed 460 or 520 when no interaction reports a height. Short content leaves empty space. The background is `Color.black`, so empty space reads as a black bar.
2. Measured heights add a constant 136 pt (`:195`). Real chrome is smaller, so every interaction card has slack.
3. The panel frame animates through AppKit (`:99-109`, 0.22 s) while SwiftUI re-measures. The frame and content disagree for a few frames. That is where content clips.
4. `.clipShape(NotchSilhouette())` (`CompactConversationView.swift:53`) cuts anything inside the 30-pt bottom corners. A button or text row near the bottom edge loses its corner pixels.
5. The open and close morph uses a different radius (10) than the final clip (30). See section 1.

How the good apps avoid it:

- They keep the NSPanel fixed and large, then resize a SwiftUI shape inside it.
  - Cyclop: window = max body height + padding (`NotchGeometry.swift:182-183`).
  - boring.notch: `windowSize = openNotchSize + shadowPadding` (`matters.swift`).
  - AgentNotch: host window scoped to the max panel rect, hit-testing passes through outside the visible rect (`AppDelegate.swift:300-325`, `Core/NotchHitTestView.swift`).
- DynamicNotchKit sizes the shape to the content with `.fixedSize()` plus 15 pt safe-area insets on the expanded content (`Sources/DynamicNotchKit/Views/NotchView.swift`). Content decides the size, so no slack exists.
- DynamicNotchKit paints the black background with `.padding(-50)` behind the mask. Its comment says spring overshoot would otherwise reveal a gap.
- Mask applies to the background only in boring.notch and DynamicNotchKit. Content is inset by the corner radius, so the mask never touches it.

## 4. Open-source notch apps: extracted values

Sources are GitHub raw files read on 2026-10-25.

### 4.1 Shape

All four projects below use the same path. It is a closed path of quad curves: concave ear at the top, straight sides, rounded bottom.

- boring.notch `components/Notch/NotchShape.swift`; DynamicNotchKit `Views/NotchShape.swift`; AgentNotch `notchi/notchi/NotchShape.swift`; Cyclop `UI/NotchShape.swift`.
- Path: `move(minX, minY)` → quad to `(minX+tr, minY+tr)` control `(minX+tr, minY)` → line to `(minX+tr, maxY−br)` → quad to `(minX+tr+br, maxY)` control `(minX+tr, maxY)` → line to `(maxX−tr−br, maxY)` → quad to `(maxX−tr, maxY−br)` control `(maxX−tr, maxY)` → line up to `(maxX−tr, minY+tr)` → quad to `(maxX, minY)` control `(maxX−tr, minY)` → close.
- The visible body is inset by `tr` on both sides. The frame must be `2 × tr` wider than the body.
- `animatableData` is `AnimatablePair(top, bottom)` so radii animate with the spring.

Radii:

| Project | Closed (top, bottom) | Open (top, bottom) |
|---|---|---|
| boring.notch | 6, 14 | 19, 24 (`matters.swift`) |
| AgentNotch | 6, 14 | 19, 24 (`NotchContentView.swift:15-18`) |
| DynamicNotchKit | 6, 14 | 15, 20 default; configurable (`DynamicNotchStyle.swift`) |
| NotchDrop | n/a | corner 16 (`NotchViewModel.swift:71`) |
| Perry | n/a | 16, 30 |
| HeyClicky | not observable | bottom about 16 pt [inference from 19 px at 1.157] |

AgentNotch can also fit the system notch outline using the private `bezelPath` of `NSScreen` via KVC (`NSScreen+Notch.swift`). That is private API. Do not copy it. The standard path above matches closely enough.

### 4.2 Closed size and screen metrics

- Width: `screen.frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width`.
  - boring.notch and AgentNotch add 4 pt to cover the hairline seam (`matters.swift`, `NSScreen+Notch.swift`).
  - DynamicNotchKit and NotchDrop do not add.
- Height: `safeAreaInsets.top` (boring.notch default mode; DynamicNotchKit; NotchDrop; coucou). AgentNotch uses `max(safeAreaInsets.top, menuBarHeight)`.
- Fallback width when areas are missing: 185 (boring.notch), 184 (coucou).
- Non-notch displays:
  - boring.notch: height from `nonNotchHeight` setting, optionally `frame.maxY − visibleFrame.maxY`.
  - DynamicNotchKit: synthetic 300 × menu bar height.
  - coucou: 80 × min(24, menu bar) (`IslandScreenGeometry.swift`).
  - Cyclop: 180 × max(menu bar, thickness, 24); collapsed strip 8 pt deep unless forced full size (`NotchGeometry.swift:159,248`).
  - AgentNotch: 224 × 38.
  - MioIsland: 38 high, max width 440 (`NotchCustomization.swift:18-20`).
- Perry's `HomeController.swift:234` draws a 64 × 7 resting tab on non-notch screens.

### 4.3 Springs and animation (SwiftUI)

| Project | Open | Close | Other |
|---|---|---|---|
| boring.notch | `spring(response 0.42, damping 0.8)` | `spring(response 0.45, damping 1.0)` | interactive `0.38 / 0.8` |
| DynamicNotchKit | `bouncy(duration 0.4)` for notch style, `snappy(0.4)` floating | `smooth(0.4)` | convert `snappy(0.4)`; content transition = blur 10 + scale y 0.6 anchored top + opacity |
| AgentNotch | `spring(0.5, 0.78)` | `spring(0.36, 0.88)` | height `spring(0.34, 0.88)`; hover swell in `spring(0.36, 0.74)`, out `spring(0.28, 0.96)`; chrome in `easeOut 0.22` delay 0.08 with y −12; chrome out `easeIn 0.12` |
| NotchDrop | `interactiveSpring(duration 0.5, extraBounce 0.25)` | same | |
| MioIsland | `easeOut(0.25)` | same | |
| Perry | custom bezier 0.34 s | custom 0.22 s | |

Observations [inference]:

- All "premium" ones use springs with damping 0.78 to 1.0. Perry's house `travel` spring (0.6 damping) is too bouncy for a large surface.
- AgentNotch staggers content after the shape (delay 0.08 to 0.12) and removes it before the shape on close. That ordering hides clipping during resize.
- DynamicNotchKit starts the animation before showing the window ("Start animation BEFORE showing window - this eliminates stutter", `DynamicNotch.swift`).

### 4.4 Hover intent

| Project | Open | Close |
|---|---|---|
| boring.notch | `minimumHoverDuration` default 0.3 s (`Constants.swift:79`) | 100 ms after exit |
| AgentNotch | `panelHoverDwellMilliseconds` default 300 ms (`AppSettings.swift:306-308`) | `hoverExitDelay` default 0 |
| MioIsland | `hoverSpeed` setting, default `.normal` | n/a |
| coucou | hover opens only when opted in; plain hover "peeks" | `hoverCloseDelay` 0.6 s |
| DynamicNotchKit | hover keeps the notch visible; `keepVisible` polls every 0.1 s | n/a |
| Perry | 110 ms (`HomeHoverIntent.swift:23`) | 250 ms (`:24`) |

Closed-state hover feedback:

- AgentNotch grows the closed shape by 7.5 pt horizontally and 5 pt down on hover, with a shadow of 0.3 opacity (`NotchPanelManager.swift:20-21`, `NotchContentView.swift:218-226,548-554`).
- DynamicNotchKit raises compact height to the menu bar height on hover and fires haptic feedback.

### 4.5 Shadow

- boring.notch: `.black.opacity(0.7)`, radius 6 (4 when corner scaling is off), only while open or hovering (`ContentView.swift`).
- AgentNotch: `.black.opacity(0.7)` radius 6 open; 0.3 hovered closed; 0.38 on a non-notch display.
- NotchDrop: shadow behind the shape.
- Panel `hasShadow = false` everywhere. Shadows are drawn in SwiftUI inside padding.

### 4.6 Window setup

- `NSPanel`, borderless and non-activating, `isFloatingPanel`, `level = .mainMenu + 3`, collection behavior `.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle`, `hasShadow = false` (boring.notch `BoringNotchWindow.swift`; AgentNotch `NotchPanel.swift`).
- coucou toggles `panel.ignoresMouseEvents` from a low-rate pointer poll, and stops polling when the screen sleeps or locks (`IslandWindowController.swift:402-459`).
- coucou caps redraws with `TimelineView(.animation(paused:))` and pauses when hidden (`BotCanvasView.swift:21`).

### 4.7 Mascots and idle life

- coucou "Mochi": squircle body, large eyes, `eyeW 0.25 × eyeH 0.27` of body size (`BotEngine.swift:80-81`), 20 pt diameter at 32 pt notch height (`IslandRestingLayout.botDiameter = min(20, height − 6)`). First blink 1.5 to 3.5 s after launch (`BotEngine.swift:266`). Eyes follow the cursor. Per-state glow color at 0.2 to 0.6 opacity (`BotEngine.swift:96-166`). Sleeping state glow 0.2. Pokes annoy it. Drag to desktop. Source: https://github.com/Louis-CFM/coucou
- MioIsland has a pixel-cat or emoji "buddy" (`NotchCustomization.swift:181-182`). Source: https://github.com/MioMioOS/MioIsland
- AgentNotch/Notchi uses sprite sheets with a shared loop anchor and a 6 s idle task; it reclaims memory after idle (`NotchContentView.swift:840-872`).
- Perry's rig: sleep after 45 s, blink cycle 3.9 s with deterministic jitter, blink length 0.14 s, minimum openness 0.3 (`PerryCharacter.swift:143-144,301-308`). The notch eyes do not use this rig. They use a separate 7 s timer with scale y to 0.12 (`HomeController.swift:357,407-413`).

## 5. Commercial references (what could and could not be verified)

- HeyClicky: web search found no notch description. The only evidence is the screenshot. Public descriptions say it is a cursor-side companion by Farza Majeed, YC Spring 2026 (https://www.lifehacker.jp/article/2604clicky-macos-companion/, https://altss.com/companies/yc/heyclicky). The open panel shows an agent list (avatar circle, 14-pt semibold title, 13-pt secondary one-line subtitle), a hairline between rows, two footer chips, and header controls in the crown. Its closed state is not visible in the provided image. Do not claim anything about it.
- Apple Dynamic Island (HIG, last updated 2026-10-13; https://developer.apple.com/design/human-interface-guidelines/live-activities):
  - Background is black and opaque; you cannot change it.
  - Use bold color for identity. A key line appears around the island in dark mode; tint it to match content.
  - Text: "large, heavier-weight … a medium weight or higher".
  - Compact: keep content "as narrow as possible and … snug against the TrueDepth camera"; leading and trailing views of balanced size. Compact views measure 62.33 × 36.67 and 52.33 × 36.67 pt.
  - Expanded: "wrap content tightly around the TrueDepth camera". Height changes dynamically with content, 84 to 160 pt.
  - Margins: even and concentric with the outer corner; do not push content into the rounded shape. Group with an inset container or a thick line, not edge-to-edge.
  - Animations: system and custom animations last at most 2 s. Preserve existing layout and animate elements to their new positions.
  - Interactivity: prefer one control; buttons take space from information.
- NotchNook: reviewers praise customization; Digital Trends notes the collapse "shrinks to a size that's just a bit bigger than the MacBook notch and then disappears". Lesson: collapse must land exactly on the closed silhouette (https://digitaltrends.com/?p=3652635). Open size not published; I did not verify it.
- Alcove: listings and reviews mention fluid transitions, live activities, swipe gestures (https://www.ifun.de/alcove-bringt-das-dynamic-island-auf-den-mac-246561/). No source gave sizes or springs. Not verified.
- Raycast: no notch-content extension found. Only "say no to notch" and zNotch, which control other apps. Nothing to learn here.
- Apple's own spring values for the Dynamic Island are not published. WWDC "Animate with springs" explains why springs preserve velocity. I could not retrieve numeric Dynamic Island curves. [gap]

## 6. Mascot and eyes on a black notch

Findings:

- Perry's current eye color has plenty of contrast. `#9CCBB6` on black is about 11.6:1. [computed] The problem is size and framing: 3.5 pt wide is 7 device pixels, antialiased, in an ear with no other shape. [inference]
- At about 32 pt height, a pair needs at least 6 to 7 pt stroke width and 11 to 12 pt height to read at arm's length. [inference; no published rule found]
- A tiny glow helps on pure black because bloom raises perceived size. coucou uses per-state glow at 0.2 to 0.6 opacity. Keep Perry's at about 0.3.
- Very low resolution kills squash-and-stretch (Adafruit eye-matrix note, https://learn.adafruit.com/adafruit-eyelights-led-glasses-and-driver/blinky-eyes-2). Use whole-shape blink and 1 to 2 pt translation, not pupils.
- Blink: random 3 to 7 s, closure 120 to 160 ms. A fixed 7 s timer feels dead and a fixed period feels mechanical. [inference]

Energy rules (Perry's idle budget is avg CPU ≤ 0.5%, `AGENTS.md` lab section):

- No looping animation while idle. Use one-shot events at jittered intervals.
- Each event is a short `CAAnimation` on two small layers. It runs in the render server, not on the main thread.
- Use a one-shot `Timer` with tolerance of 1 s so wakeups coalesce. Do not use a repeating 7 s timer.
- Pause everything when the screen sleeps or locks, in Low Power Mode, or when Reduce Motion is on. Reduce Motion shows static eyes and fades color for state.
- SwiftUI: if any `TimelineView` is used, set `paused:` true whenever the notch is closed and idle (coucou pattern).
- Do not poll the pointer for gaze. Glance on hover enter, on state change, and on timed events only.

## 7. Spec Perry can implement

Terms: `notchW` = `frame.width − auxLeft.width − auxRight.width`. `notchH` = `safeAreaInsets.top` (about 32 on notched MacBooks). `menuBarH` = `frame.maxY − visibleFrame.maxY`.

### 7.1 Closed state

- Visible shape: black silhouette `notchW + 4` wide (seam cover, as boring.notch) × `notchH` tall, ears 6, bottom 14.
- Idle wing: one wing on the right side, 38 pt wide, same height. Eyes live in the wing.
  - Why one wing: a 38-pt tab is smaller than the old 2 × 26 plate and does not cover the left menu area. HIG allows a leading-only or trailing-only compact view. [inference]
- Active states (listening, working, needs review): add a left wing of equal width with the state glyph or count. Balanced wings follow HIG.
- Non-notch display: black pill 150 × `menuBarH`, top flush, bottom radius 12, ears 0. Show it only while there is state or on hover. Idle on a non-notch display shows no pill. Keep the 64 × 7 tab only if the user turns "always show" on. [inference: judgment call]
- Never draw over the menu bar further than the wing width. Never draw below `notchH` when idle.

### 7.2 Eyes

| Property | Value |
|---|---|
| Each eye | capsule 7 pt wide × 12 pt tall, corner radius 3.5 |
| Gap | 8 pt (centers 15 pt apart); pair width 22 pt |
| Position | centered in the wing, vertical center at `notchH / 2` |
| Fill | `#F4F1E8` (warm white, 17.8:1 on black) |
| Glow | accent `#7BE3BD` at 0.30 opacity, blur radius 6, drawn behind the eyes |
| Listening | eyes 8 × 14, glow 0.55, accent fill `#7BE3BD` |
| Working | normal size; slow glance left and right every 2.5 to 4 s |
| Needs review | amber `#FFB020` fill, hold 14 pt tall, no blink |
| Sleeping (after 45 s idle, matches `PerryCharacterRig.sleepAfter`) | closed arcs 7 × 2.5 pt, fill `#F4F1E8` at 0.6 opacity, glow off |
| Blink | scale y 1 → 0.08 → 1, 150 ms, `easeInEaseOut` |
| Blink schedule | one-shot, random 3.2 to 7.5 s; 15% double blink 180 ms apart |
| Glance | translate x by ±2 pt, y by 1 pt, 220 ms, random 8 to 20 s; also look toward the notch center once after hover enter |
| Hover enter | eyes scale 1.0 → 1.12 and look down 1 pt over 120 ms |

Rationale: bigger capsule, warm white for contrast, glow for perceived size, event-driven motion for energy. [inference]

### 7.3 Hover intent

- Hover zone: the visible closed silhouette plus 6 pt on the left, right and bottom. Not the old `notchW + 52 + 12`.
- At 0 ms (pointer enters): swell the closed shape by 6 pt horizontally and 4 pt down, spring `response 0.30, damping 0.72`, shadow opacity 0.3. This is instant feedback, under 100 ms.
- At 180 ms continuous dwell: open the peek panel.
  - Why not 110 ms: the zone is a thin strip at the screen top where the pointer often passes to reach menus. boring.notch and AgentNotch both default to 300 ms. Perry's swell supplies feedback, so 180 ms is a compromise. [inference]
- Click on the notch opens immediately, skipping dwell.
- Pointer leaves the open panel: close after 350 ms. Re-entry within that time cancels. Treat a 6-pt margin around the open shape as inside.
- Swell out (pointer leaves before dwell ends): spring `response 0.26, damping 0.95`.
- Esc closes and latches until the pointer leaves the zone. Keep `HomeHoverIntent` states as they are; change only the numbers.
- Do not open on hover while a full-screen app is in a Space where the user has not used Perry. [inference: avoid surprise]

### 7.4 Open state bounds

All panels hug content. The window is fixed at the maximum rect (section 7.9).

| Mode | Width | Height | Notes |
|---|---|---|---|
| Peek (hover) | 440 | content, clamp 120 to 260 | matches HeyClicky 441 × 250 |
| Focused (approval, guide step, onboarding) | 440 | content, clamp 160 to 320 | |
| Workspace | 560 | content, clamp 220 to 400 | left rail 148 + content 412 |
| Absolute caps | min(600, 0.40 × screen width, screen width − 32) | min(0.38 × screen height, 440) | |

- Aspect ratio target 1.5:1 or wider. HeyClicky is 1.76:1. Dynamic Island expanded is 4.6:1 to 2.3:1.
- Height changes use the resize spring in 7.6. No jump.
- Overflowing content scrolls inside a fixed header and footer. The panel never grows past its cap.
- Result against HeyClicky: peek 440 × ≤260 vs 441 × 250, so area ratio about 1.0 to 1.04. Perry's old focused panel was 2.6×.

### 7.5 Shape path

- Use the quad-curve path in section 4.1 in a `Shape` with `AnimatablePair(topRadius, bottomRadius)`.
- Closed: top 6, bottom 14.
- Open: top 18, bottom 22. Pairs with 16 pt horizontal content inset.
- Frame width = body width + 2 × top radius.
- Replace the single 30-pt bottom quad with a continuous corner for the bottom. Preferred: `UnevenRoundedRectangle(bottomLeadingRadius:bottomTrailingRadius:style: .continuous)` for the body and the quad ears for the top. Otherwise keep the quad. [inference]
- Draw one hairline stroke along the sides and bottom: 1 pt, white 8% opacity, fading from 0% at the crown to 10% at the bottom. This is the HIG "key line". Do not stroke the top edge.
- Open and close animate the same shape. Delete the `CAShapeLayer` mask morph (`SessionPanelPresenter.swift:58-97`).

### 7.6 Springs

| Use | Spring |
|---|---|
| Open | `.spring(response: 0.38, dampingFraction: 0.82)` (about 1% overshoot) |
| Close | `.spring(response: 0.30, dampingFraction: 0.95)` |
| Content resize (height or width change) | `.spring(response: 0.32, dampingFraction: 0.90)` |
| Hover swell in | `.spring(response: 0.30, dampingFraction: 0.72)` |
| Hover swell out | `.spring(response: 0.26, dampingFraction: 0.95)` |
| Content in | `.easeOut(duration: 0.20)`, delay 0.08, offset y −8 → 0, opacity 0 → 1 |
| Content out | `.easeIn(duration: 0.10)`, no delay, offset y −4 |
| Reduce Motion | opacity-only 0.15 s; no spring, no offset; shape size changes `.easeInOut(0.18)` |

- On close, remove content before the shape moves (0.10 s first). This matches AgentNotch's ordering.
- Start the shape animation before ordering the window front (DynamicNotchKit note).
- Paint the black background 40 pt larger than the mask behind it so overshoot never shows a gap (DynamicNotchKit `.padding(-50)`).
- Keep every transition under 2 s total (HIG).
- The old `travel` spring (0.2 / 0.6) is for the cursor buddy, not the notch.

### 7.7 Content insets

- Horizontal inset from body edge: 18 pt. At least the bottom radius minus 4.
- Crown height: `notchH + 8`. Header controls sit in the crown on both sides of the camera at `notchH / 2`, 28 × 28 hit targets, 12 pt from the shape edge (HeyClicky does this; HIG says wrap content tightly around the camera).
- Content starts at crown bottom + 6.
- Bottom inset: 16 pt. A row or chip never sits within 14 pt of the bottom edge.
- Row spacing: 12 pt between rows, 1 pt hairline separator white 8%.
- Footer chips: 32 pt tall, 12 pt gap, 10 pt side padding, corner radius 16.
- Scroll areas fade over the last 16 pt with a `LinearGradient` mask. Never cut hard.

### 7.8 Type scale (SF Pro, `Font.system`)

HIG: use "a medium weight or higher" for primary text. HeyClicky sizes are from the screenshot at 1.157 px/pt. [inference]

| Role | Size / weight | Color |
|---|---|---|
| Panel title | 15 / semibold | text `#F5F2EA` |
| Row title | 14 / semibold | text |
| Body | 13 / regular | text 90% |
| Secondary line | 12.5 / regular | `#A6A59F` (about 7:1 on `#1A1B1D`) |
| Chip label | 13 / medium | text |
| Meta (time, counts) | 11 / medium, `.monospacedDigit()` | `#8B8A85` |
| Section label | 11 / semibold, no uppercase, no tracking | `#8B8A85` |

- Do not use `#6E6D69` for text. It is 3.4:1 on the body. Use it only for decoration.
- One line of subtitle with tail truncation, as in HeyClicky's rows.
- Perry's current macOS dynamic type styles (`.headline` 13 bold, `.subheadline` 11, `.caption` 10) are smaller and less varied than this. [inference]

### 7.9 Window and layout architecture

- One fixed-size borderless `NSPanel` at the maximum open rect + 48 pt shadow padding left, right and bottom. Set `hasShadow = false`.
- Set `NSHostingView.sizingOptions = []` so SwiftUI never changes window constraints. [inference: API exists on macOS 13+; not verified in this repo] This also removes the layout-recursion hazard recorded in `NotchStatusController.swift:3-6` and the acceptance doc.
- Hit testing: return `nil` outside the visible shape (AgentNotch `NotchHitTestView`). Toggle `ignoresMouseEvents` while closed.
- Drive size from SwiftUI state: `@State var size`. `NotchPresentation.measure` feeds it. No `setFrame` during interaction.
- Shape fill is the background; use `.background(shape)`, not `.clipShape` on content.
- Multi-screen: anchor to the screen with the notch or the screen under the pointer. Use `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` for center X, as `NotchStatusController.swift:131-136` already does.

### 7.10 Icons (SF Symbols)

Problems today [inference]: 10-pt symbols with mixed `semibold` and `medium`, flat `contentTintColor`, and the busy `gearshape.2`.

Rules:

- One weight per size: `.semibold` at 11 pt and below; `.medium` at 12 to 15 pt. Never mix within a row.
- Scale `.medium`. Point size 13 for toolbar, 15 for row leading icons, 11 for inline.
- Toolbar and chips: `.symbolRenderingMode(.monochrome)`, `.foregroundStyle(.secondary)`, primary on hover.
- Status glyphs: `.symbolRenderingMode(.hierarchical)` with the state color.
- Hit target 28 × 28. Hover wash: white 8% in a circle or 8-pt rounded rect. No bordered buttons.
- Do not draw icons in filled circles unless it is the single primary action.

Suggested names (all in SF Symbols 4 or earlier; check on the installed SF Symbols app before shipping):

| Role | Symbol |
|---|---|
| Listening / wake | `waveform` |
| Voice start | `mic.fill` |
| Settings | `gearshape` (not `gearshape.2`) |
| Background tasks | `circle.dotted` |
| Needs review | `exclamationmark.bubble` |
| Approval | `checkmark.shield` |
| Routines | `clock.arrow.circlepath` |
| Files | `doc.text` |
| Search | `magnifyingglass` |
| New | `square.and.pencil` |
| Back | `chevron.left` |
| Close | `xmark` |
| Expand | `arrow.up.left.and.arrow.down.right` |
| More | `ellipsis` |

Use `Image(systemName:)` in SwiftUI. In the AppKit status view, keep `NSImage.SymbolConfiguration(pointSize:weight:scale:)` and set `.withSymbolConfiguration(.init(hierarchicalColor:))` for hierarchical rendering.

### 7.11 Color (exact hex)

Idea: black where the hardware is black, warm charcoal below. This follows HeyClicky's measured body `#252523` and Apple's black-opaque island. Perry's flat `#000000` panel reads as a void. [inference]

| Token | Hex | Use |
|---|---|---|
| `crown` | `#000000` | top `notchH + 8`; merges with the hardware |
| `body` | `#1A1B1D` | open body below the crown fade |
| `bodyTop` fade | `#000000` → `#1A1B1D` over 48 pt starting at `notchH + 8` | vertical `LinearGradient` |
| `card` | `#232427` | inset groups |
| `chip` | `#2C2D31` | secondary chips, hover wash base |
| `separator` | white 8% | hairlines |
| `keyline` | white 0% → 10% | shape stroke |
| `text` | `#F5F2EA` | primary |
| `text2` | `#A6A59F` | secondary |
| `text3` | `#8B8A85` | meta |
| `accent` | `#7BE3BD` | eyes glow, listening, primary links |
| `primaryAction` fill | `#F5F2EA`, label `#0C0D0E` | one pill per view |
| `success` | `#5FD38D` | done |
| `caution` | `#FFB020` | needs review, amber hold |
| `danger` | `#FF6B63` | error, recording dot |

Notes:

- Perry's `PerryTheme` dark values are `#0C0D0E`, `#18191B`, `#F3F0E8`, `#9CCBB6`. The new `body` and `text` are close. The accent change (`#9CCBB6` → `#7BE3BD`) is the visible one: brighter, one hue, usable as a glow on black. [inference]
- Use one accent hue. State colors appear only on the eyes, one dot, and one glyph at a time.
- Contrast checked (WCAG relative luminance, computed by hand): `text` on `body` above 14:1; `text2` about 7:1; `text3` about 5:1; `accent` on `body` above 10:1.

Shadow (open only):

- Two layers: `.shadow(color: .black.opacity(0.45), radius: 18, y: 8)` and `.shadow(color: .black.opacity(0.35), radius: 2, y: 1)`.
- Closed: none. Hover swell: `.black.opacity(0.3)`, radius 6 as AgentNotch.
- boring.notch and AgentNotch use a single radius-6 shadow at 0.7. On a light wallpaper that reads as a hard edge. The layered version is softer. [inference]

### 7.12 Do not

1. Do not leave a region of flat black under content. If the body is taller than content, the shape is wrong.
2. Do not set a fixed open height unless content scrolls. Use content-driven height with a cap.
3. Do not call `NSPanel.setFrame` to animate open, close, or resize. Animate the SwiftUI shape.
4. Do not use `.clipShape` on content. Mask the background. Inset content by the radius.
5. Do not use a mask morph with a different corner radius than the final shape.
6. Do not open at 592 or 892 pt wide. Cap at 600 and default to 440.
7. Do not use springs below 0.78 damping for the main surface.
8. Do not run a repeating timer or a looping animation while idle.
9. Do not use private API (`bezelPath`) to fit the notch.
10. Do not draw more than the wing width into the menu bar. Do not draw below the notch while idle.
11. Do not place icons in 10-pt sizes or mix weights in one row.
12. Do not fade the panel to zero while shrinking. The close must land on the closed silhouette (NotchNook complaint).
13. Do not start the open from a different origin than the closed shape. The open grows from the hovered closed silhouette.

### 7.13 Implementation order (smallest diff first)

1. Eyes: size, color, glow, jittered one-shot blink (`HomeController.swift:363-413`). Visible at once, low risk.
2. Numbers: hover (`HomeHoverIntent`), peek width 440, heights, caps (`SessionPanelPresenter.swift:195-198`).
3. Palette: crown fade, `body`, `text` tokens, accent (`PerryTheme.swift`).
4. Shape and motion: SwiftUI shape with animatable radii, delete the mask morph and `setFrame` animation, fixed window.
5. Icons and type scale.

## 8. Gaps and risks

- Perry's closed-state screenshot, HeyClicky's closed state, and NotchNook and Alcove sizes were not available. Those rows are unverified.
- Scale for the HeyClicky screenshot is inferred. If you confirm the capture came from a different display, rescale section 2. The spec numbers in section 7 do not depend on it except the claim "matches HeyClicky".
- No Dynamic Island spring numbers are public. Spring values in 7.6 come from open-source apps and are untested in Perry.
- All eye sizes and the 180 ms dwell are design judgments. Validate with `scripts/lab/perry-drive.sh` and `latency-report.py` once Perry is back on the test Mac, per the memory note about not testing on the MacBook in use.
- `NSHostingView.sizingOptions` behavior needs a check on this SDK before relying on it.

## 9. Sources

- https://developer.apple.com/design/human-interface-guidelines/live-activities (HIG, fetched 2026-10-25)
- https://github.com/TheBoredTeam/boring.notch (`sizing/matters.swift`, `components/Notch/NotchShape.swift`, `ContentView.swift`, `models/Constants.swift`)
- https://github.com/MrKai77/DynamicNotchKit (`Views/NotchView.swift`, `Views/NotchShape.swift`, `DynamicNotch/DynamicNotchStyle.swift`, `DynamicNotch/DynamicNotch.swift`, `Utility/NSScreen+Extensions.swift`)
- https://github.com/Lakr233/NotchDrop (`NotchViewModel.swift`, `NotchView.swift`, `Ext+NSScreen.swift`)
- https://github.com/Louis-CFM/coucou (`IslandScreenGeometry.swift`, `BotCanvasView.swift`, `BotEngine.swift`, `IslandStateMachine.swift`, `IslandWindowController.swift`)
- https://github.com/MioMioOS/MioIsland (`Core/NotchViewModel.swift`, `Models/NotchCustomization.swift`)
- https://github.com/akalikbergenov/cyclop (`Notch/NotchGeometry.swift`, `UI/NotchShape.swift`)
- Local copy: `/Users/hridyaagrawal/Honey/AgentNotch/notchi/notchi/` (`NotchContentView.swift`, `NotchShape.swift`, `NSScreen+Notch.swift`, `NotchPanel.swift`, `AppDelegate.swift`, `Core/NotchHitTestView.swift`, `Core/AppSettings.swift`, `Services/NotchPanelManager.swift`)
- https://digitaltrends.com/?p=3652635 (NotchNook review)
- https://www.ifun.de/alcove-bringt-das-dynamic-island-auf-den-mac-246561/ (Alcove)
- https://www.lifehacker.jp/article/2604clicky-macos-companion/ and https://altss.com/companies/yc/heyclicky (HeyClicky background)
- https://learn.adafruit.com/adafruit-eyelights-led-glasses-and-driver/blinky-eyes-2 (low-resolution eyes)
- Perry repo files cited in section 1 and `docs/heyclicky-teardown.md`
