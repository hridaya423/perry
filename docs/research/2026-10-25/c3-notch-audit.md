# C3: Notch UI code audit (2026-10-25)

Method: static read of the code listed in the brief, plus the HeyClicky screenshot. I did not launch Perry, build, or run tests, so no claim below is visually verified. Where a claim depends on arithmetic or an assumption I say so. Line numbers are from the working tree on `codex/living-ink-redesign`.

## 0. Summary

1. The hover "peek" opens the full 892×552 pt workspace. No small peek state exists (`App/AppSubsystems.swift:526` → `App/SessionPanelPresenter.swift:176-207`). HeyClicky's open notch is about 441×250 pt. Perry is about 4.5× larger by area.
2. The "black bar beneath" has three sources: a double-counted camera inset in interaction panels, a fixed 520 pt content height, and a black layer stack (`#000` vs `#0C0D0E`). Details in §2.
3. Hover timing numbers are close to best practice. The feel problem is the curve and the content: a mask wipe over an already-laid-out full-size window. See §3.
4. The resting eyes are two 3.5×9 pt sage bars, in the right ear only, blinking every 7 s. Nothing else (`App/Home/HomeController.swift:363-412`).
5. The notch workspace uses only static mascot poses. The animated `PerryCharacter` is not used there (§5).
6. Starting voice from the notch collapses the notch (`App/SessionPanelPresenter.swift:214-221`). The only on-screen "end" controls are the onboarding "I'm done" button and a "Stop" that cancels. That is the "go to the notch and click done talking" complaint (§6).
7. Peek never auto-closes while any `NotchPresentation` entry exists, for example a running task (`App/AppSubsystems.swift:529-530`).
8. Hover-out calls `conversationVoice.cancel()` through `hidePanel()` (`App/SessionPanelPresenter.swift:279`).
9. Two accent colors, several near-black layers, no material, and default SF Symbols at mixed weights explain the "mehhh" palette and the "ugly" icons (§1.12, §1.13).
10. Ranked defects and a delete list are in §7 and §8.

---

## 1. Surface map

### 1.1 Notch geometry inputs

| Quantity | Source | Value |
|---|---|---|
| Notch height | `screen.safeAreaInsets.top` | Hardware value. 32 pt on 14"/16" MacBook Pro (assumed, not read from this machine). Code uses `max(24, safeTop)` at `App/CompactConversationView.swift:96` and `App/SessionPanelPresenter.swift:198`. |
| Notch width | `screen.frame.width − auxiliaryTopLeftArea.width − auxiliaryTopRightArea.width` | Computed at `App/SessionPanelPresenter.swift:63`. |
| Ear | `HomeController.notchEar = 26` | `App/Home/HomeController.swift:219` |

### 1.2 Hover zone, click rect, panel placement (`App/Home/HomeController.swift`)

- `zoneRect` (`:221-235`), notched screen:
  - `left = auxTopLeft.maxX`, `right = auxTopRight.minX`, `width = max(220, (right−left) + 2·26 + 12)` = notch + 64 pt.
  - `y = top − safeTop − 8`, `height = safeTop + 8` = 40 pt.
  - So the zone reaches 8 pt below the menu bar into the app window.
  - Non-notch screens: 120 pt wide, menu-bar high, centred (`:233-234`).
- `clickRect` (`:244-250`): notch + 52 pt wide, exactly `safeTop` tall. It falls back to `zoneRect` on non-notch screens.
- `notchPanelFrame(size:screenFrame:centerX:)` (`:252-257`): clamps width and height to the screen, centres on `zoneRect.midX`, and pins the top to `screenFrame.maxY`.

### 1.3 Resting eyes panel `makeNotchEyes` (`HomeController.swift:363-402`)

- Frame: `x = left.maxX − 26`, width = notch + 52, height = `safeTop` (`:367-369`). The panel covers the notch and 26 pt on each side.
- Level `.statusBar`, `ignoresMouseEvents = true`, no shadow, `canJoinAllSpaces`, `stationary`, `fullScreenAuxiliary` (`:371-376`).
- Fill: `NSColor.black`, corner radius 9, bottom corners only (`:380-382`).
- Eyes (`:384-398`):
  - Tint is `PerryTheme.Colors.accent` resolved in dark appearance = `#9CCBB6` sage (`:384-387`, `App/PerryTheme.swift:15`).
  - Size 3.5×9 pt, corner radius 1.75, gap 4 pt (`:388-396`).
  - Both eyes sit in the right ear only: `originX = frame.width − 26 + (26 − 11)/2 − 2` (`:390`). The left ear is empty.
  - The pair spans 11×9 pt, 28% of a 32 pt notch height.
- Non-notch screens get a 64×7 pt black tab, no eyes (`:414-434`).
- Blink: a 7 s repeating `Timer` (`:356-359`). `CAKeyframeAnimation` `transform.scale.y` `[1, 0.12, 1]` over 0.18 s (`:407-410`). No timing function, no jitter, skipped under Reduce Motion (`:405`).
- No glance, squint, or mood code anywhere in the repo (`rg -i "glance|squint"` returns nothing).
- The eyes are hidden with `orderOut` whenever the conversation panel is visible (`:442-447`).

### 1.4 Hover intent (`App/Home/HomeHoverIntent.swift`) and pointer handling

Timings are in §3.

### 1.5 Open notch panel (`App/SessionPanelPresenter.swift`, `App/CompactConversationView.swift`)

**Panel frame** (`notchPanelFrame()`, `SessionPanelPresenter.swift:188-207`):

```
focused  = onboarding active (and not settings) || NotchPresentation interaction showing   // :192-193
contentH = interaction?.contentHeight.map { max(220, $0 + 136) } ?? (focused ? 460 : 520)   // :195
width    = min(focused ? 592 : 892, screen.width − 32)                                       // :197
height   = min(contentH + max(24, safeTop), screen.height − 64)                              // :198
```

| State | Width | Height (safeTop = 32) |
|---|---|---|
| Workspace (default, and hover peek) | 892 | 520 + 32 = **552** |
| Onboarding | 592 | 460 + 32 = **492** |
| Approval, activity, guide interaction | 592 | max(220, c + 136) + 32 = **c + 168** (min 252) |

`c` is the measured SwiftUI content height. The frame is created once as 480×380 (`PerryTheme.Sizing.panelWidth/Height`, `SessionPanelPresenter.swift:144`) and overwritten by `place()`.

**SwiftUI body** (`CompactConversationView.swift:27-68`):

```
VStack(spacing: 0) {
  Color.black.frame(height: cameraInset)                         // :29  cameraInset @State = 32 (:19), refreshed :94-97
  NotchInteractionHost { workspace }.frame(max ∞).padding(.horizontal, 16)   // :30-36
  bottom: "Return to active task" row (caption, h pad 36, bottom 12) OR Color.clear.frame(height: 16)  // :37-50
}
.background(Color.black)            // :52
.clipShape(NotchSilhouette())       // :53
.preferredColorScheme(.dark)        // :56
```

- Hosting view `sizingOptions = []` (`App/AppController.swift:84`). SwiftUI never sizes the window. Only `notchPanelFrame()` does.
- **Silhouette** (`App/NotchPresentation.swift:90-107`):
  - Top edge is full width.
  - Each top corner flares inward with a quad curve, `shoulder = 16`.
  - The body is inset 16 pt on each side.
  - Bottom corner radius is `bottom = 30` (quad curve, not a continuous corner).
  - The visible body is 860 pt wide inside the 892 pt panel.
  - The content `.padding(.horizontal, 16)` equals the shoulder, so content sits flush against the silhouette edge with zero margin.
- **Window**: `CompactConversationPanel` (`CompactConversationView.swift:6-13`), borderless nonactivating `NSPanel`, level `.statusBar`, floating, no shadow, clear background, dark appearance (`SessionPanelPresenter.swift:141-162`). `canBecomeKey = true`. `constrainFrameRect` is overridden to return the frame unchanged, so the panel can sit over the menu bar.
- Motion is in §3.

### 1.6 Workspace (`App/Home/NotchWorkspaceView.swift`)

Layout: `HStack { rail(210) | 1pt separator | page }`, background `PerryTheme.Colors.canvas` (`:19-38`). Frame `min 560×380, ideal 860×500, max ∞` (`:69-70`).

**Rail** (`:77-292`), 210 pt wide (24% of the 860 pt body):
- Header: mascot 20 pt (static `PerryCharacterView`, `:84`) plus "perry" in system 18 semibold rounded (`:86`). Padding top 16, bottom 12.
- Search field with `magnifyingglass` (`:99`). Row background `surface` in an 8 pt continuous rounded rect. Plus button `plus` at `.callout.medium` in a 27 pt `surface` circle (`:114-118`).
- Five nav rows (`:127-131`): `checklist`, `repeat`, `folder`, `lightbulb`, `clock.arrow.circlepath`. They are 18 pt wide frames, default weight, `textSecondary`. Title is `.callout`. Padding 8×6.
- "Perrys" list (`:140-199`): mascot 22 pt (static), name `.callout.medium`, job `.caption`. `plus` at `.caption.semibold` (`:149`).
- "Recent" list (`:201-246`): `doc.text` icon, `.callout` title, `.caption` relative date.
- Footer (`:271-290`): `square.grid.2x2` "Apps" and `gearshape` "Settings", both `.callout`.
- Selection pill: white 0.10 with `matchedGeometryEffect` (`:406-413`). Row hover: white 0.05 / pressed 0.10, `Motion.snap` (`:636-657`).
- List fade mask at the bottom: a 20 pt gradient (`:251-256`).

**Resting page** (default, `sidebarSelection == nil`, `:294-358`), top to bottom:
1. `windowControls` row (`:360-372`): `ellipsis` NSPopUpButton 28×28 (13 pt semibold, `App/NotchPresentation.swift:83-84`) and `xmark` (12 semibold, 28×28, `:625`).
2. `Spacer(minLength: 12)`.
3. Mascot 40 pt (static) plus greeting `system(26, semibold, serif)` (`:304-308`).
4. `GestureHint` (`:601-615`): "Hold [⌃⌥] to talk, or double-tap [⌃] to type". The `Keycap` is 12 semibold rounded, 22×20, `surface` fill with a 1 pt `#303234` stroke and a 1 pt black drop shadow (`App/Home/WorkspaceComponents.swift:4-25`).
5. `WorkspaceComposer` (`:314-324`, `WorkspaceComponents.swift:27-96`): 15 pt text, `surface` rounded rect radius 14 continuous, 1 pt stroke, accent 0.8 when focused. Mic button is `mic.fill` 13 semibold in a 28 pt circle filled with separator 0.7. When text exists it becomes a send button `arrow.up` 13 bold in a cream `primaryAction` circle. The swap uses `.spring(response: 0.25, damping: 0.8)` plus scale 0.6 and opacity.
6. `WorkspaceVoiceStatus` (`:558-599`).
7. Context chips: `macwindow` "Choose a window" and `ModelSettingsButton`. `ContextChipStyle`: `.caption`, secondary text, white 0.05 capsule with a separator stroke (`WorkspaceComponents.swift:111-125`).
8. `Spacer(minLength: 20)` and the recovery or storage-error area.

Content column `maxWidth 500`, padding 32 (`:339-340`).

**Focused pages** (`:427-457`): a 52 pt header with `.title3.semibold` title and the same window controls, a 1 pt separator, then the page. Page transition is `opacity + offset(y: 6)` with `Motion.glide = spring(response: 0.32, damping: 0.86)` (`:35`, `:459-461`).

### 1.7 Other pages

- `App/Home/HomeConversationView.swift`: user bubble is white 0.09, radius 14, `.body`. Answer column `maxWidth 680`, padding 20, `LazyVStack` spacing 28. "Working on it" row uses `ProgressView` plus `Stop` with `stop.fill`. Follow-up composer with `.padding(20)`.
- `App/Home/BackgroundTasksView.swift:108-114`: row icon is `.headline.weight(.semibold)` in a 24 pt frame. Goal text is `.body.weight(.medium)`.
- `App/Home/HistoryView.swift:185-195`: 22 pt app icon plus a 20 pt `iconName` symbol. Title is `.body.weight(.medium)`.
- `App/Home/HomeView.swift`: a thin wrapper. At runtime `CompactConversationView` calls `NotchWorkspaceView` directly. `HomeView` is used only by tests (`AppTests/PaperOnboardingTests.swift:17-20`, `AppTests/HomeRecoveryTests.swift:159`).

### 1.8 Interactions inside the notch (`NotchPresentation`, `NotchInteractionHost`)

- `NotchInteractionHost` (`CompactConversationView.swift:186-230`): when an entry is showing, `VStack(spacing: 16) { header(Workspace ‹ / Collapse ⌃); ScrollView { entry.content.fixedSize(vertical) } }.padding(24)`. Content height is reported through `onGeometryChange` (`:222-224`) to `NotchPresentation.measure`.
- `NotchDialogView` (`App/NotchDialog.swift:87-128`): `title3.semibold` title, `.callout.medium` message, `InkButtonStyle` buttons (13 pt medium). `.padding(20)`, `minWidth 340, max 500`, `surface` fill in a radius-18 continuous rect (`PerryTheme.Radius.panel`). This is a card inside the 24 pt padded host, so it is a card in a notch.
- `AgentActivityStripView` (`App/AgentActivityStrip.swift:191-247`): header with an animated `PerryCharacter(.working/.needsYou/.resting, size 24)` (`:253`), `panelTitle` headline, tier capsule, elapsed `TimelineView`, 4 pt progress capsule, `ContextChipStyle` controls with `pause.fill`, `play.fill`, `hand.raised`, `stop.fill` (icon-only when collapsed). Expanded state is `surface` radius 18 with a stroke.
- Strip plumbing: `NotchPresentation.present(priority: .activity, reveal: state.isExpanded)` (`:587-588`). When collapsed it is registered but not shown. It adds a "Return to active task" row at the bottom of the notch (`CompactConversationView.swift:37-47`).
- `NotchStatusController` (`App/NotchStatusController.swift`): a separate AppKit panel below the notch while collapsed, shown only for recording, background tasks, approvals, or wake listening (`:88-90`).
  - Capsule fill is `black`.
  - Stack edge insets are `top = safeTop + 7, left/right 16, bottom 9` (`:141`).
  - Min width 220.
  - Bottom corners are masked to radius 14 (`:144-145`).
  - Labels are 11 pt medium.
  - Symbols are 10 pt: `waveform` (overlay accent `#34D399`), `gearshape.2`, `exclamationmark.circle`.
  - Fade in 0.18 s ease-out, fade out 0.16 s.

### 1.9 Legacy guide panel

`CompactConversationView.swift:76-88` and `App/SessionPanelView.swift`: a `ScrollView` with `minWidth 480` and its own `canvas` background, nested inside the host (which already pads 16). It has a segmented Ask/Guide/Do picker, a rounded-border `TextField`, a checkbox, a `mic.fill` button, and a full-width `Start` button. This is the older style, visibly different from the rest.

### 1.10 PerryTheme (`App/PerryTheme.swift`)

| Token | Dark | Light |
|---|---|---|
| `canvas` | `#0C0D0E` | `#F5F3EE` |
| `surface` | `#18191B` | `#FFFEFA` |
| `text` | `#F3F0E8` (warm cream) | `#202420` |
| `textSecondary` | `#AAA9A5` | `#666D66` |
| `subtleSeparator` | `#303234` | `#DCDDD5` |
| `primaryAction` | `#F3F0E8` | `#202420` |
| `accent` | `#9CCBB6` (sage) | `#3C7765` |
| `cameraCrown` | black (used only by onboarding, `OnboardingNotchView.swift:66`) | |

- The notch is forced dark (`CompactConversationView.swift:56-57`, `SessionPanelPresenter.swift:150`).
- Radius: `panel = 18`.
- Motion: `panelStateChange` easeOut 0.16, `snap` 0.16, `glide` spring(response 0.32, damping 0.86), `settle` timingCurve(0.23, 1, 0.32, 1) 0.42 s. `settle` has no use in the notch files audited.
- Typography: headline 13 semibold, body 13, callout 12, caption 10 on macOS (Apple text-style defaults; approximate).

### 1.11 Materials

None. No `NSVisualEffectView`, no `.material`, no blur in the notch files. Every surface is opaque.

### 1.12 Palette fragmentation (the "mehhh")

- Black layers: `#000` panel, `#0C0D0E` workspace canvas, `#18191B` surface, `OnboardingStyle.carbon` `#181919` (`App/Onboarding/OnboardingParts.swift:9`), plus white-alpha overlays 0.05, 0.09, 0.10. On a mini-LED XDR display `#000` and `#0C0D0E` are visibly different.
- Two accents:
  - `PerryTheme` sage `#9CCBB6` (eyes, focus rings).
  - `PerryOverlayTheme.Colors.accent` emerald `#34D399` (`Packages/PerryOverlay/Sources/PerryOverlay/PerryTypes.swift:4`), used by `NotchStatusController.swift:192`.
- Text is warm cream `#F3F0E8` on cool blue-gray black. The pairing is neutral to muddy.

### 1.13 Icons (the "ugly")

- All icons are default monochrome SF Symbols in `textSecondary`, at sizes inherited from text styles. They have no accent color and no shared frame:
  - 13 semibold (mic, ellipsis), 13 bold (send), 12 semibold (xmark).
  - `.callout.medium` plus in the rail search row (`NotchWorkspaceView.swift:115`) versus `.caption.semibold` plus in the Perrys header (`:149`).
  - Nav icons at body size in an 18 pt frame (`:380-382`).
- No icon container language: some are bare, some in `surface` circles, some in separator circles.

---

## 2. Cause of the "big black bar beneath clipping some things"

Static analysis finds four contributors. Contributor A is confirmed by arithmetic. B, C, D are structural and unverified visually.

### A. Interaction panels double-count the camera inset (about 36 pt of dead black)

`SessionPanelPresenter.swift:195`:
```swift
let contentHeight = interaction?.contentHeight.map { max(220, $0 + 136) } ?? (focused ? 460 : 520)
```
`:198`:
```swift
height: min(contentHeight + max(24, screen.safeAreaInsets.top), screen.frame.height - 64)
```

The view stack for an interaction (`CompactConversationView.swift:28-51`, `:208-227`) needs:

| Piece | Height |
|---|---|
| Camera strip (`Color.black.frame(height: cameraInset)`, `:29`) | 32 |
| Host `.padding(24)` top | 24 |
| Header buttons | about 20 (estimate) |
| `VStack(spacing: 16)` | 16 |
| Measured content `c` | c |
| Host `.padding(24)` bottom | 24 |
| Bottom `Color.clear` (`:49`) | 16 |
| **Total** | **c + 132** |

The code reserves `c + 136 + 32 = c + 168`. The 136 constant already contains the 32 pt camera strip, then `+ max(24, safeTop)` adds it again. The extra 32 to 36 pt is empty. `NotchInteractionHost` is `.frame(maxHeight: .infinity)` and the content is top-aligned, so the slack lands under the buttons, on top of the 24 pt padding and 16 pt clear strip. That gives about 70 to 76 pt of black under the last button.

**Fix (one line):** subtract the camera strip from the constant:
```swift
let contentHeight = interaction?.contentHeight.map { max(220, $0 + 100) } ?? (focused ? 460 : 520)
```
Verify the 100 against the real header height. A sturdier fix is to measure the host's total fitting height with `onGeometryChange` and drive the frame from that, so no constant needs to match the layout.

### B. Fixed content heights, not content-driven

`SessionPanelPresenter.swift:195`: the resting workspace is always 520 + 32 = 552 pt tall and 892 pt wide, whether it shows a greeting and one composer (about 250 pt of content) or a long thread. On the resting page the content column sits between two `Spacer`s (`NotchWorkspaceView.swift:300`, `:342`), so the bottom third of the window is empty near-black.

Onboarding has the same shape. The panel is 492 pt tall, leaving 444 pt of host area. `OnboardingNotchView` caps itself to `maxHeight: 430` and calls `.clipped()` (`App/Onboarding/OnboardingNotchView.swift:58-64`), top-aligned. The content is hard-clipped at 430 pt, which is a real clipping risk at large Dynamic Type sizes (`PerryTheme.Sizing.onboardingContentHeight = 430`, `PerryTheme.swift:73`).

**Fix:** size the panel from content for the resting page (about 300 to 340 pt) and let `onboardingContentHeight` match the panel's inner height (remove the `.clipped()` or raise the cap).

### C. Resize animation clips content

Height changes go through `refreshNotchLayout()` (`SessionPanelPresenter.swift:242-248`) via `DispatchQueue.main.async`, which calls `place()`. `place()` animates `panel.animator().setFrame` over 0.22 s (`:98-110`) while the SwiftUI content is laid out at the final size. The hosting view clips to the shrinking or growing window, so for about 0.2 s the bottom of the new content (for example the approve button) is cut off. The measure-then-resize order (`.task(id: contentHeight)` at `CompactConversationView.swift:67`) adds a visible two-step.

**Fix:** set the frame without animation when the height grows, or fade the content in after the frame settles.

### D. Black layer stack and top strip

- A 32 pt full-width `Color.black` strip sits on top of the content (`CompactConversationView.swift:29`). It is correct as notch clearance, but it is 892 pt wide where the hardware notch is about 180 to 200 pt wide. The rest is a plain black bar with nothing in it. HeyClicky puts its header controls in the menu-bar band beside the notch (screenshot: "Update app" pill left, ⓘ and ⚙ right, all at menu-bar height).
- A 16 pt strip of `#000` sits under the `#0C0D0E` workspace canvas (`:49` plus `:52`). With the 30 pt bottom radius (`NotchPresentation.swift:93`) the lower corners round away from the square canvas, producing a framed look.
- The panel also covers about ±446 pt of the menu bar (menu titles on the left, menu extras on the right) while open.

**Fix:** put the header controls (close, more) in the ears. Use one fill color (`canvas`) for the whole silhouette. Drop the `Color.clear.frame(height: 16)` and use content padding instead.

---

## 3. Hover to open

### 3.1 Pointer entry to fully open

| Step | Code | Time |
|---|---|---|
| Global and local `mouseMoved` monitors | `HomeController.swift:84-90` | per event |
| `inside = zones.contains(point) \|\| (previewing && previewFrame.contains(point))` | `:273` | |
| `intent.entered` → `.dwelling(deadline: now + 0.110)` | `HomeHoverIntent.swift:23, 40` | 0 |
| Single `Timer`, `tolerance = 0` | `HomeController.swift:340-347` | 110 ms |
| `deadlineReached` → `showPeek` → `onPreviewConversation` → `showPanel(activate: false)` | `:326-340`, `:436-440`, `AppSubsystems.swift:526` | +main-thread work |
| `showPanel`: `pinInvocationTargetIfNeeded`, `prepareConversation(probe.presentationTarget())` (frontmost-app lookup), `setConversationVisible(true)`, `notchStatus` update, `sessionPanel.show(frame:)` | `SessionPanelPresenter.swift:176-184` | not measured; no hover markers exist in `docs/evidence/lab` |
| Eyes `orderOut` instantly | `HomeController.swift:447` | same frame as show |
| Frame set at full size, no animation (`!wasVisible`, `place` falls to `setFrame`) | `SessionPanelPresenter.swift:36, 98-103` | 0 |
| `morph(growing: true)` | `:48, 52-96` | 340 ms |

The morph is a `CAShapeLayer` mask on the hosting layer. The path goes from a rounded rect at notch size (min 160 pt wide, `max(safeTop, 24)` tall, radius 10) to the full bounds (radius 10). `CABasicAnimation`, duration **0.34 s**, `CAMediaTimingFunction(0.2, 0.9, 0.25, 1)` (`:25, 73-77`). Reduce Motion and keyboard-initiated opens skip it (`:23, 53-56`).

**Total:** about 110 ms dwell + show latency + 340 ms, so roughly 450 ms plus an unmeasured main-thread gap.

### 3.2 Exit to closed

| Step | Code | Time |
|---|---|---|
| Pointer leaves zone and panel | `:278-280` | 0 |
| `exited` → `.tucking(deadline: now + 0.250)`. Re-entering during tuck returns to `.peekOpen`, no flicker. | `HomeHoverIntent.swift:24, 55, 42-43` | 250 ms |
| `hidePeek` → `endPreview` → `onEndPreview` | `HomeController.swift:300-304`, `AppSubsystems.swift:528-533` | |
| `hidePanel()` → `conversationVoice.cancel()` then `sessionPanel.hide()` | `SessionPanelPresenter.swift:278-288` | |
| `morph(growing: false)`: mask path to the notch rect, `duration 0.22`, curve (0.4, 0, 0.6, 1). Layer opacity fades 1→0 over 0.22 s, `easeIn`. | `:76-77, 85-94` | 220 ms |
| Eyes `orderFrontRegardless` immediately at hide start | `HomeController.swift:448-451` (called from `hideSurfaces`, `SessionPanelPresenter.swift:283-288`) | 0, while the panel is still collapsing |

**Total:** about 470 ms from exit to gone.

### 3.3 Comparison with best practice (about 100 to 200 ms hover intent, spring open 0.35 to 0.45 s, no flicker)

| Property | Perry | Verdict |
|---|---|---|
| Dwell | 110 ms | In range, at the low end. Fine for a small peek, too eager for an 892×552 window. The zone is 40 pt tall and about 260 pt wide, so any crossing of the notch area can trip it. |
| Open duration | 0.34 s | In range. |
| Open curve | cubic-bezier (0.2, 0.9, 0.25, 1), front-loaded | About 90% of the wipe is done in the first third of the duration, so it reads as a pop plus a long tail. It is not a spring: no overshoot, no settle. |
| What moves | Only the clip mask. The 892×552 SwiftUI view is already laid out, with no content fade, scale, or stagger. | The window looks revealed, not grown. This is the likely cause of "needs to be fine-tuned" and "lifeless". |
| Eyes handoff | Eyes vanish on frame 1, no cross-fade. | Abrupt. |
| Close delay | 250 ms | In range. A little more slack (300 to 350 ms) helps diagonal exits. |
| Close curve | 0.22 s ease with fade | Fine. |
| Re-entry flicker | Handled in the intent machine (`.tucking` → `.peekOpen`). While the panel is mid-collapse (`hiding == true`), `show` resets the mask and fade (`SessionPanelPresenter.swift:31-35`). | Good. |
| Eyes on close | Re-appear at collapse start while the panel is still on screen (both `.statusBar`) | Possible overlap or flicker. Unverified. |

Related hover defects:
- **Peek cannot close during a task.** `onEndPreview` returns `false` when `NotchPresentation.shared.current != nil` (`AppSubsystems.swift:529-530`). A running task registers an `.activity` entry (`AgentActivityStrip.swift:587-588`). `endPreview` has already set `previewing = false` (`HomeController.swift:300-303`), the intent machine is `.closed`, and `mouseDown` ignores clicks while `conversationVisible && !previewing` (`:289`). The panel stays open until Esc (`:306-314`, `AppSubsystems.swift:534-538`).
- **Hover-out cancels voice.** `onEndPreview` → `hidePanel()` → `conversationVoice.cancel()` (`SessionPanelPresenter.swift:279`).
- **Peek is not key.** `showPanel(activate: false)` does not make the panel key. Typing after a hover goes to the previous app until the user clicks.

---

## 4. Size comparison with HeyClicky

### 4.1 Scale used for the screenshot

The image is 2000×1293 px. That aspect ratio (1.547) matches a 16" MacBook Pro screen of 1728×1117 pt. That gives **1.157 px per pt**. As a check, the menu bar is about 38 px tall = 32.8 pt, close to a 32 pt notch inset.

The brief says "2x pixels". If that were literal (1000 pt wide), HeyClicky would be 255×145 pt. A 1000 pt wide Mac display does not exist, so I use 1.157. If you know the real display scale, rescale the numbers below.

### 4.2 Measured

| | Width | Height | Area |
|---|---|---|---|
| HeyClicky open (screenshot: x 745 to 1255 px, y 0 to about 290 px, read by eye) | about **441 pt** | about **250 pt** | about 110k pt² |
| Perry hover peek / workspace | **892 pt** (body 860) | **552 pt** | 492k pt² (body 475k) |
| Perry focused (onboarding) | 592 pt | 492 pt | 291k pt² |
| Perry approval (typical c = 160) | 592 pt | 328 pt | 194k pt² |

Perry is about 2.0× wider, 2.2× taller, and 4.5× the area of HeyClicky. Even the "focused" Perry is 1.3× wider and 2.0× taller.

HeyClicky's panel color is a near-black neutral, about `#131313` by eye. I could not sample pixels (no image library in this environment), so treat that value as an estimate.

### 4.3 What HeyClicky shows

- Header controls (Update pill, ⓘ, ⚙) sit in the menu-bar band beside the notch.
- Two agent rows: a 47 pt avatar, a 13 to 14 pt semibold name, a 12 pt gray one-line description, a hairline between rows.
- One bottom row: ghost "Apps +" chip, mint "Invite & Earn" pill, a round expand button.
- No sidebar, no text field, no greeting, no hints.

### 4.4 What makes Perry bigger (by contribution)

1. **Sidebar rail:** 210 + 1 pt (24% of width) showing search, five nav rows, a Perrys list, and a Recent list. Source: `NotchWorkspaceView.swift:21`.
2. **892 pt width, 552 pt height**, chosen for the workspace case and applied to the hover peek (`SessionPanelPresenter.swift:195-198`).
3. **Resting page content:** 40 pt mascot, 26 pt serif greeting, keycap hint line, a full composer, and a chip row (`NotchWorkspaceView.swift:302-337`), with `Spacer`s that expand to fill the height.
4. **Camera strip:** 32 pt full-width plus a 16 pt bottom strip (`CompactConversationView.swift:29, 49`).
5. **Outer padding stack:** 16 shoulder, 16 host padding, 24 interaction padding, 20 dialog padding, 32 content padding.
6. **Cards in the notch:** `NotchDialogView` and `AgentActivityStripView` each draw their own `surface` rounded rect inside the host.
7. **Type sizes:** 26 pt greeting, 18 pt wordmark, 15 pt composer text, `.title3` page titles. HeyClicky's body text is 12 to 14 pt.

---

## 5. Liveliness inventory

### 5.1 What exists

| Item | Where | State |
|---|---|---|
| Notch eyes blink: `scale.y` 1→0.12→1, 0.18 s, every 7 s fixed | `HomeController.swift:356-359, 404-412` | **Used**. Mechanical (no jitter). Off under Reduce Motion. |
| `PerryCharacter`: `TimelineView` rig with moods `resting, listening, thinking, speaking, working, celebrating, needsYou, sleeping` | `Packages/PerryOverlay/Sources/PerryOverlay/PerryCharacter.swift:1-27, 279-561` | **Used** by the overlay buddy (`CompanionFollower.swift:272`), `GhostCursor.swift:30`, `InkLayer.swift:300, 487`, `AgentActivityStrip.swift:253`, and `HomeOnboardingView.swift:156, 171`. |
| Character blink `blinkOpenness`: 3.9 s cycle with a hash jitter, 0.14 s, floor 0.3 | `PerryCharacter.swift:~345` | Only through `PerryCharacter` (the animated path). |
| Gaze, lean, stretch, hop, travel trail, mood blend 0.28 s, sleep after 45 s, celebrate hop 0.9 s | `PerryCharacter.swift` (`PerryCharacterRig`) | Same. |
| Voice-state chip (listening bars, thinking dots, working arc, done tick, needsYou "!", asleep "z") | `PerryCharacter.drawStatus` | Same. |
| Onboarding `NotchPeek`: mascot slides in with `spring(duration 0.55, bounce 0.35)` | `App/Onboarding/HelloGreetingView.swift:160-185` | Onboarding only. |
| Page transition opacity + 6 pt offset, `glide` spring | `NotchWorkspaceView.swift:35, 459-461` | Used. |
| Rail selection pill `matchedGeometryEffect`, row hover fade | `:406-413, 636-657` | Used. |
| Composer send/mic swap spring | `WorkspaceComponents.swift:82` | Used. |
| Notch status capsule fade | `NotchStatusController.swift:154-159` | Used. |

### 5.2 Not used or disabled in the notch

- **The notch workspace never uses the animated `PerryCharacter`.** It uses the static `PerryCharacterView(pose: PerryCharacterPose())`, which is a fixed `.open` face with no blink: rail logo (`NotchWorkspaceView.swift:84`), Perry rows (`:177`), welcome mascot (`:304`), `SessionPanelView.swift:93`, `WorkspaceEmptyState` (`WorkspaceComponents.swift:151`), `WhatsNewView.swift:17`, `GuideControlsWindow.swift:64`. The mascot is on screen but never blinks or reacts. This is the strongest cause of "lifeless" inside the open notch.
- **The notch eyes ignore all state.** They do not react to listening, thinking, speaking, working, approvals, or a task finishing, even though `PerryMood(voice:buddy:)` (`PerryCharacter.swift:11-26`) already maps those states.
- **No glance or squint** anywhere, and no pointer-tracking for the eyes.
- **Blink is disabled** for Reduce Motion (`HomeController.swift:405`). That is correct.
- `PerryTheme.Motion.settle` (0.42 s custom curve, `PerryTheme.swift:92`) is not used by the notch files audited.
- `WorkspaceVoiceStatus` uses a static `waveform` symbol (`NotchWorkspaceView.swift:589`) with no `symbolEffect` and no level meter, although `micLevel` exists in the rig.
- The open notch has no entrance choreography: the full window appears via mask only (§3).

---

## 6. Voice surface in the notch

### 6.1 State flow

`VoiceConversationController.State`: `idle, requestingPermission, listening, thinking, speaking, failed` (`App/VoiceConversationController.swift:16-23`).

Start: mic button in the composer (`WorkspaceComponents.swift:68-80`) → `conversationVoice.start()` (`NotchWorkspaceView.swift:321`, `HomeConversationView.swift:112-115`).

`presentConversationVoice` (`App/SessionPanelPresenter.swift:209-240`) reacts to every state change (`AppSubsystems.swift:292-294`):

| State | Notch behavior | Overlay behavior |
|---|---|---|
| `requestingPermission` | nothing (`:212-213`) | nothing |
| `listening` | **collapses the notch**: `dismissCurrent()`, `cancelNotchConfirmations()`, `hideSurfaces()` (`:214-221`) | overlay buddy `.listening` (`:215-218`) |
| `thinking` | stays collapsed | bubble "Working on your request" (`:222-225`) |
| `speaking` | stays collapsed | bubble "Speaking" (`:226-229`) |
| `idle` | stays collapsed | bubble "Answer ready" if an answer exists (`:230-233`) |
| `failed` | `showPanel(activate: false)` reopens the notch (`:234-238`) | buddy `.blocked` |

### 6.2 What the notch shows

`WorkspaceVoiceStatus` (`NotchWorkspaceView.swift:558-599`) renders only if the panel is visible:
- Listening: static `waveform` (accent) plus the partial transcript (or "Listening…") plus a `Stop` button (`:587-598`).
- Thinking: "Thinking…" plus `Stop`.
- Speaking: the answer text plus `Stop`.
- Failed: warning label plus `Dismiss` (`:574-583`).

Because `listening` collapses the notch, this row is visible only if the user hovers back to the notch (`showPeek`). Leaving the zone then runs `hidePanel()` → `conversationVoice.cancel()` and kills the turn.

### 6.3 Where "done talking" lives

- **The only wired "finish" control is in onboarding.** `FirstTalkBeat` shows a primary button whose title is `"I’m done"` while listening (`App/Home/HomeOnboardingView.swift:279-286`, button at `:227`, handler `talk()` at `:296-301` calls `voice.finishListening()`). Because `listening` collapses the notch, the user has to go back to the notch to reach it. This matches the complaint.
- **`finishListening()` has one call site outside the controller:** that onboarding `talk()` (`HomeOnboardingView.swift:299`). The controller also calls it from `armFinalize` (`VoiceConversationController.swift:143-151`).
- **The generic notch `Stop` button** (`NotchWorkspaceView.swift:594`) calls `voice.cancel()`, which discards the audio and the transcript. It is not "send now".
- **Automatic end exists but is narrow.** `finalizeDelay = 1.5` s is armed only from `handlePartial` (`:24-29`), so the 1.5 s timer starts after the last partial transcript. If no partial ever arrives, `silenceTimeout = 20` s (`:42, 153-161`) fails the turn with "I didn’t hear anything." Copy in onboarding says "I’ll answer when you pause" (`HomeOnboardingView.swift:~140`), so the pause path is meant to work. A long pause mid-sentence, or a recognizer that is slow to emit partials, produces either a cut-off or a 20 s wait.
- **The overlay buddy has no click-to-finish.** Overlay windows set `ignoresMouseEvents = true` (`Packages/PerryOverlay/Sources/PerryOverlay/OverlayHost.swift:44`). The hold-to-talk gesture (`TalkGesture`, `App/Talk/ModifierHoldMonitor.swift:11-16`) ends on key release, so that path has no "done" step.

**Fix (smallest):**
1. Make the composer mic a toggle: when `state == .listening`, tap calls `finishListening()`, and the icon becomes `stop.circle.fill` / `arrow.up` with a level meter.
2. Do not collapse the notch on `.listening` when it was opened from the notch. Keep the panel open and show the live transcript.
3. Change the row's `Stop` to `Send` (finish) with a separate small cancel.
4. Do not call `conversationVoice.cancel()` from `hidePanel()` for a hover-out (`SessionPanelPresenter.swift:279`).
5. Auto-finish on voice-activity end of speech as well as on partial-transcript silence, so the user never needs a button.

---

## 7. Ranked defects

Severity: **P0** breaks a stated complaint or a flow; **P1** large visible or functional problem; **P2** polish or risk.

| # | Sev | Where | Cause | Smallest fix |
|---|---|---|---|---|
| 1 | P0 | `AppSubsystems.swift:526` → `SessionPanelPresenter.swift:176-207` | Hover "peek" calls `showPanel(activate: false)`, which sizes the panel to the full 892×552 workspace. No peek size exists. | Add a peek size (about 440×220: recents list plus one composer row). Click expands to the workspace. Pass a `peek: Bool` to `notchPanelFrame()`. |
| 2 | P0 | `SessionPanelPresenter.swift:195, 198`; `CompactConversationView.swift:29, 49` | Camera inset counted twice for interaction panels (`+136` already includes it, then `+ safeTop`). About 32 to 36 pt of dead black under approvals, dialogs, and activity. | `$0 + 100` (verify header height) or drive the frame from the measured host height. |
| 3 | P0 | `AppSubsystems.swift:529-530`; `AgentActivityStrip.swift:587-588` | `onEndPreview` bails when `NotchPresentation.current != nil`. A running task registers an `.activity` entry, so a hover peek never closes (state is `.closed`, `previewing` is `false`, `mouseDown` returns at `HomeController.swift:289`). | Close the peek when the entry is not revealed (`showsInteraction == false`), or keep `previewing = true` until the panel is dismissed. |
| 4 | P0 | `SessionPanelPresenter.swift:214-221`; `NotchWorkspaceView.swift:594`; `HomeOnboardingView.swift:279-301` | Listening collapses the notch, and the only finish control is behind it (onboarding "I’m done"). Generic `Stop` cancels instead of sending. | See §6.3 fix list. |
| 5 | P1 | `HomeController.swift:384-398` | Eyes are 3.5×9 pt, sage `#9CCBB6`, right ear only, no glow, no left-ear counterpart. On a bright menu bar they are a tiny speck on a black patch. | Larger eyes (about 5×12 pt), centred on the notch edge or in both ears, brighter tint (or use `PerryCharacter`-style glyphs), subtle glow. |
| 6 | P1 | `HomeController.swift:356-359, 404-412` | Only a fixed 7 s blink. No glance, no reaction to voice or task state, no entry or exit animation. | Jittered blink (about 3 to 6 s random), occasional glance, mood-driven pose from `PerryMood(voice:buddy:)`. |
| 7 | P1 | `SessionPanelPresenter.swift:25, 73-77, 52-96` | Open is a front-loaded mask wipe over a fully laid-out view: no spring, no content fade or stagger, eyes vanish instantly. | Spring (response about 0.38, damping about 0.82) on the panel frame or a scale-from-notch transform; fade content in after about 40% of the animation; cross-fade the eyes out first. |
| 8 | P1 | `SessionPanelPresenter.swift:195`; `NotchWorkspaceView.swift:300, 342` | Fixed 520 pt content height regardless of page, with two expanding `Spacer`s. Resting page has an empty bottom third. | Size from content per page; resting about 300 to 340 pt. |
| 9 | P1 | `NotchWorkspaceView.swift:21` | 210 pt sidebar rail (24% width) on the default view. HeyClicky shows only agents and tasks. | Remove the rail from the default view. Use a compact segmented or icon row in the ears. |
| 10 | P1 | `SessionPanelPresenter.swift:278-281` via `AppSubsystems.swift:528-533` | `hidePanel()` calls `conversationVoice.cancel()`, so a hover-out kills an in-flight spoken turn. | Call `sessionPanel.hide()` directly for the preview-close path. |
| 11 | P1 | `NotchWorkspaceView.swift:84, 177, 304`; `WorkspaceComponents.swift:151` | Notch mascots are static poses, no blink or mood. Lifeless. | Replace with `PerryCharacter(mood:)` (already used elsewhere). |
| 12 | P1 | `OnboardingNotchView.swift:58-64`; `PerryTheme.swift:73` | Onboarding is hard-capped at 430 pt with `.clipped()`, inside a 444 pt area. Large Dynamic Type clips content. | Remove `.clipped()`, or compute the cap from the panel height. |
| 13 | P1 | `SessionPanelPresenter.swift:98-110`, `:242-248` | Frame animates 0.22 s after an async hop while content is already final-size. Bottom content is clipped mid-resize. | Apply height growth without animation, or fade content after the frame settles. |
| 14 | P2 | `PerryTheme.swift:7-14`; `CompactConversationView.swift:52`; `PerryTypes.swift:4` | Palette: `#000` vs `#0C0D0E` vs `#18191B`, two accents (`#9CCBB6` and `#34D399`), warm cream text on cool black, no material. | One canvas fill for the whole silhouette; one accent; pick warm or cool. |
| 15 | P2 | `NotchWorkspaceView.swift:99-131, 149`; `WorkspaceComponents.swift:56, 70` | Icons: default SF Symbols at mixed sizes and weights, mixed containers. | One icon style (size 13, weight `.medium`, one container shape), and tinted active states. |
| 16 | P2 | `NotchDialog.swift:123-125`; `CompactConversationView.swift:226` | Card inside host padding: 24 + 20 pt padding plus a `surface` fill inside a notch. Heavy. | Drop the card fill; use the host padding only. |
| 17 | P2 | `HomeController.swift:442-452` vs `SessionPanelPresenter.swift:283-288` | Eyes re-order front at collapse start while the panel is still on screen (same `.statusBar` level). | Delay `orderFrontRegardless` until the collapse completes. |
| 18 | P2 | `HomeHoverIntent.swift:23`; `HomeController.swift:229-231` | 110 ms dwell, 40 pt tall zone that extends 8 pt below the menu bar, for a 4.5× larger window. | Raise to about 150 ms for the big panel, or fix item 1 so the peek is small. |
| 19 | P2 | `SessionPanelPresenter.swift:176-184` | Peek panel is not key. Typing after a hover goes to the previous app. | Make the panel key on first key event or on pointer entry into the peek. |
| 20 | P2 | `CompactConversationView.swift:76-88`; `SessionPanelView.swift:39-44` | Legacy guide panel: a `ScrollView` inside the host, own `canvas` background, `minWidth 480`, system controls. Visually off-brand. | Re-skin to the workspace style or fold into the composer. |
| 21 | P2 | `NotchPresentation.swift:90-107` | Bottom radius 30 with the content flush to the silhouette edge (16 + 16). Square canvas corners meet a round bottom. | Inset content 12 to 16 pt from the silhouette edge, and round the canvas to match. |

---

## 8. Code to delete (or collapse)

| Item | Where | Why |
|---|---|---|
| `homeOpen` and `setHomeOpen(_:)` | `App/Home/HomeHoverIntent.swift:25-26, 37, 91-102` | Never called in `App/`. Only tests set it (`AppTests/HomeHoverIntentTests.swift:57, 65`). Delete with those tests. |
| `HomeView` wrapper | `App/Home/HomeView.swift:9-19` | Production uses `NotchWorkspaceView` directly (`CompactConversationView.swift:73, 90`). Only tests use it (`PaperOnboardingTests.swift:17-20`, `HomeRecoveryTests.swift:159`, listed at `SemanticTypographyTests.swift:20`). Retarget the tests, then delete. |
| `idealWidth: 860, idealHeight: 500` | `NotchWorkspaceView.swift:69-70` | Hosting view has `sizingOptions = []`, so ideal sizes never apply at runtime. Keep the minimums if tests depend on them. |
| `Color.clear.frame(height: 16)` bottom spacer | `CompactConversationView.swift:49` | Part of the dead bar. Replace with content padding. |
| Duplicate black constants | `PerryTheme.Colors.cameraCrown` (`PerryTheme.swift:14`), `Color.black` (`CompactConversationView.swift:29, 52`), `NSColor.black` (`HomeController.swift:380, 429`) | Collapse into one token. |
| Second accent | `PerryOverlayTheme.Colors.accent` (`PerryTypes.swift:4`) | Keep one accent, update `NotchStatusController.swift:192`. |
| `PerryTheme.Sizing.panelWidth/panelHeight` as the panel's initial rect | `SessionPanelPresenter.swift:144`, `PerryTheme.swift:70-71` | Overwritten by `place()` before first display. `panelWidth` is still used by `SessionPanelView.swift:45`. |
| `PerryTheme.Motion.settle` | `PerryTheme.swift:92` | No use in the audited notch files (confirm repo-wide before deleting). |
| `WorkspaceVoiceStatus` listening branch as written | `NotchWorkspaceView.swift:567-568` | Reached only after the user hovers back to a collapsed notch. Rewrite as part of the voice fix. |
| Legacy guide panel path | `CompactConversationView.swift:76-88` plus `SessionPanelView.swift` | Candidate if "Do" mode moves into the composer. Not dead today (`showsGuide` is set from `consumePrompt`, `:99-110`). |
| Static mascot call sites | `NotchWorkspaceView.swift:84, 177, 304` | Replace with the animated `PerryCharacter`, not delete the mascot. |

---

## 9. Open questions I could not answer from code

- Real `safeAreaInsets.top` and notch width on the user's Mac (assumed 32 pt).
- Measured hover-to-visible latency (`home.hover_start` to `panel.visible`). No markers exist in `docs/evidence/lab`.
- Whether the right-ear black patch covers menu extras on the user's menu bar (depends on window ordering at `.statusBar` level).
- Exact header height in `NotchInteractionHost` (estimated 20 pt), needed for the `+100` constant in defect 2.
- Exact HeyClicky pixel colors and dimensions (read by eye from one screenshot).
