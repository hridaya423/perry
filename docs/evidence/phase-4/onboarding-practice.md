# Phase 4 evidence — onboarding practice drill (live)

Date: 2026-10-01. Release build `build/release-p1` (pid 21765 final), model =
local (`qwen3:4b` via ollama), driven with cua-driver + CGEvent.

## Path walked

| Beat/step | Result | How |
|---|---|---|
| greet | passed live | "Set up Perry" clicked in Home onboarding card |
| brainChoice | passed live | picker switched to "On this Mac" |
| firstTalk | passed live | composer turn → local model answer persisted in thread |
| screenAccess | passed via checkpoint | Device Control TCC dialog surfaced on schedule — left for the user; resumed via `perry.onboarding.beat` |
| practice · pointAsk | passed live | pointer moved onto practice window, question sent, local answer persisted → step auto-advanced to `guide` |
| practice · guide | **TCC-blocked** | "show me how to rename a file" submitted twice; a real Guide session started each time and reached reporting with `outcome: interrupted` ("Guide stopped before it finished") — the Cua worker cannot read/observe windows without the Device Control grant. Step requires `.completed`, so it cannot advance until the user grants TCC. The interrupted outcome is itself clean failure-choreography evidence (in-thread message, no stuck state). Checkpoint advanced past it manually. |
| practice · renameUndo | passed live | "Rename these three files" renamed all 3 sandbox files on disk (`Perry — X.txt`); "Undo rename" restored them → `.renamedAndUndone` fired → step advanced |
| practice · dictate | passed live | text entered into the practice Notes box → `.dictated` fired → beat advanced to finale |
| finale · Done | passed live | `perry.onboarding.completed = 1`; beat+practice checkpoints cleared; Home shows post-onboarding surface |

## Checkpoint persistence

`perry.onboarding.beat` / `perry.onboarding.practice` persist every transition;
relaunch resumed mid-practice at the persisted step — verified across two
relaunches.

## Bugs found and fixed during the drill

- **Practice window close wedged the beat** (`2b…` this diff): closing the
  window left `practiceStarted = true` with no "Start practice" button — the
  beat could only be skipped, losing remaining steps. `PracticeWindow` now
  reports close via `onClose` → `notePracticeWindowClosed()` resets
  `practiceStarted`; "Start practice" returns and resumes at the persisted
  step. Test: `testPracticeWindowCloseAllowsRestart`.

## UX findings filed during the drill

1. **Send button invisible to AX**: the Home composer send control never
   appears in the accessibility tree (label `Send message` is set but not
   emitted). Keyboard submit is `⌘Return`, not Return
   (`HomeConversationView.swift` `.keyboardShortcut(.return, modifiers:
   .command)`). A11y gap: no AX-reachable submit path.
2. **AX `set_value` doesn't drive SwiftUI submission**: writing the composer
   field via accessibility updates the visible text but not the binding path
   the send action needs; real key events (`type_text` foreground) work.
3. **Practice `guide` step ordering**: the step requires a *completed* Guide
   run, which needs Device Control — but the earlier `screenAccess` beat
   explicitly allows deferring that grant. A user who defers hits a practice
   step that can never complete; only "Skip practice" (whole beat) escapes.
   Options: let `guide` complete on `.stopped`, or add a per-step skip.
