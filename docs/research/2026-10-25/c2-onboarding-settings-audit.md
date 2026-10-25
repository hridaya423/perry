# C2 audit: onboarding, Settings, command menu, design system

Date: 2026-10-25. Branch: `codex/living-ink-redesign`. Read-only code audit. Nothing was built, launched or run.
Evidence is static: file and line only. Claims about runtime behavior are marked **(inferred)** when I did not run the app.

Paths are relative to the repo root. `OP` = `App/Onboarding/OnboardingParts.swift`. `HOV` = `App/Home/HomeOnboardingView.swift`. `OD` = `App/Onboarding/OnboardingDirector.swift`. `OC` = `App/Onboarding/OnboardingCoordinator.swift`. `SV` = `App/SettingsView.swift`. `SM` = `App/StatusMenuController.swift`.

## 0. Surprises (read first)

1. **`HelloInk.metal` does not exist.** `find . -name '*.metal'` outside `build/` returns nothing. `HelloInk` is a Swift enum (`App/Onboarding/HelloGreetingView.swift:4`). The grain is a CPU `Canvas` (`OP:459-474`). The AGENTS.md note that a clean build needs the Metal Toolchain for `App/Onboarding/HelloInk.metal` is stale for this tree.
2. **The first answer runs before a model is chosen.** Beat order is `greet, firstTalk, screenAccess, brainChoice, practice, finale` (`OD:7-9`). The default choice is `"chatGPT"` (`App/PerryPreferences.swift:56`). The only rescue is `preferOnDeviceModelIfUnchosen()` (`App/Brain/BrainController.swift:284-290`), run on entering `firstTalk` (`OD:193-194`). It works only if `onDeviceRouteAvailable` (`BrainController.swift:273-279`): Apple Foundation Models on macOS 26+, or a local model that already passed `checkLocalModel`. Nothing in onboarding runs that check. An Ollama or LM Studio user, or anyone without Apple Intelligence, reaches `firstTalk` on an un-signed-in ChatGPT route. The first turn then fails **(inferred)**: `route()` pins `providerID = .codex` (`BrainController.swift:350-351`).
3. **Finale teaches a gesture onboarding never made work.** `FinaleBeat` shows "Hold to talk" `⌃⌥` and "Double-tap to type" `⌃⌃` (`HOV:557-558`). Both use a listen-only event tap (`App/Talk/ModifierHoldMonitor.swift:65-74`). Input Monitoring is requested only from Settings (`SV:244`), never in onboarding. The NSEvent fallback only sees Perry's own events per the comment at `App/PushToTalkController.swift:59-61`. The gesture can be dead after "Start using Perry" **(inferred)**.
4. **Talk hold overlaps the ⌃⌥⌘ dictation option.** `ModifierHoldMonitor.handle` fires on `control && option` and ignores ⌘ (`ModifierHoldMonitor.swift:166`). `PushToTalkShortcut.controlOptionCommandHold` is "Hold ⌃⌥⌘" (`PushToTalkController.swift:16`). Choosing it fires both **(inferred)**.
5. **The practice window is excluded from screen capture.** `PerryWindowChrome.applyChrome` sets `sharingType = .none` (`Packages/PerryOverlay/Sources/PerryOverlay/PerryTypes.swift:217-221`). `PracticeWindow.makeWindow` calls it (`App/Onboarding/PracticeWindow.swift:126`). The step "Point at something in the practice window … and ask what it is" (`OD:206`) may get no pixels of that window **(inferred)**. AX text may still work.
6. **Practice steps do not verify what their hints say.**
   - `pointAsk` completes on any completed Talk turn (`OD:83-84`). It does not check that the user pointed.
   - `dictate` completes on any text in the notes box, typed or dictated (`PracticeWindow.swift:187-189`; the doc comment at `:18` admits "dictated or typed").
   - `renameUndo` is done by two window buttons, not by Perry (`PracticeWindow.swift:167-168`; the header comment at `:9-10` admits it).
   - `dictatedFired` is never reset (`PracticeWindow.swift:27,105-109`). `practiceWindow` is a `lazy var` on a long-lived coordinator (`OC:17`). On a replay via "Set up Perry…" the dictate step cannot complete until skipped **(inferred)**.
7. **Login item is turned on silently.** `OC:127-129` calls `LoginItem.setEnabled(true)` in release on first completion (`try?`, no UI). Finale prints "Opens at login. Change it in Settings." with `on: true` always (`HOV:541`). That is false in DEBUG and when registration throws.
8. **Memory has three stores and one is inert.**
   - `MemoryStore` (`Packages/PerryGuide/Sources/PerryGuide/MemoryStore.swift:46`) writes `memory.json` plus `PROFILE.md` and `VOLATILE.md` in the support dir (`:196-197`). It is **off by default**: `MemoryConfiguration.enabled = false` (`MemoryStore.swift:36`), and `remember()` returns false when disabled (`:94-97`).
   - `MemoryFiles` (`Packages/PerryBrain/Sources/PerryBrain/Perrys/MemoryFiles.swift`) writes `<support>/memory/PROFILE.md` and `CONTEXT.md` (`App/Tools/AppToolHost.swift:65`). Its doc comment says "injected into Talk and agent prompts via `promptBlock()`". No caller does that: `promptBlock()` is used only inside `memory.read` (`MemoryTools.swift:30`).
   - The erasure target is `<support>/PROFILE.md`, not `<support>/memory/PROFILE.md` (`App/PerryErasureErasers.swift:441`). Erase-all appears to miss the `MemoryFiles` copy **(inferred, paths differ)**.
   - Per-Perry memory is a third file (`PerryStore.swift:108-126`).
9. **A permanently grey menu item.** "Check for Updates…" is enabled only when an update is already available (`SM:149-152`).
10. **The dictation note contradicts its own picker.** "Hold it in any app to type by voice. Double-tap Caps Lock for hands-free." (`SV:189`) sits under a picker that offers Caps Lock double-tap as one of four exclusive options (`PushToTalkController.swift:3-8`).
11. **Closing onboarding with X does not complete it.** X calls `collapseNotch` (`App/Onboarding/OnboardingNotchView.swift:33`). `onboardingCompleted` stays false and the saved beat persists (`OD:191`). Every launch re-opens onboarding at that beat (`App/AppController.swift:332`; DEBUG: `App/DebugLaunchSeams.swift:141`).

---

## 1. Onboarding inventory

### 1.1 Shell

| Item | Detail |
|---|---|
| Host | Expanded notch. `HomeView` shows `OnboardingNotchView` when `model.onboarding != nil && sidebarSelection != .settings` (`App/Home/HomeView.swift:13-14`). |
| Size | `onboardingContentWidth` 560 × `onboardingContentHeight` 430 (`App/PerryTheme.swift:72-73`; applied `OnboardingNotchView.swift:58-62`). Content padding 24 horizontal, 14 bottom (`:55-56`). Top bar 36 pt (`:44`). |
| Chrome | Black `cameraCrown` background + `SketchbookGrain` (`OnboardingNotchView.swift:65-66`). Progress is 6 capsules (`OP:109-124`), replaced on `greet` by `NotchPeek` (`OnboardingNotchView.swift:17-19`). Back button leading, Close X trailing (`:24-42`). |
| Back | `canGoBack` is false only on `greet` (`OD:53-56`). `goBack` ends the practice window when leaving `practice` (`OD:75`). |
| Close X | `collapseNotch`; does not mark done (see surprise 11). `.keyboardShortcut(.cancelAction)` (`OnboardingNotchView.swift:41`). |
| Resume | `OD.start(resume:)` reads the saved beat and practice step (`OD:58-67`). `runIfNeeded` resumes (`OC:43-46`). "Set up Perry…" passes `force: true`, which restarts from `greet` (`App/PerryApp.swift:46`, `App/AppController.swift:508-510`). Other callers: `AppSubsystems.swift:416,599`, `DemoFlowController.swift:109`. |
| Persistence keys | `perry.onboarding.completed` (`PerryPreferences.swift:41`), `perry.onboarding.beat` (`:42`), `perry.onboarding.practice` (`:43`). Brain card taps write `perry.brain.modelChoice` (`:56`) immediately (`BrainController.swift:26-33`). Shortcut keys `perry.wakeShortcut`, `perry.ptt.shortcut` (`:51-52`) are only read here. |
| Finish | `OC.finish` (`:121-137`): completed = true, login item on (release only), clear bubble, `collapseNotch`. |
| Transition | 0.5 s slide + blur per beat (`OnboardingNotchView.swift:73-81`). |
| Layout primitive | `OnboardingBeatLayout`: art (120 pt) → title (26 semibold) → message (14, max 400 wide) → detail (max 420 wide) → spacer → actions (`OP:15-53`). Footer is 46 pt tall with 128 pt side slots (`OP:74-91`). |

### 1.2 Beats in order

#### Beat 1: `greet` (`HOV:36-62`)

- **View:** `GreetBeat`. `HelloGreetingView` 420×210 writes "hello." in ink, 3.4 s (`HelloInk.duration`, `HelloGreetingView.swift:30`). A tap skips the animation (`:203`).
- **Copy:** "I’m Perry. I live up in your notch and help with whatever is on your screen." Button: "Let’s begin" (+ return glyph, `OP:55-72`). Accessibility label "hello." (`HelloGreetingView.swift:210`).
- **Controls:** one `InkButtonStyle` large button, `.defaultAction`. Late entrance delay 3.4/3.5 s (`HOV:51,57`).
- **Skip / back:** no Back. Close X only.
- **Verifies:** nothing.
- **Advances:** `director.skip()` → `advance()` (`OD:69-71`).

#### Beat 2: `firstTalk` (`HOV:79-303`)

- **Titles (verbatim):** "Ask me something." / "I’m listening." / "Let me think…" / "Here’s what I found." / "Getting the mic ready…" / "That didn’t go through." (`HOV:126-136`). After an answer the title is nil.
- **Messages:** "Say it out loud or type it. Try “What can you help me with?”" / "Talk normally. I’ll answer when you pause." / "Your microphone is off for Perry, so let’s type. Try “What can you help me with?”" / after answer: "That’s the idea. Ask me anything, any time." (`HOV:138-149`).
- **Controls:**
  - Primary talk button: "Talk to Perry" / "I’m done" / "Stop" / "Try again" / "Ask another" (`:279-286`).
  - Leading link: "Type instead" or "Use my voice".
  - Trailing link: "Skip".
  - Composer: `TextField("Ask Perry…")`, capsule 260×46, 30 pt send circle (`:239-267`).
  - After an answer: "Continue".
- **Layout:** art 120 pt (96 pt `PerryCharacter`), or 210 pt when the exchange card or answer shows (`:152`). Exchange card max 470 wide, radius 16 (`:175,184`).
- **Persistence:** none of its own. Entering the beat calls `preferOnDeviceBrain` (`OD:193-194`).
- **Verifies:** `answeredTurns > 0` (`HOV:110-111,166`) → `noteTalkTurnCompleted` → `firstAnswerReceived`. There are three triggers for the same event: the view's `onChange` (`HOV:166`), `talkSession().onTurnCompleted` (`OC:102-104`), and `controller.onTurnCompleted` (`App/AppSubsystems.swift:291`).
- **Mic denied:** `noteMicrophoneDenied` forces typing (`OC:115-117`, `HOV:164-165`).
- **Advances:** "Continue" or "Skip" → `skip()`. Leaving calls `endTalk` (`OD:182`).

#### Beat 3: `screenAccess` (permissions) (`HOV:305-371`)

- **Copy:** title "Let me see what you mean." Message "Two permissions let me point at things for you."
- **Rows** (`OnboardingRow`, 48 pt tall, `OP:126-158`):
  - "Accessibility" / "Read buttons, menus and fields". Button "Allow", then "Open again". After a click the detail reads "Turn on Perry in System Settings, then come back".
  - "Screen Recording" / "See the window you point at". Same buttons.
  - Footnote "Opens System Settings. You can turn either off any time."
  - Granted state: `GrantedMark` "Allowed".
- **Primary slot:** "Continue" when both are granted, else a plain text link "Not now, I’ll type" (`HOV:338-345`).
- **Art:** `PermissionSketch` (`OP:228-266`).
- **How "Allow" works:** `PerryPermissionProbe.requestAccessibility()` or `requestScreenRecording()`, then `NSWorkspace.open(x-apple.systempreferences:…)` (`OC:70-83`). **There is no drag helper, no floating panel and no icon to drag** (grep for `onDrag`, `NSItemProvider`, `draggingSource` hits only unrelated files).
- **Verifies:** a 1 s poll (`OD:152-157`) via `PerryPermissionSnapshot.probe()`; `requiredPermissionsGranted = accessibility && screenRecording.isUsable` (`Packages/PerryCapture/Sources/PerryCapture/PerryPermissionProbe.swift:87-89`).
- **Auto-advance:** if both are already granted on the first probe going forward, the beat advances itself (`OD:144`).
- **Not requested here:** Input Monitoring, Microphone (the mic is requested implicitly in beat 2). Settings lists four permissions (`SV:211-250`).

#### Beat 4: `brainChoice` (`HOV:373-472`)

- **Copy:** title "Choose how I think." Message "Start on this Mac or connect ChatGPT. Switch any time in Settings."
- **Cards:** two `option` buttons, each 214×56 (`HOV:461`), custom radio dot, `carbon` fill.
  - "On this Mac": detail "Private and offline", or "Not on this Mac" and **disabled** when `!brain.onDeviceRouteAvailable` (`:400-401`).
  - "ChatGPT": detail "Signed in" or "Uses your account".
  - Tapping a card writes `modelChoice` at once (`:443`).
- **Footer:**
  - Leading: "Other models" → `openOnboardingSettings` → Settings, Models tab (`AppController.swift:512-514`). This replaces the onboarding view with the full workspace shell (`HomeView.swift:13`).
  - Primary: "Waiting for sign-in…" (disabled) / "Continue" / "Connect ChatGPT" (`:414-428`).
  - Trailing: "Cancel" while signing in, else "Later".
- **Art:** `ChoiceSketch` (`OP:339-382`).
- **Verifies (`ready`, `HOV:380-388`):** `.local` → `onDeviceRouteAvailable`; `.chatGPT` → signed in; `.claudeCode` → installed; `.acp` → agent present; **`.direct` → always true**, even with no profile or key. `.claudeCode`, `.acp` and `.direct` are only reachable through the Settings detour.
- **Local models:** `brain.refresh()` discovers Ollama or LM Studio models (`:438`; `BrainController.swift:214-231`). The beat never shows them and never calls `checkLocalModel` (`BrainController.swift:233`). The only UI that does is `BrainModelSettingsView` (see §2).
- **Advances:** `noteBrainChoiceMade()` (guard `beat == .brainChoice`, `OD:92-95`) or "Later" → `skip()`.

#### Beat 5: `practice` (`HOV:474-512`)

- **Pre-start copy:** title "Try it on something safe." Message "A practice window with sample files and notes. Point, ask, rename, undo. Nothing of yours is touched." Button "Open practice window".
- **Started copy:** title "Step N of 4". Message is the hint (`OD:204-211`):
  - `pointAsk`: "Point at something in the practice window, then hold ⌃⌥ to talk and ask what it is."
  - `guide`: "Ask Perry to show you how to rename a file."
  - `renameUndo`: "Rename the three practice files, then undo the change."
  - `dictate`: "Click the notes box, hold fn (globe) …, and say a sentence." The hint uses the user's saved `pttShortcut` title (`OD:209,213-215`).
  - Controls: "Show practice window", "Skip this step", "Skip practice". `StepGrid` (`OP:423-457`, labels "Point and ask", "Follow a guide", "Rename, then undo", "Dictate a note") sits in the detail slot. Art is `PracticeWindowSketch` (`OP:384-421`).
- **Separate window** (`PracticeWindow.swift:113-128`): 460×330, `NSWindow` titled "Perry Practice", `[.titled, .closable]`. Left pane "Files" + three real files in `<support>/PracticeSandbox` (`:29-32,64`) + buttons "Rename files" / "Undo rename". Right pane `Toggle("Sync drafts")` (constant), `Button("Save draft")` (empty action), "Notes" `TextEditor`, caption "A safe practice space. The files are real; the rest is fake." (`:152-199`). Placed below the notch (`:130-136`).
- **Persistence:** `perry.onboarding.practice` (`PerryPreferences.swift:43`, written `OD:119,198`).
- **Verifies:** see surprise 6. `guide` completes when a Guide run ends `.completed` (`OC:53-60`; caller `App/AppController.swift:244`).
- **Advances:** the last step calls `advance()` (`OD:121-123`). Closing the window resets `practiceStarted` (`OD:109-113`).

#### Beat 6: `finale` (`HOV:514-590`)

- **Contents:**
  - `FinaleCard`, 330 wide, rotated −1.5°, radius 20 (`OP:488-546`, `HOV:548`): "<First name>’s Perry" (from `NSFullUserName`, `HOV:523-525`) or "Your Perry", "Since <date>", plus three check or gear lines (`HOV:527-543`):
    - "Answers on this Mac" / "Answers with <model>" / "Answers wait for ChatGPT in Settings." / "Answers wait for a model in Settings."
    - "Sees the window you point at" / "Typing works now. Screen access waits in Settings."
    - "Opens at login. Change it in Settings."
  - Title "I live in your notch now." (26 pt, `HOV:552-555`).
  - Two `LargeShortcut`s: `["⌃","⌥"]` "Hold to talk", `["⌃","⌃"]` "Double-tap to type" (`HOV:556-559`). `ModifierWatcher` lights held keys (`OP:268-293`).
  - Button "Start using Perry".
- **This is the "keyboard shortcuts screen".** It is display-only. Keys are string literals. No control edits any shortcut. It does not show the wake shortcut (⌥⌘P) or the dictation shortcut (fn).
- **Verifies:** a fresh permission probe for the checklist (`HOV:579`).
- **Advances:** 0.38 s exit animation, then `skip()` → last beat → `stop()`, remove saved beat and practice keys, `effects.finish` (`OD:166-178`).

### 1.3 Dead and duplicated paths

| What | Where | Note |
|---|---|---|
| `skip()` is a one-line alias for `advance()` | `OD:69-71` | Used for Skip, Continue and Later. Rename or drop. |
| Triple completion trigger for the first answer | `HOV:166`, `OC:102-104`, `AppSubsystems.swift:291` | One is enough. |
| `preferOnDeviceBrain` plumbing | `OD:27-30,193-194`, `OC:14,25,32,89`, `AppController.swift:116`, `BrainController.swift:284-290` | Exists only because the model choice comes after the first answer. Moot if the order changes. |
| Permission UI ×2 | Beat 3 rows `HOV:353-370` and `SV:252-275` | Plus two copies of the Settings URL logic (`OC:70-83`, `SV:294-297`). |
| ChatGPT sign-in UI ×3 | `HOV:422-424`, `HomeConnectionView` (`App/Home/HomeConversationView.swift:167-210`), `ModelSettingsButton` in the composer (`NotchWorkspaceView.swift:331`) | |
| Card/row styles ×4 | `OnboardingRow` (`OP:126`), `BrainChoiceBeat.option` (`HOV:441`), `InkChoiceStyle` (`App/InkButtonStyle.swift:79`), `RowButtonStyle` (`OP:160`) | |
| Keycap ×2 and hint ×2 | `Keycap` (`App/Home/WorkspaceComponents.swift:4`) vs `LargeKeycap` (`OP:295`); `GestureHint` (`NotchWorkspaceView.swift:601`) vs `LargeShortcut` (`OP:318`) | |
| `OnboardingStyle.carbon` | `OP:9` = (0.094, 0.098, 0.106) = `PerryTheme.Colors.surface` dark 0x18191B (`PerryTheme.swift:8`) | Same value, second name, no light variant. |
| `OnboardingDirector.dictationShortcut` | `OD:213-215` | Only the practice hint uses it. |
| Debug-only entry points | `OC:139-151` (`runDenied`), `DebugLaunchSeams.swift:108,150` | Fine, but DEBUG skips `runIfNeeded` in `AppController` (`:329-333`). |
| Stale doc | AGENTS.md "Verified commands" Metal note | See surprise 1. |

---

## 2. Settings inventory

Settings is not a window. It is the `.settings` page inside the notch workspace (`App/Home/NotchWorkspaceView.swift:526-530`; reached from the rail footer `:268-282` or the app menu `PerryApp.swift:44`). `PerryTheme.Sizing.settingsWidth/Height/MinimumWidth/MinimumHeight` (`PerryTheme.swift:74-77`) have **zero uses**.

Chrome: a horizontal scroll of six text tabs with a sliding underline (`SV:82-112`), then `Divider`, then the tab body. Global styles: `.buttonStyle(InkButtonStyle(.secondary))` and `.toggleStyle(InkSwitchStyle())` on the whole root (`SV:127-128`). Selected tab is persisted in `perry.settings.tab` (`PerryPreferences.swift:40`). Tab enum: `general, voice, runtimes ("Models"), integrations ("Apps"), memory, safety` (`SV:10-28`).

| Tab | Section: controls (`SV` line) |
|---|---|
| **General** (`:143-209`) | **Startup:** "Open Perry when you log in" toggle (`:146`), approval note (`:157`). **Invocation:** "Say “hey Perry” to wake" toggle (`:162`); "Wake shortcut" picker, 4 presets ⌥⌘P, ⌥⌘O, ⌃⌘P, ⌃⌘O (`:169`; `App/HotkeyController.swift:4-34`); "Dictation" picker, 4 presets (`:183`; `PushToTalkController.swift:3-18`); system-conflict note (`:196`). **Permissions:** Accessibility, Screen Recording, Microphone, Input Monitoring rows with "Enable…" (`:211-275`). |
| **Voice** (`:299-394`) | **Voice out:** "Speak replies" toggle (`:302`); recommended-voice rows with preview (`:304`, `VoiceChoiceRow` `:899-954`); "All voices" picker (`:312`); speed slider (`:319`); "This voice sounds robotic" row (`:327`). **Captions:** opacity slider (`:334`). **Dictation** (`:396-470`): language picker (`:398`), microphone picker (`:405`), "Test microphone" (`:413`), word-replacement list and add row (`:423-468`). **Realtime voice (bring your own key)** (`:344-387`): 8 fields in a `DisclosureGroup`. |
| **Models** (`:536-658`) | **Conversation model:** `BrainModelSettingsView` (picker over 5 choices; per-choice body). **Agents:** runtime records, "Copy sign-in command", "Copy sign-out command", "Check again", "Open Terminal" (`:541-593`). **Computer use:** status, "Custom driver path" disclosure, "Save Cua Driver settings" (`:594-611`). **Local skills:** per-skill toggles, "Open local skills folder" (`:612-650`). |
| **Apps** (`:660-681`) | Intro note; one card holding 4 `IntegrationRow`s from `RemoteIntegrationDefinition.catalog` (Notion `App/RemoteIntegrations.swift:788`, Slack `:802`, Linear `:824`, Google Workspace `:838`); `CustomConnectorsSection` (`App/CustomConnectorsSection.swift`). The only tab that is not a `Form`. |
| **Memory** (`:472-525`) | **Memory:** "Remember context between conversations" toggle (`:475`); 3 category toggles (`:482`). **Activity:** "Activity log" export, "Diagnostics" export, "Report a problem…" (`:493-499`). Unlabeled section: "Erase all Perry data" (`:500-504`). |
| **Safety** (`:683-717`) | Read-only list of blocked apps ("Always blocked", each "Never"). No controls. |

Sub-components:

- `BrainModelSettingsView` (`App/Brain/BrainModelSettingsView.swift`): picker `:8`; `.chatGPT` → `HomeConnectionView` `:17-20`; `.claudeCode` `:21-29`; `.acp` → `AcpAgentSection` `:30-31`; `.direct` → `ModelProfilesSection` `:32-33`; `.local` `:34-79` (explainer, Apple Intelligence label, "Find models on this Mac", per-model "Check capabilities", Text/Images/Tools rows).
- `IntegrationRow` (`App/IntegrationRow.swift:38-263`): "Set up" opens a form with the callback URL `dev.perry.perry:/oauth/callback`, "OAuth client ID", optional "Client secret", "Connect <name>" (`:73-97`). **The user must bring their own OAuth app.** No bundled client IDs exist (`RemoteIntegrations.swift:1181-1187` rejects an empty client ID; Notion is `.basicSecret`, `:796`, and needs a secret). `IntegrationConnections` (`App/IntegrationConnections.swift:5-72`) is a clean connect/test/preview/disconnect facade. Connected state shows a Menu (Test, Preview, Disconnect) and an "Allow agent writes" toggle.

### Shortcuts: what exists

| Shortcut | Default | Code | Editable? |
|---|---|---|---|
| Talk (hold ⌃⌥) and typed composer (double-tap ⌃) | fixed | `ModifierHoldMonitor` (`App/Talk/ModifierHoldMonitor.swift:11-16,166,181-197`); wired `AppSubsystems.swift:298-334`; strings in `TalkGesture` | **No.** No preference key, no UI. |
| Wake | ⌥⌘P | Carbon `RegisterEventHotKey` (`HotkeyController.swift:125-138`); `update(modifiers:keyCode:)` accepts any chord (`:104`); `AppController.updateWakeShortcut` (`:516-525`) | **Presets only.** Picker `SV:169`, `WakeShortcut` enum of 4. |
| Dictation (push to talk) | hold fn | `PushToTalkController` (`:50-310`); `VoiceController.updatePushToTalkShortcut` (`:983`) | **Presets only.** Picker `SV:183`, 4 cases incl. Caps Lock double-tap. |
| Wake word "hey Perry" | off | `VoiceController.updateWakeWordEnabled` (`App/VoiceController.swift:987`) | Toggle `SV:162`. |

**There is no shortcut recorder anywhere** (grep for `KeyRecorder`, `ShortcutRecorder`, `recordShortcut`, `KeyboardShortcuts` over `App` and `Packages` returns nothing).

### Memory and profile stores (for a personalization step)

| Store | Write API | Gate | Read into prompts? |
|---|---|---|---|
| `MemoryStore` | `remember(MemoryRecord(category: .preference, summary:))` (`MemoryStore.swift:94`); `.preference` rows also render `PROFILE.md` (`:196`) | **Needs `configuration.enabled == true`.** Default false. Enable with `AppController.setMemoryEnabled` (`SV:880-886`). | Yes: `promptContext` (`MemoryStore.swift:119`) feeds `agentCoordinator` (`AppSubsystems.swift:491-494`) and `GuideSessionCoordinator` (`:936,983`). |
| `MemoryFiles` | `writeProfile` (`MemoryFiles.swift:23`), agent tool `memory.write` (`MemoryTools.swift:56-63`, approval title "Remember this?" `ToolApprovalPresenter.swift:89`) | none | No (only `memory.read`). |
| `PerryStore.setMemory` | per-Perry (`PerryStore.swift:114`) | none | per-Perry only |

---

## 3. Command menu

There is no menu-bar item. The "menu" is an `NSPopUpButton` pull-down behind the notch's "…" button (`App/NotchPresentation.swift:60-82`, placed `App/Home/NotchWorkspaceView.swift:364`). It is built by `StatusMenuController.buildMenu` (`SM:82-171`). Release builds show **20 flat items** (+ 3 separators, + a Watch & Learn submenu with 2 fixed items and one submenu per saved routine, `SM:173-201`). DEBUG adds 7 more (`SM:119-144`).

| # | Item (`SM` line) | Action | Also reachable elsewhere? |
|---|---|---|---|
| 1 | Wake Perry (⌥⌘P) (`:85`) | `host.wake()` | Yes: the hotkey itself; ⌃⌥ gesture. Title also leaks the preset (`:84`). |
| 2 | Ask Perry… (`:87`) | `wake()` + `speak("What are you curious about?")` (`:219-222`) | Yes: composer in the notch; `SessionPanelView` mode picker (`SessionPanelView.swift:10-13`). |
| 3 | Guide me… (`:88`) | `wake()` + `speak("What should I teach you?")` (`:224-227`) | Same as #2. |
| 4 | Show full guide (`:89`) | `showFullGuideForFrontmostWindow` (`SM:344-347`) | **Menu only** (plus voice commands, `GuideVoiceCommands.swift`). |
| 5 | Do a task… (`:90`) | `wake()` + `speak("What are we taking off your hands?")` (`:229-232`) | Same as #2. |
| 6 | Run in background… (`:91`) | `presentBackgroundComposer` (`SM:351-354`) | Yes: "Run in background" checkbox in Do mode (`SessionPanelView.swift:154`). |
| 7 | Background tasks (`:94`) | `showBackgroundTasks` | Yes: rail "Tasks" (`NotchWorkspaceView.swift:127`). |
| 8 | Retry last task (`:98`) | `foreground.retry()` | Partly: "Retry task" button on failure (`SessionPanelView.swift:226`). |
| 9 | Workspace: ~/… (disabled label, `:99-103,204`) | none | Info only. |
| 10 | Choose workspace folder… (`:104`) | `NSOpenPanel` → `setWorkspaceRoot` | **Menu only.** Not in Settings. |
| 11 | Watch & Learn ▸ (`:105-118`) | Record a demonstration…, Import routine…, per-routine Run / Export… / Delete | Partly: Routines page has "Record a routine" (`App/Home/HomeView.swift:161-162`). Import and export are menu only. |
| 12 | History (`:146`) | `showHistory` | Yes: rail (`NotchWorkspaceView.swift:131`). |
| 13 | Export diagnostics… (`:147`) | `exportDiagnostics` | Yes: Settings → Memory → Activity (`SV:495`). |
| 14 | What’s New (`:148`) | `showWhatsNew` (`AppController.swift:492`) | **Menu only** (no rail link; `.whatsNew` selection exists, `HomeModel.swift:16`). |
| 15 | Check for Updates… (`:149-152`) | `checkForUpdates` | **Menu only**, and greyed unless an update is already available. |
| 16 | Settings… ⌘, (`:153`) | `showSettings` | Yes: rail footer, app menu. |
| 17 | Memory: on/off (`:155-158`, title `:67-71`) | `toggleMemory` | Yes: Settings → Memory (`SV:475`). |
| 18 | Notch status ✓ (`:160-163`) | `toggleNotchStatus` | **Menu only.** Key `perry.notchStatus.enabled` (`PerryPreferences.swift:44`). |
| 19 | Erase all Perry data… (`:165-167`) | `requestCompleteErasure` | Yes: Settings → Memory (`SV:501`). |
| 20 | Quit Perry ⌘Q (`:169`) | `NSApp.terminate` | App menu. |

DEBUG only: Run live Perry demo, Brain smoke test, Failure drills ▸, State fixtures ▸, Invocation prototypes, Cursor prototypes (`SM:119-144`).

Look problems visible in code: nouns and verbs mixed ("History" vs "Do a task…"); state in titles ("Memory: on", "Workspace: …"); three prompt items that only change what Perry says (`:219-232`); one destructive item adjacent to settings toggles (`:165`); no grouping beyond three separators. A system `NSMenu` gives none of Perry's tokens.

---

## 4. Design system

### 4.1 Tokens that exist (`App/PerryTheme.swift`, 94 lines)

- **Colors** (`:6-33`): `canvas, surface, text, textSecondary, subtleSeparator, primaryAction, onPrimaryAction, cameraCrown, accent, onAccent, success, caution, warning, danger, active, focus`. Light + dark pairs through `NSColor(name:)`.
- **Typography** (`:39-52`): all Dynamic Type styles (`.headline`, `.body`, `.caption` …) plus `mono`, `monoSmall`, `value`.
- **Spacing** (`:54-63`): 1, 2, 6, 8, 10, 12, 16, 18. **Radius:** one value, `panel` 18 (`:65-67`). **Sizing** (`:69-86`). **Motion** (`:88-93`).
- **Controls:** `InkButtonStyle` (primary / secondary / destructive; sizes by `controlSize`, 13 pt or 15 pt, `App/InkButtonStyle.swift:3-77`), `InkChoiceStyle` (`:79-122`), `InkSwitchStyle` (`:124-158`), `InkSlider` (`:160-212`). `settingNote()` (`SV:859-864`).
- **Onboarding-only parallel set:** `OnboardingStyle` (`OP:5-13`), `OnboardingLinkStyle`, `RowButtonStyle`, `OnboardingRow`, `OnboardingFooter`.

### 4.2 Where views bypass them (counted by grep on `App/**/*.swift`)

| Finding | Count / location |
|---|---|
| `Font.system(size:)` literals | 36 total; **27 in onboarding** (`OP` 16, `HOV` 10, `OnboardingNotchView` 1). Onboarding uses ten sizes: 9, 10, 11, 12, 13, 14, 15, 16, 17, and 26 via `OnboardingStyle.title`. |
| Onboarding use of `PerryTheme.Spacing`, `Radius` or `Typography` | **0** across `App/Onboarding/*` and `HOV`. It uses `PerryTheme.Colors` and its own `OnboardingStyle`. |
| `white.opacity(...)` / `black.opacity(...)` fills | 27 (`InkButtonStyle` 7, `OP` 6, `HomeConversationView` 3, `WorkspaceComponents` 2, `NotchWorkspaceView` 2 …). Dark-mode assumptions; no light variant. |
| Corner radii | 10 numeric values: 2, 5, 7, 8, 9, 10, 12, 14, 16, 20. The theme defines one (18), and it is used at 8 sites. |
| Button styles in use | `InkButtonStyle` 47 sites, `.plain` 31, `.borderless` 12, `RailRowStyle` 5, `OnboardingLinkStyle` 3, `InkChoiceStyle` 2, `ContextChipStyle` 3, `RowButtonStyle` 1. `.borderedProminent` appears only in debug prototypes (`DebugInvocationPrototypes.swift:128,163,185`). |
| Materials | None. Grep for `Material`, `NSVisualEffect`, `glassEffect` returns nothing. All surfaces are flat fills. |
| Dead tokens (zero uses) | `Sizing.settingsWidth/Height/MinimumWidth/MinimumHeight`, `Spacing.cardInset`, `Elevation.shadow`, `Motion.settle`, `Colors.focus`. |
| Spacing | `PerryTheme.Spacing` used 57 times; raw `.padding(20)` ×12, `.padding(16)` ×8, `.padding(24)` ×4, `.padding(.horizontal, 14)` ×7, etc. |

### 4.3 "Look" problems visible in code

1. **Two surface languages inside Settings.** Five tabs use native `Form.grouped` (`SV:144,300,473,537,684`) with system rounded-border text fields, native pickers and disclosure groups. The Apps tab uses a hand-built `PerryTheme.Colors.surface` card at radius 12 (`SV:674`). The root forces `InkButtonStyle(.secondary)` and `InkSwitchStyle` onto the native rows (`SV:127-128`). Result: ink capsules and ink switches sitting on system grouped backgrounds.
2. **Tab naming and grouping drift.** Case `runtimes` is titled "Models" (`SV:13,22`). "Apps" is `integrations`. Diagnostics and Erase live under "Memory". Safety is a read-only list.
3. **Developer-grade content at the same rank as basics.** Copy-sign-in-command, Open Terminal, driver path, skills folder and an 8-field realtime-voice form (`SV:344-387,541-650`).
4. **Onboarding looks like a second product.** Own font sizes, own colors (`carbon`, `hairline`), own buttons (46 pt footer, 132 pt minimum label with a return glyph `OP:55-72`), hand-drawn art on every beat, a −1.5° rotated card. The keycaps (`OP:295-316`) fake depth with a hard shadow.
5. **The finale's fixed footer geometry.** `OnboardingFooter` fixes 128 pt side slots and 46 pt height (`OP:74-91`). Long labels such as "Not now, I’ll type" sit in the primary slot as text links (`HOV:344`), so the main action changes visual weight between steps.
6. **The notch menu is the one surface with no Perry tokens** (system `NSMenu`, §3).

---

## 5. Complaint → cause → smallest fix

| # | Complaint | Exact cause | Smallest change (reuse first) |
|---|---|---|---|
| 1 | "instead of a stupid practice window, ask the user what they've been wanting to learn" | Beat `.practice` (`OD:8`), `PracticeBeat` (`HOV:474-512`), `PracticeWindow.swift` (199 lines), `PracticeStep` and its state in `OD`, coordinator wiring (`OC:17,53-60,84-88,105-117`), `PracticeWindowSketch` and `StepGrid` (`OP:384-457`), key `perry.onboarding.practice`. | Replace `.practice` with a `.learn` beat. Copy: "What’s something you’ve been wanting to learn lately?" Reuse the `FirstTalkBeat` composer and talk button (`HOV:239-267,296-302`). On submit call `model.onStartConversation?(text)` (already used at `HOV:275`) so Perry answers or guides for real. Save the sentence as a `.preference` memory (see #2). Delete everything in the left column. |
| 2 | "heyclicky even has talk to me about yourself … why don't we have that?" | No surface writes or reads a user profile. Teardown notes HeyClicky's `PROFILE.md` at `docs/heyclicky-teardown.md:38`. Perry's closest pieces: `MemoryStore` toggles (`SV:474-492`) and the unused-in-prompts `MemoryFiles`. | Merge into the same `.learn` beat: one prompt "Tell me a bit about yourself and what you want to learn" (name prefilled from `NSFullUserName`, `HOV:523`). Store with `MemoryStore.remember(MemoryRecord(category: .preference, …))`. **Must first enable memory** (`AppController.setMemoryEnabled(true)`, `SV:880`), because the default is off and `remember()` silently returns false (`MemoryStore.swift:94-97`). That needs one consent line ("Stored on this Mac. Erase any time."). Do **not** use `MemoryFiles.writeProfile`: it is never injected into prompts and Erase-all misses it (surprise 8). |
| 3 | Shortcuts screen "looks hella ugly" and should be editable | `FinaleBeat` (`HOV:514-590`): rotated `FinaleCard`, two `LargeShortcut`s with literal glyphs (`:557-558`), `LargeKeycap` fake-3D (`OP:295-316`), 10 font sizes, `carbon` fills. Not editable because Talk has no preference (`ModifierHoldMonitor.swift:166`), and wake and dictation are 4-case enums (`HotkeyController.swift:4`, `PushToTalkController.swift:3`) editable only in Settings pickers. No recorder exists. | **Step 1 (small):** make this a real "Your shortcuts" step with three rows: Talk (display), Dictation (`Picker` over `PushToTalkShortcut`), Wake (`Picker` over `WakeShortcut`). Bind the same `@AppStorage` keys and call `controller.updateWakeShortcut` and `voice.updatePushToTalkShortcut` as `SV:174-195` do. Extract one `ShortcutsSection` view and use it in both Settings and onboarding. Keep `ModifierWatcher` for "press it to try". Add the Input Monitoring request here. **Step 2 (a recorder):** `HotkeyController.update(modifiers:keyCode:)` already takes any chord (`:104`), so a recorder for Wake needs only a capture view (`NSEvent` local monitor) and a changed preference type. Talk and dictation holds need `ModifierHoldMonitor` / `PushToTalkController` parameterized by a modifier set (the `control && option` test at `ModifierHoldMonitor.swift:166` is the only hard-coded place). Fix the ⌃⌥ vs ⌃⌥⌘ overlap at the same time. |
| 4 | "the apps I should be able to set those up in onboarding too no?" | Connect UI exists (`IntegrationRow`, `IntegrationConnections`), but it asks for the user's own OAuth client ID and secret (`IntegrationRow.swift:73-97`; `RemoteIntegrations.swift:1181-1187`). | Embedding `IntegrationRow` as is would put a developer form in onboarding. Two honest options: (a) ship bundled public OAuth clients (PKCE: Slack is already `.pkce`, `RemoteIntegrations.swift:818`) and then reuse `IntegrationConnections.connect` with one "Connect" button per app; (b) cheaper, no product decision: an "Apps" step listing the four catalog entries (`RemoteIntegrationDefinition.catalog`) with "Set up in Settings" that calls `openSettingsTab(.integrations)` (`NotchWorkspaceView.swift:268-276`). I recommend (b) now and (a) as a separate decision. |
| 5 | "On this Mac → the next screen needs to be the local models" and "ChatGPT instead do cloud?" | `BrainChoiceBeat` has two fixed cards (`HOV:400-402`); the local card is disabled unless `onDeviceRouteAvailable` (`:401`), which only becomes true after `checkLocalModel` passes, and nothing in onboarding calls it (`HOV:438` only calls `refresh()`). The local model list and check UI live only in `BrainModelSettingsView.swift:34-79`. The cloud choice is hard-wired to ChatGPT although `ModelChoice` has five cases (`BrainController.swift:11-23`). | (1) Extract the `.local` branch of `BrainModelSettingsView` (`:34-79`) into a `LocalModelsList` view and show it as the next sub-screen when the user picks "On this Mac"; auto-call `checkLocalModel` for each model `refresh()` returns. (2) Rename the second card "In the cloud" and, when picked, show a small picker over ChatGPT / Claude Code / My API provider rendering the existing per-choice bodies (`HomeConnectionView`, `ModelProfilesSection`, claude-code status — `BrainModelSettingsView.swift:17-33`). (3) Move `brainChoice` **before** `firstTalk` by swapping enum order (`OD:8`) so the first answer has a model; then delete the `preferOnDeviceBrain` plumbing (§1.3). Fix `ready` so `.direct` needs a profile (`HOV:386`). |
| 6 | Permission steps need a "drag me into the list" helper like HeyClicky | `ScreenAccessBeat` only opens the pane (`OC:70-83`). No panel, no drag source in the repo. | After "Allow", show a small borderless floating `NSPanel` (reuse the window pattern in `PracticeWindow.swift:113-136` and `PerryWindowChrome`) next to the System Settings window, found via `CGWindowListCopyWindowInfo`. It holds the Perry app icon with `.onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) }` and the line "Drag Perry into the list". Dismiss it when the existing 1 s poll sees the permission flip (`OD:152-157`). Add Input Monitoring as a third row. **Unverified:** whether macOS 27's panes accept bundle drags; needs one live check before building. |
| 7 | "settings UX can be made much better?" | §2 and §4.3: six tabs, two surface languages, developer content at top level, shortcuts not editable, no "Set up Perry again" (only `PerryApp.swift:46`). | (1) Cut to four tabs: **General** (startup, shortcuts, permissions), **Voice**, **Models & Apps**, **Privacy** (memory, safety, activity, erase). (2) Move the Agents, Computer use, Local skills and Realtime sections behind one "Advanced" disclosure. (3) Put Permissions first, with live status. (4) Pick one surface language: use the card style already in the Apps tab (`SV:665-674`) for every section, or drop the custom button and switch styles from `Form`. (5) Add the missing controls: shortcuts (#3), notch status, workspace folder, "Set up Perry again". |
| 8 | Menu "holy ugly wtf is this slop" | 20 flat items (§3). | Keep six: Settings… ⌘, · What’s New · Check for Updates… (enabled always) · Quit Perry, plus "Run in background…" if wanted. Everything else is already reachable (rail, composer, Settings). Move **Notch status**, **Choose workspace folder** and **Watch & Learn import/export** into Settings and the Routines page. Delete Ask/Guide/Do (they only change a spoken prompt) and the workspace label. Replace the native pull-down with a SwiftUI popover only if you need Perry tokens. |

---

## 6. What can be deleted without losing user value

### Onboarding

- Beat `.practice` and everything it owns: `PracticeWindow.swift` (199 lines); `PracticeBeat` (`HOV:474-512`); `PracticeWindowSketch`, `StepGrid` (`OP:384-457`); `PracticeStep`, `practiceStarted`, `startPractice`, `showPracticeWindow`, `notePracticeWindowClosed`, `notePracticeStepCompleted`, `practiceHint`, `dictationShortcut` (`OD:11-13,37-38,97-124,187,197-198,204-215`); coordinator `practiceWindow`, `noteSessionTransition`, `beginPractice`/`endPractice`, the `onEvent`/`onClose` blocks (`OC:17,52-60,84-88,105-117`); the key `perry.onboarding.practice` (`PerryPreferences.swift:43`); `Effects.beginPractice/endPractice` (`OD:25-26`).
- `preferOnDeviceBrain` chain, if brain choice moves before first talk (§1.3).
- Two of the three first-answer triggers (§1.3).
- `FinaleCard`'s rotation, "Since <date>" line and `shown` spring (`HOV:520,548-551,574-577`; `OP:488-546`). The checklist is the only information; keep it as a plain list.
- `LargeKeycap` and `LargeShortcut` once a shared shortcut row exists (`OP:295-337`); `ModifierWatcher` can stay if "press it to try" stays.
- `OnboardingRow` / `BrainChoiceBeat.option` / `RowButtonStyle` duplicates: fold into `InkChoiceStyle`.
- Four skip labels for one action: "Not now, I’ll type", "Later", "Skip", "Skip practice" (`HOV:234,344,434,508`). One "Not now" is enough.
- `OnboardingDirector.skip()` alias (`OD:69-71`).
- `OnboardingStyle.carbon` duplicate color (`OP:9`): use `PerryTheme.Colors.surface`.

### Settings

- Dead tokens (§4.2). `.borderedProminent` debug prototypes are not in scope.
- Safety tab as a separate tab (`SV:683-717`): a read-only list. Make it a footnote under Privacy.
- Captions section with one slider (`SV:334-342`): fold into Voice out.
- Dual voice UI: recommended rows plus "All voices" picker (`SV:304-318`). Keep one.
- "Test microphone" (`SV:413-418`): it only shows a static availability string.
- Realtime-voice BYO block (`SV:344-387`), Agents "Copy sign-in/out command" and "Open Terminal" (`SV:559-592`), "Custom driver path" (`SV:601-608`): move to Advanced, or delete if unused by shipping builds.
- The contradictory Caps Lock sentence (`SV:189`).

### Menu

- Ask Perry…, Guide me…, Do a task… (`SM:87-90,219-232`).
- Workspace label (`SM:99-103,203-205`).
- Memory toggle (`SM:155-158`), Export diagnostics (`SM:147`), Erase all (`SM:165-167`): duplicates of Settings.
- History and Background tasks (`SM:94,146`): duplicates of rail links.
- Retry last task (`SM:98`): duplicate of the failure button.
- Show full guide (`SM:89`) if the voice command is enough.

---

## 7. Method and gaps

- Files read in full: `OD`, `OC`, `OnboardingNotchView`, `OP`, `HOV`, `PracticeWindow`, `HelloGreetingView`, `SettingsView`, `StatusMenuController`, `HotkeyController`, `PerryTheme`, `InkButtonStyle`, `PerryPreferences`, `BrainModelSettingsView`. Partial: `PushToTalkController`, `ModifierHoldMonitor`, `IntegrationRow`, `MemoryStore`, `MemoryFiles`, `MemoryTools`, `BrainController`, `NotchWorkspaceView`.
- Not read: `ModelProfilesSection`, `AcpAgentSection`, `CustomConnectorsSection` bodies, `RemoteIntegrations` OAuth internals beyond the lines cited, `PerryPermissionProbe` internals.
- `docs/research/2026-10-25/` was empty when I wrote this file.
- The `prose` skill named in `~/AGENTS.md` is not in the skill list available to this session, so I did not load it. This report does not claim its self-audit.
