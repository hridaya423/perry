# Perry follower test card

You're running a public beta. Twenty minutes is enough to be useful.
Reports go through GitHub issues — pick the template that matches, and
attach the diagnostics file Perry exports for you. Perry never uploads
anything itself.

## The 20-minute pass

1. **Install & permissions** — right-click → Open the unsigned build. Grant
   Accessibility and Screen Recording when onboarding asks. If Perry can't
   see your screen after that, that's a bug — report it.
2. **The demo** — finish onboarding's live demo. It's the product teaching
   itself: Perry circles a spot, guides you through a rename, then does a
   small file task itself and proves it worked.
3. **Guide mode** — invoke Perry, ask "show me how to …" in an app you use
   daily. It should point at real controls and advance on your clicks. Try a
   wrong click on purpose — it should not advance.
4. **Do mode** — ask for a small reversible task ("create a note file on my
   Desktop"). Check the plan before approving; watch for the exact-phrase
   approval on anything destructive; verify the report matches reality.
5. **Voice** — hold the push-to-talk key and dictate a request. The active
   route is shown; if voice fails, the typed fallback should be right there.
6. **History & privacy** — open history, find the session, export it, delete
   a record. Then look at Settings → Memory & Privacy and confirm the erase
   path makes sense to you.

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
- Apps with fully custom-drawn interfaces may be partially readable.
- Unsigned beta build — the right-click → Open step is expected.

## Diagnostics

Settings → Memory & Privacy → Report a problem → **Export diagnostics
first**. The file is counts, states, and environment only — no requests,
transcripts, memory text, paths, or audio. Read it, then attach it to the
issue by hand.
