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

## Beat 4 — typed Do plan with exact approval (90s)

Back in the Finder folder, switch to Do and type:
"move perry-demo-a.txt and perry-demo-b.txt into a new folder called Archive".

- The plan appears as typed steps in the activity strip — each step named.
- The approval card names the files and destination. Note the orange card:
  reversible, one tap to approve.
- Approve. Watch the strip: steps tick off, then the verified line —
  "Verified: both files moved and contents unchanged."

*Nothing runs without the approval card, and Perry reads the result back
instead of claiming it worked.*

Optional: queue "empty the Trash" to show the red card — it demands the exact
target phrase typed out before it will proceed.

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

## Beat 7 — local history (20s)

Open History from the menu. Show the sessions just recorded — searchable,
expandable, exportable to Markdown or CSV, deletable with a confirmation that
says exactly what leaves the Mac.

*Everything Perry did is on this machine, inspectable and erasable.*

## Close (10s)

"Local-first. Every action visible, every destructive step approved, every
result read back. Perry beta — it teaches, it does, and it shows its work."

## Reset checklist

- Delete `Archive` and restore the three demo files.
- History → select the demo sessions → Delete selected…
- If a permission was revoked for the voice beat, re-grant it.
