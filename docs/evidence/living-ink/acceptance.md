# Current acceptance: 2 October 2026

The active direction is light paper, charcoal illustration and the drawn Perry mascot. The user explicitly deferred dark mode and yellow-accent removal. The historical checklist below predates these decisions; its dark-mode and character-flight items are not current release requirements.

| Surface or behavior | Current evidence | Remaining verification |
| --- | --- | --- |
| Welcome, connection, first talk | Native illustrated screens inspected; automatic voice permission startup and cancellation observed | Real spoken question and response after OS permissions |
| Attached notch | Native panel constraint override; seven placement/status tests including presented NSPanel frame; running content inspected | Desktop-relative full-screen capture and physical display changes |
| Permission setup and practice | All six setup stages resume with correct surface routing in isolated checkpoint tests; eleven onboarding tests pass; live notch transition and Back; both permission branches rendered at 480×348 content size; skip actions visible | Actual permission grant/relaunch and connected practice flows |
| Voice fallback | Live typing controls fit; existing draft preserved; native-host prefill regression and image confirm editable conversation draft without voice startup/submission; repeated task-edit regression reproduced and fixed; revised task draft, paper canvas and charcoal Start action rendered and inspected | Real listening/interruption/retry and connected task-edit flow |
| Workspace | Native fullSizeContentView fixes observed toolbar overlap; live welcome and Settings inspected; Talk to Perry opens notch and Cancel returns to idle; live local arithmetic reply reopened from notch history and a follow-up short story completed in the notch | Narrow sizes and completed spoken response |
| Settings | Section picker restored; General, Voice & Input and Safety inspected; native scroll background now shares paper canvas; speech output uses existing preferences; Appearance, Memory and Models inspected; Connected Apps setup disclosure and unique accessible labels built and inspected | Broader keyboard navigation and larger text |
| Guide | New paper/mascot hierarchy built, rendered and inspected | Real guidance, step changes and cancellation |
| Active tasks, approvals and routines | Updated activity and approval light fixtures inspected; 27 focused onboarding/notch/interactive-panel tests pass after removing unused character-flight code; earlier short/long fixtures and control tests recorded below | Connected execution, approval/rejection, steering, recovery and undo |
| History, files and suggestions | History focus and selection colors inspected; Files light canvas and keyboard focus inspected; Suggestions introduction inspected live and synthetic cards rendered; sidebar now uses native selection text/icon colors | Suggestions content fits a native 600×460 render; other minimum-width and larger-text checks plus connected suggestion generation/actions remain |
| Final engineering review | Focused builds/tests and diff checks logged per pass; latest 60-sample closed-conversation probe passed at 0.037% average CPU and 145.4 MB maximum RSS | Final scoped review and remaining connected-flow regressions |

No blanket completion claim is supported yet. Runtime microphone, speech, Accessibility and Screen Recording permissions have not been granted by the agent. Progress and live process handles are recorded in `.devin/ui-redesign/notch-checkpoint.md`.

Latest voice regression run passed all eight tests, including permission denial followed by a fresh capture, rejection of stale capture text after retry, clearing the old turn when starting a new conversation and rejecting a late answer after cancellation. This verifies controller behavior with controlled input and output; it does not verify microphone capture or audible speech.

Latest idle evidence: `docs/evidence/perf/idle-20261002T080411Z.csv`. The conversation was closed and the existing task indicator remained visible. This is a one-minute spot check, not a long-duration leak test.

## Historical evidence

# Living ink acceptance record

The redesign is incomplete. This record separates implemented behavior from verified behavior. The source contract is `DESIGN.md`; the implementation plan is `docs/plans/2026-10-01-living-ink-product.md`.

## Verified

| Requirement | Evidence | Limits |
| --- | --- | --- |
| Dedicated illustrated welcome | `welcome-light.png`, `welcome-dark.png`; live dark welcome inspected | Entrance timing and larger text still need review |
| Welcome moves setup into compact panel | Live replay through setup; new character-flight implementation lands at model choice; 21 focused tests pass | Motion trajectory and live Skip target still need visual inspection; endpoint capture alone does not prove motion quality |
| Back and settings return preserve setup stage | Live replay through Models and Back to setup | Relaunch during every stage not yet covered |
| Permission pages do not request access on entry | OnboardingDirectorTests and live skipped-permission path | Actual denial/regrant flows not exercised |
| Composer fits first-conversation setup | Live 480×440 screenshot after nested-scroll removal | Long conversation and larger text require visual checks |
| Compact panel preserves drafts on close/reopen | Live status click, edit draft with temporary suffix, close/reopen, restore original | No model request sent in this visual pass |
| Escape dismisses compact panel | Live keyboard check; routing calls existing cancellation-aware dismiss | Every execution state still needs review |
| Workspace shortcut opens Home | Live Control–Command–Space check | Global shortcut variants not all exercised |
| Work navigation is above conversation history | Live workspace screenshot | Narrow window and light theme need another visual check |
| Advanced model settings remain reachable | Live Models, Configure direct provider expanded; fields and save state present | No credentials or provider settings changed |
| Local model readiness is understandable | Live Settings shows Apple Intelligence availability separately from local server discovery | Checked current available state only |
| History gives results enough width | Live revised History: badges below result, full result wrapping, readable metadata | Dark appearance checked live; light and narrow widths pending |
| Files support keyboard opening | Live Tab focus ring; Return opened PracticeSandbox/Cover draft.txt in TextEdit; file closed unchanged | Other file types not exercised |
| Typed conversation loading and completion | Live prompt “Reply with the word hello.” showed Working on it and Stop, then returned “hello” | Workspace surface tested; cancellation and failure recovery still pending. Original unsent draft restored exactly |
| Approval detail remains readable | `approval-light.png`, `approval-dark.png` | Actual approval input/rejection needs end-to-end verification |
| Guide action hierarchy and contrast | `guide-light.png`, `guide-dark.png` | Actual target/keyboard flow not exercised |
| Recovery behavior preserved | 26 tests across HomeRecovery, HomePerryRow and RuntimeSettingsState passed after test-harness corrections | Tests do not establish overall visual acceptance |
| Idle resource spot check | `docs/evidence/perf/idle-20261001T223513Z.csv`: average CPU 0%, max RSS 110.7 MB over 30 samples | Predates the latest UI changes; final probe pending |

## Implemented, awaiting sufficient evidence

- The 24 pt ink companion replaces the primary glass pointer. Actual active spatial screenshots over light and dark applications are still required.
- Status can open conversation and appears for approval-only activity. Placement on a physical no-notch display and menu-bar reachability remain unverified.
- Routine review uses solid surfaces and can become key. Six fixture renders were inspected, but actual text entry and cancellation still need verification.
- Files have named accessibility actions, Routines has a recording entry, and routine delete controls have accessible names. Recording was not started during this review.
- Reduced-motion handling exists for welcome and existing panel transitions. System-level reduced-motion and Increase Contrast checks remain pending.

## Outstanding product work

- Visually verify the implemented welcome-to-notch character flight, live Skip target and reduced-motion cross-fade.
- Verify compact typed response, cancellation, failure and recovery. Workspace loading and completion have been observed through the configured local route.
- Verify explicit voice initiation, denied microphone behavior and voice-to-text fallback.
- Verify guide, active task, approval and cancellation as connected flows, not isolated fixtures.
- Verify live scrolling and text entry for task and routine panels. Short and long fixture renders now fit in both appearances; task controls remain outside the bounded scroll region.
- Finish both-appearance and narrow-width checks for Home task/history/suggestion surfaces. Updated What’s New copy has been rendered and inspected in both appearances.
- Check display changes while panels are visible, no-notch anchoring and safe-area geometry.
- Complete keyboard/accessibility, both-appearance and larger-text review of all major surfaces.
- Complete structural/code-deslop review against the scoped diff and run final build, affected tests and idle probe.
- Obtain the requested design.how skill content. The public skill index routes to a signup; those unavailable skills have not been represented as used.

## Current test evidence

Logs under `.devin/ui-redesign/` are local working records, excluded from commits:

- `fit-hierarchy-tests.log`: onboarding, status policy and interactive panel tests passed.
- `guide-contrast-tests.log`: panel tests passed after primary-action rendering fix.
- `workspace-regression-rerun.log`: 26 tests passed. Two snapshot tests now create their output directory; welcome layout expectation now checks the dedicated welcome rather than the removed sidebar.
- `routine-accessibility-tests.log`: panel tests and routine fixture rendering passed before the pending content-fitting revision.
- `placement-routine-fit-tests.log`: status geometry and interactive panel tests passed.
- `routine-intrinsic-tests.log`: interactive panel tests passed after intrinsic-height correction. Inspected short dark and long light routine renders; short content fits closely and long content retains the bounded scroll region.
- `display-activity-tests.log`: 16 interactive-panel and status tests passed after task content sizing and display-notification integration. Inspected short and 20-step task renders in both appearances. Physical display changes remain unverified.

The initial workspace regression failure and its reason remain in `workspace-regression-tests.log`. A passing build alone does not close any outstanding visual or interaction requirement.
