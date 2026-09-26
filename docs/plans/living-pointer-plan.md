---
agent: devin-local
session: brazen-wish
created: 2026-09-19T21:48:29Z
---
# Perry Megaplan II — The Living Pointer

Turn Perry into a coherent spatial AI interface: an original glass cursor that explains what you point at, rehearses changes, shares control, learns explicitly demonstrated routines, and reverses only changes it can safely verify.

## 1. Summary and product thesis

Perry should not become a larger assistant dashboard. Its next primitive is **a shared pointer into the user's work**: point at an object, understand it, preview a change, choose who performs it, and keep the useful procedure. The distinguishing quality is continuity between these actions, not the number of modes, integrations, or animations.

The user is a Mac power user or prosumer working inside real applications, including dense creative tools. Their job is to understand or change something without translating their entire screen into a chat prompt. The consequence is real: Perry can modify files and operate applications. Speed, legibility, bounded authority, and recovery are part of the product experience, not a separate compliance phase.

**Product promise:** “Point at it. Understand it. Change it together. Teach Perry your way.” This is a direction, not a claim that arbitrary applications or workflows already work.

This plan extends the previous public-beta megaplan; it does not rerun its completed architecture migrations or treat its progress report as proof. Preserve the existing work, close concrete foundational gaps, then deliver vertical slices with real-device evidence. Implementation starts only after this plan is approved.

Repository root for all relative paths below: `/Users/hridyaagrawal/Honey/perry`.

## 2. Decisions settled with the user

- Build all four approved bets: **Watch & Learn, Ghost Rehearsal, shared-control handoff, and Agent Undo**.
- Add **Ask** as a first-class mode alongside Guide and Do. Ask is the lowest-commitment default for a new session.
- Begin with a **feel-first validation phase**, not a features-first sprint. “Feel week” describes the working loop, not a calendar estimate or a requirement that the user become the QA harness.
- Watch & Learn is explicitly started/stopped, uses **AX-derived observations only for typed values**, and installs no keyboard recording hook.
- Use an **original glass cursor**, not a walking, running, or celebrating animal. Existing mascot choreography is an anti-reference for this redesign. No exact website replication is required.
- An on-screen companion is primary. Notch integration is **not prohibited**, but must justify itself as a secondary status placement. No notch-dependent core journey.
- Add well-written app skills gradually. No quota, bulk-generated library, or “89 skills” parity exercise.
- Keep local-first architecture, user-owned providers, zero third-party telemetry, AGPL, Apple Silicon, and macOS 14+.
- No Perry backend, hosted workers/inference/accounts, billing, marketplace, proactive monitoring, or new platform port.
- After approval: create a local checkpoint of the existing tree, then reviewed per-phase commits. No push or publishing is authorized.

Product-rule anchors: `rule/control-matches-cardinality` for Ask/Guide/Do; `rule/inline-before-modal` and `rule/smallest-intervention` for the spatial surface; `rule/name-object-scope-consequence` and `rule/irreversible-action-safeguard` for execution; `rule/undo-only-when-honest` for recovery; `rule/gesture-has-control-alternative`, `rule/keyboard-complete-flow`, and `rule/cover-reachable-states` for every new interaction. Existing stricter trust rules take precedence over generic advice to remove confirmations.

## 3. Honest baseline and comparison to HeyClicky

### What is established

The current source has a native SwiftUI/AppKit shell, Cua-owned capture/control, typed executable plans, app-owned dispatch, Guide re-observation, provider adapters, local history/memory, voice paths, and workspace journals. The feature registry currently records **68 entries: 25 absent, 18 wired, 25 unit-tested; none live-tested or release-proven**. “Absent” includes deliberate exclusions, so it is not a missing-feature score.

The earlier goal report records passing deterministic suites and unsigned builds. This planning session has not rerun them. Its missing live/UI/performance evidence does not prove the application has never been used.

HeyClicky's fetched public website describes screen-aware conversation, teaching, drawing, agents, and dictation. The repository's August 26 audit adds voice-route and recovery details, but is historical and partly stale. For example, it still describes telemetry that Perry subsequently removed and understates the current bundled resource count. Do not use it as a current parity certificate.

**Verdict:** Perry is comparable in feature categories and has useful trust-oriented foundations. Comparable smoothness, task success, voice dependability, and release readiness remain unproven. The approved new primitives are differentiation hypotheses, not claims that nobody else has implemented them.

### Concrete source findings that change this plan

1. `App/SessionPanelView.swift` is a two-mode, single-turn entry surface. `submit()` clears the input before acceptance; language parsing can redirect to Do. Ask must not silently acquire action authority.
2. `Packages/PerryGuide/Sources/PerryGuide/RuntimeLadder.swift` still brace-extracts JSON, accepts loosely shaped targets, and `compactMap`s invalid map steps away. Its prompt uses `done` for both completed and unable-to-advance.
3. `GuideEngine.swift` interprets no next step as finished. Its verifier accepts broad screen/title/app changes before checking the declared postcondition. Unrelated change is not sufficient evidence for shared-control continuation.
4. `AXModels.swift` has role, label, frame, and an ID, but no separate safe value or sensitivity field. `CuaDriverClient.guideSnapshot` can fall back from label to value and uses driver tokens/indexes as IDs. Those are not portable semantic locators for learned routines.
5. `CompositeActionVerifier.swift` currently accepts text anywhere in the window, whole-image digest change, or a response-body substring for several effect types. These are weaker than target-bound outcome evidence.
6. `ActionPolicyTable.swift` classifies generic computer and sandboxed-shell operations as reversible. That flag is not proof Perry can undo an operation, nor does a generic click establish its semantic risk.
7. `DoSupervisor` processes a precomputed action array. Later hidden UI cannot honestly be drawn at known coordinates in a full-plan rehearsal.
8. `TaskCoordinator.validateExecutablePlanForEnqueue` currently requires workspace transforms and action-scoped approval. The app-level queue validator advertises all operation kinds. Durable general computer/integration execution is not established by this path.
9. `WorkspaceFileExecutionReceipt` records useful rename/trash identities, but creation receipts lack the complete conflict-detection information needed for undo. Foreground execution does not retain the same durable receipt chain as the workspace queue.
10. `PerrySpriteView` continuously draws an animated animal and `OverlayWindow.swift` contains its following/travel choreography. Replace the character behavior while preserving window placement, capture exclusion, and input pass-through.

These are source observations, not newly reproduced runtime incidents. First write regressions for the relevant behavior; do not simply repeat the previous report's completion claims.

## 4. The experience we are building

### 4.1 One session, three intentions

The hotkey opens a compact, immediately focused input beside the pointer. **Ask / Guide / Do** remain visible; one primary action changes to match the selection. The active app/window and any explicit spatial selection form a small removable context label.

- **Ask:** “What does this do?” Answer near the referenced object. No action executor is available to this path.
- **Guide:** “Show me how.” One grounded next instruction with controls and keyboard alternatives.
- **Do:** “Do this.” Show a reviewable change, then execute under the existing permission and approval system.

A new session begins in Ask. Within an active session, maintain its chosen intention and bounded context. Language may suggest a mode, but cannot silently promote Ask to Do. Retain unsent input across permission/provider failures. Switching intention preserves the user's goal and verified progress, not stale coordinates or old approvals.

Watch & Learn is an explicit action in the session menu, not a fourth primary mode. Rehearsal belongs inside Do. Undo belongs on the result/history receipt. This keeps the first interaction understandable.

### 4.2 The glass cursor

Perry appears as a small, asymmetric translucent pointer with a crisp tip, neutral glass body, restrained mint edge, and a short attached caption. It remains distinguishable from the user's OS pointer. It never hides, replaces, warps, or steals the real pointer.

Its signature is **shape continuity tied to meaning**: a pointer becomes an anchored focus ring/callout, then an outlined rehearsal cursor, then a compact result mark. Do not morph unrelated objects merely to demonstrate animation.

Initial design targets: approximately 28–32 pt pointer, readable 13–14 pt caption, maximum caption width around 320 pt with expansion for long content. Existing accessibility scaling wins over these nominal sizes. Use one original silhouette across panel, overlay, and status representations; no parallel mascot identity.

- Listening: bounded edge/luminance response plus a visible microphone state.
- Thinking: a quiet static caption with bounded activity feedback; no fake percentage.
- Explaining/guiding: a stable anchor and leader to the actual object.
- Rehearsing: dashed/outlined geometry and an explicit Preview label.
- Acting: solid geometry and the current action name.
- Approval: the exact target plus the existing consequential card.
- Finished: one short settle, specific verified result, no confetti.
- Blocked: stable marker and one recovery action, not a sad-character performance.

Native materials, SwiftUI Shape/Canvas and AppKit panels are sufficient. No shader, animation framework, screen resampling for fake refraction, or new dependency. macOS 14 fallback is a first-class appearance, not a broken imitation of a newer OS effect. Reduce Transparency makes surfaces opaque; Increased Contrast strengthens edges; Reduce Motion removes travel and pulse.

### 4.3 Spatial Ask

Circle, point, or choose a target through an accessible control list; type or speak a question. Perry gives a concise answer with up to three grounded callouts. Text and explanation are accessible in the panel even when a visual reference is unavailable.

Follow-ups such as “the other one,” “why?”, and “show me” reuse the active session's selected references and recent turns. Ambiguous references trigger clarification rather than guessed coordinates. Re-observe when the target changes. Historical statements can remain in the transcript, but old annotations disappear when invalidated.

Read-only labels and images are valid Ask references; they need not pass Guide's actionable-control requirement. Use a shared observation validator with purpose-specific rules, not fake clickable Guide steps.

Ask has no shell, integration write, or computer-input tools. A next-action suggestion is data; selecting Guide or Do starts a separate, validated transition.

### 4.4 Ghost Rehearsal

Show **what Perry intends**, not a fabricated future screenshot. For currently observed targets, show a numbered highlight, ghost pointer path, and optional text insertion preview. For file operations, show before/after names and destinations. For integration writes, show account, object, recipient if applicable, and exact payload in the existing approval surface.

Later controls hidden behind a menu/dialog appear as a plain-language outline labeled “after the next screen opens.” They receive spatial ink only after fresh observation. A full future UI simulation is explicitly out of scope.

Review supports Next/Previous, Replay preview, Edit request, Cancel, and the single primary Run action. Preview has no executor reference and must cause zero side effects. Viewing a rehearsal is not approval. Existing orange/red action confirmations remain; the 5-second cancellation window remains. Do not add a second equivalent approval dialog.

A changed plan, target, workspace, payload, or observation invalidates the rehearsal binding. Regenerate the affected preview and obtain any new required approval.

### 4.5 Shared control

Guide offers **“Perry, do the next step”** and **“Finish with Perry.”** Do offers **“I'll do this step.”** Voice can request the transition, but never satisfy red approval.

The transition is a real action-boundary handoff: stop admitting actions, let an in-flight action settle, record its verified/uncertain outcome, revoke unused grants, re-observe, and then yield control. Never interrupt halfway through a click-and-type operation and assume it did not happen.

Human-performed steps are verified against their target-specific expected outcome. They are labeled as human work; Perry does not claim their receipt or offer to undo them. If the user takes a different route, re-plan the remaining goal from the current screen. Do not blindly execute the rest of an old array.

If an in-flight operation is uncertain, stop and offer inspection/replanning. “Handoff” is not a shortcut around no-replay guarantees.

### 4.6 Watch & Learn → My Routines

The user starts “Teach Perry,” chooses the window, sees an always-visible recording label with Pause/Stop, and performs a short workflow. Perry observes semantic before/after changes and click targets, not keystrokes or a continuous screenshot movie.

On Stop, present an editable routine draft: goal, supported app, named steps, inferred outcome, missing information, and suggested parameters. Variable-looking values become required parameters by default. Literal values persist only after review. Unknown fields are not guessed.

Example: demonstrate renaming a test document and exporting it. Perry proposes “Rename and export,” asks which filename is variable, marks an unobservable export step as manual, and requires a live test before displaying a Tested badge. The export example only becomes a launch claim once the chosen application's flow passes the real compatibility gate.

Replay means **freshly grounded planning with a reviewed procedure**, never replaying recorded event coordinates or old Cua tokens. Each run gets new identities, current permissions, current approvals, and outcome verification. One demonstration creates a draft, not a guarantee of generality.

Routines are local, inspectable, versioned Markdown with a small strict metadata block. Multiple routines may belong to one app. Existing per-app skill notes remain compatible. Import/export is through explicit file selection, not a marketplace or executable plugin system.

### 4.7 Agent Undo

Offer **Undo available changes** only from actual verified receipts with safe inverses. Show which changes can be reversed, which cannot, and why before running a partial rewind.

First supported scope:

| Original effect | Inverse | Admission requirement |
|---|---|---|
| Rename in an authorized workspace | Rename the same object back | Identity matches; original name unoccupied; same authorized root |
| Move a workspace item to Trash | Restore the exact recorded trash entry | Identity/fingerprint match; entry remains; original destination unoccupied; safe same-volume restore |
| Create a file | Move the unchanged created file to Trash | Exact created identity and content fingerprint still match |
| Create a directory | Move the unchanged empty directory to Trash | Exact identity, directory still empty, no additional user content |

Every inverse is a new approved typed action with its own receipt. Undo is durable, conflict-aware, and resumable only from safe prepared states. It never overwrites a new file at the old path and never deletes later user work.

No universal Cmd-Z, unsend, purchase reversal, arbitrary GUI rollback, shell rollback, or automatic integration reversal. Those entries say “Not undoable by Perry.” A future API-specific inverse needs a separate reviewed contract and read-back test; it is not included by implication. Do not infer support from `policy.reversible`.

## 5. Architecture and contracts

### 5.1 Reuse existing owners

- `AppController`: composition, lifecycle, windows only.
- `SessionController`: the one active interaction state, mode, session ID, draft, bounded conversation, and control ownership.
- `GuideSessionCoordinator` / `GuideEngine`: observation-driven human guidance.
- `ForegroundTaskController` / `DoSupervisor`: reviewed execution, safe boundary yielding, and foreground continuity.
- `TaskCoordinator` / `ResumableTaskRunner`: durable records and background lifecycle.
- `CuaWorkerService` / `CuaDriverClient`: sole production capture and computer input route.
- `DirectProviderClient`: existing provider transport, reused for Ask and routine synthesis. No new AI SDK.
- `AppSkillLibrary`: existing app notes plus explicit routine storage APIs, without turning ordinary app notes into executable authority.
- Existing theme, overlay, activity strip, intent card, history, onboarding, erasure, and diagnostics surfaces are extended rather than duplicated.

New files below are justified by new behavioral owners or shared domain contracts. Do not create a generic agent framework, event bus, workflow graph editor, parallel state store, or provider-specific Ask implementation.

### 5.2 Observation identity and sensitivity

Extend `GuideObservation` with an explicit observation ID / driver snapshot ID. Extend AX elements with separately represented safe value, raw-role/subrole metadata when available, sensitivity (`ordinary`, `secure`, `unknown`), and an optional semantic reference. Existing decoding defaults missing sensitivity to `unknown`, not `ordinary`.

An in-memory target binding includes observation ID, bundle/process/window/generation, semantic reference, current driver token, and bounds. Driver tokens are scoped to the current observation. A routine stores only semantic intent and reviewed locator hints, never a token, pid, window ID, generation, or global coordinates.

At the Cua boundary, confirm which pinned protocol fields actually exist before using them. If reliable security metadata or AX-only reads are unavailable, automatic field recording is unavailable; the routine editor asks for a parameter. Do not add direct AX scraping or a second capture backend to work around it. Do not infer that a field is safe because it is not labeled Password.

Protected windows are rejected before capture. During recording, unknown/secure fields contribute no value to model prompts, logs, or disk. Use metadata-only Cua requests for recording where supported. If the driver cannot meet that boundary, pause/disable the affected recording capability and report it rather than silently screenshotting.

### 5.3 Explicit planning outcomes

Replace the Guide optional-step completion ambiguity with a strict result:

```swift
public enum GuideDecision: Sendable {
    case step(GuideStep)
    case complete(evidence: GuideCompletionEvidence)
    case blocked(reason: String)
    case needsInput(prompt: String, choices: [String])
}
```

`GuideCompletionEvidence` is validated against app-owned observed conditions. A model's claim alone may end an explanation but may not generate a verified task result. Step-count limits produce a paused/limit state, not success. Invalid target shapes and unknown JSON keys reject the response; a malformed map rejects as a whole instead of presenting a deceptively shortened route.

Ask's separate response contract is read-only:

```swift
public struct SpatialAnswer: Sendable {
    public let text: String
    public let references: [SpatialReference]
    public let followUp: String?
}
```

`SpatialReference` contains a caption and a reference to the current observation (element or in-bounds visual region). Bound text to 8 KiB, references to three, and recent context to eight turns / 16 KiB text. Raw images are in-memory inputs, not part of Codable history. Reject oversized responses rather than allowing unbounded UI/model context.

### 5.4 Verification and risk are not presentation

Add target-bound postconditions for exact safe-field equality, element presence/absence/state, and the expected window transition. Whole-image changes are observation signals, not proof of a particular side effect. Include connection generation in read-back identity checks. Integration verification decodes the expected service object and compares its ID and fields; perform a separate allowlisted read-back where the write response cannot prove the result.

Generic GUI input has unknown consequence until admission can establish the target and semantic action. Unknown-effect writes require explicit action review; high-risk effects keep typed confirmation; protected operations stay blocked. A model-supplied label or claimed tier cannot downgrade risk. Arbitrary shell tasks and generic GUI actions must not advertise undoability or replay safety.

Keep separate facts: action risk, retry/idempotency policy, verified outcome, and available inverse. Reversibility must not stand in for idempotency.

### 5.5 Durable receipts: extend, do not parallelize

Evolve the existing workspace execution journal into a typed **action execution journal** with operation-specific receipt payloads. Preserve the existing prepared → dispatched → verified lifecycle and single-current-attempt invariant. Migrate callers and then retire the old executable surface; keep read-only decoding for old records.

The durable envelope binds task ID, plan ID/digest, revision, action ID, attempt ID, origin (`perry` or `human`), outcome, and optional inverse metadata. File fingerprints are app-derived and include identity plus content/structure checks required by the supported inverse; no screenshots or complete transcripts belong here.

Use `TaskCoordinator` as durable record owner for foreground as well as background runs. `DoSupervisor` must await journal writes before dispatch and after read-back, not rely on a fire-and-forget UI event. A narrow journal interface is justified by the foreground and background consumers; implement it through the existing coordinator and an in-memory test boundary.

Introduce `ActionPerformer` only as the shared execute-and-record boundary: validate grant → persist prepared → persist dispatched → dispatch → independently verify → persist outcome. Scheduling, approval UI, and product mode remain with their current owners. Migrate the background runner first, then foreground, and delete duplicate side-effect ordering. If persistence fails before dispatch, nothing runs. If it fails after dispatch, the task is uncertain and cannot replay automatically.

Old receipts lacking adequate fingerprints remain inspectable but non-undoable. Recovery never reconstructs authority from backup records.

### 5.6 Rehearsal and handoff bindings

`RehearsalSnapshot` is a pure projection of a validated plan plus current observation and contains plan digest, observation ID, visible target marks, nonspatial future outline, and inverse availability. Its initializer cannot accept arbitrary model drawing commands. Edits produce a new plan revision and invalidate pending review/grants.

Add `yieldAtBoundary()` to `DoSupervisor`, returning a typed result containing the verified prefix and next action or an uncertain/stopped reason. Complete any in-flight verification/journaling before acknowledging the yield. New work from the same goal uses a new revision and current observation. `SessionController` retains one session ID and tracks transitions; do not add a second orchestration state machine in the UI.

For changed UI, plan a bounded next grounded action/batch. A GUI action that changes the observable screen ends that grounding segment; reacquire before the next segment. Deterministic file batches may remain batched. Bound a continuation to 20 automatic actions or five minutes before asking to continue; limits pause rather than claim completion. All automatic revisions pass the same publication, risk, approval, and verification gates.

### 5.7 Routine document contract

Store explicitly saved routines under `AppSkills/Routines/<UUID>.md` using existing application storage. Keep `AppSkills/<bundle-id>.md` app notes intact. Use a strict fenced JSON metadata block followed by editable Markdown so Foundation's JSONDecoder is sufficient; no YAML dependency.

Metadata fields: `schemaVersion`, `id`, `revision`, `name`, `appBundleIDs`, `parameters`, `steps`, and `provenance`. A step records an instruction, locator hints (role/label/ancestor hints), desired outcome, and whether it requires a human. Parameters are literal data substitutions with declared types and length bounds, never interpolated shell/code. Initial types: text, filename, and choice. Paths must bind inside a user-authorized workspace.

Limits: 64 KiB document, 50 steps, 20 parameters. Recording: one selected application/window scope at a time, max 10 minutes or 100 bounded observations before pausing with review/discard options. Preserve explicit user control; warn before pausing. Raw observations remain memory-only and are discarded at review completion/cancel. Store reviewed procedure data only.

Imported content is inert and untrusted. Reject traversal/symlink escape, duplicate/unknown keys, unsupported schema, oversized content, and embedded execution claims. An imported Tested label is not local evidence. Changing a routine revision invalidates its local tested status. Replay is always planned and approved anew.

## 6. Implementation phases

Every phase follows: reproduce/write a failing behavioral check → implement the minimum slice → run focused tests → execute the live drill where relevant → inspect the complete diff → update evidence and commit locally. Implementation and mechanical verification can be delegated; design, safety decisions, and review stay with the lead. Never lower existing gates to obtain a pass.

### Phase 0 — Preserve the work and establish a real feel baseline

**Modify as needed:** `App/DebugStateFixtures.swift`, `AppUITests/DebugStateFixtureUITests.swift`, existing UI/live suites, `App/PerformanceSampleLog.swift`, `.audit/perry-release-progress.tsv`, feature registry.

1. Record current branch/status/diff, inventory untracked source and generated artifacts, and inspect for accidental sensitive content. Preserve every pre-existing change. Create the authorized local baseline commit only after review; do not stage fetched binaries, personal data, or ignored build output. Do not reset/clean.
2. Refresh a deterministic baseline using existing scripts, then run the actual `PerryUI` and `PerryCuaLive` schemes on an interactive GUI-capable host. Diagnose runner/bootstrap/TCC failures from artifacts. Ask only for permissions/credentials that require the user; do not repeatedly rerun the same hanging test or weaken signing/TCC controls.
3. Capture current invocation, guide, approval, result, history, settings, and voice failure states using synthetic fixtures. Real screen capture evidence requires explicit recording consent and non-sensitive demo data; never silently persist a user's screen.
4. Exercise the existing six product journeys and record actual results, including skipped/blocked evidence. Measure focus, hotkey response, target fidelity, cancellation, background capability, audio routes, and idle resource use.
5. Resolve blockers in the primary typed/voice/Guide/Do loop before introducing new primitives. The agent owns repeatable captures/drills; optional user dogfooding supplements them, not replaces them.

**Gate:** reproducible visual evidence and working live test lane, or an explicitly named environment blocker with the affected claims left unproven. No claim of parity from a compile-only UI test. Independent source work may continue behind unreleased surfaces, but missing live gates cannot be declared complete.

### Phase 1 — Repair the truth boundaries

**Modify:** `RuntimeLadder.swift`, `GuidePlan.swift`, `GuideEngine.swift`, `AXModels.swift`, `CuaDriverClient.swift`, `CuaGuideTreeReader.swift`, `CompositeActionVerifier.swift`, `ExecutionPlan.swift`, `ExecutableActionDecoding.swift`, `ActionPolicyTable.swift`, `TypedPlanning.swift`, `BackgroundTaskController.swift`, relevant package/app tests and evidence claims.

1. Replace Guide parsing with strict Codable/unknown-key rejection using the existing strict decoding conventions. Add explicit complete/blocked/needs-input decisions and migrate all GuidePlanner callers and doubles. Do not leave `nil` as a success shortcut.
2. Preserve observation identity and separate role/label/safe-value/sensitivity data. Validate actual driver capabilities using synthetic non-sensitive fields. Unknown security metadata stays unknown.
3. Make verification target-specific: unrelated window/title/text changes cannot complete a step. Declared postconditions take precedence; steps lacking an observable outcome remain awaiting user confirmation or report unverified, not silently verified.
4. Strengthen action read-back and capability admission. Scope generic GUI risk conservatively and stop advertising general GUI/shell reversibility. Preserve all existing approval floors; do not downgrade them when adding undo.
5. Align queue publication to its actual current workspace-only executor until Phase 4 widens it. Report unavailable background operation families before queue creation.
6. Fix demonstrated containment issues at shared file-read helpers if regression tests show symlink/path escape in verification. Use the descriptor-relative patterns already implemented in WorkspaceFileRuntime, not string prefix checks.

**Regression cases:** prose-wrapped JSON; unknown keys; malformed target cannot become verbal-only; one invalid map marker rejects map; limit/blocked result not completed; wrong click; unrelated label change; same expected text in another field; changed generation; protected/unknown-sensitive field; mismatched integration resource; unsupported background operation; unknown-effect GUI input cannot inherit a low-risk approval.

**Gate:** focused Guide/runtime/app suites pass and live target-specific Guide/Do evidence is honest. These fixes precede Watch & Learn, handoff, or new verified-result copy.

### Phase 2 — Original glass identity and a single spatial surface

**Modify:** `PerrySpriteView.swift`, `OverlayWindow.swift`, `PerryTypes.swift`, `GuidanceModels.swift`, `PerryTheme.swift`, `SessionPanelView.swift`, `GuideControlsWindow.swift`, `AgentActivityStrip.swift`, `IntentCardWindow.swift`, `DESIGN.md`, `DebugStateFixtures.swift`, related UI/overlay tests.

1. Use the existing DEBUG prototype surface to compare two original native shapes: a faceted pointer and a softer lens-pointer. Select the faceted pointer unless rendered legibility shows a defect; selection criteria are distinction from OS cursor, legibility on light/dark/busy content, and clear preview/acting states—not novelty alone.
2. Replace animal rendering and running/waving/jumping behavior with the semantic glass states. Migrate callers, then remove unused pose machinery. Do not retain a new appearance picker or dead alternate identity.
3. Separate decorative pass-through marks from interactive caption/controls. Keep one focused interaction surface; avoid panel + HUD + strip + modal all competing. Consequential approval remains the interrupting surface.
4. Preserve screen-relative geometry and target-window anchoring. Position callouts to avoid the target, text insertion point, screen edges, menu bar, Dock, and notch safe areas. Reanchor on window movement; discard on loss of identity.
5. Stop the always-running sprite timeline when idle/hidden. Pointer following must not enqueue animations on every input tick. Use interruptible travel only when changing target; direct tracking follows the real pointer without visible elastic lag.
6. Use semantic typography/spacing, static state labels, native focus, and existing sounds sparingly. No forced greeting on every invocation.

**Tests/drill:** each state at 1x/2x, light/dark/busy backgrounds; reduced motion/transparency/contrast; multiple displays with negative origins; moving target window; Space/fullscreen changes; clipping; pointer pass-through; keyboard control alternatives; no offscreen animation work.

**Gate:** canonical screenshots plus recorded motion and real frame measurements. No OS cursor theft, unreadable glass, stale floating marks, or focus loss.

### Phase 3 — Spatial Ask and session continuity

**New:** `Packages/PerryGuide/Sources/PerryGuide/SpatialAnswer.swift`, `App/AskSessionController.swift`, focused tests at the corresponding package/app boundaries.

**Modify:** `SessionController.swift`, `SessionPanelView.swift`, `AppController.swift`, `VoiceController.swift`, `RuntimeCatalog.swift`, `DirectProviderClient.swift` only if the shared transport needs bounded cancellation support, `GuideSessionCoordinator.swift`, `EnvironmentProbe.swift`, spatial/overlay presentation, history/finalization, debug fixtures.

1. Add Ask state and mode routing. Default new sessions to Ask. Preserve explicit user selection; require a visible mode transition before any Do request.
2. Capture the pre-invocation target rather than accidentally reading Perry's own panel. Resolve explicit point/circle selections and expose a keyboard-accessible list of available references.
3. Implement strict SpatialAnswer decoding and purpose-aware reference validation. Ask can reference read-only elements; no executor is injected.
4. Preserve up to eight bounded turns and current semantic references. Re-observe on follow-up, drop stale callouts, and ask when “that” is ambiguous. Explicit “new session” discards transient context.
5. Route through the configured user-owned reasoning provider. If no capable provider is available, offer literal visible-label information or setup, clearly distinguished from reasoning. Do not present the lexical Guide fallback as a general answerer.
6. Present text as soon as safely available; only publish callouts after the complete structured response validates. Do not build a new multi-provider streaming layer merely for a typing animation. Measure the current transport before adding streaming.
7. Preserve draft on failure; let Esc dismiss, hotkey reopen, and one Cancel stop provider work. Keep transcript storage consistent with existing retention/erasure controls and disclose cloud transmission accurately.

**Tests:** Ask cannot reach router even with malicious response; valid read-only reference; invalid IDs/bounds; protected target; target change during provider response; cancelled response cannot paint; repeated follow-up memory bound; no-provider path; offline retry preserves input; explicit Do intent cannot run while Ask remains selected.

**Gate:** in a real app, point → question → relevant anchored answer → follow-up → Guide works without re-entering context. No action occurs in Ask.

### Phase 4 — Durable outcome receipts and safe continuation

**New, where the boundary requires it:** `Packages/PerryRuntimes/Sources/PerryRuntimes/ActionExecutionReceipt.swift`, `ActionPerformer.swift`.

**Modify/migrate:** `WorkspaceActionJournal.swift`, `WorkspaceExecutionJournal.swift`, `TaskCoordinator.swift`, `TaskPlan.swift`, `ResumableTaskRunner.swift`, `DoSupervisor.swift`, `TypedActionRouter.swift`, `WorkspaceFileRuntime.swift`, `ForegroundTaskController.swift`, `BackgroundTaskController.swift`, `SessionController.swift`, erasure/history, journal/compatibility tests. Rename the journal files to operation-neutral names only while migrating their real callers; keep one authoritative journal.

1. Add strict operation-specific outcome payloads and richer file identity/fingerprint evidence. No model may author a verified receipt or inverse.
2. Version the task envelope and decode older records conservatively. Preserve readable legacy history; missing evidence means non-undoable/non-authorizing. Add upgrade and unsupported-downgrade tests.
3. Consolidate the prepared/dispatched/verified persistence ordering through the shared ActionPerformer. Foreground and background execution consume the same write-ahead semantics without replacing their scheduling/interaction owners.
4. Wire the exact app-owned router capabilities into background admission, extending beyond transforms only as each family gains durable outcome and recovery tests. Unknown in-flight remote/GUI work remains blocked after relaunch; read-back may reconcile effects but cannot imply retry authorization.
5. Support bounded plan revisions after UI-changing segments with fresh observation, renewed resources, and grant invalidation. Add revision lineage, not a second copy of the plan in UI state.
6. Make partial success visible: completed verified effects, unknown effects, and pending actions are distinct. Cleanup cannot delete workspaces containing user-visible results or live undo dependencies.

**Tests:** crash before prepare/after prepare/after dispatch/after verify; disk full; cancelled verification; record-write failure; old envelope decode; backup fallback; changed plan digest; duplicate grants/attempts; two tasks on same resource; no double dispatch; no completion notification until durable outcome; foreground/background same semantics.

**Gate:** exact receipt chain survives relaunch; uncertainty blocks replay; both execution paths use the same effect-ordering boundary. This phase is the foundation for trustworthy handoff and undo, not an optional infrastructure detour.

### Phase 5 — Ghost Rehearsal

**New:** `Packages/PerryGuide/Sources/PerryGuide/Rehearsal.swift` for pure projection/binding; no executor methods.

**Modify:** `ForegroundTaskController.swift`, `SessionController.swift`, `AgentActivityStrip.swift`, `IntentCardWindow.swift`, `GuidanceModels.swift`, `OverlayWindow.swift`, `BackgroundTasksWindow.swift`, fixtures and focused tests.

1. Project an admitted typed plan into visible target marks, file/integration changes, and explicitly ungrounded future outline entries.
2. Add step-through/replay/edit/cancel controls, usable by keyboard. Keep the real OS pointer unmoved. Mask sensitive payloads; exact authorized details remain inspectable in the appropriate approval card.
3. Bind review to plan digest and current observation. On changed geometry, re-observe/reposition only if semantic target identity remains established; on changed content/target/plan, invalidate and review again.
4. Start execution only through existing action grants and the cancel window. Per-action orange/red confirmation remains distinct from viewing the plan.
5. During continuation, preview newly grounded segments rather than pretending the initial preview predicted later screens.

**Tests:** preview executor spy sees zero calls; hidden controls have no coordinates; edited payload invalidates review; stale window/observation blocks Run; Stop clears marks and provider work; repeat preview does not repeat actions; reduced-motion preview has the same information.

**Gate:** user can explain the next change and its target before running it. What is executed matches the reviewed revision.

### Phase 6 — Shared-control handoff

**Modify:** `DoSupervisor.swift`, `GuideEngine.swift`, `GuidePlan.swift`, `SessionController.swift`, `GuideSessionCoordinator.swift`, `ForegroundTaskController.swift`, `VoiceController.swift`, Guide HUD/activity strip, journal and lifecycle tests.

1. Add boundary-yield support and typed handoff states: requesting, settling, human-controlled, replanning, blocked. Only the active owner can authorize the transition.
2. Guide → Do uses original goal + verified human progress + current observation to form a fresh typed action/plan. Never translate a plain instruction directly into an executable click.
3. Do → human waits for durable settled outcome, invalidates unused grants, removes action cursor, then presents the next human instruction. “I'll do this step” is immediately acknowledged even when waiting for a safe boundary.
4. Human completion uses target-specific verification. Deviations become changed context, not an error loop demanding the original click sequence.
5. Return to Do re-observes and replans, retaining one session/history narrative. New approval is required wherever scope changes. Preserve previous verified receipts; no replay of completed effects.
6. Ensure stop, erase, sleep, window closure, provider failure, and replacement invocation cancel or settle all transition tasks consistently.

**Tests:** handoff at idle boundary, during execution, during verification, during orange/red approval, and during provider planning; late callbacks; double request; wrong human action; unexpected app change; partial uncertain action; resource reuse only after ownership release.

**Gate:** a real three-step workflow changes controller twice without restart, duplicated work, or lost evidence. UI always tells the user who currently controls the task.

### Phase 7 — Watch & Learn, safely

**New:** `App/DemonstrationRecorder.swift`, `Packages/PerryGuide/Sources/PerryGuide/LearnedRoutine.swift`, focused recorder/document tests.

**Modify:** `ClickAdvanceObserver.swift` only for shared click-event needs, Cua observation/sensitivity boundary, `AppSkillLibrary.swift`, `SessionController.swift`, `SessionPanelView.swift`, `SettingsView.swift` or a cohesive `RoutinesWindow.swift`, privacy/erasure and fixtures.

1. Start through an explicit consent surface stating selected application/window, observed data, provider transmission, no keyboard recording, and local draft retention. Recording cannot start in protected windows.
2. Use click events plus bounded AX-only sampling (maximum two reads per second, coalesced, no overlapping reads) while the chosen target is active. Record semantic before/after differences and outcomes; do not record raw key events. No idle monitoring or automatic resume after relaunch.
3. Pause on target change, permission loss, secure/unknown input, or unsupported driver metadata. Unknown values become required user-supplied parameters; do not store a placeholder that secretly contains the original text.
4. On Stop, build a draft from the bounded safe observations using the existing provider client. Provider synthesis returns only the strict routine data; no tools or side effects. With no provider, retain an editable local outline.
5. Review shows omitted/manual steps, named parameters, literals, and outcome conditions. Save only after explicit review. Distinguish Recorded, Reviewed, and Tested; no exaggerated “learned forever” status.
6. Cancel discards raw observations. Erasure covers saved routines, local test badges/provenance, drafts, and any temporary metadata. Diagnostics remain counts/timings only.

**Tests:** start/stop/pause cleanup; no installed key monitor; secure and unknown fields never enter draft/model transport/disk; protected app switch; bounded sampling/memory; network failure retains safe draft; synthesis prompt injection cannot create authority; malformed import/oversize/traversal; erase during recording; interrupted session does not resume monitoring.

**Gate:** show a small safe task once, review an accurate parameterized draft, and save it without retaining raw screen history or sensitive field values.

### Phase 8 — Replay routines and implement honest Undo

**New:** `Packages/PerryGuide/Sources/PerryGuide/UndoPlanner.swift` as deterministic receipt-to-inverse planning, not an LLM; focused undo tests. Add a narrowly scoped `App/UndoController.swift` only if foreground/history orchestration cannot remain coherent in the existing foreground owner.

**Modify:** `AppSkillLibrary.swift`, routine editor/library, `RuntimeLadder.swift`, runtime planning context, `ExecutionPlan.swift`, `ExecutableActionDecoding.swift`, `ActionPolicyTable.swift`, `WorkspaceFileRuntime.swift`, `TypedActionRouter.swift`, verifier, journals, `HistoryWindow.swift`, activity strip, erasure and fixtures.

1. Add My Routines list with search, inspect/edit, duplicate, import/export, delete, and Run/Guide. Reuse native list/forms; no community catalog. Plain app skills continue to load unchanged.
2. Routine run collects validated parameters, binds current app/workspace, and plans against live observations. Reuse Ask clarification, Guide handoff, rehearsal, and the normal execution gates. Unresolved/ambiguous locators stop for input.
3. Test a routine against changed filenames and window geometry. Only a verified current-revision run earns a local Tested badge with app/build/date; one pass is not a universal compatibility claim.
4. Add typed receipt-derived inverses for rename, exact Trash restore, unchanged created file, and empty created directory. Internal restore references bind to the original receipt; external planner JSON cannot forge a trash-entry capability.
5. Authorize selected filesystem scope explicitly. The current generated `PerryDemo/<UUID>` workspace is not authority over arbitrary user folders; add a visible native folder-picker/workspace binding for user-requested file work. Undo inherits the authorized root, never broadens it.
6. Check identity, expected content, destinations, empty-directory condition, same-volume constraint, and symlink-safe containment immediately before inverse dispatch. No overwrite-on-conflict and no broad directory snapshot rollback.
7. Undo processes a contiguous reverse-order suffix up to a non-undoable/dependency barrier. Do not invent a dependency graph to skip unsafe intermediate steps. Show partial scope explicitly before running.
8. Persist inverse prepared/dispatched/verified state and link it to the original receipt. Double-click/late callback/relaunch cannot apply the inverse twice. Re-do is a new reviewed task, not automatic authority restoration.
9. Result/history exposes available, partial, conflicted, unavailable, in-progress, and completed recovery. No disappearing toast as the only Undo entry point. Keep content in Trash recoverable; do not empty Trash as cleanup.

**Tests:** rename round trip; occupied original path; changed file bytes; replaced inode; new directory child; moved/deleted trash entry; cross-volume refusal; symlink replacement; interrupted inverse; disk full; double Undo; uncertain original action; partial reverse barrier; user-performed action; forged receipt; old receipt lacking identity; erasure closes pending recovery without replay.

**Gate:** taught routine replays with a different parameter and moved window using fresh targets; a supported file task reverses safely after relaunch; conflict leaves all user changes untouched. Integration/GUI/shell records honestly show no inverse.

### Phase 9 — Whole-product polish and everyday reliability

**Modify:** existing voice/dictation/audio/input files, onboarding/demo, settings/runtime/integration rows, history/background surfaces, theme/overlay, diagnostics, skills resources only when independently authored and verified.

1. Make onboarding's first result an actual spatial Ask or Guide interaction, then a safe preview/Do/Undo in an isolated demo workspace. Offer Teach Perry after value, not another mandatory step. Memory/wake remain opt-in and skippable.
2. Voice follows the same session/mode/control contracts as typing. Barge-in stops speech, not silently approving or repeating a task. Preserve transcript/draft on permission, route, or network failures.
3. Run built-in/external/Bluetooth route changes, muted output, denied mic, disconnect/reconnect, non-English dictation, terminal-safe insertion, layout-safe paste, and long-session endurance. Fix measured failures at the existing owning boundaries.
4. Every failed/partial task says what changed, what is uncertain, and one safe next action. A Retry must create a new observed plan, not replay a dispatched step.
5. History becomes a useful outcome surface: request, selected target/provider route, human/Perry contributions, verified changes, recovery availability, and linked routine—not an unbounded model transcript dashboard.
6. Runtimes/integrations expose actual capability/authentication/health. Never call local storage private from the provider: selected screen/text/audio may leave the Mac for user-configured services.
7. Keep auth credentials in Keychain; no new telemetry. Repair stale capability/audit/design/PRD wording, including actual background scope and reversal limits.
8. Skills improve incrementally from observed failures. Each new resource declares assumptions and has one reproducible app journey; no app-specific Swift behavior or bulk-generated content.

**Gate:** primary journey completes using only keyboard, only typing with voice disabled, and VoiceOver. Test large text, narrow panels, long content, all appearance accessibility modes, offline recovery, app/window changes, sleep/wake, and complete erasure/relaunch.

### Phase 10 — Conditional notch status placement

This is a bounded late experiment, not a required innovation pillar.

1. Compare existing menu-bar/task-strip status with an optional compact top-center status placement for background count, awaiting approval, and recording indicator. It must consume existing state; no second task manager.
2. Use public NSScreen safe-area information with runtime availability checks. Work identically on non-notched/external displays with the standard status surface. Do not create hover-only actions or put controls behind the physical cutout.
3. Keep approval, text entry, and primary Ask/Guide/Do on the spatial surface. No notch expansion animations on routine events or duplication of permanent chrome.
4. Retain this placement only if it demonstrably reduces obstruction and passes fullscreen/Spaces/multiple-display/accessibility tests. Otherwise keep menu bar + compact strip and record that the experiment was evaluated. User openness is not a mandate to ship a notch feature.

**Gate:** useful status without hiding the workspace or creating a hardware dependency. No core release is blocked on this experiment.

### Phase 11 — Product proof and release candidate

**Modify:** product journeys, registry, `.audit` ledger, support/capabilities/demo/follower documents, existing release metadata/scripts only where affected by the actual product.

1. Run one final full deterministic suite, then all live journeys for the exact candidate. Record build/commit, OS/device, provider/model, relevant app version, and result.
2. Produce the connected signature demonstration through production paths, not debug fixture state. It may consist of linked truthful segments where routine/Undo scope differs; never splice a fake general capability into a one-take claim.
3. Validate macOS 14, 15, 26, and 27, including the material fallback. Unsupported/unavailable hosts remain named gaps rather than inferred passes.
4. Execute privacy/erasure, crash recovery, update migration, and stored-approval invalidation tests. New routine/journal schemas participate in rollback safety.
5. Keep signing/notarization/Sparkle credentials as a separate release lane. No publishing without explicit authorization. UI evidence should not be held hostage to distribution credentials.
6. Ship a candidate and concise known-limits test card. Triage trust/data loss first, then primary flow/accessibility, then recovery/latency, then cosmetic polish. Every reproducible primary-flow defect gets a regression at its owner.

**Gate:** no known trust bypass, destructive replay, false verification, data loss, or severe accessibility defect. Every advertised primitive has live evidence on its supported scope. Missing evidence is displayed, not hidden behind the phrase code-complete.

## 7. Acceptance journeys and quality bar

Add these to the existing `docs/release-readiness/product-journeys.v1.json` with explicit versioning rather than creating a competitor benchmark framework.

| Journey | Required observable outcome |
|---|---|
| Point and ask | Correct current object referenced; concise useful answer; no computer-input calls |
| Contextual follow-up | Refers to prior object without retyping; ambiguity asks; moved/closed target removes stale ink |
| Explain → guide → act | One session, preserved goal, explicit control changes, current targets and renewed grants |
| Ghost rehearsal | Zero side effects before Run; hidden future controls not spatially fabricated; changed plan invalidates preview |
| Human takes over | No new dispatch after acknowledged yield; human result independently checked; no repeated effect |
| Teach and replay | Explicit recording only; reviewed parameterized routine; second run uses new data and geometry |
| Conflict-safe Undo | Supported changes reverse after relaunch; conflicting user edits remain untouched |
| Mixed outcome | Non-undoable or uncertain changes are named; partial success is not total success |
| Real-world failure | Permission loss, provider disconnect, window close, disk full, and cancelled approval recover without lost draft or silent replay |
| Accessible equivalent | All spatial/voice actions have keyboard/control alternatives; target/state understandable without animation |

For release evidence, run each deterministic new journey three times consecutively on the candidate and each applicable live journey at least once on a native app and one browser/Electron surface. Include an AX-poor creative application as an explicit supported/fallback/blocked result; do not imply it is supported just because pixels are available. Freeze actual app versions and fixtures during Phase 0. Safety invariants require zero failures; task-quality outcomes retain individual results rather than a hand-wavy average.

### Existing budgets to preserve

- Input feedback p95 ≤50 ms; usable hotkey panel p95 ≤100 ms.
- Overlay first frame p95 ≤200 ms; active 60 Hz frame interval p95 ≤16.7 ms.
- Main-thread stall p100 ≤100 ms; cooperative worker cancellation p100 ≤500 ms.
- Idle CPU p95 <1% with ambient wake disabled.
- Dictation speech-end-to-insert p50 ≤450 ms, p95 ≤900 ms.
- Voice barge-in p95 ≤150 ms; realtime first audio p50 ≤1,200 ms under declared network conditions.
- Voice-session memory growth ≤5% after the existing endurance interval.
- Existing capture/action budgets and ≤10% regression rule remain in force.

Cursor/UI changes must be measured at the rendered surface. `OverlayPerfProbe` currently samples tick/main-hop timing; do not label those samples actual presented-frame latency. Extend the existing instrumentation or use native frame analysis to measure the claimed phenomenon.

New local budgets: acknowledge handoff/record/preview controls within 100 ms; paint an already validated answer/rehearsal within the existing 200 ms overlay budget; stop recording admission immediately on Stop. Provider reasoning latency is recorded separately from local UI latency, not promised as subsecond. Record p50/p95 per declared provider/model/network with sample counts and errors; never improve a chart by dropping failed requests. No “fast” badge without matching evidence.

## 8. Verification commands and test routing

Commands below are for implementation, not to be run during this planning-only session. Workdir is the repository root. Reuse installed pinned tools and existing build processes; do not refetch or restart unnecessarily.

### Setup, only if required by the existing environment

```sh
./scripts/fetch-xcodegen.sh --fetch
./scripts/fetch-codex-runtime.sh --fetch
./scripts/fetch-cua-driver.sh --fetch
build/tools/xcodegen/bin/xcodegen generate --spec project.yml
```

Never hand-edit the generated Xcode project. No new dependency is expected.

### Focused iteration

```sh
swift test --package-path Packages/PerryGuide --filter RuntimeLadderTests
swift test --package-path Packages/PerryGuide --filter GuideEngineTests
swift test --package-path Packages/PerryGuide --filter AppSkillLibraryTests
xcodebuild test -project Perry.xcodeproj -scheme Perry -configuration Debug -destination 'platform=macOS,arch=arm64' -only-testing:PerryTests/CompositeActionVerifierTests CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

For new suites use stable names `SpatialAnswerTests`, `RehearsalTests`, `LearnedRoutineTests`, `UndoPlannerTests`, `ActionExecutionReceiptTests`, and app `DemonstrationRecorderTests` / `SharedControlTests`; invoke the same package `--filter` or `-only-testing:PerryTests/<suite>` pattern. Run the smallest owner suites that cover each slice, plus changed callers. Expected: new behavioral test fails before implementation for the intended reason, then passes; no unexpected skips.

### GUI/live lane

```sh
xcodebuild test -project Perry.xcodeproj -scheme PerryUI -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
xcodebuild test -project Perry.xcodeproj -scheme PerryCuaLive -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

These require a functioning GUI/TCC host. If local test signing/bootstrap needs project/environment changes, obtain approval and fix the runner correctly; do not bypass controls. `build-for-testing` is not a test pass, and a skipped Cua test does not satisfy the live gate.

### One final complete gate

```sh
swift test --package-path Packages/PerryCore
swift test --package-path Packages/PerryRuntimes
swift test --package-path Packages/PerryOverlay
swift test --package-path Packages/PerryCapture
swift test --package-path Packages/PerryGuide
xcodebuild test -project Perry.xcodeproj -scheme Perry -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
./scripts/test-release-automation.sh
./scripts/generate-release-metadata.sh --check
./scripts/verify-artifact-manifest.sh --check
./scripts/validate-release-evidence.sh
./scripts/performance/self-test.sh
./scripts/verify-release.sh
git diff --check
```

Expected: exit 0, no new warnings in touched code, no unexplained skips, consistent evidence registry. Performance self-tests validate the harness only; real-device captures and budget evaluation remain separate required artifacts. Keep screenshots and raw account/app data out of diagnostics and source commits.

## 9. Files and scope boundaries

Primary existing app surfaces: `App/{AppController,SessionController,SessionPanelView,GuideSessionCoordinator,GuideControlsWindow,ForegroundTaskController,BackgroundTaskController,AgentActivityStrip,IntentCardWindow,HistoryWindow,BackgroundTasksWindow,OnboardingWindow,DemoDirector,DemoRecipe,SettingsView,PerryTheme,DebugStateFixtures}.swift`.

Observation/control: `App/{CuaDriverClient,CuaGuideTreeReader,CuaWorkerService,EnvironmentProbe,ClickAdvanceObserver,SpatialInputMonitor,TypedActionRouter,CompositeActionVerifier}.swift`.

Guide and routines: `Packages/PerryGuide/Sources/PerryGuide/{AXModels,GuidePlan,GuideEngine,RuntimeLadder,AppSkillLibrary,TaskCoordinator,TaskPlan,ResumableTaskRunner,WorkspaceActionJournal,WorkspaceExecutionJournal}.swift` plus new narrowly named contracts listed in phases.

Execution: `Packages/PerryRuntimes/Sources/PerryRuntimes/{ExecutionPlan,ExecutableActionDecoding,ActionPolicyTable,TypedPlanning,DoSupervisor,WorkspaceFileRuntime,DirectProviderClient,RuntimePlanningPrompt}.swift` and shared receipt/performance boundary only where justified.

Overlay: `Packages/PerryOverlay/Sources/PerryOverlay/{PerrySpriteView,PerryTypes,GuidanceModels,OverlayWindow}.swift`.

Privacy/release: existing erasure owners, `App/DiagnosticsReporter.swift`, `App/PrivacyInfo.xcprivacy` if actual declarations change, `PRD.md`, `DESIGN.md`, existing capability/support/audit/tone/demo documents, journey/evidence/performance manifests, `AppTests`, `AppUITests`, package tests. Update existing documentation; do not create a parallel documentation tree for each feature.

Out of scope: hosted/cloud services, marketplace/social discovery, proactive desktop watching, general-purpose event recording, automatic remote connector expansion, generic MCP plugin execution, arbitrary filesystem authority, full future-screen simulation, universal undo, new appearance themes, an autonomous app-specific script library, and an architecture rewrite for its own sake.

## 10. Risks, boundaries, and stop conditions

- **Model quality:** a compelling demo cannot substitute for general task reliability. Keep outcomes grounded, explicit limitations, and provider-specific evidence. Routine generalization remains a proposal until tested.
- **AX limitations:** no secure-value inference from missing metadata. If the pinned driver cannot supply the required safe observation contract, retain manual parameter entry and pause automatic recording of those fields. Any driver upgrade needs a separately reviewed pin/contract change.
- **Dynamic UI:** stale tokens/coordinates never survive as executable routine authority. Hidden screens require re-observation, not interpolation.
- **GUI semantic risk:** a click may send or delete. Conservative action review and blocked-window policy are required; a keyword heuristic cannot prove safety.
- **Undo precision:** supported inverses are narrow by design. Cross-volume restores, modified objects, and unverified effects stop with a conflict explanation; no broad snapshots or destructive overwrite shortcuts.
- **Concurrency:** one foreground controller owns the screen interaction. Background jobs cannot acquire conflicting application/workspace/account claims. Handoff and undo participate in the same resource system.
- **Persistence:** journal migration is the highest-risk phase. Keep old records inspectable, migration tested, prepared/dispatched distinctions intact, and legacy authority disabled. No deletion of user stores to make tests green.
- **Visual performance:** glass must not require continuous screen reads or idle GPU work. If it fails native budgets, simplify the effect rather than add a rendering engine.
- **External blockers:** after two materially different runner-repair attempts, report the exact blocker and continue only on independent work. Authentication/permissions/signing require user assistance; never log credentials.
- **Scope pressure:** no new primitives are added until these approved ones work together. Notch placement and skill breadth cannot delay the main path.
- **Destructive development operations:** planned functionality does not authorize deleting real user files, resetting the dirty worktree, overwriting data, or publishing. Test inverses in synthetic isolated workspaces. Obtain specific approval for any irreversible development action.

## 11. Definition of done

The result is not done because every phase has code. It is done when:

1. A user can point, ask, follow up, guide, rehearse, and hand off within one understandable session.
2. The original glass cursor is readable, responsive, non-obstructive, and unmistakably distinct from the OS pointer, without mascot walking or ambient monitoring.
3. A reviewed demonstrated routine replays with changed inputs and fresh grounding; unsupported steps are explicit.
4. Supported changes can be undone after relaunch without overwriting intervening user work; unsupported inverses are never advertised.
5. Every executed effect has the correct approval, identity, durable outcome, and verification, or is reported as uncertain without replay.
6. Existing performance/accessibility/privacy gates and the new live acceptance journeys pass for the declared environment.
7. The local commit checkpoints, evidence registry, product copy, and actual implementation agree. Signing/publishing gaps are separate and plainly recorded.

**The product should feel extraordinary because it understands the object you mean, keeps your place, and makes control tangible—not because it claims unlimited autonomy or fills the screen with effects.**
