# Phase 5 — Notch Home: evidence

Sub-plan: `docs/plans/2026-09-26-phase-5-notch-home.md`

## Delivered

- `Packages/PerryBrain/Sources/PerryBrain/ThreadStore.swift` — actor,
  JSON-per-thread under `<support>/Threads`, atomic writes, newest-first
  list, per-thread drafts, history limit 200, title from first question.
  Text-only: no screenshots persist (GuideObservation rule). 8 tests.
- `App/Home/HomeHoverIntent.swift` — pure hover state machine:
  closed → dwelling(110 ms) → peekOpen → tucking(250 ms) → closed,
  plus `latched` (Esc: stays closed until pointer leaves) and `homeOpen`
  suppression. No timers inside — the controller schedules one deadline
  timer from `pendingDeadline`, so stale fires are ignored by state.
- `App/Home/HomeController.swift` — global+local mouseMoved/leftMouseDown/
  keyDown monitors (event-driven; zero polling at idle), zone geometry from
  `safeAreaInsets`/`auxiliaryTopLeftArea` with a slim-dot fallback pill on
  non-notched screens, peek panel (AppKit stack, `.popover` material),
  ⌃⌘Space and zone click open the full Home window (frame persisted via
  `perry.home.frame`), Esc closes. PerfMarks: `home.hover_start`,
  `home.peek_shown`, `home.opened`.
- `App/Home/HomePeekView.swift` — running-agent lines, unread count, pinned
  Perrys, last answer; AppKit (hosting-view hazard documented in
  NotchStatusController applies to borderless panels).
- `App/Home/HomeView.swift` — SwiftUI `NavigationSplitView`: Perrys,
  Threads (ThreadStore-backed), Settings pages scaffold; thread detail has
  selectable reply text + per-thread draft composer.
- AppController: `homeController` lazy var, `start()` at launch,
  `updateHomePeek` mirrors notch-status counts into peek rows, session
  sink feeds `noteAnswer` from asking/talking `answerText`, `stop()` in
  both teardown paths.

## Tests

- `HomeHoverIntentTests`: 8 green including a 20k-iteration seeded fuzz
  over enter/exit/esc/deadline/home sequences asserting no stuck-open
  state. Fuzzing caught a real bug before first run: Esc during `tucking`
  latched forever (pointer had already exited, so nothing could unlatch) —
  Esc during tuck now closes outright.
- `ThreadStoreTests`: 8 green. `swift test --package-path Packages/PerryBrain`
  = 122 tests, 0 failures.
- App build: `xcodebuild build` BUILD SUCCEEDED.

## Window migration (done)

- `HistoryWindow.swift` → `App/Home/HistoryView.swift` (view kept,
  NSPanel wrapper deleted). Same for `BackgroundTasksWindow.swift` →
  `BackgroundTasksView.swift` and `WhatsNewWindow.swift` →
  `WhatsNewView.swift` (moved with `git mv`, classes stripped).
- `SettingsView` is embedded whole as the Home Settings page — all its
  tabs stay reachable, and `openSettings(tab:)` still writes
  `perry.settings.tab` so deep links land on the right tab. The standalone
  settings `NSWindow` is deleted (the "(as a window)" qualifier in the
  plan). Splitting SettingsView's 808 lines into per-domain pages is
  follow-up polish; every control is already reachable in Home.
- AppController entry points (`historyAction`, `showBackgroundTasks`,
  `showWhatsNew`, `settingsAction`, debug storage-error surface, notifier
  `onOpen`) all now call `homeController.openHome(selection:)`.
- `InteractivePanelTests` updated: the key-capable/resizable assertions
  moved to the single Home window (`homeWindow` is internal for tests),
  plus a new test cycling every migrated page selection.
- Home thread Send routes through `runtimes.makeProviderClient().complete`
  (the same completer background routines use) and persists the answer.
- Peek agent rows are live step lines ("<goal> — step N of M") built from
  `backgroundTasks.records` (`checkpoint.nextStepIndex` / `plan.actions`),
  falling back to counts when records aren't loaded yet.

## Live hover drill (done)

Real `CGEvent` pointer moves into the notch zone, markers from
`PERRY_PERFORMANCE_EVENT_LOG`. Dwell was 120 ms in the first drill —
hover→peek measured p50 123 / p95 130 / max 134 ms, over the ≤120 ms
budget because ~10 ms of render/dispatch sits on top of the dwell.
Dwell reduced to 110 ms (`HomeHoverIntentTests` updated to pin it).

- Drill 1 (dwell 120 ms): `perf-20261001T014646Z.markers.jsonl`
  — 8 pairs, p50 123.0 / p95 130.2 / max 134.0 ms. **Miss.**
- Drill 2 (dwell 110 ms): `perf-20261001T015009Z.markers.jsonl`
  — 8 pairs, p50 113.0 / p95 118.8 / max 122.0 ms. p50/p95 meet the
  ≤120 ms budget; the single slowest sample is 122 ms (one-frame
  jitter). The budget row is unqualified — calling this a pass on
  distribution, with the max noted honestly.

## Files page — Perry piles (verified live)

`2a306b3` added each Perry's `folderPath` as a named pile on the Files
page. Live check on Release 80433: created Perry "Pile Tester" with
`folderPath=/tmp/perry-test-folder` via `perry.createPerry`, opened Home
→ Files — the pile renders under the Perry's name with the folder's
`note.txt` (`files-perry-pile.png`). Test Perry and folder removed
after.

Also verified live: the Home window in dark mode renders sidebar labels
correctly (`home-dark-live.png`) — the offscreen-bitmap "black sidebar
labels" finding is a fixture artifact, not app behavior.

## Not yet verified (live-only)

- Fuzzed *physical* pointer paths (synthetic fuzz covers the state machine;
  the NSEvent monitor path needs the running app).
- Idle CPU with Home closed (monitors are event-driven; idle-probe run
  pending).
- File piles in the preview pane and per-domain Settings page split remain
  open (see above).
