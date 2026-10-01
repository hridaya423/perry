# Diagnostics export — live drill (2026-10-01)

Debug build (post-`f3858f8`), pid 6859.

## Drive

Status-item menu → "Export diagnostics…" → NSSavePanel → accepted the
default `~/Documents/perry-diagnostics.json`.

## Result

Real 883-byte JSON written to disk (`diagnostics-sample.json` is a copy).
Sections: `activity`, `app`, `generatedAt`, `memory`, `permissions`,
`runtimes`, `transcripts`. Contents are counts and booleans only —
transcript totals/outcomes by name, no request text, paths, or memory
content — matching the redaction claim in Settings.

Notable reads from the sample: `permissions.accessibility=false`,
`screenRecording=denied`, `microphone=notDetermined` (the known TCC
blockers), `memory.enabled=false` (default off), and runtimes reporting
bundled Codex, installed Claude Code, and the private local planner all
present.
