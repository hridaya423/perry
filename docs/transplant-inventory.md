# Transplant inventory

Source of record for what Perry takes from [openclicky](https://github.com/jasonkneen/openclicky) (MIT) and how. Reference clone lives at `vendor/openclicky-reference/` (gitignored, never on a build path). Rule from the PRD: transplants compile against new Perry code only, never against `CompanionManager` or any monolith extension.

Measured against upstream as of 2026-08-25 (main @ 257fc11).

| Organ | Source file | Lines | Monolith refs | Imports | Verdict |
|---|---|---|---|---|---|
| Overlay engine | `cursor-buddy/OverlayWindow.swift` | 3234 | 12 | AppKit, Combine, SwiftUI, UniformTypeIdentifiers | Transplant into PerryOverlay; replace the 12 CompanionManager touchpoints with a narrow `OverlayControlling` protocol owned by PerryCore |
| Screen capture | `cursor-buddy/CompanionScreenCaptureUtility.swift` | 465 | 0 | AppKit, ScreenCaptureKit | Near drop-in for PerryCapture; add blocked-window refusal at this layer |
| Control bridge | `cursor-buddy/OpenClickyExternalControlBridge.swift` | 1280 | 0 | AppKit, Foundation, Network | Transplant last, kept internal (loopback only) per PRD |
| Process spawn | `cursor-buddy/CodexProcessManager.swift` | 517 | 0 | Foundation | Pattern source for PerryRuntimes CLI adapter; port ideas, rename surface |
| Permission probes | scattered (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess` across ~10 files) | — | — | — | Do not transplant files; write a fresh `PerryPermissionProbe` in PerryCore calling the same stable APIs |

## Explicitly not taken

`CompanionManager*.swift` (741 KB core + extensions), notch stack (`OpenClickyNotch*`, DynamicNotchKit bridge), widgets, ElevenLabs/OpenAI voice clients (Perry uses Apple STT/TTS), gogcli integration, bundled binaries under `AppResources/` (33 MB incl. a checked-in .app and cua-driver), reminder systems, onboarding music.

## Adaptation notes

- OverlayWindow's companion touchpoints concentrate in bubble/avatar sizing paths; the Perry buddy sprite replaces those views, so expect deletion more than wrapping.
- Capture utility returns CGImage-shaped results; Perry keeps frames memory-only per PRD section 8, so any disk-write path found during surgery gets removed.
- Bridge server is `@unchecked Sendable`; re-audit its isolation when transplanted under Swift 6 strict concurrency.
