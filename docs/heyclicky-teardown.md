# HeyClicky teardown: what the DMG actually contains, and what it means for Perry

Source of record for the 2026-08-26 analysis of `HeyClicky.dmg` (SHA-256
`912ffcb47881690ce98dd4aea43c3dafaffeb69692f555545f05686a7258fa8b`, app v1.0.48,
build branch `internal-testing-github-release` @ `808e1f56`). Extracted bundle:
`~/honey/heyclicky-re/app-extract/HeyClicky.app`. Nothing from this teardown is
copied into Perry's build; this document records findings and upstream pointers.

## What HeyClicky is, architecturally

Not Electron, not a monolith agent. Three moving parts:

1. **A native SwiftUI shell** (`MacOS/HeyClicky`, universal Mach-O, Sparkle +
   Sentry + PostHog + PLCrashReporter) handling hotkeys, panels, voice capture,
   onboarding videos, and the floating session HUD.
2. **A bundled agent runtime** — `Resources/CodexRuntime/` is OpenAI's open-source
   `codex` CLI (v0.132.0), custom-built per-arch under
   `vendor/{aarch64,x86_64}-apple-darwin/codex/codex`, launched through a small
   arch-dispatch shell script that prepends vendored tooling to PATH. The version
   marker also carries `cua-0.21.0`, tying it to their computer-use stack.
3. **A computer-use helper** — `Helpers/cua-driver` (62 MB universal binary,
   trycua/cua). The skill doc states the design outright: the *app* supervises an
   embedded cua-driver daemon spawned inside Clicky.app so macOS attributes
   Accessibility and Screen Recording permission use to the host app; codex talks
   to it "through a thin stdio proxy" exposing MCP tools named `computer-use`.

The agent brain is not in the app. The app is permission holder, session manager,
and runtime supervisor. That is the single biggest architectural lesson for Perry.

## The behavior contract ships as readable markdown

`Resources/ClickyModelInstructions.md` (~20 KB) is the entire prompt contract for
their agent mode. Its routing ideas are idea-level takeaways (not copied):

- **Narrowest-capable-route discipline:** structured APIs / local files / MCP
  connectors first; computer-use only as last-mile GUI work after structured
  routes fail. Screenshots are context, never route selection.
- **Draft-first email:** search/read/triage freely; sending requires draft +
  explicit approval with account/recipient/subject/body summary.
- **Schema-contract writes for Composio-style integrations:** fetch exact tool
  schema when key names are uncertain, write with exact keys, verify with a
  structured read-back before saying done.
- **Honest capability reporting:** if a provider route isn't shipped, say the
  blocker instead of pretending it ran; no suggested next actions for unavailable
  routes.
- **Session semantics:** fresh vs resumed thread vs active steer decided by the
  shell, not the model.

Perry already implements the trust-tier version of several of these; the ones we
lack are the read-back verification habit (TrustGuard could require a structured
verify step for yellow+ Composio-class actions post-v1) and "context is not route"
as an explicit planner rule.

## Skills library

`Resources/*.md` + `Resources/ClickyBundledSkills/` = ~25 workflow skills plus a
capability set (pdf, doc/spreadsheet via scripts, obsidian, frontend-design,
vercel-deploy...). `ATTRIBUTION.md` confirms the provenance: SKILL.md files are
**vendored unmodified from NousResearch/hermes-agent (MIT)**; blender.md from
dev-gom/claude-code-marketplace. Skill selection happens by intent ("users do not
need to know or name skills"), recorded to UserDefaults pre-sign-in.

For Perry: pull skills directly from hermes-agent upstream when wanted, do not
vendor from the DMG. Our PRD keeps v1 scope tighter than theirs; treat their skill
taxonomy as evidence that intent-based routing over a flat skill list scales.

## Backend topology (from endpoint strings)

- `api.heyclicky.com` — main API; Anthropic Messages URL present in Info.plist;
  auth via Supabase (`mrpvynsdsnimuisyhkow.supabase.co`) with token refresh +
  anonymous-ID distinct tracking; realtime session minting with bearer refresh on
  401.
- Deepgram + OpenAI endpoints for voice/model routes; Mux for streaming video.
- Analytics dual-region PostHog (eu/us); Canny for feature requests; GitHub
  releases channel (`farzaa/clicky-releases`) for distribution.

No secrets were found embedded in the binary (anon-key style strings absent;
config values resolved at runtime). Perry's BYOK direct-to-provider posture
remains simpler and needs none of this.

## What is NOT recoverable

The SwiftUI shell source, orchestration glue, drawing-overlay internals, and
backend code are compiled Swift; no Swift source, AST, or usable symbol tables
exist in the bundle (only mangled type names). Decompilation yields assembly at
best. Their visual identity (sprite art, sounds, videos, Assets.car) is their
copyrighted property regardless. This is fine — Perry's differentiator should be
its own expression anyway.

## Direct consequences for Perry

1. **The bundled-runtime pattern beats the CLI-probe pattern.** HeyClicky vendors
   codex into Resources and supervises it as a child process. Our current
   `CLIRuntime` probes standard Claude Code install paths. Vendoring a pinned
   codex release (Apache-2.0, allows redistribution) into Perry removes the
   user's need to own any CLI and makes version drift our decision, not theirs.
2. **Permission attribution trick:** spawning cua-driver (or any AX/screen helper)
   inside Perry.app means one TCC grant covers everything. Relevant when Perry
   adds real computer-use execution post-v1.
3. **stdio MCP proxy shape:** their agent reaches the driver through a thin stdio
   proxy advertising MCP tools. When Perry wires Do-mode to a real executor, the
   same shape (app-owned daemon + stdio MCP + snapshot-act-verify contract) fits
   our trust tiers cleanly: tier checks sit between plan and execute either way.
4. **Skill loading:** flat markdown skills loaded by intent is validated UX; keep
   Perry's GuideIntentParser as the router surface.
5. **Distribution:** they ship the DMG via GitHub Releases latest-download link.
   Cheap and works; note for Perry launch.
