# Perry: living ink

## Direction and evidence

Perry is a small, expressive ink companion that helps inside the Mac you already use. The approved direction combines **Perry redraws the window** and **Drawn to life**: handwriting becomes a character, and the character helps form the interface. References: `docs/design/2026-10-01-onboarding-concepts/10-redraw-the-window.png` and `09-drawn-to-life.png`.

This is the target product contract, not a claim that the existing app already implements it. The current approved references are `docs/design/notch-only/refined/workspace-v3.png`, `cursor-feedback.png`, `results-approval.png`, and `routines-settings.png`. Migration and verification live in `docs/plans/2026-10-02-approved-notch-rebuild.md`. Codex owns design decisions and review; Devin SWE-2 Max implements bounded specifications.

Hey Clicky provides interaction evidence: a focused welcome, an introduction, a transition into the notch, contextual permissions, and a small companion beside the normal pointer. Its Home exists but does not lead every interaction. Perry uses original artwork and its own expression.

## Surface hierarchy

1. **Notch is home base.** The opaque black surface grows directly from the top edge and incorporates the camera exclusion area. It must never appear as a detached card beneath the notch. On displays without a notch, use the same top-edge anchored surface. Do not hide functionality on external displays.
2. **The pointer stays yours.** A 20–24 pt ink companion may appear beside it during an active spatial interaction. Idle has no follower. No oversized glass pointer, persistent orbit, glow or animation loop. Contextual guide marks disappear when their target or session ends.
3. **The workspace expands inside the notch.** A compact left rail holds saved Perrys and recent conversations. The main resting surface centers the companion and voice action; Tasks, Routines and Files remain easy to reach. There is no standalone Home window or Perry status-bar item. Typing is a secondary option; existing drafts remain recoverable.
4. **Approvals remain explicit.** Notch status can announce that review is needed; full consequences, scope and Approve/Stop remain readable in an appropriately sized review surface. Red-tier confirmation and recovery behavior must survive the redesign.
5. **Settings stay inside the notch.** Use native grouped controls, horizontal section navigation, understandable labels and inline recovery. Technical routing belongs here rather than in the welcome.

## Visual language

The approved product uses dark surfaces: a black crown and perimeter, near-black content, and warm ivory ink. Light theme tokens remain available for existing components but are not the active presentation direction. Hand-drawn texture belongs to the character, welcome lettering and a few purposeful guide strokes. Body text and controls remain precise and native. Never rasterize buttons or body copy into illustrations.

Target semantic palette, to be implemented in `PerryTheme` and the overlay theme:

| Role | Light | Dark |
| --- | --- | --- |
| canvas | #F5F3EE | #0C0D0E |
| surface | #FFFEFA | #18191B |
| primary ink | #202420 | #F3F0E8 |
| secondary ink | #666D66 | #AAA9A5 |
| subtle separator | #DCDDD5 | #3A403B |
| primary action | #202420 | #EDEEE4 |
| on primary | #FFFEFA | #202420 |
| guiding accent | #3C7765 | #9CCBB6 |


These are design targets, not measured accessibility results. Verify rendered contrast before acceptance. System status colors retain semantic meaning; warning and destructive colors are never decoration. Increase Contrast strengthens edges; Reduce Transparency uses solid surfaces.

Typography: SF Pro for all functional copy, 13–15 pt body, 11–12 pt metadata, 20–28 pt surface headings. Rounded type is reserved for short friendly headings. Custom brush lettering is artwork used in the first welcome, not a font applied to every label. Dynamic text must wrap and remain usable at larger text sizes.

Spacing: 4/8/12/16/24/32/48 pt. Controls use 8–12 pt radii; panels 20–24 pt; primary welcome actions may be capsules. One clear filled action per surface. Avoid nested card borders, oversized empty composers, repeated dividers and multiple equally prominent setup buttons.

## Character and art

The character has an imperfect ink outline, simple round head, two small eyes and a readable pose. Its identity comes from gesture, not costumes or a settings gallery. It draws a line, peeks from an edge, listens, points and settles. Small versions simplify detail rather than shrinking a dense illustration. The welcome stroke becomes the character; later appearances recall that origin.

Produce separate artwork assets for the welcome lettering and character, preserving alpha and adequate resolution. Keep text, actions and focus indicators native. Avoid shipping a full concept screenshot as the UI. Use light/dark-aware ink treatment; do not invert embedded paper backgrounds.

## First-run experience

The first-run welcome appears inside the notch. Start with the approved ivory hello artwork, one sentence and **Let’s begin**. Clicking or Return starts the introduction; no automatic microphone recording or speech on launch.

Introduce where Perry lives with a short, skippable visual transition into the notch. Reduced Motion uses a cross-fade and the same explanatory text. Connect an account with one recommended action and an Other models link. Preserve pending, cancellation, error and retry states without discarding input.

Ask for screen access at the moment the user chooses help in other apps. Explain Accessibility and Screen Recording separately, show their actual status, and offer a useful typed path without permission. Microphone access follows an explicit voice action. Never fire several system permission prompts merely by entering a page.

Practice demonstrates one small action at a time with sample content and a visible skip. Back, dismiss and relaunch preserve coherent progress. Completion settles into the notch rather than opening an unrelated dashboard.

## Interaction and motion

The first welcome may draw itself once. Subsequent invocations are fast: feedback within 100–150 ms, panel arrival around 180–240 ms, shorter dismissal. Move the same character between surfaces to establish continuity. Do not replay onboarding spectacle in everyday use.

Idle is still. Listening, thinking, acting and awaiting approval have distinct labels or shapes; motion is supplemental. Escape dismisses or cancels according to the current operation without silently approving anything. Keyboard focus is visible and initial focus is intentional. Mouse passage across the notch must not unexpectedly steal keyboard focus.

Tasks expose Stop while running, a specific recovery action on failure and an honest completed or unverified result. Listening uses three bars beside the cursor. Working uses a short progress capsule with Stop; results can open in the notch. Long replies remain readable in the notch workspace. Background work remains discoverable when the active surface closes.

## Removal list

Remove the faceted glass cursor identity, permanent oversized follower, decorative state rings, automatic spoken first-run narration, stacked permission requests, onboarding inside the history shell, repeated model-configuration prose in the composer, duplicate Settings navigation, and primary actions competing with one another. Preserve backend capabilities, data, permission boundaries, trust checks and recovery paths.

## Acceptance

Look at and operate the real app in the approved dark appearance. Verify welcome, setup, denied permissions, voice initiation, optional typing, notch expansion, no-notch fallback, guide target, running task, approval, failure, completion, expanded workspace, settings and relaunch. Inspect actual frames for clipping, texture, typography and character scale. Unit tests do not prove visual quality; generated concepts do not prove motion quality. Build, relevant behavioral tests, visual evidence and code review must all pass before this contract is considered implemented.
