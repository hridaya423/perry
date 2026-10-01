# Quit mid-turn recovery — live drill (2026-10-01)

Kill an in-flight agent turn, relaunch, verify honest recovery. Ran on the
Debug build via `perry-drive.sh` + System Events AX driving.

## Sequence

1. `perry-drive.sh launch` → pid 74569, marker log `perf-20261001T040100Z`.
2. ⌥⌘P hotkey (real CGEvent) → peek panel; typed
   "Write a 3000 word fairy tale about a village named Elm. Do not use tools."
3. AXPress on the Send button → `home.question.sent` marker at
   04:01:43.995Z; thread `48669A43` created.
4. `kill 74569` ~1 s in — confirmed `pendingTurn` persisted in the thread JSON
   (`startedAt` 04:01:44Z, zero turns recorded).
5. Relaunch → Home → "Pick up where you left off" surfaces the thread.
6. Conversation view renders the interrupted banner:

   > This task was interrupted. Review any changes in the affected app before
   > continuing. Perry will not repeat the task automatically.

   Composer is gated (`canSend: pendingTurn == nil`) — no input until resolved.
7. "I've reviewed the changes" → `pendingTurn` cleared; turn appended as
   `interrupted` with reason
   "Interrupted task closed after your review. Its effects have not been
   independently verified." Answer length 0 — nothing fabricated.
8. The question text was restored into `draft` (ThreadStore.finishTurn:
   non-completed outcome + empty draft → draft ← pending question), so one
   send retries it.

## Design path verified

- `ThreadStore.beginTurn` persists `pendingTurn` synchronously at submit.
- No silent retry, no replayed partial work — the user is asked to review
  real-world side effects before the turn is even recorded.
- `ConversationContext` does not replay interrupted turns (verified earlier
  with the fabrication guard work).

## Earlier attempts (for the record)

- Kill after "Write an 800 word story about a lighthouse keeper": the local
  model refused inside ~1 s (`completed`), before the signal landed — the
  thread was never mid-flight at kill time.
- An earlier kill captured an `interrupted` turn (Cedar tale, 494-char
  partial answer) — consistent with this same path.

## Note on driving

System Events `keystroke` targets the frontmost app, which stayed "Devin"
(Perry is LSUIElement — `activate`/`AXRaise` don't flip the menu-bar owner).
Working recipe: CGEvent click → `AXFocused` on the composer field →
`keystroke` → AXPress on the Send button (36×36 AXButton, unlabeled in AX).
Send-button AX node exposes no actions — a real a11y gap already recorded in
phase-4 evidence.

## Audio failure drills (status menu, DEBUG build)

- `Simulate muted output` — ran live on pid 75351 via the status menu:
  reply text arrived on the clipboard
  ("This reply is from the muted-output recovery drill."),
  status set to "Muted-output drill passed…". The muted→clipboard
  failover path is verified end to end. User clipboard preserved and
  restored.
- `Simulate wedged microphone` — reviewed in code
  (`DictationController.simulateInputFailure`): both `onFallback` and
  `onFailure` are invocation-gated (`voiceInvocation.id`), so it is a
  no-op outside a live dictation — needs mic TCC to verify live.
- `Simulate audio route flip` — TTS + `handleAudioRouteChange`; not run
  (audible output, low marginal evidence vs. muted-output drill).
- `Simulate missing runtime` — forces onboarding + honest stop; not run
  (would re-enter onboarding UI over the user's completed state).
