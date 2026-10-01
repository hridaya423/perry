# Polish passes — code-deslop + clean-copy (2026-10-01, iteration 14)

Two phase-10 polish gates run over the megaplan-era code and copy.

## code-deslop — verdict: CLEAN

Scope: mechanical catalog sweep across `App/` + `Packages/*/Sources/`
plus judgment reads on the highest-churn files (ForegroundTaskController,
AgentLoop, PerryErasureErasers, SettingsView). The branch's full
main-vs-HEAD surface (748 files) is too large for a line-by-line audit;
the sweep covered every source file for the fingerprint patterns and the
15 recent commits' files in full.

Checked, none found:

- Narration/banner/placeholder comments — zero hits for the
  leading-verb and end-label patterns. Comment density tops out at 16%
  (ToolApprovalPresenter); all sampled comments are *why*-type
  (constraints, workarounds, ownership notes).
- `print(` in app paths — zero. Logging goes through PerfMark/os_log.
- Dead protocols — all 27 declared protocols have real conformers or
  DI consumers in tests (PerryOwnedDataSweeper, GuideSessionContext,
  TalkSpeechOutput, AppNotificationClient verified individually).
- `else { return false }` hits were all `guard ... else` — idiomatic.
- `catch is CancellationError` sites are deliberate rethrow filters.
- No TODO/FIXME/XXX markers in the scoped files.

No edits resulted. The codebase was built with minimal-comment discipline
throughout the megaplan phases, so there was nothing to cut.

## clean-copy — 5 cuts out of ~384 string sites

Method: walked every `Text(...)`, `.help(...)`, and alert string in
`App/` down the ladder (surface at all? → label needed? → preempting a
non-question? → rewrite or delete). What survived: consequence copy at
destructive moments (erasure, key removal, history deletion), scope
facts the user can't see (local-only memory, read-only defaults,
TrustGuard refusals), empty-state guidance.

Cuts (rung cited):

- `SettingsView.swift` wake-word caption — "Off by default." restates
  the toggle it sits under (rung 2). Kept the privacy fact.
- `SettingsView.swift` realtime disclosure note — "endpoint mechanics
  stay behind this disclosure" describes the UI around it, and "keeps
  one duplex session open and cancels playback" is mechanics the user
  can't act on (rung 1/3). Kept the data-flow consequence.
- `SettingsView.swift` report-a-problem message — "so the problem can
  be reproduced" is filler after the instruction (rung 4).
- `SettingsView.swift` Cua note — "Grounded tasks stop when Cua is
  unavailable or unhealthy" restates "requires" plus the health row
  already above it (rung 3).
- `SettingsView.swift` skills note — "Disable any skill you do not want
  Perry to use" is a permission slip under visible toggles (rung 3).

Deliberately kept borderline cases: "If voice input is unavailable,
Perry leaves the panel ready for typing" (answers the question the
permission row raises), "It does not watch your screen" under the
suggestions toggle (the toggle copy creates the question), and the
long OAuth caption (every clause is a consequence the user can't infer).

## Result

- Build: `** BUILD SUCCEEDED **` on the same command as every iteration.
- Strings are the only artifact of these passes — no behavior change.
