# Perry

A screen-aware companion that teaches you any app by pointing and drawing on your screen, and can take the whole task off your hands. Product spec lives in [PRD.md](PRD.md).

Status: Milestones 1–6 executed. Session orchestrator, trust tiers, activity log, permission probes, Guide engine (step-follows-you + show-me-everything), intent cards with tier policy, Finder task suite, memory store, background runner with notifications, wake-word gate, keychain, hardware probe with honest local-tier gate, BYOK planner, runtime router, onboarding flow. 110 tests green across five packages; app builds clean.

```bash
cd Packages/PerryRuntimes && swift run perry-demo
```

Docs: [tone sheet](docs/tone-sheet.md) · [transplant inventory](docs/transplant-inventory.md) · [performance notes](docs/performance-notes.md) · [demo script](docs/demo-script.md). Licensed AGPL-3.0 per PRD §12 recommendation.

## What "executed" means here

Milestone gates are demo-gated in the PRD. The logic, state machines, trust enforcement, and adapters are implemented and tested headlessly (see `Packages/*/Tests`). What remains for a shippable 1.0 app is UI binding: the buddy sprite art replacing donor visuals, menu-bar docking view, intent-card SwiftUI surface, and the System Settings-style onboarding screens — all sequenced behind tested controllers already in this repo.

## Development

The Xcode project is generated, never hand-edited.

```bash
brew install xcodegen
xcodegen generate
open Perry.xcodeproj
```

Tests: `swift test` inside any package under `Packages/`, or `xcodebuild test -project Perry.xcodeproj -scheme Perry`.

## Layout

- `App/` — the Perry application target
- `Packages/` — local Swift packages (PerryCore, PerryRuntimes, PerryOverlay, PerryCapture)
- `docs/transplant-inventory.md` — what we take from openclicky and why
- `vendor/` — inert reference clones, never on a build path
