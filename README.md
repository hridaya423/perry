# Perry

A screen-aware companion that teaches you any app by pointing and drawing on your screen, and can take the whole task off your hands. Product spec lives in [PRD.md](PRD.md).

Status: Milestone 1 (Skeleton) complete. Session orchestrator state machine, trust tiers, activity log, runtime adapters, overlay/capture/bridge transplants all building and tested — 52 tests green across four packages. Demo gate met: scripted Finder task runs end-to-end through plan → guard → execute → log.

```bash
cd Packages/PerryRuntimes && swift run perry-demo
```

Try the real CLI adapter by setting `PERRY_CLAUDE_CODE_PATH` to a Claude Code binary; tests never require it.

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
