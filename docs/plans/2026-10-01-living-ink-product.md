# Living ink product implementation plan

## Goal

Apply the approved ink-character direction throughout Perry and make the notch the primary daily surface, while preserving useful capabilities and trustworthy execution.

## Ownership and baseline

Codex owns design, architecture choices, generated art, visual QA and final review. Devin CLI with `--model swe-2-max` performs bounded implementation only. Each delegation lists allowed files and exact behavior; Codex inspects the result before integration. No push, dependency additions, generated-project hand edits, clean builds or destructive data resets.

Baseline: branch `codex/living-ink-redesign`; existing unrelated evidence and .devin changes are preserved. The prior megaplan report is not evidence of this redesign. Progress for this objective is recorded separately in `.devin/ui-redesign/progress.md`.

## Work packages

### 1. Foundation and artwork

Files: `App/PerryTheme.swift`, new `App/PerryInkComponents.swift`, `App/Resources/`, `project.yml` only if resource registration needs it.

Implement the semantic palette from DESIGN.md, shared primary-action treatment and ink character presentation. Preserve existing token interfaces used by callers. No blanket replacement of semantic warning colors. Produce original transparent illustration assets from the approved concept; native text and controls remain separate. Codex compares the real rendering with the approved references.

Evidence: build, light/dark screenshots of welcome and a representative ordinary surface; contrast check for body text and actions; no full-screen raster UI.

### 2. Dedicated onboarding

Files: `App/Onboarding/OnboardingDirector.swift`, `App/Home/HomeOnboardingView.swift`, `App/AppController.swift`, new onboarding window/view as needed; existing onboarding tests.

Replace the banner embedded in Home with a dedicated welcome. Keep the director as progress owner. Welcome leads to a skippable introduction and clear account connection. Stop automatic spoken narration. Make permission requests explicit, separate and accurately reflected. Preserve skip, retry, back/resume, practice and completion. Move to notch after introduction and settle there after completion. Do not clear user progress or credentials to demonstrate it; use debug fixture paths.

Evidence: behavioral tests for progress and permission effects; actual welcome, connection, denial, skip, resume and completion screenshots and keyboard walkthrough.

### 3. Notch as the primary surface

Files: `App/NotchStatusController.swift`, `App/CompactConversationView.swift`, panel routing in `App/AppController.swift`, `App/Home/HomeController.swift` where required.

Trace invocation and session ownership before editing. Reuse the actual conversation model; do not create another transcript or agent state. Upgrade the passive status pill into a compact interactive entry and expand below the notch for typed interaction, listening and task status. Add equivalent top-centre behavior on displays without a notch. Keep Home available explicitly. Escape, focus, click-through areas and display changes must behave predictably. Retain dedicated high-stakes approval surfaces.

Evidence: geometry tests where useful; real invocation, typing, response, dismiss, reopen and background task flows. Capture notch and no-notch placement and confirm menu-bar controls remain reachable.

### 4. Small spatial companion

Files: `Packages/PerryOverlay/Sources/PerryOverlay/PerryGlassCursor.swift`, `PerryOverlay.swift`, `PerryTypes.swift`, `OverlayWindow.swift`, and cursor routing in `App/AppController.swift`.

Replace the faceted pointer with a readable 20–24 pt ink companion during active spatial use. Preserve the normal system cursor. Remove idle follower, giant pulse rings and decorative animation loops. Keep grounded marks, selection feedback, semantic failure/approval states and reduced-motion behavior. Inspect every explicit cursor size callsite rather than only changing the default.

Evidence: overlay behavioral tests; actual cursor and guide screenshots over light and dark apps; idle resource probe.

### 5. Home, conversations and ongoing work

Files: `App/Home/HomeView.swift`, `HomeConversationView.swift`, `HomeOnboardingView.swift`, `HomeModel.swift`, relevant task/files/routines views.

Make Home an intentional workspace, with a quiet character-led empty state and one compact composer. Remove setup prose from normal conversation flow, duplicate Settings labels and overly dominant repeated history rows. Preserve search, ongoing tasks, drafts, recovery, saved conversations, files and routines. Selected model status becomes a compact control leading to settings.

Evidence: empty/populated Home, long conversation, running/failed task, restored draft and settings navigation; light/dark visual review and keyboard flow.

### 6. Remaining product surfaces

Files: `App/SettingsView.swift`, `App/Brain/BrainModelSettingsView.swift`, `App/SessionPanelView.swift`, `App/AgentActivityStrip.swift`, `App/IntentCardWindow.swift`, `App/GuideControlsWindow.swift`, routine review, What's New and relevant Home detail views.

Apply shared typography, action hierarchy, surface colors and spacing. Keep dense settings native rather than illustrating every row. Simplify user-facing technical language without hiding actionable failures. Retain approval scope, typed red-tier confirmation, stopping, undo and unverified-result distinctions.

Evidence: surface inventory with representative screenshots and interaction checks; no remaining old pointer branding or duplicate competing primary actions on reviewed paths.

### 7. Review and verification

Regenerate with `build/tools/xcodegen/bin/xcodegen generate --spec project.yml`. Build with `xcodebuild build -project Perry.xcodeproj -scheme Perry -configuration Debug -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64'`.

Run affected package tests using `swift test --package-path Packages/<package>` and app tests supported by the repository. Do not gate on the known-hanging XCUITest runner. Use real app and supported computer-use tools for UI verification. Run `scripts/performance/self-test.sh` when performance tooling changes; run the existing idle probe after overlay/notch changes.

Codex performs code-deslop and thermo-nuclear structural review, fixes findings, then compares all explicit DESIGN.md acceptance items with current evidence. Document remaining blockers honestly. Do not mark the goal complete on a build alone.

## External skill source

https://design.how/skills.md lists design-system-boss, build-design-system, migrate-design-system, token-mapping, ui-review and component-docs, but directs users to an email signup for their content. Requested install source is pending from the user. Installed design-engineering/design-systems skills are being applied meanwhile; the unavailable six have not been claimed as used.

## Status

- [x] Approved concepts recorded and product design contract written.
- [x] Current surfaces and central routing inspected sufficiently to identify first work packages.
- [ ] Design.how skill contents obtained and applied.
- [ ] Shared visual foundation and illustration assets.
- [ ] Dedicated onboarding and deliberate permission flow.
- [ ] Notch-first invocation and no-notch fallback.
- [ ] Small active spatial companion.
- [ ] Home and remaining surface migration.
- [ ] Full behavioral, visual, accessibility and performance checks.
- [ ] Structural review and requirement-by-requirement completion audit.
