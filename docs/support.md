# Support

Perry is a public beta. Reports go through GitHub issues; diagnostics are
exported by you, redacted, and attached by hand — Perry never uploads anything
automatically.

## Report a problem

In the app: **Settings → Memory & Privacy → Report a problem**.

The dialog offers two actions:

- **Export diagnostics first** — writes a redacted diagnostics file you can
  inspect before sharing.
- **Open GitHub issues** — opens Perry's issues page (release builds only;
  development builds omit the link).

On GitHub, pick the template that matches your report:

- **Bug report** — anything broken or unexpected.
- **App compatibility** — Perry can't see or drive a specific app.
- **Voice route** — dictation, push-to-talk, or realtime voice issues.
- **Unsafe or misleading behavior** — Perry acted, or offered to act, in a way
  that felt wrong. These are triaged first.

## What diagnostics contain

The export is counts, states, and environment only — enough to reproduce the
problem, nothing more. It never contains your requests, transcripts, memory
text, file paths, or audio. Open the file and check before attaching.

## Privacy

- Local-first: requests, transcripts, and memory stay on this Mac.
- No telemetry, no analytics, no crash reporters.
- Screen pixels stay in memory; nothing is written unless you export it.
- Settings → Memory & Privacy can erase everything Perry stores.

## Before you file

- Check [docs/capabilities.md](capabilities.md) — your report may be a known
  limit rather than a bug.

- Permission issues: System Settings → Privacy & Security → Accessibility and
  Screen Recording must list Perry. Toggling a permission off and on after an
  update fixes most "Perry can't see my screen" reports.
- Voice issues: check the active input route shown in the listening status;
  typed input always works as a fallback.
- Runtime issues: Settings → Agent runtime shows each runtime's status and its
  official sign-in command.
