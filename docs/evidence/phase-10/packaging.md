# Phase 10 — packaging & distribution checks

Date: 2026-10-01. Target: `build/release-p1/Build/Products/Release/Perry.app`
(Release, arm64, "Sign to Run Locally" ad-hoc identity).

## Code signature

`codesign --verify --verbose=2` → `valid on disk`, `satisfies its
Designated Requirement`, exit 0 (verified both on the Xcode output and after
the binary-level re-sign described below).

## Entitlements

`codesign -d --entitlements :-` (DER form, after Xcode's CodeSign step):

```json
{
  "com.apple.security.automation.apple-events": true,   // System Events / app driving
  "com.apple.security.device.audio-input": true,        // hold-to-talk + dictation mic
  "com.apple.security.get-task-allow": true             // debug attach; local-dev signing
}
```

All three map to shipped features. `get-task-allow` is expected under ad-hoc
"Sign to Run Locally"; a notarized build would drop it.

## Privacy usage descriptions (Info.plist)

- `NSAppleEventsUsageDescription` — explains driving other apps.
- `NSMicrophoneUsageDescription` — explains hold-to-talk.
- `NSSpeechRecognitionUsageDescription` — explains on-device speech recognition.

Screen capture uses `CGPreflightScreenCaptureAccess` /
`CGRequestScreenCaptureAccess` (see
`Packages/PerryCapture/Sources/PerryCapture/PerryPermissionProbe.swift`), the
legacy Screen Recording consent flow — `NSScreenCaptureUsageDescription` only
applies to ScreenCaptureKit prompts, so its absence is correct, not a gap.

## Known packaging issue

Xcode signs the Release app with `-o runtime` (hardened runtime) even under
the ad-hoc identity. On this machine the resulting binary is killed at launch
(amfid-style rejection); stripping the hardened-runtime flag by re-signing the
executable directly (`codesign --force --sign - …/Contents/MacOS/Perry`)
produces a launchable binary. This is a local-dev packaging wrinkle, recorded
so a real signing identity pass can revisit it.

## Test gates at packaging time

| Suite | Result |
|---|---|
| PerryBrain (swift test) | 289 / 289 |
| PerryGuide (swift test) | 268 / 268 |
| PerryRuntimes (swift test) | 187 run, 10 skipped |
| PerryOverlay (swift test) | 6 / 6 |
| PerryTests (xcodebuild, app bundle) | 525 run, 4 skipped, 0 failed — TEST SUCCEEDED |

## Resource budget (ongoing soak)

`scripts/lab/soak` sampling against the live Release instance reports 0.0 %
average CPU and ~149 MB RSS across 266+ samples — inside the §8 idle budget
(≤0.5 % CPU, ≤180 MB).
