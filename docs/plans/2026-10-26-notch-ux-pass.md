# Notch UX pass: past the preview

**Goal:** the expanded notch reads as simple as the new preview. Every control responds to the first click. No control sits where the menu bar can take the click.

## What is wrong now (from renders and code, 2026-10-26)

1. Dead controls. In the task view, Back and Collapse sit in the crown strip (`CompactConversationView.crown`, inside `cameraInset`). That strip lies beside the hardware notch, in the menu bar band. The old preview put "…" and × there too. The likely cause is that the menu bar band takes the click. The "…" in the workspace is an `NSPopUpButton` (`NotchCommandsMenu`) in a non-activating panel. It can ignore the first click while the panel is not key.
2. The expanded workspace is still a dense desktop app inside the notch:
   - a permanent 150 pt sidebar with 5 links, Helpers, Apps and a gear;
   - a header with "…" and ×;
   - a composer with three chips (mode, Window, brain).
   The preview is calm, and one click lands in all of this.
3. The rail icons (`checklist`, `repeat`, `folder`, `lightbulb`, `clock.arrow.circlepath`) are thin grey outlines with mixed visual weight. Suggestion and helper rows have no identity.
4. The task view stacks a progress bar, three chips, a divider, a hint and a "Type instead" disclosure. That is five rows for one job.

## Plan

### 0. Land what is already done (no design change)
- Run the full suite on the mini, then commit each change on its own:
  - the preview redesign;
  - the listening tile;
  - mic: no voice processing in dictation;
  - hotkey: re-arm the event tap after the grant;
  - the shorter reply prompt.
- Install on the MacBook so the owner can test the mic and the hotkey. The mini has no microphone, so the mic fix is backed by log evidence only.

### 1. One rule for the crown
- Likely cause: the panel opens without becoming key (`showPeek` passes `activate: false`), and nothing in it accepts the first mouse. The first click only focuses the panel. HeyClicky keeps working buttons in the band beside the notch, so the band itself is not the rule.
- Fix: a hosting view that returns true from `acceptsFirstMouse`. Replace the `NSPopUpButton` with a SwiftUI `Menu`.
- Keep the crown free of controls anyway when the panel sits under a hardware notch, until a click test on the MacBook proves the band works.
- Add a test that asserts the hit areas of every notch control start below `cameraInset`, using the render geometry.

### 2. Two levels, like HeyClicky and the Dynamic Island
Reference: the owner's HeyClicky screenshots and Apple's Live Activities guidance (compact stays glanceable; expanded keeps the same layout, only with more detail).

- **Level 1: the notch card.** This is the new preview, grown into the home.
  - A list of what matters: needs-you, working, recent and helpers, as face rows.
  - Tapping a conversation row opens it inside the same card: messages plus a follow-up line. The card grows in place.
  - Footer: "Hold ⌃⌥ to talk", then three icon buttons: Apps, Settings, Expand.
  - No sidebar and no chips.
- **Level 2: the full panel.** Expand opens a roomy panel under the notch, about 860×560, like HeyClicky's Settings.
  - This is where the sidebar belongs: Tasks, Routines, Files, Suggestions, History, Helpers, Apps and Settings.
  - It has a Back control and a close control.
  - The space fixes the density. The current 524 pt workspace crams a desktop layout into the notch.
- The composer in both levels is one text line with a mic. The brain chip moves to Settings > Brain. Window and mode become one "+" menu.

### 3. Task view
- Use the face tile, title and live status line from the preview row, with a thin progress bar under it.
- Controls go on one row: Stop as the primary action, and Pause and Take over as icon buttons with tooltips.
- The footer hint line matches the preview: "Hold ⌃⌥ to steer · Type" (Type is a link).

### 4. Icons
- Use one icon family, filled SF Symbols at the same weight. Each place gets a small tinted tile like the preview faces.
- Suggestions use the source app's real icon (`BrandMark`). The fallback is a tinted lightbulb tile.
- Helpers keep their coloured Perry faces everywhere: the preview, home and the editor.

### 5. Drag-me-in helper docks inside System Settings
- Today `SettingsWindowTracker.dockFrame` puts a fixed-size card 10 pt below the Settings window, and only falls back inside it. It guesses the list column at `minX + 252`. On a large or low window the card floats somewhere unrelated.
- Match HeyClicky: the card always sits inside the Settings window, over the bottom of the app list. It takes the list column's width minus 16 pt on each side and sits 16 pt above the window's bottom edge.
- It follows the window as it moves or resizes. The tracker already polls, and the card re-docks on every change. It hides while Settings is minimised or another app covers it.
- The list column is measured from the window width with the sidebar ratio of macOS 27 Settings. Accessibility may not be granted yet, so AX cannot be used for this.
- Copy and layout: an arrow mark, then "I'm Perry. Drag me into the list above.", with the draggable Perry row below it. This is the same two-line structure as the reference.
- Tests: unit tests on `dockFrame` for small, large and off-screen-edge windows. A render of the card.

### 6. Verify
- Render tests for home (empty, busy, helpers), each secondary page, the task view and the listening view. Inspect every frame.
- A synthesized-click drill on the mini with `cua-driver` for every control: Back, Collapse, the menu, ×, Stop and the footer icons. The mini has no notch, so the owner confirms the notch band on the MacBook.
- Full suite green. Evidence goes to `docs/evidence/first-impressions/9.3-notch/`.
