# Demo script — public beta

One take, no cuts, no debug-only shortcuts. Everything runs from a normal
build of the app. The point of each beat is in italics — say it, don't read it.

## Setup (before recording)

1. Build once so DerivedData is warm:
   `xcodegen generate && xcodebuild -scheme Perry -destination 'platform=macOS' build`
2. Launch Perry from DerivedData or Xcode. Complete onboarding: grant
   Accessibility and Screen Recording when asked, let the bundled Codex verify,
   and run the live demo at the end of onboarding — that *is* beat zero.
3. Finder open on a folder with three files: `perry-demo-a.txt`, `-b`, `-c`.
4. A second everyday app ready (Preview or Notes) for the Guide beat.

## Beat 1 — meet Perry (20s)

Press **⌥⌘P**. The panel appears with Guide / Do segmented and one field.
*One way to call Perry; two ways it can help.*

Say the line: "Guide points at the next click. Do carries the task out and
shows you what it verified."

## Beat 2 — dynamic Guide (60s)

Switch to the second app. Type "guide me through exporting this as a PDF" and
start guiding.

- Perry circles the first real control and waits.
- Click where it points — it advances because the screen actually changed.
- Click somewhere wrong — nothing happens; it only advances on the right
  change.
- Show the Guide controls HUD: step position, Done, Skip, Re-point, Stop.
  Press Skip once, then Stop with Escape.

*Guide reads the live accessibility tree — it can't point at a control that
isn't there, and it can't be tricked by text on screen into doing something.*

## Beat 3 — spatial map (30s)

Invoke again and circle a region of the screen with the pointer. Ask "what
does this button do?" — Perry answers about *that* region.

*The circle is the question. Perry grounds answers in the exact window and
region, not the whole screen.*

## Beat 4 — typed Do plan with rehearsal and exact approval (90s)

Back in the Finder folder, switch to Do and type:
"move perry-demo-a.txt and perry-demo-b.txt into a new folder called Archive".

- Before anything runs, the plan card previews every step with numbered
  marks painted on the real targets and a ghost path through them.
- Show the controls: Run, Step through (⌘S), Replay (⌘R), Edit (⌘E), Stop.
  Hit Replay once — the marks repaint from a fresh observation.
- The approval card names the files and destination. Note the orange card:
  reversible, one tap to approve.
- Approve. Watch the strip: steps tick off, then the verified line —
  "Verified: both files moved and contents unchanged."

*You review the exact plan against the live screen before it runs — and
Perry reads the result back instead of claiming it worked.*

Optional: queue "empty the Trash" to show the red card — it demands the exact
target phrase typed out before it will proceed.

## Beat 4b — shared control and Undo (45s)

Run the same kind of task again. Mid-run, hit "I'll do this step" on the
activity strip — Perry settles at the boundary and hands you the pointer;
do a step by hand, then Continue and Perry replans the rest from the live
screen.

Then open the tasks window and Undo the finished task: Perry reverses only
what it provably did, stops at anything you changed, and says which. Edit
one of the moved files first to show the conflict stop.

*Control passes back and forth without restarting, and Undo touches only
verified Perry work — never your edits.*

## Beat 5 — voice and fallback (30s)

Hold the dictation shortcut, speak a request, release — partial transcript
appears live, the request dispatches once on release.

Then unplug or mute the microphone (or deny permission in System Settings)
and show the typed path: the same field still works, and the status line says
so in plain words.

*On-device Apple dictation is the default. Typing always works.*

## Beat 6 — recovery (30s)

Start a Do task, then close the target window mid-run. Perry reports the stop
honestly — "Stopped: the target window closed before the second step" — and
offers retry instead of pretending.

*It tells you what it couldn't do, not a success it didn't have.*

## Beat 7 — teach Perry once (60s)

In Finder, open Perry's routine library and start a Watch & Learn
recording on the folder. Rename `perry-demo-c.txt` once, stop recording.

- The review card lists the steps Perry observed — drag-free, no raw keys.
- Mark the new filename as "ask each run", save the routine.
- Run it again with a different name — Perry re-reads the live window and
  does the rename fresh, then verify it in the task's report.

*A routine is steps with meaning, not a macro — it re-looks every run, and
review before save means Perry never hides what it recorded.*

## Beat 8 — local history (20s)

Open History from the menu. Show the sessions just recorded — each row says
what you asked, which runtime answered, whether Perry verified it, and
whether Undo is still available. Searchable, exportable to Markdown or CSV,
deletable with a confirmation that says exactly what leaves the Mac.

*Everything Perry did is on this machine, inspectable and erasable.*

## Close (10s)

"Local-first. Every action rehearsed before it runs, every destructive
step approved, every result read back, every file change reversible. Perry
beta — it teaches, it learns, it does, and it shows its work."

## Reset checklist

- Delete `Archive` and restore the three demo files; rename
  `perry-demo-c.txt` back if the routine renamed it.
- Routine library → delete the demo routine.
- History → select the demo sessions → Delete selected…
- If a permission was revoked for the voice beat, re-grant it.
