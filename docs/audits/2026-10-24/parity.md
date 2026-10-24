# Perry vs HeyClicky (Aug–Oct 2026): parity audit

Audited 2026-10-24. Read-only: no builds, no tests, no edits. Working tree as-is on `codex/living-ink-redesign` (156 files modified vs HEAD, notch redesign uncommitted).
HeyClicky source: heyclicky.com/changelog (fetched; summarized by the fetch tool, not verbatim).
Legend: **verified** = I read the code or file cited. **inferred** = deduced from absence in grep or from docs.
Rule applied: "unit-tested only" is not "has". `features.json` has 83 features: 3 live-tested, 47 unit-tested, 13 wired, 20 absent. Zero release-proven.

## Bottom line on the user's claims

| Claim | Verdict |
|---|---|
| 2D drawing on screen | **Has (2D only), live proof missing.** Model-driven and element-grounded. Registry status is `wired` / `unit-tested`. |
| 3D drawing | **Absent.** Not a gap in polish; no code. |
| Top-tier computer use (Cua) | **Partial.** Strong safety rails and a sound background-click design. Not proven live for any agent-driven task. Post-action verification is missing on the path that serves open-ended work. |
| Drive-your-Mac mode | **Partial / different product.** Agent controls any allow-listed app, in the background, one window at a time. No takeover mode that moves the real pointer. |
| Home | **Has, but redesigned away from HeyClicky's Home.** Notch-only workspace; not resizable; not a window. |
| Routines | **Has two separate systems.** Both unit-tested only. One live scheduler drill exists. |
| "Lacks only Clickys" | **Wrong.** Perry already has a named persistent-agent concept ("Perrys") with job, thread, folder, schedule, memory file, per-Perry approvals. See §Clickys. The gap is polish, UI, and live proof, not the concept. |

## Surprises (surfaced, not worked around)

1. **Open-ended Do no longer uses the typed pipeline.** `ForegroundTaskController.swift:51` comment: "typed-plan supervisor remains for routine replay only". `executePreparedPlan` has exactly one caller: `startRoutine` (`:385`). So `CompositeActionVerifier`, `TypedActionRouter`, the rehearsal card with numbered marks, and the 5-second cancel window apply **only to Watch & Learn replay**. Fresh Do goals, background tasks and scheduled Perrys run `AgentLoop` with `ui.*` tools (`App/Tools/UITools.swift`) and no verifier.
2. **`docs/capabilities.md:41-42` is stale.** It says "Plans are typed and rehearsed before execution". True only for routine replay. `features.json` `do.rehearsal` cites `ForegroundTaskController` but inherits the same limit.
3. **Two routine systems.** (a) `LearnedRoutine` from Watch & Learn, replayed through the typed path. (b) `Perry.schedule` jobs run as unattended agent turns. They share a name in the UI ("Routines") but not code.
4. **The Perrys concept and its tests are not in `features.json`.** No feature id covers `perry.createPerry`, `PerryStore`, or `PerrySchedulerController`. The registry understates what exists.
5. `docs/heyclicky-feature-audit.md:174` lists "notch stack" and "widgets" as rejected, and PRD §5 says "Notch-only features" are out of scope. `progress.md:9` now says the notch-only contract applies. The product contradicts its own PRD §5 line.

---

## Feature-by-feature

### v1.1.1: 2D and 3D drawings

**2D: HAS (partial evidence).** Verified.
- Shapes the model can draw: `point` (inked dot plus leader), `ring` (ellipse, 8 pt padding), `arrow` (36 pt shaft ending below the element, pointing up, fixed geometry), `underline`, `caption` (identical to `ring` with a label, `TalkSession.swift` draw switch), `path` (freehand polyline, agent tool only), `clear`. Source: `Packages/PerryBrain/.../Talk/InlineMarkupParser.swift:3-6`, `Packages/PerryOverlay/.../GuidanceModels.swift:74-79,200-300`, `App/Tools/DrawTools.swift`.
- Overlay primitives: `scribble`, `rectangle`, `ellipse` only. `rectangle` exists in the model but no draw verb produces it for the model (ring is always an ellipse).
- Model-driven: yes. Inline `⟦ring e12 "label"⟧` tags in the reply stream, parsed live. Also tools on the `talk`/`guide`/`agent` surfaces (`ToolGate.drawTools`).
- Grounded: yes for tags. Element ids must be in the per-turn `ElementIndex`; unknown ids are dropped and the label stays as text (`InlineMarkupParser.resolveTag`). Rects come from AX frames converted with `AXCoordinateConverter`. A reanchor timer keeps marks glued to moved windows (`TalkSession.swift` `startReanchor`). Ink colour adapts to luminance under the mark.
- **Not grounded:** `path` and `x/y` arguments in draw tools take raw screen points from the model.
- Cannot draw: free text labels without a target element, boxes, multi-part diagrams, images, "photo cards", draggable objects.
- Evidence status: `guide.annotations` = **wired** ("no live visual-rendering test is recorded"). `talk.ink` = **unit-tested** (`InlineMarkupParserTests.testValidRingEmitsLabelAndCommand`, `GuidanceModelTests.scribbleRequiresAtLeastTwoPointsAndClampsPoints`). `guide.click-advance` = live-tested (see below). Offscreen render tests exist (`NotchSurfaceRenderTests`); `docs/evidence/lab/*.png` show overlay captures. No registry live-run artifact for ink.
- Done would need: a live Talk-to-ink run bound to a parsed artifact; a text-label verb and a box verb; ungrounded `path` either grounded or capped to the target window; decision on whether "drawing" must match HeyClicky's richer cards.

**3D / photo cards: ABSENT.** Verified. `grep -ri "3d|scenekit|realitykit|sphere|cube|metal"` over `Packages/PerryOverlay/Sources` returns nothing. The only Metal file is `App/Onboarding/HelloInk.metal` (onboarding shader). Done would need: a 3D scene layer (SceneKit/RealityKit or Metal) in a click-through overlay, a model-facing schema, asset sourcing, and a safe loader. Large; no plan in `docs/plans` (inferred from grep of plan titles).

### v1.1.1: Windows version, Chrome extension, captions, jobs

- **Windows: ABSENT, rejected.** PRD §5 and `features.json` (no entry). Verified.
- **Chrome extension / agent in signed-in browser: ABSENT.** Verified. App exposes only `browser.read` (`App/Tools/BrowserTools.swift`). `CuaCapabilityManifest.toolAllowList` allow-lists `browser_click`, `browser_navigate`, `browser_type`, etc. for the driver, but no code in `App/` or `Packages/*/Sources` calls them (grep over `browser_click|browser_navigate` found only the manifest). Done: expose those as `browser.*` act tools with their own tiers, or ship an extension.
- **Optional captions: HAS, narrower.** `CaptionLayer`, `CaptionPlacer`, Settings → Voice → Captions with opacity slider. Unit-tested placement (`InkStrokeTests` caption cases). No live run recorded. Verified.
- **Notch with Home, chat, Settings: PARTIAL.** See Home below.
- **Long tasks as followable jobs: HAS (unit-tested).** `BackgroundTaskController` (max 3 concurrent, `:57`), Tasks page, completion notifications (`background.completion-notifications` unit-tested). `do.concurrent-background-agents` limitation: "Production Cua sessions still share one worker; independent progress and process-level cancellation are not verified." Verified.
- **Routines by asking: PARTIAL.** `perry.createPerry` + `perry.schedule` are agent tools, so "run this every morning" works if the model calls them. No UI to create or edit a schedule (grep of `App/` for schedule UI found none). Inferred from grep.

### v1.1.1: "drive-your-Mac" mode

**PARTIAL; not the same product.** Verified.
- Perry's computer use is deliberately **background and window-scoped**: every `ui.*` call passes `pid`, `window_id`, `session`, `delivery_mode: "background"` (`CuaDriverClient.swift:681,715,1052-1072`). The code comment at `UITools.swift:6-7` states the real pointer never moves and focus is never stolen. No `CGEventPost` / `CGWarpMouse` in `App/` or package sources.
- Multi-app: yes in a limited sense. The agent can `app.launch` (orange tier) and `screen.observe` with a `bundleID`, so one run can hop between apps. The manifest allows ~190 installed apps minus the TrustGuard block list (`docs/evidence/phase-6/reach.md`: 193 entries).
- "Foreground" naming is misleading: `ForegroundTaskController` is "the Do flow the user is watching", not a pointer-moving mode. A `foreground` worker scope exists (`CuaWorkerService.swift:6`), capacity 1, but actions are still background-delivered.
- Whole-Mac takeover (move the real mouse, type into whichever app is focused, drive apps whose AX tree is empty): absent. Pixel-coordinate clicks exist but are scoped to a window id.
- Handoff: `takeOver()` pauses at a step boundary and hands the user control (`ForegroundTaskController.swift:893`). Continue steers the model to re-observe. Unit-tested (`do.shared-control`).
- Done would need: decide whether a pointer-moving mode is wanted at all. HeyClicky's v1.0.52 "background operation without a floating cursor" and v1.1.1 "drive" suggest they have both. For Perry: a per-conversation approval for it, a tinted real-cursor mode via `delivery_mode: foreground`, and a live drill. The driver already supports modes; Perry hard-codes `background`.

### v1.0.53: Multiple accounts per app

**ABSENT.** Verified by structure. `RemoteIntegrationDefinition` is keyed by provider id (`notion`, `slack`, `linear`, `google-workspace`, `RemoteIntegrations.swift:286-297`); one `CredentialReference(service, account)` per provider. `IntegrationRow` has no account label. No voice selection of an account. `integrations.composio-connectors` = unit-tested, limitation "no live provider round trip". Done: account list per provider in the Keychain, label, default account, and an `account` argument on `integrations.read/write`, plus tests that a write cannot cross accounts.

### v1.0.53: More dependable computer use

**PARTIAL.** Verified.
- What exists: driver respawn on wedge (`2c4a98a`), 6 s read timeout vs 15 s mutation timeout (`CuaDriverClient.swift:436-443`), zombie reaping (`1091ead`), session windows kept across respawns, stale-target clearing on failed retarget (`testFailedRetargetRetiresPreviousWindowBeforeAnotherAction`), late response never replays an action (`testLateResponseDoesNotReplayAction`), pre-cancel never starts the driver (`testPreCancelledActionDoesNotStartDriver`), window must exist or action fails (`testWindowTitleMustExistInsteadOfSelectingFallback`).
- **Fails closed:** unavailable driver, missing permission, `noTargetWindow`, `targetMismatch` (window changed since plan), `protectedTarget` (TrustGuard: password managers etc.), unknown element cannot become an untargeted key action, schema validation rejects unknown keys, malformed actions never reach the wire, red tier always asks, unattended runs deny anything without a stored grant, zero-tool "fabricated transcript" answers fail instead of completing (`docs/evidence/phase-9a/scheduled-routine.md`).
- **Verify-after-act:**
  - Typed/replay path: `CompositeActionVerifier` re-captures the window. `elementValue` checks typed text appears in AX. `visualChange` compares screenshot SHA256 to baseline. Any click without a postcondition returns `.unverified("no observable postcondition")`. Verified.
  - Agent path (all open-ended work): **no verifier.** `ui.click` returns the driver's message text. `type_text` alone has driver confirmation (`actionWasVerified`, `CuaDriverClient.swift:719`). Everything else relies on the model calling `screen.observe` again; `AgentPrompt.swift:36` says "Observe before you act" (before, not after). Budget 60 tool calls / 20 min (`AgentLoop.swift:18-24`).
- **Retries:** none automatic for mutations (by design). Reads retry on a respawned driver. User-triggered Retry exists in the activity strip.
- **Live evidence:** `do.computer-use` = **unit-tested**; limitations: "no live app task is recorded", "no last successful run". `CuaLiveTests` are capture-only, skip unless `PERRY_LIVE_CUA=1`, and the last recorded runs (2026-08-31) failed at the TCC permission probe (`docs/release-readiness/cua-live-fixtures.md`). The only live-tested driver evidence is `guide.click-advance` (20 runs, 75 clicks, 0 misses, Preview, p50 1148 ms, p95 13800 ms, rev `b5265ea`, `runs/guide-click-advance-2026-10-14.json`). That is the guide drill, not an agent `ui.*` task. `scripts/lab/routine-drill.sh` exists for a Watch & Learn replay; I found no recorded result for it.
- Done would need: a live drill per `ui.*` verb through the agent loop (TextEdit fixture is enough), a post-action observe-and-assert step or driver `verify_state` use (it is in the allow-list, unused in `App/`), a recorded `runs/*.json` for `do.computer-use`, and the p95 tail (13.8 s) understood.

### v1.0.53: Hold-to-talk follow-ups on agent cards

**PARTIAL.** Verified for foreground; inferred for background.
- A dictation hold that begins while a foreground task runs steers it (`CommandRouter.route(commandText:voiceTaskScope:)`, `CommandRouter.swift:35-94`), scoped to the task that was active when the hold began. Unit-tested.
- Steering lands at the next step boundary (`do.shared-control` limitation). 
- Background task cards: typed follow-up through Home conversation composer. I found no per-card hold-to-talk binding (grep of `BackgroundTasksView` / `NotchWorkspaceView` for steer: no hits). Inferred.

### v1.0.52: Smaller notch with hover peek

**PARTIAL, then replaced.** Verified.
- Hover intent exists (`HomeHoverIntent`, `testDwellThenPeek`); live drill p50 113 ms vs 120 ms budget (`features.json appearance.notch-home`).
- `HomePeekView.swift` is deleted in the staged tree. The redesign opens a full notch workspace instead (`NotchPresentation.swift`, width 592 focused / 892 expanded, `SessionPanelPresenter.swift:145`). So the "compact peek with recent files" is gone; the Files page replaces it.
- Referral program: ABSENT, and conflicts with PRD §5 (no cloud accounts or billing). Don't chase.

### v1.0.51: Resizable Home, one-card suggestions, several Clickys at once

- **Resizable Home: ABSENT.** Notch panel has two fixed widths. Perry's PRD/`progress.md` direction is "no Home window". Verified.
- **One-card-at-a-time suggestions: PARTIAL.** `SuggestionRules.maxCards = 3`, ranked list, backoff after ignored days, quiet on call/screenshare/Focus (`SuggestionEngine.swift`). UI is a list with a dimmed example (`HomeView.swift:21-110`), not a carousel. Suggestions are opt-in and read-only research. `do.proactive-suggestions` unit-tested; live acceptance pending.
- **Create several at once:** one tool call creates one Perry (`PerryTools.swift:59`). A model can call it several times in one turn; no test or UI for batch. Inferred.
- **Routines wait for Mac wake and internet: HAS (unit-tested).** `RoutineDecisions.shouldRun(isAwake:hasNetwork:)`, plus catch-up of one missed slot. `PerrysCoreTests.testNoRunWhenAsleepOrOffline`, `testMissedSlotCatchesUpOnce`.

### v1.0.50: Routines pause after three failures; drafts kept across views

- **Pause after three failures: HAS in logic, unit-tested, with one live observation.** `RoutineDecisions.maxConsecutiveFailures = 3`, `record(...)` sets `paused` (`PerryStore.swift`). `testThreeFailuresPause`, `PhaseNineControllerTests.testFailedRunIncrementsConsecutiveFailures`. Live: `phase-9a/scheduled-routine.md` shows `consecutiveFailures: 2` on a real record after two failed runs (never reached 3 live).
- **No UI shows paused state or offers resume.** grep for `.paused`/`consecutiveFailures` in `App/` outside the scheduler finds nothing user-facing. A paused Perry silently stops. Inferred from grep; verify by running.
- **Drafts kept across views: PARTIAL.** Requests not saved are recovered ("Requests not saved", `HomeController.swift`), `restoreWaitingInput`, composer drafts in `homeModel.newConversationDraft`. Not audited per view.

### v1.0.49: Introducing Clickys (named persistent agents, own memory, new Home, routines)

See next section.

### v1.0.48: Walkthroughs up to 15 steps; "Always approve"

- **Walkthrough length: HAS, exceeds.** `GuideSessionCoordinator.swift:937` starts with `maximumSteps: 25`. The engine plans one step at a time from the changed UI, bounded by `GuideEngine.maximumSteps` (`GuideEngine.swift:388`: "The guide reached its step limit. Goal completion has not been verified."). Context retained across pauses: guide controls have Back/Skip/Find again; I did not verify pause persistence across relaunch for guides. `guide.click-advance` live-tested; `guide.skill-injection` unit-tested; local skill catalog is "five live-guide apps" in tests, "22 bundled app skills" per a live Settings screenshot (`features.json skills.bundled-workflows`). HeyClicky's catalog is ~89 apps.
- **"Always approve": HAS (narrower).** `ToolConsentStore`: "Allow once / Always for this Perry / Not now". Always-grants persist per thread (each Perry owns a thread), apply to orange and below; **red always asks** with a typed phrase. Unattended runs deny without a grant. Live: `do.agent-cards` limitation records a real card with Stop/Always allow/Approve and an executed move (`docs/evidence/phase-7/approval-card.md`). Scope is per tool per thread, not "for this whole long task". Done for parity: a per-task "approve this run" toggle, if wanted.
- **Flexible shortcuts incl. double-tap: PARTIAL.** Hold gestures, fn/⌃⌥⌘ holds, conflict detection (commit `19c4938`). Free-form recorder was skipped on purpose (`progress.md`). `dictation.hands-free` = wired.
- **New computer-use driver:** Perry bundles Cua driver 0.22.1 (pinned digest).

---

## Clickys equivalent: "Perrys"

**How close: closer than the user claims. Concept exists end to end; UX and proof are thin.** Verified.

What exists:
- Data model `Perry { id, name, job, threadID, folderPath, schedule }` (`Packages/PerryBrain/.../Perrys/PerryStore.swift`). JSON file per Perry, atomic writes.
- Two-word generated names that describe the job ("Inbox Keeper"), deterministic (`PerryNameGenerator`).
- Own memory file `<id>.memory.md`, separate from global PROFILE.md/CONTEXT.md, injected into that Perry's system prompt (`AgentCoordinator.systemPrompt(for:)`). **Only when global memory is enabled** and memory is off by default (`MemoryAndRunnerTests.testOffByDefaultRequiresExplicitOptIn`). So a new Perry has no memory until the user opts in elsewhere. Inferred from code reading.
- Own conversation thread, created on first open and stamped with `perryID` (`HomeController.swift:551`).
- Own tool consent scope (`thread.perryID ?? threadID`, `AgentCoordinator.swift:261`).
- Own folder (`folderPath`), schedule (daily/interval/once), catch-up, three-failure pause, wake/network gating.
- Conversational creation: `perry.createPerry`, `perry.schedule`, `perry.list`.
- Sidebar rows with character + name + job (`NotchWorkspaceView.swift:138-165`).
- Live evidence: `docs/evidence/phase-9a/scheduled-routine.md` — created via MCP socket, scheduled at 90 s, scheduler ran it on the bound thread, backoff counted. It also found and fixed fabricated-success runs. Strong honest evidence for a unit-tested feature, but it is a 2026-10-01 Release/Debug drill with a local qwen3:4b model and is not bound to `features.json`.
- Tests: `PerrysCoreTests` (create/list/update/remove, memory file, corrupt file skipped, name generator, schedule rules), `PhaseNineControllerTests` (tick runs due Perry, skips when asleep/offline/busy, failure bookkeeping).

What HeyClicky has that Perry lacks:
- Onboarding with character styles and three personalized Clickys. Absent.
- Migration of legacy work into Clickys. N/A.
- Cross-Clicky voice routing ("hey Inbox Keeper, …"). Absent (`TalkSession` does not resolve a Perry by name; inferred from grep of `perryID` use).
- Pinning, customization, archived Clicky search, completion announcements per Clicky. Absent / partial (task completion notifications exist, not per Perry).
- Live progress view per Clicky. Partial: activity strip is global for the foreground run; Tasks page lists background tasks.
- A UI to create, rename, edit, schedule, or delete a Perry. Absent (creation is tool-only, inferred from grep of `App/`).
- A schedule/paused indicator. Absent.
- Concurrency: `AgentCoordinator` allows one run per thread, so different Perrys can run in parallel; the scheduler skips scheduled runs while a foreground Do is active (`isBusy`). Shared Cua worker caveat applies.

What "done" would need (smallest set): Perry create/edit/pause UI in the notch workspace; show paused state with a Resume; memory on by default for a Perry the user created (or a clear prompt); voice addressing by name; a live drill with a real model that does a GUI step, recorded as a `features.json` entry (e.g. `perrys.persistent-agents`) at live-tested.

---

## Home and routines

**Home.** Verified. Home as a window is deleted in the working tree. `progress.md:9-10`: "notch-only contract… no Home window, no status-bar item, no floating panels." Rail: Tasks, Routines, Files, Suggestions, History (⌘1-5), a Perry list, and recent conversations (`NotchWorkspaceView.swift:120-210`). Pages: `BackgroundTasksView`, `HistoryView`, `RoutineLibraryController`, Files, Suggestions. Not resizable. `appearance.notch-home` = unit-tested, "the full feature run is not yet bound to a parsed structured artifact". `appearance.notch-status` unit-tested. Everything notch-redesign is **uncommitted** and verified mostly by offscreen renders; a user-blocked test run on this MacBook ("No local tests while in use" memory) means the last full suite I can cite is `progress.md:192`: app 627/0/6, PerryBrain 317/0 (2026-10-22 23:05).

**Watch & Learn routines.** Verified. `DemonstrationRecorder` (bounded recording, secure fields drop keystroke text, clicks outside observed elements dropped), `RoutineReviewWindow` (review before save), `LearnedRoutine` (max 50 steps, `LearnedRoutine.swift:8`), `RoutineReplay` (resolves targets against a fresh observation, refuses missing/ambiguous/foreign targets, pauses on manual steps). Tests: `DemonstrationRecorderTests`, `LearnedRoutineTests` (4 replay tests). Registry: `routines.watch-learn` and `routines.replay` = **unit-tested**; both say "no structured live run". The live script `routine-drill.sh` exists; no result artifact found. Cannot call this "has" for HeyClicky-style recurring routines: Watch & Learn replays are manual ("Run now"), not scheduled.

**Scheduled routines** = Perry.schedule (see above). Unit-tested plus one drill.

## Other HeyClicky features in the list

| Feature | Perry | Evidence |
|---|---|---|
| Suggestions carry source details | Has (`SuggestionCard.sourceServiceID/Name`, `sourcePerryID`) | `SuggestionEngine.swift`; thread annotated with source integration (`AgentCoordinator.systemPrompt`) |
| Custom MCP connectors | Has | `App/CustomConnectors.swift`, `CustomConnectorsTests` runs a real Python MCP server; Keychain-stored keys; unknown-effect tools orange. Not in `features.json`. |
| Per-conversation computer-use approval | Partial | per-thread/Perry Always allow (above) |
| Quiet during calls | Has | `SuggestionRules.quietNow(isOnCall:isScreenSharing:focusActive:)` — for suggestions; sound cues muted under Focus (`QuietHours`) |
| Clicky edits its own settings | Has | `perry.settings.open` opens a page; it does not change values. Partial. |
| GPT-6 models / model routing | Has routing | `runtime.model-routing` unit-tested; providers in `PerryBrain/Providers` |
| Clarifying questions instead of guessing | Has | `TaskQuestionPresenter`, `askUser` action, `AgentPrompt` |
| Referral / accounts / billing | Absent by PRD | PRD §5 |

---

## Perry features HeyClicky lacks (as far as the changelog and the earlier binary teardown show)

Marked **verified** (I read Perry's code) with the HeyClicky side **inferred** (absence in the changelog and in `docs/heyclicky-teardown.md`).

1. **Local-first / no telemetry with proof.** `privacy.no-telemetry` is **live-tested** (zero outbound network while opted out). No Sentry/PostHog. HeyClicky ships both.
2. **Complete erasure** across Keychain, support folder, Cua artifacts, history (`CompleteErasureCoordinator`, `PerryErasureErasers`), with race fixes (`progress.md` 2026-10-22). HeyClicky has account deletion, server-side.
3. **Agent Undo for file changes** with durable write-ahead receipts and conflict-safe reversal (`do.undo`, `do.durable-receipts`; unit-tested). Not in HeyClicky's changelog.
4. **Ghost rehearsal** with numbered marks on real targets before execution. Exists only for routine replay (see surprise 1).
5. **Watch & Learn:** record a demo, review, replay by re-reading the live screen, never coordinates. Not in HeyClicky's changelog.
6. **Word-timestamp deixis:** align spoken "this/that" with pointer position (`DeixisResolver`, `talk.deixis` unit-tested; live drill: deixis bound to element 5/5, `progress.md` 2026-10-22).
7. **Spatial input:** point/circle/scribble selection as part of a question (`input.spatial-context`). HeyClicky has a similar v1.0.33 feature, so parity, not a lead.
8. **Typed trust tiers with red typed-phrase confirmation**, deny-by-default driver capability manifest, TrustGuard block list for sensitive apps, MCP socket hardening (0600, peer pid/team check, rotating token, reviewed in `docs/evidence/phase-6/mcp-socket-approval-review.md`).
9. **BYOK providers and local models** (Ollama/qwen3 drill, Codex, Claude, OpenCode runtimes, OpenAI-compatible, Gemini, Anthropic). HeyClicky is hosted inference with plans.
10. **Perry as its own MCP server** (`perry-mcp` socket + `perry-mcp` executable) so outside clients can use its tools.
11. **Fabricated-transcript guard:** an agent turn that narrates tool results without running a tool fails instead of completing. Found live, fixed (`phase-9a`).
12. **Hand-drawn ink engine with a living character** (`PerryCharacter`, blind critic wins vs HeyClicky cat per `progress.md`). Subjective and self-judged.
13. **Shipped installer design** (DMG with drawn path, `docs/evidence/installer/dmg-finder-window.png`).
14. **Share-hiding:** every Perry window hidden from screen capture via one chrome contract (`f58d25d`).
15. **Idle budgets enforced by script:** CPU ≤ 0.5%, RSS ≤ 180 MB (`idle-probe.sh`; 0.000% / 155 MB on 2026-10-22).

---

## Priority list for "done" (my recommendation, ordered by user-visible gap per effort)

1. **Live-prove computer use** through the agent loop (TextEdit fixture; click/type/key/scroll/drag; record `runs/do-computer-use-*.json`; flip `do.computer-use` honestly). Add an observe-and-assert after mutating `ui.*` calls or wire driver `verify_state`. This is the claim the user leads with and it is the least proven.
2. **Perrys UI:** create/edit/pause/resume, schedule + paused state, memory default, voice addressing by name. Register `perrys.*` in `features.json`.
3. **Multi-account integrations.**
4. **Pointer-moving drive mode** (only if the product wants it; background-only is a defensible position).
5. **Browser act tools** (`browser_*` already allow-listed).
6. **3D / rich cards:** large, speculative; defer.
7. Fix stale `docs/capabilities.md` and decide where rehearsal should apply to agent runs.

## Files read

`docs/heyclicky-feature-audit.md`, `progress.md`, `docs/release-readiness/features.json` (parsed with `python3 -I`), `docs/capabilities.md`, `docs/release-readiness/cua-live-fixtures.md`, `docs/release-readiness/runs/guide-click-advance-2026-10-14.json`, `docs/evidence/phase-6/reach.md`, `docs/evidence/phase-9a/*`, `docs/evidence/phase-7a/README.md`, `.devin/goal/report.md` (head), `PRD.md` §5, `App/{CuaDriverClient,CuaCapabilityManifest,CuaWorkerService,ComputerAction,CompositeActionVerifier,TypedActionRouter,ForegroundTaskController,BackgroundTaskController,PerrySchedulerController,CommandRouter}.swift`, `App/Tools/{UITools,DrawTools,ScreenTools,BrowserTools,AppTools,AgentCoordinator,ForegroundWorkerLease}.swift`, `App/Home/NotchWorkspaceView.swift`, `App/Home/HomeController.swift`, `Packages/PerryBrain/Sources/PerryBrain/{Talk,Perrys,Tools}/*`, `Packages/PerryOverlay/Sources/PerryOverlay/GuidanceModels.swift`, `Packages/PerryGuide/Sources/PerryGuide/GuideEngine.swift`, `LearnedRoutine.swift`.
Not read: Settings views, onboarding views, provider code, most tests (names only via grep), Packages/PerryRuntimes (typed planner internals).
