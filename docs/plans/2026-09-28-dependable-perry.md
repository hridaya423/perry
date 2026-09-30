# Perry: dependable Mac companion

Approved implementation contract, 2026-09-28. Supersedes the execution sequence in Megaplan III; preserves its full product scope.

## Product

Deliver a private beta with public-release quality for everyday Mac users. Point at something, ask naturally, and continue through understanding, guidance, execution, and follow-up without starting over.

Retain Talk, spatial pointing and ink, Guide, Do, dictation, notch Home, persistent Perrys, routines, suggestions, and local models. ChatGPT sign-in is the default. BYOK and local models are advanced options. No managed inference, billing, marketplace, or new platform.

## Experience

Expressive mint living glass and warm companion language, built on native macOS behavior. Pointer, ink, compact composer, and notch carry the expressive materials and motion. Conversations, documents, and settings use calm readable surfaces. System typography and controls; rounded type for short companion captions. All surfaces support light/dark, Reduce Motion, Reduce Transparency, Increase Contrast, keyboard, and VoiceOver. Overlays must not obscure their targets.

Control–Option invokes Talk. Double-Control opens the typed composer. Show the referenced object, input, answer, and relevant next action. Guide/Do/takeover continue the same conversation and target context.

The notch shows activity and unread results. Hover reveals a compact summary; click or Control–Command–Space opens Home. Escape dismisses until the pointer leaves. One shared state drives these presentations.

Home opens with a composer and useful recent work, New Conversation, Perrys, suggestions, and searchable conversations. Routines belong to Perrys; files/results belong to originating conversations; task controls are inline. Attached below the notch by default, detachable/resizable, top-centre fallback without a notch. Preserve drafts, selection, scrolling, and geometry. One Settings destination.

First launch provides accessible setup, verified ChatGPT sign-in, contextual permissions, a real successful interaction, optional practice, and resumable progress. Do not depend on Accessibility before it is granted. Talk supports spatial references, streaming, interruption, and follow-up. Guide advances on observed completion and recovers from wrong clicks. Do previews consequential effects, supports steering/stopping, verifies outcomes, and offers only supported undo. Dictation preserves text and destination across interruptions. Perrys support creation, editing, pause, archive/restore, memory, schedules, and results. Routines expose waiting/running/failure/paused states without duplicate effects. Suggestions retain sources and genuinely support adjustment.

## Architecture

Retain native app and packages; consolidate incrementally. One execution owner accepts conversation/Perry identity, invocation source, request, and explicit context, emitting typed state, content, approval, effect, and outcome events. One active run per conversation, explicit steer or queued follow-up, one persistence owner. Per-run cancellation, worker ownership, approvals, cleanup. Stop prevents subsequent effects and preserves completed-effect evidence. Typed routines share action/result boundaries. AppController becomes composition/lifecycle/system entry points, without forwarding-wrapper proliferation.

Assemble bounded conversation history, Perry job, permitted memory, app skills, and fresh context. Screenshots remain transient; never capture Home as the task target or resend stale screenshots. Preserve older source turns with bounded context summaries. Explicit provider readiness and capability states; reusable providers/router health; no silent privacy-boundary fallback. Verify local-model feature capabilities.

Structured effect results identify action, target, outcome, verification evidence, and recovery/undo references. Reuse receipts/journals/verifiers. Run-bound observations/workers replace ambient foreground borrowing. Assess action risk by effect/target; native/MCP share policy. Bind approval to concrete actions and revalidate changed targets. Request takeover when background operation is impossible. Distinguish delivered, verified, partial, and unverified. Serialize conflicting resources only.

Retain local storage, add versioned records/migration backups. Save input/run identity before effects, checkpoint and persist outcomes, reconcile interrupted work before retry. Surface write failures while retaining text; preserve unreadable records. One presentation owner. Delete old paths only after replacement journeys pass.

## Milestones and gates

0. Baseline: preserve work, identify source/binary/account/permissions, run packages/app tests, UI/performance baseline and paired competitor fixtures. Record evidence and blockers.
1. Complete polished launch → sign-in → question → useful answer → contextual follow-up → reopen in Home. Include pointer/composer, Home default, readiness, context, persistence, cancellation, and native visual inspection.
2. Consolidate execution and prove rename/verify/undo; document/summary artifact/revision; destination-bound draft/approved send. Integration tests exercise production routing, interruption and recovery.
3. Finish Talk/spatial guidance/Guide, including moved targets, wrong clicks, ambiguous references, multiple windows/displays and Guide/Do handoff.
4. Finish dictation, Perrys, routines, suggestions, memory, results; verify existing Google/Notion/Slack/Linear connections, revocation and approved writes, and live local-model capability.
5. Profile Release including helpers; exercise provider/rate-limit/TCC/audio/storage/worker/sleep/shutdown failures; accessibility; structural review and remove stale paths/docs.
6. Signed/notarized installer, real updates/migration/export/erasure/diagnostics/support. Clean-account install without developer tools. Support first release without a prior release; rehearse update and feed withdrawal. 8–12 ordinary users, two weeks, repair critical failures before expansion. Publishing/pushing/account provisioning require separate authorization.

## Acceptance

At least 30 tasks across Finder, Preview, Notes, Mail, Safari/Chrome, and creative apps, three reset-fixture runs each. At least 90% supported-task success. Zero unapproved consequential actions, false verified success, or destructive retries. Failures preserve input and offer recovery. At least 80% beta participants complete setup/first useful task unassisted; at least 70% use Perry on three separate days in week two. No unresolved crash/data-loss/permission/cancellation defect.

Compare completion, total time, interventions, recovery, and usability with current HeyClicky on the same Mac. Report losses as well as wins; feature counts do not prove superiority.

Performance: invocation feedback ≤50 ms p95; pointer lag ≤1 display frame; barge-in silence ≤150 ms; notch response after intent ≤120 ms; dictation insertion ≤450 ms p50 modern/≤700 ms legacy; idle CPU ≤0.5%; Release main RSS ≤180 MB with helpers separately reported; 8-hour/200-interaction soak with settled growth <30 MB. Stop acknowledges immediately and dispatches no further effects. Substantive ChatGPT answers ≤4 s p50/≤8 s p95, separate from acknowledgement. Supported fast path target ≤700 ms p50.

Run affected packages, PerryTests, performance tests and release automation. Real app/lab UI verification; no hanging XCUITest gate. Inspect milestone screenshots/recordings across appearance, accessibility, long/empty/failed content and display configurations. Apple Silicon/macOS 14+ remains the target; require actual oldest/modern OS evidence before compatibility claims.

No unapproved dependencies, generated-project hand edits, clean builds, pushes, or broad rewrites. Update the progress ledger after each slice. A milestone is complete only when its built-app journey works.
