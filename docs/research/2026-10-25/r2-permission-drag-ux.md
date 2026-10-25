# R2: "Drag me into the list" permission helper — how it works and how to build it in Perry

Date: 2026-10-25. Target: macOS 26/27, Swift/AppKit/SwiftUI, arm64, non-sandboxed Developer ID.
Method: read-only. No GUI app was launched, System Settings was not opened, nothing was built. Evidence comes from bundle inspection (`strings`, `nm -u`, `plutil`), shallow clones of public repos into `/tmp`, the local Xcode SDK headers, and web fetches. Claims marked **(inference)** are not directly evidenced.

## 1. Short answer

The pattern is the same everywhere it appears:

1. Open the privacy pane with an `x-apple.systempreferences:` URL.
2. Find the System Settings window with `CGWindowListCopyWindowInfo` (no permission needed for bounds) and poll it at 30–60 Hz.
3. Show a borderless, non-activating `NSPanel` at `.floating` level, docked to the Settings window.
4. The panel holds a custom `NSView` that is an `NSDraggingSource` and writes the app bundle's file URL (`appURL as NSURL`) to the drag pasteboard.
5. Poll for the grant. Accessibility flips live in-process. Screen Recording and Input Monitoring cache per process, so use a fresh-process probe or a relaunch.

Everything needed is public AppKit/CoreGraphics. The only undocumented pieces are the deep-link anchors and the `com.apple.TCC.updated` distributed notification (optional poke, not required).

## 2. Who does this

| App | Drag helper? | Evidence |
|---|---|---|
| **HeyClicky** 1.1.1 (`com.humansongs.clicky`) | Yes, own implementation | `/Applications/HeyClicky.app/Contents/MacOS/HeyClicky`: Swift symbols `PermissionGuideStripView`, `PermissionGuideDragSourceView`, `PermissionGuideDragSourceOverlay`, `PermissionFlowCoordinator` (source path `HeyClicky/PermissionFlowCoordinator.swift`); copy "drag me into the list above.", "Drag me into the Accessibility list.", "Drag me into Screen Recording."; "The guide will stay attached to System Settings while you drag HeyClicky into the list above. If the app does not show up automatically, reveal it in Finder and drag from there."; imports `AXUIElement*`, `CGWindowListCopyWindowInfo`, `CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`; **no** `AXObserver` import (`nm -u` count 0), so it polls **(inference)**. Uses both URL forms: `com.apple.preference.security?Privacy_Accessibility` and `com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility`/`Privacy_ScreenCapture`. Screenshot: panel docks inside the lower part of the Settings window, over the list. |
| **OpenAI Codex Computer Use** 26.1015.1001540 (`com.openai.sky.CUAService`) | Yes, the most elaborate | `~/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService`: `SlimCore.SystemSettingsAccessoryWindow`, `SystemSettingsAccessoryWindowView`, `DraggableApplicationView`, `DragHintView`, `SystemSettingsAccessoryWindowDragDelegate`, `SystemSettingsAccessoryTransition{Controller,OverlayWindow,OverlayReplicantWindow,Capture,Session}`, `ComputerUse.PermissionWindowController`, analytics event `CodexComputerUsePermissionWindowShown`. Imports `AXObserverCreateWithInfoCallback`, `AXObserverAddNotification`, `CGWindowListCopyWindowInfo`, `CGWindowListCreateDescriptionFromArray`, `CGRequestScreenCaptureAccess`, `CGPreflightScreenCaptureAccess`, `CGShieldingWindowLevel`. The "replicant" transition window matches the fly-in animation in AskForPermission (section 3). |
| **ChatGPT** 26.1016 (`com.openai.codex`, Electron) | Fallback text only | `ChatGPT.app/Contents/Resources/app.asar`: "If {appName} doesn't appear in {permissionSettingsName}, reveal it in Finder, then drag the app into the open System Settings panel" plus a "Show {appName} in Finder" button; legacy deep links for Accessibility, ListenEvent, Microphone, ScreenCapture. The floating helper is in the native Computer Use service above, not in this Electron shell. |
| **CuaDriver** 0.38.0 (`com.trycua.driver`) | No helper found | `strings` shows the Accessibility URL and doc text "If macOS offers **Quit & Reopen**, accept it." No `NSDraggingSource`/panel symbols in `cua-driver`. Text guide only. |
| **Cap** 0.6.0 (Tauri) | Open Settings only (binary) | URLs for `Privacy_Microphone`, `Privacy_ScreenCapture`. No drag strings. Frontend assets not searched. |
| **Dayflow** 2.7.1 | Open Settings only (binary) | URL for `Privacy_ScreenCapture`. |
| **Raycast** 2.6.2 | Open Settings only (binary) | Legacy URLs for Accessibility, AllFiles, Automation, Calendars, Camera, Contacts, etc. No drag strings. |
| **Handy**, **Cue** | Open Settings only (binary) | `Privacy_AllFiles` / `Privacy_Accessibility` URLs only. |
| **Tinycast** | Unclear | Has `Privacy_Accessibility` URL and `NSDraggingSource` symbol, but no guide strings. Not enough to call it a drag helper. |
| **Devin** (Electron fork of VS Code) | Not found | `main.js` has no privacy URLs. |
| **Wispr Flow** | Card with Allow button, then manual | Setup guide: onboarding cards for Microphone and Accessibility; fallback is "open System Settings → Privacy & Security and turn on Wispr Flow" ([docs.wisprflow.ai](https://docs.wisprflow.ai/articles/3152211871-setup-guide)). No drag helper found. |
| Codex docs | System prompts only | Docs say Screen Recording and Accessibility are requested through macOS prompts ([developers.openai.com/codex/app/computer-use](https://developers.openai.com/codex/app/computer-use)). The docs do not describe the drag helper. |
| Superwhisper, Rewind/Limitless, Screen Studio, CleanShot X, Bartender, Ice, Rectangle, Loop, Alcove, BetterTouchTool, Perplexity, Granola, Highlight AI, Windsurf, Claude desktop | **Not verified** | Not installed here and no source found in this pass. Do not assume. |
| Perry (this repo) | Open Settings only | `App/Onboarding/OnboardingCoordinator.swift:73,80` and `App/SettingsView.swift:295` open `com.apple.preference.security?Privacy_*` URLs. No drag helper, no panel. |

Classification: drag helper = HeyClicky, Codex Computer Use. Finder-reveal-plus-manual-drag text = ChatGPT. Open-Settings-only or text guide = everything else that was checkable.

## 3. Open-source implementations

All cloned shallow into `/tmp/r2` (untrusted, read only). Line numbers refer to those checkouts.

| Repo | License | Notes |
|---|---|---|
| [jaywcjlove/PermissionFlow](https://github.com/jaywcjlove/PermissionFlow) v2.11.4 (commit `65434c9`, 2026-10-23), 431★ | MIT | The reference library. macOS 13+, Swift 6 tools. Covers Accessibility, Screen Recording, Input Monitoring, Full Disk Access, App Management, Developer Tools. Has the macOS 27 rename. |
| [riko2chen/AskForPermission](https://github.com/riko2chen/AskForPermission) | MIT | Fly-in "replicant" animation, guide panel, `TCCPromptWatcher` drop race, Stage Manager detection. Best architecture doc: `docs/architecture.md`. |
| [kitlangton/scrawl](https://github.com/kitlangton/scrawl) `helper/PermissionPanel.swift` (1246 lines) | MIT | Single file. Fresh-process grant check, dock placement logic (below / inside / right / left), macOS 26/27 layout constants, reduce-motion path. Credits AskForPermission and PermissionFlow. |
| [arpitagarwal1301/PermissionPilot](https://github.com/arpitagarwal1301/PermissionPilot) | MIT | Not a docked panel; a drag card inside the app's own UI. Best notes on the pasteboard and on `CGRequestScreenCaptureAccess` prompt collisions. Has a `Relauncher`. |
| [iannuttall/barkeep](https://github.com/iannuttall/barkeep) `PermissionAssistant.swift` | MIT | 263 lines. `NSPasteboardItem` data provider for `.fileURL`. |
| [noma4i/clipmoar](https://github.com/noma4i/clipmoar) `AccessibilityDragWindow.swift` | MIT | 177 lines. Smallest working example. |
| [ElwinLiu/handless](https://github.com/ElwinLiu/handless) `permission_assistant.swift` | MIT | Tauri app with a Swift helper. Uses `.statusBar` level. |
| [linearmouse/linearmouse](https://github.com/linearmouse/linearmouse) PR #1442 | MIT | Production macOS 27 example. Adapted PermissionFlow ideas without a dependency and kept the MIT notice. |
| `Captain-Justin/dtools`, `erfansaffari/Calshot` | No license | Do not copy. |
| `ixxxxoooo/Quick`, `NanmiCoder/cc-haha` | NOASSERTION | Do not copy. |
| [sparrowcode/PermissionsKit](https://github.com/sparrowcode/PermissionsKit) | MIT | Status/request API only, no drag helper evidenced. |
| `ayangweb/permission-flow` | MIT | Rust wrapper around PermissionFlow. Not relevant. |
| `alt-tab-macos` | GPL-3.0 | Mentioned in search results. Not a drag helper. Do not copy. |

### How each one does the five hard parts

| Concern | PermissionFlow | AskForPermission | scrawl | PermissionPilot | clipmoar / barkeep |
|---|---|---|---|---|---|
| **Find Settings window** | `NSRunningApplication` for `com.apple.systempreferences`, then `CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements])`, filter by owner PID, layer 0, alpha > 0, size > 320×240, take largest (`Tracking/SettingsWindowTracker.swift:297-336`). Needs no permission. | Same call, matches owner **name** `"System Settings"` or `"System Preferences"`, ≥300×200 (`SystemSettingsWindowTracker.swift:79-106`). Name match breaks under localization. | Owner PID from bundle id (`:671-700`), layer 0, ≥300×200, largest. Then caches the window id and re-reads one window with `CGWindowListCreateDescriptionFromArray` (`:702`). | n/a (no docked panel). | clipmoar matches owner name (`:135-141`); barkeep uses the PID (`:94-116`). |
| **Track the window** | 30 Hz `Timer` (`:11`). If `AXIsProcessTrusted()`, also an `AXObserver` for moved/resized/main-window-changed (`:104-158`). Tracker needs 12 consecutive misses before it decides Settings closed (`:16`). | Polling task. Waits for two identical frames within a 1.2 s budget before the first dock, to ride out cold launch and the Dock genie animation (`docs/architecture.md`, "Cold-launching Settings"). | 60 Hz `Timer` in `.common` mode (`track()` at `:942`); closed after 0.6 s of misses; fades panel to 0 when another app is frontmost; 600 s timeout. | n/a | clipmoar 0.25 s, barkeep 0.2 s, handless 0.15 s timers. |
| **Panel** | `NSPanel` `[.borderless,.nonactivatingPanel]`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]`, `canBecomeKey/Main = false`, `hidesOnDeactivate = false` (`UI/FloatingDropPanel.swift:49-62,106-108`). `NSHostingView.sizingOptions = []` to stop SwiftUI resizing the window (`:80-82`). | Guide panel `.floating`, replicant `.screenSaver`, both `[.canJoinAllSpaces,.fullScreenAuxiliary]` (`Panel/GuidePanelWindow.swift:32-35`, `Replicant/FlightReplicantWindow.swift:77-84`). | `OverlayPanel`: `[.borderless,.nonactivatingPanel,.fullSizeContentView]`, `[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]`, `becomesKeyOnlyIfNeeded`, `animationBehavior = .none`, overrides `constrainFrameRect` (`:642-663`). | n/a | barkeep `.floating` + `.ignoresCycle` (`:35-37`); handless `.statusBar` + `.stationary` (`:394-397`). |
| **Pasteboard** | `AppBundlePasteboardWriter` writes `.fileURL`, `.URL`, `NSFilenamesPboardType` (`[path]`), `com.apple.pasteboard.promised-file-url`, `.string`; op mask `.copy`, `ignoreModifierKeys = true`, drag threshold 4 pt (`UI/AppDropArea.swift:80-171`). | `NSDraggingItem(pasteboardWriter: bundleURL as NSURL)`, `.copy`, drag image = snapshot of the whole row (`Drag/DraggableAppIconView.swift:119-186`). | `appURL as NSURL`, 3 pt threshold, opaque drag image drawn with `performAppearance` (`:497-520`). | `appURL as NSURL`; op mask `[.copy,.link,.generic]` for `.outsideApplication`, `[]` otherwise; `acceptsFirstMouse = true`, `mouseDownCanMoveWindow = false` (`AppBundleDragSource.swift:44-69`). | barkeep: `NSPasteboardItem.setDataProvider(forTypes:[.fileURL])`, data = `(appURL as NSURL).dataRepresentation` (`:238-258`). clipmoar: `bundleURL as NSURL`. |
| **Detect grant** | Accessibility: `AXIsProcessTrusted()`; Screen Recording: `CGPreflightScreenCaptureAccess()`; Input Monitoring: `CGPreflightListenEventAccess()` (status provider files, line 11 each). Does not describe relaunch. | Same three calls, plus a "drop race": after drop, wait for the earliest of grant flips, Settings window count dropping below its peak (TCC sheet dismissed), `NSApp.isActive` regaining, or a 10 s timeout; then sleep 200 ms and read once more (`docs/architecture.md` step 6). | Reads the grant in a **fresh child process** (`--check`) because `CGPreflightScreenCaptureAccess` caches per process (`:19`, `:174-198`); observes `com.apple.TCC.updated` (`:761`) to speed polling to 0.25 s for 5 s. | `AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`; `didBecomeActive` + 2 s poll (`PermissionProbe.swift:50-69`). | clipmoar polls `AXIsProcessTrusted` at 0.25 s; stops if Settings closed. |
| **Relaunch** | None in the library. | Docs only: "Screen Recording often requires the host app to relaunch" (`docs/integration.md:77`). | Fresh-process probe avoids relaunch for the check itself. | `Relauncher`: detached `/bin/sh -c "sleep 1; /usr/bin/open <bundle>"`, then `NSApp.terminate` (non-sandboxed); LaunchServices `createsNewApplicationInstance` path for sandboxed (`Relauncher.swift:22-88`). | n/a |

Related facts:

- `cc-haha` (NOASSERTION) probes with a fresh `cu-helper check_permissions` child for both Accessibility and Screen Recording, on the claim that the in-process checks "stay STALE-false" (`:502-563`). Only a single-source claim for Accessibility; PermissionFlow and Pilot treat `AXIsProcessTrusted()` as live.
- `parakeet` PR #4 ([LPFchan/parakeet#4](https://github.com/LPFchan/parakeet/pull/4)) also uses a fresh process every 0.5 s for Screen Recording, and reports that dropping the app reached "macOS's admin-password prompt".
- `drift` PR #15 ([woosublee/drift#15](https://github.com/woosublee/drift/pull/15)) swapped a plain deep link for PermissionFlow 2.11.2 and removed the system prompt from the settings button to avoid two UIs at once.
- LinearMouse PR #1442 ([link](https://github.com/linearmouse/linearmouse/pull/1442)): drag guide does not trigger the system alert; app restarts once after a newly seen Accessibility grant because event taps may not work in the current process.

## 4. Platform facts (macOS 15, 26, 27)

### Deep links

| Pane | Anchor | Works today? |
|---|---|---|
| Accessibility (macOS 27 title: "Device Control and Data Access") | `Privacy_Accessibility` | Yes. Anchor string present in `SecurityPrivacyExtension` on this Mac (macOS 27.0.1, build 26A434). |
| Screen & System Audio Recording | `Privacy_ScreenCapture` | Yes (same check). |
| Microphone | `Privacy_Microphone` | Yes (same check). |
| Automation | `Privacy_Automation` | Yes (same check). |
| Input Monitoring | `Privacy_ListenEvent` | Used by PermissionFlow (`SystemSettingsDestination.swift:201`), Perry (`SettingsView.swift:245`) and ChatGPT's asar. **Not found** as a standalone string in this Mac's `SecurityPrivacyExtension`; verify at runtime. |
| Full Disk Access | `Privacy_AllFiles` | Same caveat as Input Monitoring. |

Two URL forms exist. Both are in use in the wild:

- Legacy: `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` (Raycast, Cap, Dayflow, CuaDriver, ChatGPT, Perry).
- Current: `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility` (PermissionFlow `SystemSettingsDestination.swift:255-263,272-290`; scrawl `:171`; AskForPermission; HeyClicky ships both).
- Extension bundle id on this Mac is `com.apple.settings.PrivacySecurity.extension` (`/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Info.plist`).
- A Stim issue reports the legacy form still opens the renamed macOS 27 pane ([appandflow/stim#2494](https://github.com/appandflow/stim/issues/2494)); I did not open either URL here.

**Recommendation:** use the current form, fall back to the legacy form if `NSWorkspace.open` returns false.

**How to verify on a test Mac** (not done here, because it opens Settings): `open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"`, and `strings -a /System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/MacOS/SecurityPrivacyExtension | grep '^Privacy_'` (this one was run here and is read-only).

### macOS 27 rename

Accessibility is labelled **Device Control and Data Access** in Privacy & Security; the anchor and URL are unchanged ([PermissionFlow `PermissionFlowPane.swift:11-13,83-88`](https://github.com/jaywcjlove/PermissionFlow); [Microsoft Learn](https://learn.microsoft.com/en-us/purview/endpoint-dlp-macos-27-changes); [mjtsai](https://mjtsai.com/blog/2026/09/14/macos-27-golden-gate/)). Screen Recording is **Screen & System Audio Recording** (macOS 15+, per the Stim issue above). Branch copy on `ProcessInfo.operatingSystemVersion.majorVersion >= 27`.

### Drag-and-drop versus "+"

- Apple's own page says "click the Add button below the list, then navigate to the app" ([Apple Support](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)); it does not mention drag.
- Drag works in practice for Accessibility and Screen Recording on current macOS: PermissionFlow's README, PermissionPilot's header comment (`AppBundleDragSource.swift:4-13`), parakeet (drop reached the admin-password prompt), LinearMouse (tested on macOS 27). So "+" is not required, but it is the documented fallback; show it in the help text.
- The payload has to look like a Finder drag: a real file URL for the installed bundle. PermissionPilot reports that SwiftUI `.onDrag { NSItemProvider(contentsOf:) }` produces a file promise with copy only, and the list refuses it (`AppBundleDragSource.swift:4-13`). Use AppKit.
- After the drop, macOS asks for an administrator password (parakeet PR #4). Say so in the copy.
- Microphone, Camera, Calendars, Reminders do **not** use a manual list. The app appears only after it calls the request API. PermissionFlow disables its panel for them (`PermissionFlowPane.swift:64-71`); AskForPermission calls them out of scope. Automation is per-target: use `AEDeterminePermissionToAutomateTarget(target, class, id, askUserIfNeeded: true)` (SDK header `AppleEvents.h:363`, macOS 10.14+, returns `errAEEventWouldRequireUserConsent` (-1744) when it cannot prompt).

### Request APIs and prompts

| API | Documented? | Behavior |
|---|---|---|
| `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` | Yes (`AXUIElement.h:55-66`) | "Prompting occurs asynchronously and does not affect the return value." Prompt offers "Open System Settings". |
| `AXIsProcessTrusted()` | Yes | Live. Flips without relaunch (PermissionFlow, Pilot, AskForPermission all rely on it). Event taps created earlier may still need a restart (LinearMouse PR). |
| `CGPreflightScreenCaptureAccess()` | Yes (`CGWindow.h:294-300`) | "without prompting". Returns the answer cached at first call in the process (Pilot `PermissionProbe.swift:56-59`; scrawl `:19`). |
| `CGRequestScreenCaptureAccess()` | Yes (`CGWindow.h:302-308`) | Prompts if undetermined. "A previously denied process is not re-prompted." Still prompts on macOS 27 for an undecided process. PermissionPilot's author reports it prompts on the **first request of every launch** until granted, "verified: 5 launches, 5 prompts" (`PermissionProbe.swift:159-161`). Single source. |
| `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` | Yes (`CGEvent.h:399,402`) | Input Monitoring. Grant takes effect after relaunch (Pilot `Permission.swift`, `mayRequireRelaunch`). |
| `IOHIDCheckAccess` / `IOHIDRequestAccess` | Yes | Alternate Input Monitoring route used by Pilot. |
| `com.apple.TCC.updated` distributed notification | **No** | Observed by scrawl (`:761`). Use only to speed polling. |
| `TCCAccessPreflight` via `dlopen` of `TCC.framework` | **No (private SPI)** | Used by AskForPermission only for Developer Tools and App Management. Avoid. |

### Monthly Screen Recording re-consent

- macOS 15 (Sequoia) added a recurring "allow this app to keep recording?" prompt. Early betas asked weekly; the shipped cadence is **monthly** ([TechRadar](https://www.techradar.com/computing/mac-os/on-macos-sequoia-youll-only-have-to-deal-with-screen-recording-permission-pop-ups-once-a-month-rather-than-once-a-week), headline only; page body not retrievable).
- Apple's current support page does not mention it (fetched above).
- Tahoe: an enterprise vendor thread reports repeated prompts even after Allow ([BeyondTrust](https://beekeepers.beyondtrust.com/general-45/beyondtrust-remote-support-customer-client-repeated-screen-capture-permission-pop-ups-on-macos-tahoe-7998)); a Teams thread reports a permission loop on 26.4 ([Microsoft Q&A](https://learn.microsoft.com/en-sg/answers/questions/5848423/teams-for-mac-screen-sharing-permission-loop-on-ma)). Not general rules.
- No source found that gives an API to suppress it, and no source found on how `CGRequestScreenCaptureAccess` interacts with it. Treat as **unknown**. Design so a lost grant is detected (poll `CGPreflightScreenCaptureAccess` in a fresh process, see section 6) and the helper can be re-opened from Perry's menu.
- Lead, not verified: HeyClicky ships a ScreenCaptureKit "picker" step ("The ScreenCaptureKit picker needs to finish once before HeyClicky can inspect content", "Open Screen Content Picker"). That may reflect a macOS 27 flow; I could not confirm what it replaces.

### Relaunch rules

- **Screen Recording:** after the toggle, System Settings may show a **Quit & Reopen** sheet. HeyClicky copy: "Mac can require a relaunch after you toggle Screen Recording on."; "Click Quit & Reopen to finish Screen Recording." CuaDriver strings say the same. scrawl treats the sheet as an extra Settings window (`SettingsWindow.count()`, `:714`).
- **Accessibility:** HeyClicky copy: "Accessibility should not need a relaunch." LinearMouse restarts once after a newly seen grant if it uses event taps.
- **Input Monitoring:** grant applies after relaunch (Pilot).

## 5. Edge cases

| Case | Handling | Evidence |
|---|---|---|
| **Multiple displays** | CG window bounds are global, top-left origin, in points. AppKit frames are bottom-left. Do not subtract from `NSScreen.screens.first.frame.height` blindly; map through each screen's `CGDisplayBounds` (PermissionFlow `appKitFrame` `:346-376`). Clamp the panel to the `visibleFrame` of the screen that contains the Settings window. | PermissionFlow `SettingsWindowTracker.swift:346-376`; clipmoar `:135-141` (single-primary shortcut); barkeep `:118-132`. |
| **Settings already open on another pane** | `NSWorkspace.open(url)` navigates the existing window. Keep tracking the same window id; the panel does not need to restart. If Settings is not frontmost, show a gear button that re-opens the pane. Pane title is not readable without Screen Recording (window titles are gated) or AX **(inference)**. | PermissionFlow `PermissionFlowPanelView.swift:78-88`; Pilot `SystemPromptWatch.swift` doc: "only titles are gated". |
| **Settings window closed or minimized** | Count misses; close after 0.6 s (scrawl) or 12 polls at 30 Hz = 0.4 s (PermissionFlow). Minimized-to-Dock windows are not on screen, so `.optionOnScreenOnly` drops them; wait for a stable frame (2 samples, 1.2 s budget) on restore. | AskForPermission architecture doc. |
| **Wrong app copy (DMG, Downloads, translocation)** | The drag payload is `Bundle.main.bundleURL`. If the path contains `/AppTranslocation/`, starts with `/Volumes/`, or is outside `/Applications` and `~/Applications`, the entry points at the wrong place. Block the helper, ask the user to move Perry to Applications and relaunch. TCC keys grants by code identity and path **(inference; not tested here)**. No repo checked does this guard; PermissionFlow and others just use `Bundle.main.bundleURL` (`PermissionFlowController.swift:152-158`). |  |
| **Dark / light** | Use a material background (`.ultraThinMaterial`, PermissionFlow `PermissionFlowPanelView.swift:15-22`). Render the drag image under `effectiveAppearance.performAsCurrentDrawingAppearance` so it is opaque and legible over any window (scrawl `:500-520`). |  |
| **Stage Manager** | Use `[.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]` and **omit** `.transient` so the panel survives window piles being rearranged when Settings activates. AskForPermission detects Stage Manager via `com.apple.WindowManager` / `GloballyEnabled` (`Platform/StageManagerDetection.swift`); scrawl adds `.ignoresCycle`. |  |
| **Panel steals focus** | `canBecomeKey/Main = false`, `.nonactivatingPanel`, `acceptsFirstMouse = true`. PermissionFlow also calls `SystemSettings.activate()` on `becomeKey`/`sendEvent` (`FloatingDropPanel.swift:112-131`). |  |
| **Another app in front** | scrawl fades the panel to alpha 0 unless Settings, the host app, or a drag is active (`:957-972`). PermissionFlow leaves it floating. Prefer scrawl's behavior. |  |
| **Panel covers the drop target** | HeyClicky and Codex dock inside the lower part of the window. PermissionFlow makes the panel mouse-transparent and `orderBack`s it for the drag's duration (`FloatingDropPanel.swift:200-208`). The dragged image itself is a separate system dragging window. Whether passthrough is required is untested **(unverified)**; keep it, it is cheap. |  |
| **System prompt collision** | If you call `AXIsProcessTrustedWithOptions(prompt)` or `CGRequestScreenCaptureAccess()` and also open the pane yourself, the prompt can get stranded. Pilot watches for prompt windows owned by `universalAccessAuthWarn` or `UserNotificationCenter` and opens the pane only if none appears (`SystemPromptWatch.swift:25-70`). Simpler: do not call the prompting variant at all. Open the pane and show the helper. LinearMouse and drift both removed the prompt for this reason. |  |

## 6. Recipe for Perry

Signatures only. Names are suggestions. All types `@MainActor` unless noted. No dependency; ideas from the MIT sources above can be reimplemented. If any code is copied verbatim, keep that repo's MIT notice (LinearMouse PR #1442 did exactly this).

### 6.1 Pane model and opening

```swift
enum PrivacyPane: String, CaseIterable {
    case accessibility, screenRecording, inputMonitoring, fullDiskAccess
    var anchor: String { get }                 // "Privacy_Accessibility", "Privacy_ScreenCapture", "Privacy_ListenEvent", "Privacy_AllFiles"
    var url: URL { get }                       // x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?<anchor>
    var legacyURL: URL { get }                 // x-apple.systempreferences:com.apple.preference.security?<anchor>
    var supportsDrag: Bool { get }             // true for these four; false for microphone/automation/camera
    func displayName(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String
        // accessibility -> osMajor >= 27 ? "Device Control and Data Access" : "Accessibility"
        // screenRecording -> "Screen & System Audio Recording" (macOS 15+)
    var relaunchLikelyAfterGrant: Bool { get } // true: screenRecording, inputMonitoring
}

func openPane(_ pane: PrivacyPane) -> Bool
    // NSWorkspace.shared.open(url) ?? open(legacyURL); then activate com.apple.systempreferences with .activateIgnoringOtherApps
```

PermissionFlow also launches `/System/Applications/System Settings.app` via `openApplication` before opening the URL (`SettingsNavigator.swift:12-21`). Only needed if a cold launch drops the deep link; test it.

### 6.2 Find and track the Settings window

```swift
struct SettingsWindowSnapshot: Equatable { let id: CGWindowID; let frame: CGRect /* AppKit, bottom-left */; let screen: NSScreen? }

@MainActor final class SettingsWindowTracker {
    var onChange: (SettingsWindowSnapshot) -> Void
    var onGone: () -> Void
    func start()                                      // Timer(1.0/60) on RunLoop .common
    func stop()
    func waitForStableFrame(budget: Duration = .milliseconds(1200)) async -> SettingsWindowSnapshot?
}

// Internals
func settingsPIDs() -> Set<pid_t>                     // NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
func mainSettingsWindow() -> (id: CGWindowID, cgFrame: CGRect)?
    // CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID)
    // filter ownerPID in settingsPIDs, kCGWindowLayer == 0, alpha > 0, w >= 300, h >= 200; largest area wins
func frame(of id: CGWindowID) -> CGRect?              // CGWindowListCreateDescriptionFromArray, kCGWindowIsOnscreen
func appKitFrame(fromCG cg: CGRect) -> (CGRect, NSScreen?) // map via NSScreen.deviceDescription["NSScreenNumber"] + CGDisplayBounds
```

Rules:

- No Accessibility needed; it would be untrusted during the very step you are guiding. Skip `AXObserver`.
- Treat the window as gone only after ~0.5 s of misses.
- Do not read `kCGWindowName`; it is gated.
- Optional later: `AXObserver` as a latency optimisation when `AXIsProcessTrusted()` (PermissionFlow `:104-158`, Codex imports the same symbols).

### 6.3 Dock placement

```swift
enum Dock { case below, inside, right, left, clamped }
func dockFrame(settings: NSRect, visible: NSRect, cardSize: CGSize) -> (NSRect, Dock)
```

Order (scrawl `:237-271`): below the window if it fits `visibleFrame` (10 pt gap), else inside the window's empty lower 30% (20 pt above the bottom edge, as Codex and HeyClicky do), else right, else left, else clamp. Horizontal anchor: the list column, not the sidebar. scrawl's macOS 26/27 constants: sidebar 232 pt, list starts 252 pt from the window's left edge and ends 20 pt before the right edge, window corners about 26 pt round (`:48-52`). PermissionFlow uses sidebar 230 (`FloatingDropPanel.swift:17`). Constants are measured, not documented: re-check on each major macOS.

### 6.4 Helper panel

```swift
final class PermissionHelperPanel: NSPanel {
    init(contentRect: NSRect)
        // styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView]
        // level = .floating; isFloatingPanel = true; hidesOnDeactivate = false
        // collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // isOpaque = false; backgroundColor = .clear; hasShadow = false (draw shadow in the view)
        // animationBehavior = .none; becomesKeyOnlyIfNeeded = true
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to: NSScreen?) -> NSRect { r }   // keep fly-in off the menu bar clamp
    func setDragging(_ on: Bool)       // ignoresMouseEvents = on; alphaValue = on ? 0.72 : 1; on ? orderBack(nil) : orderFrontRegardless()
    func setVisibleFor(frontmost: NSRunningApplication?, dragging: Bool) // fade to 0 unless Settings, Perry, or dragging
}

struct PermissionHelperView: View {      // SwiftUI content, hosted with NSHostingView.sizingOptions = []
    let pane: PrivacyPane; let appName: String; let appURL: URL
    var phase: Phase                      // .instruction, .dropping, .waitingForRelaunch, .granted
    var onClose: () -> Void; var onReopenPane: () -> Void
}
```

Use `NSHostingView.sizingOptions = []` (macOS 13.3+) and size the panel yourself; otherwise SwiftUI resizes the window and reverts your frames (PermissionFlow `FloatingDropPanel.swift:64-83`).

### 6.5 Drag source

```swift
final class AppBundleDragView: NSView, NSDraggingSource {
    var appURL: URL
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with: NSEvent)               // store event
    override func mouseDragged(with: NSEvent)            // after 3–4 pt: begin session
    override func resetCursorRects()                     // .openHand
    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor: NSDraggingContext) -> NSDragOperation
        // .outsideApplication -> [.copy, .link, .generic]; .withinApplication -> []
    func draggingSession(_: NSDraggingSession, willBeginAt: NSPoint)
    func draggingSession(_: NSDraggingSession, endedAt: NSPoint, operation: NSDragOperation)
}
// beginAppDrag:
//   let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)         // file URL, like Finder
//   item.setDraggingFrame(bounds, contents: opaqueRowSnapshot)           // whole row, not only the icon
//   let s = beginDraggingSession(with: [item], event: down, source: self)
//   s.animatesToStartingPositionsOnCancelOrFail = true; s.draggingFormation = .none
```

Start with the plain `NSURL` writer (four repos use only that). If a test Mac refuses the drop, widen to PermissionFlow's multi-type writer (`.fileURL`, `.URL`, `NSFilenamesPboardType`, `com.apple.pasteboard.promised-file-url`, `.string`; `AppDropArea.swift:141-171`). Never use SwiftUI `.onDrag`. `NSFilePromiseProvider` is the wrong tool: Pilot reports the list refuses promises (`AppBundleDragSource.swift:4-13`).

### 6.6 Grant detection

```swift
enum GrantState { case granted, notGranted }

protocol GrantProbe { func isGranted(_ pane: PrivacyPane) async -> Bool }

struct InProcessProbe: GrantProbe       // accessibility: AXIsProcessTrusted()
                                        // inputMonitoring: CGPreflightListenEventAccess() (stale until relaunch)
struct FreshProcessProbe: GrantProbe    // screenRecording: Process(Bundle.main.executableURL, ["--check-permission", pane.rawValue]) -> {"granted":Bool}
                                        // handle the flag in main() before NSApplication starts; exit 0 immediately

@MainActor final class GrantMonitor {
    func start(pane: PrivacyPane, onGranted: @escaping () -> Void)
        // poll 0.75 s idle; 0.25 s for 5 s after com.apple.TCC.updated (DistributedNotificationCenter) or after a drop
        // also re-check on NSApplication.didBecomeActiveNotification
    func noteDropped()      // start the drop race: fast poll for ≤10 s, watch SettingsWindowTracker window count vs peak (TCC sheet or Quit & Reopen sheet), re-read 200 ms after count falls
    func stop()
}
```

Notes:

- A drop is a hint, never the answer (scrawl `dragEnded`, `:1022-1040`). Fade the panel out during the drop race so the password sheet is not covered, then fade back in if the grant is still missing.
- Do not call `CGRequestScreenCaptureAccess()` or `AXIsProcessTrustedWithOptions(prompt:)` while the helper is open; see section 5.

### 6.7 Relaunch handling

```swift
enum RelaunchNeed { case none, advised, required }
func relaunchNeed(for pane: PrivacyPane, grantedInFreshProbe: Bool, grantedInProcess: Bool) -> RelaunchNeed
    // screenRecording/inputMonitoring: fresh=true && inProcess=false -> .required
    // accessibility: .none, or .advised if Perry owns an event tap created before the grant
func relaunchSelf()
    // Process /bin/sh -c "sleep 1; /usr/bin/open \"<bundle path>\""; then NSApp.terminate(nil)  (Pilot Relauncher.swift:28-43)
    // Perry is not sandboxed, so the shell helper is allowed. Persist the "resume permission step N" state before terminating.
```

Flow: grant seen by the fresh probe but not in-process → panel phase `.waitingForRelaunch`: "Choose **Quit & Reopen** if macOS asks. If you pick Later, use the button below." Show a **Restart Perry** button that calls `relaunchSelf()`. After relaunch, resume at the next unmet permission.

### 6.8 Flow coordinator

```swift
@MainActor final class PermissionGuideCoordinator {
    func present(_ pane: PrivacyPane, from sourceRect: CGRect?) async -> GrantState
        // 1. guard bundle location (not translocated / not /Volumes / in Applications) else show move-to-Applications message
        // 2. if grant already true -> return .granted
        // 3. openPane(pane); await tracker.waitForStableFrame()
        // 4. build panel, fly in (or fade if Reduce Motion), start tracker + GrantMonitor
        // 5. on granted -> checkmark phase -> fade out (0.4 s) -> return
        // 6. on Settings gone > 0.5 s, 600 s timeout, user close -> cancel and return .notGranted
    func dismiss(returnFocusToPerry: Bool)
}
```

One active guide at a time (PermissionFlow closes the previous controller, `PermissionFlowController.swift:211-215`).

## 7. Copy and motion

### Copy

Evidence from shipped apps:

- HeyClicky: "I'm HeyClicky — drag me into the list above." (header); "Drag me into the Accessibility list."; "Drag me into Screen Recording."; "Enable HeyClicky, then choose Quit & Reopen if asked."; "Mac can require a relaunch after you toggle Screen Recording on."; "Accessibility should not need a relaunch. If it still looks stuck, reopen the pane and make sure HeyClicky is fully allowed."
- PermissionFlow: "Drag **{App}** to the list above to allow **{Permission}**."; tooltip "Drag"; loading "Opening System Settings...".
- clipmoar tooltip: "Drag into the Accessibility list".

Recommended Perry copy (short, one idea per line; names resolved at runtime):

| State | Copy |
|---|---|
| Opening | "Opening System Settings…" |
| Instruction (header) | "Drag Perry into the list above." |
| Instruction (sub, Accessibility) | "Then switch it on in **{Device Control and Data Access / Accessibility}**." |
| Instruction (sub, Screen Recording) | "Then switch it on in **Screen & System Audio Recording**." |
| Drag row hint | "Drag" with a hand glyph (PermissionFlow uses `hand.draw`) |
| Password | "macOS will ask for your password." |
| Restart needed | "Choose **Quit & Reopen** if macOS asks." Button: "Restart Perry" |
| Granted | "Perry has access." (checkmark, then fade) |
| Fallback help (small, under the row) | "Perry not in the list? Click **+** under the list and choose Perry." Button: "Show Perry in Finder" (ChatGPT does the same) |
| Wrong location | "Move Perry to Applications first, then try again." |

### Motion

- **Fly-in** from the Grant button to the dock: spring, duration 0.85 s, no bounce, width leading height (scrawl `:34-40`); or quadratic Bézier with apex ~160 pt and ease-in-out (AskForPermission); or PermissionFlow's critically damped response 0.72 s with Bézier lift 44–140 pt (`FloatingDropPanel.swift:24,419-456`). Pick one. Recommendation: scrawl's spring, settle time = 1.8 × duration.
- **Landing**: AskForPermission uses an underdamped spring (mass 1, stiffness 200, damping 11) for a visible settle. Optional.
- **Header arrow**: gentle wiggle (±12°, 0.22 s autoreverse) while idle, pulse while dragging (PermissionFlow `HeaderDirectionIcon`, `PermissionFlowPanelView.swift:162-195`).
- **Drag**: panel alpha 0.72 while dragging; drag image is the whole row, opaque, 56 pt icon or row snapshot; `animatesToStartingPositionsOnCancelOrFail = true`.
- **Drop**: fade panel to 0 in 0.18 s so the password sheet is clear; fade back if not granted.
- **Reduce Motion** (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`): no flight; 0.18 s fades only (scrawl `:38`, `fadeDuration`).
- **Grant**: swap the row for a checkmark, hold ~1 s, fade out. `cc-haha` (no license, idea only) rests 1.1 s on the all-green card before closing (`PermissionCard.swift`, around `:521-527`).
- **Verify visually** on a test Mac per `AGENTS.md`: record with `scripts/lab/record.sh`, drive with `scripts/lab/` plus `cua-driver`. Not done here (no GUI allowed).

## 8. What I could not verify

- Whether HeyClicky embeds PermissionFlow. Its own symbols suggest a custom implementation, but source is closed.
- How Codex attaches its accessory window: public AppKit cannot parent a window to another process's window **(inference)**, so it almost certainly uses a floating overlay at a tracked frame, like the others.
- Which of `Privacy_ListenEvent` / `Privacy_AllFiles` the macOS 27 Settings extension accepts. Not found as strings in `SecurityPrivacyExtension`.
- The exact current cadence of the Screen Recording re-consent prompt on macOS 26 and 27, and how it interacts with `CGRequestScreenCaptureAccess`.
- That `Bundle.main.bundleURL` under translocation or a DMG is a bad drop payload. Reasoned, not tested.
- Whether the panel needs mouse passthrough during the drag.
- Apps listed as "Not verified" in section 2.
- The prose skill named in `AGENTS.md` was not in the available skill list, so the report is written in plain technical prose without its audit.

## 9. Sources

- PermissionFlow: https://github.com/jaywcjlove/PermissionFlow (MIT, commit `65434c9`)
- AskForPermission: https://github.com/riko2chen/AskForPermission (MIT)
- scrawl: https://github.com/kitlangton/scrawl (MIT), `helper/PermissionPanel.swift`
- PermissionPilot: https://github.com/arpitagarwal1301/PermissionPilot (MIT)
- barkeep: https://github.com/iannuttall/barkeep (MIT), clipmoar: https://github.com/noma4i/clipmoar (MIT), handless: https://github.com/ElwinLiu/handless (MIT)
- LinearMouse PR: https://github.com/linearmouse/linearmouse/pull/1442
- parakeet PR: https://github.com/LPFchan/parakeet/pull/4 ; drift PR: https://github.com/woosublee/drift/pull/15
- Stim issue: https://github.com/appandflow/stim/issues/2494
- Microsoft Learn, Endpoint DLP on macOS 27: https://learn.microsoft.com/en-us/purview/endpoint-dlp-macos-27-changes
- Michael Tsai, macOS 27 Golden Gate: https://mjtsai.com/blog/2026/09/14/macos-27-golden-gate/
- Apple Support, screen and system audio recording: https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac
- TechRadar, monthly prompt: https://www.techradar.com/computing/mac-os/on-macos-sequoia-youll-only-have-to-deal-with-screen-recording-permission-pop-ups-once-a-month-rather-than-once-a-week
- Wispr Flow setup: https://docs.wisprflow.ai/articles/3152211871-setup-guide
- Codex Computer Use docs: https://developers.openai.com/codex/app/computer-use
- Local SDK headers: `…/MacOSX.sdk/System/Library/Frameworks/CoreGraphics.framework/Headers/CGWindow.h:294-308`, `CGEvent.h:399-402`, `…/HIServices.framework/Headers/AXUIElement.h:55-66`, `…/AE.framework/Headers/AppleEvents.h:349-366`
- Local bundles: `/Applications/HeyClicky.app`, `~/.codex/computer-use/Codex Computer Use.app`, `/Applications/ChatGPT.app/Contents/Resources/app.asar`, `/Applications/CuaDriver.app`, `/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex`
- Screenshots supplied by the user (HeyClicky docked panel and onboarding card), `~/.t3/userdata/attachments/58557fdf-…`
