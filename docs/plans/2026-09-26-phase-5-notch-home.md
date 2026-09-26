# Phase 5 — Notch Home

Master plan §7 Phase 5 + §4.7. Perry lives in the notch: a resting pill,
hover-peek, and a full Home with threads + settings pages.

## Surveyed current state

- `App/NotchStatusController.swift` (166 ln) — a **status-only** pill below
  the notch: AppKit stack view (recording dot, task count, approvals),
  `ignoresMouseEvents = true`, `.statusBar` level, `canJoinAllSpaces +
  stationary`, hidden unless recording/tasks AND a notched screen
  (`safeAreaInsets.top > 0`). Becomes the resting/peek host: keep the
  AppKit pill (hosting-view sizing hazard is documented in its header),
  add a hit-testable peek panel below it.
- Windows to fold in: `HistoryWindow` (265 ln), `BackgroundTasksWindow`
  (359), `SettingsView` (808, as window), `WhatsNewWindow` (98 → Home card).
- `SessionController` is the interaction state machine; Home must not
  duplicate it — threads persist *content* (turns, answers, marks), state
  stays in SessionController.
- `SpatialConversation` (App/Talk/TalkContext.swift) is per-window, 10-min
  TTL, in-memory only. `ThreadStore` is the persistent counterpart for Home
  threads — JSON under `~/Library/Application Support/Perry/Threads/` —
  and must NOT store screenshots (GuideObservation rule).
- No notch-hover infrastructure exists; `NotchStatusController` is the
  first hit-testable thing near the notch.

## Interfaces (settled)

- `App/Home/HomeController.swift` — owns the resting pill (evolved
  NotchStatusController), peek panel, and full Home window. Geometry:
  `NSScreen.safeAreaInsets.top`/`auxiliaryTopLeftArea` for the notch pill;
  centered pill fallback on non-notched Macs (§4.7).
- Hover intent: pointer enters pill zone → 120 ms dwell → peek opens;
  pointer exits → 250 ms tuck; Esc closes and stays closed until pointer
  leaves the zone (no reopen flicker).
- `HomePeekView` — running agents w/ live step line, unread badge, pinned
  Perrys, last answer preview. Click-through opens full Home.
- `HomeView` — sidebar (threads + Perrys + settings), thread view
  (selectable text, per-thread draft composer), preview pane.
- `App/Home/HomeSettings/*` — settings as plain pages inside Home (Brain /
  Voice / Shortcuts / Apps & connectors / Memory & privacy / Perrys /
  About), reusing SettingsView's sections' content, not the window shell.
- `Packages/PerryBrain/.../ThreadStore.swift` — Codable threads
  (id, title, createdAt, turns[{question, answer, refs}], perryID?,
  draft), JSON per thread, capped history. Pure + testable.

## Order of work

1. ThreadStore (pure, PerryBrain, tests).
2. HomeController: resting pill evolve + peek panel (AppKit host like the
   existing pill; hit-testing ON for the peek zone only — the pill itself
   stays click-through except its own frame).
3. HomePeekView content wired to real sources (background task count,
   last Talk/Ask answer, pinned Perrys placeholder until Phase 9).
4. HomeView + settings migration; delete the four windows after migration.
5. Fuzzed pointer-path drill + latency marks (`home.hover_to_peek` etc.).

## Acceptance (from plan)

- Hover→peek, peek→open ≤120 ms; no stuck-open under fuzzed pointer paths;
  idle CPU unchanged with Home closed (pill already pass); all old window
  functions reachable in Home.
- PerfMarks: `home.hover_start`, `home.peek_shown`, `home.opened` for
  latency-report pairing.

## Open decisions

- Peek is a `nonactivatingPanel` below the pill (doesn't steal focus;
  click in peek area activates like Spotlight behaviors).
- On no-notch Macs the pill centers at the top edge of the main screen —
  same hit model.
- Pop-out window: Home can detach to a regular NSWindow remembering its
  frame (`perry.home.frame` defaults key).
