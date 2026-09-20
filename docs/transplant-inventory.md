# Transplant inventory

Source of record for what Perry takes from [openclicky](https://github.com/jasonkneen/openclicky) (MIT) and how. Reference clone lives at `vendor/openclicky-reference/` (gitignored, never on a build path). Rule from the PRD: transplants compile against new Perry code only, never against `CompanionManager` or any monolith extension.

Measured against upstream as of 2026-08-25 (main @ 257fc11).

| Organ | Source file | Lines | Monolith refs | Imports | Verdict |
|---|---|---|---|---|---|
| Overlay engine | `cursor-buddy/OverlayWindow.swift` | 3234 | 12 | AppKit, Combine, SwiftUI, UniformTypeIdentifiers | Transplant into PerryOverlay; replace the 12 CompanionManager touchpoints with a narrow `OverlayControlling` protocol owned by PerryCore |
| Platform capture | `cursor-buddy/CompanionScreenCaptureUtility.swift` | 465 | 0 | AppKit native capture | Not used; Cua Driver is Perry's only live computer-use capture/action boundary |
| Control bridge | `cursor-buddy/OpenClickyExternalControlBridge.swift` | 1280 | 0 | AppKit, Foundation, Network | Transplant last, kept internal (loopback only) per PRD |
| Process spawn | `cursor-buddy/CodexProcessManager.swift` | 517 | 0 | Foundation | Pattern source for PerryRuntimes CLI adapter; port ideas, rename surface |
| Permission probes | scattered (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess` across ~10 files) | — | — | — | Do not transplant files; write a fresh `PerryPermissionProbe` in PerryCore calling the same stable APIs |

## Explicitly not taken

`CompanionManager*.swift` (741 KB core + extensions), notch stack (`OpenClickyNotch*`, DynamicNotchKit bridge), widgets, ElevenLabs/OpenAI voice clients (Perry uses Apple STT/TTS), gogcli integration, bundled binaries under `AppResources/` (33 MB incl. a checked-in .app and cua-driver), reminder systems, onboarding music.

## Adaptation notes

- OverlayWindow's companion touchpoints concentrate in bubble/avatar sizing paths; the Perry buddy sprite replaces those views, so expect deletion more than wrapping.
- Capture utility returns CGImage-shaped results; Perry keeps frames memory-only per PRD section 8, so any disk-write path found during surgery gets removed.
- Bridge server is `@unchecked Sendable`; re-audit its isolation when transplanted under Swift 6 strict concurrency.

## Transplant status (updated 2026-08-25, M1 complete)

| Organ | Status |
|---|---|
| Overlay engine (`OverlayWindow.swift` → `PerryOverlay/OverlayWindow.swift`) | Done. 3234 → ~2200 lines; dock stack, dock manager, voice waveform/spinner UI, Codex pet sprites cut; all CompanionManager touchpoints rerouted to Perry-owned `PerryCursorState`; builds against new code only. |
| Guidance models (`→ GuidanceModels.swift`) | Done verbatim + publicized; donor's own tests ported and passing (with one documented macOS 26 CGRect-standardization drift fix). |
| Screen capture (`→ PerryCapture/PerryScreenshot.swift`) | Replaced. Perry no longer owns native window capture; the Cua Driver refuses protected target windows before inspection, and PerryCapture retains only image geometry plus Vision OCR helpers. |
| Control bridge (`→ PerryOverlay/ExternalControlBridge.swift`) | Done. Inference proxy removed per PRD §8 no-middleman rule; Gmail stub surface removed (out of scope v1); drawing/display tools always advertised; auth via `PERRY_BRIDGE_TOKEN` with constant-time compare; live loopback auth test green. |
| Process spawn (`CodexProcessManager.swift` patterns) | Done as pattern source only: `CLIRuntime.runProcess` implements spawn + locked pipe buffers + timeout kill; locator probes standard Claude Code install paths with `PERRY_CLAUDE_CODE_PATH` override. |
| Permission probes | Done as fresh code per plan (`PerryCapture/PerryPermissionProbe.swift`): AXIsProcessTrusted, CGPreflightScreenCaptureAccess, AVCaptureDevice microphone status + snapshot aggregation; unit-tested without triggering TCC prompts. |

## Platform drift found during surgery

Since the macOS 26 SDK, CGRect standardization no longer repositions the origin for negative width/height: `(120, 90, -80×60)` normalizes to `(120, 90, 80×60)`, not the older `(40, 90, …)` that upstream's test asserted. The ported guidance test documents this and asserts current behavior. This validates the PRD's OS-compat-matrix risk; overlay coordinates derived from AX frames should never be constructed with negative extents.
