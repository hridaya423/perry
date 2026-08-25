# Perry

A screen-aware companion that teaches you any app by pointing and drawing on your screen, and can take the whole task off your hands. Product spec lives in [PRD.md](PRD.md).

Status: Milestone 1 (Skeleton) in progress. Demo gate: orchestrator state machine tested, overlay + capture transplants building against new code only, one scripted Finder task driven end-to-end by a CLI runtime adapter.

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
