# Perry follower test card

You're running a public beta. Twenty minutes is enough to be useful.
Reports go through GitHub issues — pick the template that matches, and
attach the diagnostics file Perry exports for you. Perry never uploads
anything itself.

## The 30-minute pass

1. **Install & permissions** — right-click → Open the unsigned build. Grant
   Accessibility and Screen Recording when onboarding asks. If Perry can't
   see your screen after that, that's a bug — report it.
2. **The demo** — finish onboarding's live demo. It's the product teaching
   itself: you circle a spot, Perry answers a question about what's actually
   there, guides you through a rename, then does a small file task itself
   and proves it worked.
3. **Ask mode** — invoke Perry (it's the default), circle or point at
   something on screen, and ask a question about it. Perry should name real
   elements and outline what it means on screen. Ask a follow-up — it
   should remember the context. Switch the window mid-answer: the stale
   answer must not land.
4. **Guide mode** — switch to Guide, ask "show me how to …" in an app you
   use daily. It should point at real controls and advance on your clicks.
   Try a wrong click on purpose — it should not advance.
5. **Do mode + rehearsal** — switch to Do and ask for a small reversible
   task ("create a note file on my Desktop"). A plan card shows every step
   with numbered marks on the real targets before anything runs. Try
   **Step through** (⌘S) once — each step asks separately. Try **Edit**
   (⌘E) — the prompt reopens with your goal so you can revise it. Then Run
   a task and watch the report match reality.
6. **Shared control** — during a Do task, hit "I'll do this step" on the
   activity strip: Perry pauses at the next boundary and hands you the
   pointer; Continue replans from where you left off. Or type a steering
   instruction mid-run — the next segment re-plans and re-previews.
7. **Undo** — after a file task finishes, open the tasks window and Undo
   it. Perry reverses only what it provably did, stops at anything you
   changed since, and the row says so. Undo a second time — it should
   refuse honestly, not silently redo.
8. **Teach Perry (Watch & Learn)** — record a tiny demo in one app (a
   rename, a menu click), review the step list Perry drafts, mark a value
   as "ask each run", save it, then run it again with a different value.
   Perry re-looks at the live screen each run — it never replays clicks.
9. **Voice** — hold the push-to-talk key and dictate a request. The active
   route is shown; if voice fails, the typed fallback should be right
   there. Talk over Perry's reply — it should stop speaking, not act.
10. **History & privacy** — open history: each session shows what you
    asked, which runtime answered, whether Perry verified it, and whether
    Undo is still available. Export it, delete a record. Then look at
    Settings → Memory & Privacy and confirm the erase path makes sense.

## What to report (in priority order)

- **Unsafe or misleading** — Perry did or offered something wrong. P0.
- **Crash, hang, or stuck task** — P0.
- **Can't see/drive an app** you expected to work — app-compatibility template.
- **Voice route issues** — wrong device, dead dictation, no fallback.
- **Everything else** — rough edges, confusing copy, visual glitches. All
  welcome; polish is the point of this phase.

## Known limits (don't report these)

- macOS 14+ Apple Silicon only.
- The local planner handles a disclosed deterministic task set; open-ended
  work needs a signed-in runtime (Claude Code / OpenCode / bundled Codex)
  on your own account.
- Undo covers workspace file changes only (create, rename, trash, restore).
  GUI clicks, shell commands, and integration writes are reported honestly
  with no Undo button — that's deliberate, not a missing feature.
- Routines replay against the live screen, so a renamed app or a moved
  button may stop a run for input — it should never click blind.
- Apps with fully custom-drawn interfaces may be partially readable.
- The notch status pill is optional and off by default; on displays without
  a notch it stays in the menu bar.
- Unsigned beta build — the right-click → Open step is expected.

## Diagnostics

Settings → Memory & Privacy → Report a problem → **Export diagnostics
first**. The file is counts, states, and environment only — no requests,
transcripts, memory text, paths, or audio. Read it, then attach it to the
issue by hand.
