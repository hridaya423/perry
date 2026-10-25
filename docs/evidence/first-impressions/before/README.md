# Baseline renders (before the rework)

Rendered 2026-10-25 by the CI baseline run (commit 40ec19e) with `NotchSurfaceRenderTests`. Images are 2x; sizes below are in points. The white corners are the render background outside the notch shape, not part of the app. Numbers in brackets are complaint numbers from plan section 0.

| Image | Size (pt) | Defect seen |
|---|---|---|
| `notch/acp-agent.png` | 640 × 300 | Settings fragment. Dense developer copy ("read-only mode… refuses the agent's own requests") next to basics [9]. |
| `notch/acp-registry.png` | 640 × 320 | Settings fragment. Registry list with developer wording ("no checksum") [9]. |
| `notch/approval-long.png` | 592 × 414 | Card fills the top; about 120 pt of empty black below it [8]. |
| `notch/approval-short.png` | 592 × 350 | Same empty black band below a short card [8]. |
| `notch/conversation-narrow.png` | 720 × 500 | Full workspace with sidebar even at 720 pt [8, 10]. |
| `notch/conversation.png` | 892 × 552 | Full 892 × 552 workspace; sidebar takes a third of the width for one answer [8, 10]. |
| `notch/dialog-inline.png` | 500 × 126 | Fine. Plain alert. |
| `notch/dialog-ok-only.png` | 500 × 126 | Fine. Plain alert. |
| `notch/dialog-stacked.png` | 500 × 213 | Fine. Three full-width buttons. |
| `notch/failure-notice.png` | 592 × 420 | One-line notice in a 420 pt tall panel; the lower half is empty black [8]. |
| `notch/files.png` | 892 × 552 | Empty state inside the full workspace [10]. |
| `notch/guide-question.png` | 592 × 420 | Small card at the top, empty black below [8]. |
| `notch/guide-step.png` | 592 × 420 | Step card uses about a third of the panel; the rest is black [8]. Default SF Symbol in "Let Perry do it" [15]. |
| `notch/history.png` | 892 × 552 | Empty state inside the full workspace [10]. |
| `notch/model-profiles.png` | 640 × 420 | Provider rows with "Check" and "Remove…" buttons; developer vocabulary [9]. |
| `notch/perry-editor-existing.png` | 892 × 720 | 720 pt tall form; memory text box is an empty grey slab [9]. |
| `notch/perry-editor-new.png` | 892 × 552 | Form with "Only when I ask" control; disabled "Create Perry" in the corner [9]. |
| `notch/routine-review.png` | 592 × 492 | Review card, then empty black below [8]. |
| `notch/routines-populated.png` | 892 × 552 | Two-column list inside the workspace; tiny type [10]. |
| `notch/routines.png` | 892 × 552 | Empty state inside the workspace [10]. |
| `notch/settings-general.png` | 892 × 552 | Six tabs; startup, invocation and permissions in one long scroll [9]. Wake shortcut is a fixed menu, not a recorder [6]. |
| `notch/settings-integrations-tall.png` | 892 × 1400 | At 1400 pt the Apps list is still a stack of "Set up" rows; needs own OAuth app [12]. |
| `notch/settings-integrations.png` | 892 × 552 | Every app says "Set up" and leads to client ID and secret fields [12]. |
| `notch/settings-memory.png` | 892 × 552 | Three greyed toggles under an off switch; diagnostics mixed in [9]. |
| `notch/settings-narrow.png` | 720 × 500 | Settings unreadable at 720 pt; text is a few pixels tall [9]. |
| `notch/settings-runtimes.png` | 892 × 552 | "No local server models found. Start Ollama or LM Studio" — no guided local model setup [3]. |
| `notch/settings-safety.png` | 892 × 552 | Fine content; long blocked-app list is the whole tab [9]. |
| `notch/settings-voice.png` | 892 × 552 | Voice list is fine; no end-of-turn setting [11]. |
| `notch/settings.png` | 892 × 552 | Same as settings-general [9]. |
| `notch/suggestions.png` | 892 × 552 | Disabled example card with grey buttons that look broken [10]. |
| `notch/task-failed.png` | 592 × 492 | Error card at the top, empty black below [8]. |
| `notch/task-question-long.png` | 500 × 258 | Standalone card, fits its content. Good reference for sizing. |
| `notch/task-question-notch.png` | 592 × 400 | Question card inside the notch panel; about 90 pt empty black below [8]. |
| `notch/task-question.png` | 500 × 190 | Standalone card, fits its content. |
| `notch/task-working.png` | 592 × 492 | Progress row at the top, about 300 pt of black below [8, 13]. Mixed icon styles in Pause/Take over/Stop [15]. |
| `notch/tasks.png` | 892 × 552 | Empty state inside the workspace [10]. |
| `notch/whats-new.png` | 892 × 552 | Release notes inside the workspace, small type [10]. |
| `notch/workspace.png` | 892 × 552 | The hover peek today: 892 × 552 with a sidebar, greeting, keycaps and composer. HeyClicky peeks at about 441 × 250 [8, 10]. |
| `onboarding/onboarding-1-greet-reduced-motion.png` | 592 × 492 | Ink "hello" static. Fine. |
| `onboarding/onboarding-1-greet.png` | 592 × 492 | Ink "hello". Fine; strongest beat. |
| `onboarding/onboarding-2-firstTalk.png` | 592 × 492 | "Ask me something" with a large empty middle. |
| `onboarding/onboarding-2b-firstTalk-answered.png` | 592 × 492 | Canned answer, not the live model; the live path gave the "I cannot read apps" reply [1]. |
| `onboarding/onboarding-3-screenAccess-denied.png` | 592 × 492 | Two "Allow" buttons, no drag-into-list helper [2]. |
| `onboarding/onboarding-3b-screenAccess-half.png` | 592 × 492 | Half granted. Same, no helper [2]. |
| `onboarding/onboarding-3c-screenAccess-granted.png` | 592 × 492 | Both allowed. Fine. |
| `onboarding/onboarding-4-brainChoice.png` | 592 × 492 | Only "On this Mac" and "ChatGPT"; Cloud providers hidden under "Other models"; no local model step [3, 4]. |
| `onboarding/onboarding-5-practice.png` | 592 × 492 | Practice window beat [5]. |
| `onboarding/onboarding-5b-practice-step2.png` | 592 × 492 | Practice step 2 of 4; checks nothing it claims [5]. |
| `onboarding/onboarding-6-finale.png` | 592 × 492 | Hard-coded keycaps that cannot be edited; the card is tilted [6]. |
