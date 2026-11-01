# Perry

A screen-aware companion that teaches you any app by pointing and drawing on your screen, and can take the whole task off your hands. Product spec lives in [PRD.md](PRD.md).

Status: public beta, not GA. The arm64 app builds and the automated suites cover typed plans, fail-closed execution, screen-control session generations, guide postconditions, durable task checkpoints, bounded voice dispatch, integration policy, onboarding, and persistence recovery. These results establish wiring and automated behavior; they do not replace live TCC, provider-account, signed-release, performance, accessibility, or acceptance-journey evidence.

```bash
cd Packages/PerryRuntimes && swift run perry-demo
```

Docs: [capabilities](docs/capabilities.md) · [support](docs/support.md) · [follower test card](docs/follower-test-card.md) · [tone sheet](docs/tone-sheet.md) · [performance notes](docs/performance-notes.md) · [demo script](docs/demo-script.md). Licensed AGPL-3.0 (PRD §12).

## What is live

The app target binds the menu-bar companion, intent cards, onboarding, guide overlays, push-to-talk, optional realtime voice, route fallback, task controls, history, integrations, and diagnostics to tested controller boundaries. agent-desktop is the required computer-use boundary, and Perry binds its sessions to process and window identities. Accessibility and Screen Recording are required for grounded screen work; the local planner handles only its disclosed deterministic task set, while open-ended work requires a healthy authenticated runtime.

A pinned agent-desktop build ships inside the app bundle (`App/Resources/AgentDesktop`) and is verified by SHA-256 against `scripts/agent-desktop.lock` (see `docs/release-readiness/agent-desktop.md`). It is required for grounded computer-use sessions. If it is unavailable or unhealthy, Perry reports the failure instead of switching to another backend. A pinned cua-driver (`App/Resources/CuaDriver`, `scripts/cua-driver.lock`) ships beside it as a background fallback: clicks at a point, drags, and control clicks that agent-desktop provably did not deliver, or reports as delivered with no observable effect, go through cua without moving the user's cursor.

## Development

The Xcode project is generated, never hand-edited.

```bash
./scripts/fetch-xcodegen.sh --fetch   # pinned, hash-verified
build/tools/xcodegen/bin/xcodegen generate --spec project.yml
open Perry.xcodeproj
```

Tests: `swift test` inside any package under `Packages/`, or `xcodebuild test -project Perry.xcodeproj -scheme Perry`.

## Layout

- `App/` — the Perry application target
- `Packages/` — local Swift packages (PerryCore, PerryBrain, PerryRuntimes, PerryOverlay, PerryGuide)
- `docs/transplant-inventory.md` — what we take from openclicky and why
- `vendor/` — inert reference clones, never on a build path
