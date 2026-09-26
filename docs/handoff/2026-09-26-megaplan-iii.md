# Handoff: Megaplan III "Painkiller" — Perry

**Read first:** the full approved plan is `docs/plans/megaplan-iii-painkiller.md`
(same file as `~/.devin/plans/plan-c221ed45bb308d87.md` on the source machine).
The product thesis and phase detail live there. The superseded Living Pointer
plan is `docs/plans/living-pointer-plan.md` for reference only.

**Execution contract:** `AGENTS.md` at repo root — verified commands, the
XCUITest hang note, and the commit rules. Follow it literally.

## Mission

Finish implementing every phase 0–10 of the megaplan. For each phase:
sub-plan in `docs/plans/` → implement → focused tests → live drill of the real
app via `cua-driver` → evidence in `docs/evidence/phase-N/` → local commit.
Never fake live evidence; record external blockers honestly in the goal report
and evidence READMEs. Budgets are megaplan §8; the §9 scorecard vs HeyClicky is
the definition of done.

The user wants a painkiller: butter-smooth setup, living-glass UI, fully
functioning features that beat HeyClicky (`https://www.heyclicky.com/`).

## Repo state at handoff (all committed)

| Commit | Contents |
|---|---|
| `7753e09` | Phase 0 laboratory: lab scripts, perf markers, probes, spikes doc |
| `87f922a` | Phase 1 PerryBrain: streaming providers, confined Codex brain, router |
| `35ea3b6` | Phase 1 app wiring: `BrainController`, package link, debug smoke test |
| `0c59072` | Phase 2a Talk core (DeixisResolver, InlineMarkupParser, ToolGate, SentenceChunker, TalkPrompt + tests) |
| `e7fd2df` | Phase 3 overlay: InkStroke, CaptionPlacer, cursor morphs, DebugCursorGallery |
| `0b3aa4d` + `201140f` | Phases 2b/4/5 app wiring: `App/Talk/`, `App/Onboarding/`, `App/Home/`, ThreadStore; OnboardingFlow deleted |

**Verification at handoff:** `xcodebuild` Debug build **succeeded**;
`swift test` all packages green — PerryBrain 122, PerryOverlay 18,
PerryGuide 267, PerryCore 69, PerryRuntimes 187 (10 skipped: live Cua/TCC),
PerryCapture 9.

## What's done vs pending (see `.devin/goal/report.md` for the live ledger)

- **Phase 0:** lab + spikes committed. Pending: user TCC grants, HeyClicky
  install + §9 baseline scorecard (12 journeys, recordings).
- **Phase 1:** package + router + Codex provider done; live Codex smoke passed
  (~3.1–4.2 s first-delta, >1.5 s gate → fast tier must be on-device).
  Pending: Ollama-only offline vision acceptance, mid-stream network-cut test,
  user's ChatGPT sign-in for Perry's own CODEX_HOME.
- **Phase 2:** 2a pure core done (114-test green). 2b app wiring done per
  evidence README (29 tests; perf markers wired). Pending: live Talk drills
  in Figma/Chrome/Finder/Resolve/Slack, barge-in, first-audio/draw budgets.
- **Phase 3:** morph grammar + ink + caption placer foundations (18 tests).
  Pending: per README — display-link follow verification, live evidence.
- **Phase 4:** onboarding rebuilt as OnboardingDirector + PracticeWindow;
  remaining per report (Settings-toggle pointing, live fresh-run acceptance).
- **Phase 5:** Notch Home started — ThreadStore, HomeHoverIntent (8 tests +
  seeded fuzz), HomeController, Home/Peek views, window migration done.
  Remaining per report: file piles, live-step agent rows, settings split,
  hover/peek latency + idle drills.
- **Phases 6–10:** not started. Phase 6 Guide refinement, 7 tool host +
  `perry-mcp` + agent Do + receipts, 8 dictation, 9 Perrys/routines/
  suggestions/local models, 10 failure choreography + polish + scorecard.

## User-only blockers (do not fake)

- TCC Screen Recording + Accessibility for the debug Perry.app.
- HeyClicky install + free-tier sign-in for the §9 baseline.
- ChatGPT sign-in inside Perry's own CODEX_HOME.
- Ollama/LM Studio vision model for offline acceptance
  (`ollama pull qwen2.5vl` suggested).
- Connector OAuth test accounts (Phase 7+).
- A BYOK API key for live BYOK streaming tests.

## Environment notes (Mac mini)

- The mini is macOS 26.2 with **Xcode 16.3** — the app targets Xcode 26.6 /
  macOS 27 SDK features (FoundationModels etc.). Install a current Xcode
  (26.x) before expecting `xcodebuild` to succeed. SwiftPM package tests may
  still run under 16.3 since `FoundationModels` code is `#if canImport`-guarded.
- First `xcodegen generate` needs `scripts/fetch-xcodegen.sh --fetch`
  (installs the pinned binary to `build/tools/xcodegen/`).
- `build/` and `Packages/*/.build` were excluded from the copy — first build
  is a clean build.
- `codex` CLI: `App/Resources/CodexRuntime` is bundled in the repo; sign-in is
  still a user step.
- cua-driver on the mini needs its own Accessibility/Screen Recording grants
  (`cua-driver permissions grant`).

## Getting started on the mini

```sh
devin            # auth on first run (browser), then:
/model opus      # or start with: devin --model opus
/goal resume     # goal state was copied in .devin/goal/
```

If no goal resumes, run `/goal` with the objective in `.devin/goal/objective.md`
(or simply: "implement the rest of docs/plans/megaplan-iii-painkiller.md,
starting at Phase 5 leftovers, following AGENTS.md and this handoff").

## Suggested skills for the next agent

- `executing-plans`, `writing-plans` — the per-phase sub-plan loop
- `test-driven-development`, `verification-before-completion`
- `agent-laboratory` — the measurement-first discipline (perf budgets §8)
- `cua-driver` — driving the real app for live drills
- `ponytail` — minimal-diff code style contract
- `design-engineering` / `design-review` — Phases 3–5, 10 polish
- `code-review` — full-diff review before each phase commit
