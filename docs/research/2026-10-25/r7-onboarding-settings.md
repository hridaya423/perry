# R7: Onboarding, settings and menu for Perry

Date: 2026-10-25. Scope: research only. No builds, no GUI, no code changes.
Marks: **(inference)** means my conclusion, not a sourced fact. **(unverified)** means a source I could not read directly.

## 0. Decisions in one page

1. **Delete the practice window.** Replace it with the real thing: a short spoken interview, then the user's own learning goal becomes the first task.
2. **New beat order:** Hello, Brain, Access, Shortcuts, Interview, Apps, First goal. Target 125 s of setup plus about 40 s of first task. Every step after Hello is skippable.
3. **Interview, not a form.** Three spoken questions. The last one is the user's own idea: "What's something you've been wanting to learn lately?" Show what Perry learned as editable chips before saving. HeyClicky does a four-question interview and stores it in memory ([changelog](https://heyclicky.com/changelog)).
4. **Shortcut screen becomes a recorder with a live check.** Perry has no recorder today. Three of its gestures cannot be edited at all.
5. **Permission helper:** a small panel pinned to System Settings with a draggable Perry icon, as HeyClicky does (user screenshot, section 2.2). Ask for Accessibility and Microphone early. Ask for Screen Recording and Input Monitoring only when a step needs them.
6. **Apps in onboarding, one tile at a time.** Offer the apps the user named in the interview. Each connect is skippable. The rest wait in Settings.
7. **Settings:** replace the six-tab strip with a left sidebar of eight items (section 5).
8. **Menu:** cut 20 items to 7 plus one conditional (section 6). Everything cut already has a home in the notch rail or in Settings.
9. **Surprise worth reading first:** this "menu bar menu" is not a menu bar item. It is the notch's More popup (`App/StatusMenuController.swift:42-43`, `App/NotchPresentation.swift:61-88`). Perry has no menu bar extra.

---

## 1. Perry today (read-only audit)

### 1.1 Onboarding

| Fact | Where |
|---|---|
| Six beats: greet, firstTalk, screenAccess, brainChoice, practice, finale | `App/Onboarding/OnboardingDirector.swift:7-9` |
| Practice has four sub-steps: pointAsk, guide, renameUndo, dictate, in a fake window with sample files | `OnboardingDirector.swift:11-13`, `App/Onboarding/PracticeWindow.swift` (199 lines), `App/Home/HomeOnboardingView.swift:475-512` |
| Practice copy: "Try it on something safe. A practice window with sample files and notes." | `HomeOnboardingView.swift:483-486` |
| Access beat asks for Accessibility and Screen Recording. It opens System Settings by URL. No drag helper exists (grep for drag code in `App/` finds none relevant). | `HomeOnboardingView.swift:304-360`, `OnboardingCoordinator.swift:68-82` |
| Permission polling runs every 1 s and auto-advances if both are already granted | `OnboardingDirector.swift:136-157` |
| Brain beat: "On this Mac" or "ChatGPT", with "Other models" and "Later" | `HomeOnboardingView.swift:372-440` |
| First-talk beat runs before the brain choice and prefers the on-device model | `OnboardingDirector.swift:27-30, 193-194` |
| Finale shows "Hold to talk" (⌃⌥) and "Double-tap to type" (⌃⌃) as keycaps. This is the "hella ugly" shortcut screen. | `HomeOnboardingView.swift:552-560`, `App/Onboarding/OnboardingParts.swift:318-337` |
| The keycap "lit" demo uses an `NSEvent` **local** monitor, so it only proves keys reach Perry's own window. It does not prove the global gesture works. | `OnboardingParts.swift:268-293` |
| No profile or interview. The only personal touch is `NSFullUserName()` first name on the finale card. | `HomeOnboardingView.swift:523-525` |
| No app connections in onboarding. Integrations live only in Settings. | `App/SettingsView.swift:660-681` |
| Beat progress persists, so a relaunch resumes. An unknown saved beat falls back to greet. | `OnboardingDirector.swift:58-60, 191` |
| Timing marks exist: `onboarding.start`, `onboarding.first_answer`, `onboarding.finish` | `OnboardingDirector.swift:61, 81, 174` |

Evidence of a weak first answer: in the user's screenshot, the first on-device answer to "what can you help me with" says it cannot read apps or files and tells the user to "paste needed text or choose a capable model in Settings." (`.t3/userdata/attachments/…639be2d6….png`). The first impression must not come from that route unless it is fixed. **(inference)** This is why Brain should come before any conversation.

### 1.2 Shortcuts

| Gesture | Options today | Editable? | Where |
|---|---|---|---|
| Wake chord | 4 fixed: ⌥⌘P, ⌥⌘O, ⌃⌘P, ⌃⌘O | Picker only | `App/HotkeyController.swift:4-33`, `SettingsView.swift:169-182` |
| Dictation hold | 4 fixed: hold fn, hold ⌥⌘Space, double-tap Caps Lock, hold ⌃⌥⌘ | Picker only | `App/PushToTalkController.swift:3-52`, `SettingsView.swift:183-195` |
| Talk hold ⌃⌥ and type double-tap ⌃ | 1 hard-coded | **No** | `App/Talk/ModifierHoldMonitor.swift:11-16` |

- Conflict check covers only chord shortcuts, and in practice only ⌥⌘Space (`PushToTalkController.swift:54-58`, `SettingsView.swift:282-292`). Hold-fn has no check. **(inference)** macOS "Press 🌐 to…" can still take fn. Wispr documents that assigning fn alone "prevents its usual system action" ([Wispr docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)).
- The PTT controller already reports which listener is live (`CaptureMode`). The event tap needs Input Monitoring. The fallback sees only Perry's own events, "so a missing grant silently leaves the shortcut dead" (`PushToTalkController.swift:59-64, 160`). A try-it check must read this value. Otherwise it passes inside Perry and fails everywhere else.
- A user sees three gestures for three jobs (wake, talk, dictate). Settings labels the dictation picker "Dictation" and never lists the talk gesture.

### 1.3 Settings

Six horizontal tabs (`SettingsView.swift:10-28`, strip at `:82-112`), rendered inside the notch workspace (`App/Home/NotchWorkspaceView.swift:526-531`).

| Tab | Contents | Lines |
|---|---|---|
| General | Open at login; wake word; wake shortcut; dictation shortcut; Permissions (4 rows) | 143-250 |
| Voice | Speak replies; voice list; speed; robotic-voice nudge; caption opacity; Dictation (language, mic, test, word list); Realtime BYOK (8 fields) | 299-470 |
| Models | Conversation model; Agents (runtimes, sign-in commands); Computer use (Cua path); Local skills | 536-658 |
| Apps | Integration rows (Notion, Slack, Linear, Google Workspace); custom connectors | 660-681 |
| Memory | Memory on/off + 3 category toggles; Activity log; Diagnostics; Report a problem; Erase all | 472-525 |
| Safety | Always-blocked apps list | 683-717 |

Problems:
- Shortcuts are split across General and Voice, and one is missing.
- "Models" mixes the brain, agent runtimes, the screen driver and skills.
- Memory is a set of toggles. There is no list of what Perry remembers.
- Erase, diagnostics and memory are in the menu **and** Settings. Duplicated.
- No Account/About/What's New/Updates/Replay-intro home. Those live in the menu.
- Perry's own workspace root is set only from the menu (`StatusMenuController.swift:246-255`).
- The workspace is `minWidth: 560` with a 210 pt rail (`NotchWorkspaceView.swift:21, 69`). A second nested sidebar will not fit (see 5.3).

### 1.4 Menu (20 items in the release build)

`StatusMenuController.swift:82-171` builds it. Debug adds five more items (`:119-144`). It opens from the notch More button (`NotchWorkspaceView.swift:364-366`). Visible defects in the user's screenshot:
- "Memory:…" shows a literal ellipsis until an async refresh lands (`StatusMenuController.swift:155`, refresh at `:67-71`).
- "Check for Updates…" is disabled unless an update is already available (`:149-152`). The label promises an action the item refuses.
- "Ask Perry…", "Guide me…" and "Do a task…" call the same two lines with different spoken prompts (`:219-232`).
- The Home rail already holds Tasks, Routines, Files, Suggestions, History (`NotchWorkspaceView.swift:127-131`). The menu repeats three of them.

### 1.5 Memory and integrations (needed for the interview and apps steps)

- `MemoryRecord` has categories `appWorkflow`, `preference`, `pastSession` (`Packages/PerryGuide/Sources/PerryGuide/MemoryStore.swift:4-9`).
- **Nothing writes `.preference`.** Grep finds only the label in Settings (`SettingsView.swift:776`). The slot for "how this user likes things" is empty.
- `promptContext` injects only the 12 most recent records, newest first (`MemoryStore.swift:119-131`). **(inference)** Interview facts would be pushed out by task summaries within days. HeyClicky hit the same bug: "Clicky's memory of you could get cut off partway through, often losing how you like it to talk to you" (v1.0.53, [changelog](https://heyclicky.com/changelog)). Profile facts need a pinned slot that is always injected.
- Integration catalog: Notion, Slack, Linear, Google Workspace. Writes are off by default. Google scopes cover Gmail, Calendar, Drive, Docs and Sheets read-only in one grant (`App/RemoteIntegrations.swift:784-856`). **(inference)** One Google connect can light three tiles: Gmail, Calendar, Drive.

---

## 2. How the best apps onboard

Method note: Mobbin, Pageflows and Growth.Design need accounts or returned nothing useful. I used official docs, changelogs, the user's screenshots, and open-source PRs. Third-party guides are marked **(unverified)**.

### 2.1 Step lists

| App | Steps (in order) | Personalization | Aha | Shortcut setup | Integrations | Skippable |
|---|---|---|---|---|---|---|
| **Wispr Flow** ([setup guide](https://docs.wisprflow.ai/articles/3152211871-setup-guide)) | Install, sign in, mic + Accessibility, setup questions + privacy notice, mic test, set shortcut, languages, practice demos, data preference, Hub | "Answer setup questions" (multiple choice; "Other" needs text) | Practice demo with the shortcut | Push-to-talk or Hands-free, default fn (Ctrl+Opt if no fn found) | None | "each demo can be skipped"; a "Skip onboarding" jumps to Permissions, Mic test, Shortcut, Language |
| **Superwhisper** ([quickstart](https://superwhisper.com/docs/get-started/quickstart)) | Install, mic + Accessibility (+ optional system audio), mic test + shortcut, first dictation | None | "Setup ends with a practice message": hold key, speak, text appears at cursor | Default hold Right ⌘, "Change shortcut" link; also ⌥Space toggle | None | Permissions can be granted later |
| **Raycast** ([quickstart](https://manual.raycast.com/quickstart), [Windows manual](https://manual.raycast.com/windows/getting-started)) | Few onboarding steps, pick global hotkey, search, Action Panel, Quicklinks, hotkey for a command, AI chat, install an extension | None | Search the system, then first AI chat | Hotkey chosen during onboarding, default ⌥Space | Extensions after, from the Store | Walkthrough command lets users finish later (2021 [changelog](https://www.raycast.com/changelog/macos-v1/1-26-0)) |
| **Granola** ([setup](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time)) | Install, open warning, Google/Microsoft sign-in, calendar "Select all", mic + system audio, demo meeting | None asked. Calendar is the personalization | A **demo meeting** is waiting, a 2-minute tutorial from the co-founder, "a one-time experience" | None | Calendar is required in the flow | Replay at a demo URL |
| **Claude desktop** ([Quick Entry](https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac)) | First-run prompt: tick "enable", Continue, **double-tap Option to test** it | None | The test opens the real quick-entry window | Double-tap Option, ⌥Space or custom. Voice off by default "because it takes over Caps Lock" | None | Managed later in Settings > Desktop app |
| **HeyClicky** ([changelog](https://heyclicky.com/changelog), [audit](../../heyclicky-feature-audit.md)) | v1.0.40: guided tutorial where users "do things": speak, watch it draw, dictate in a real text box (about two minutes). v1.0.49: interview of "four quick questions about yourself and your work", then three helpers made for the user. v1.1.1: "shorter onboarding tour" | Interview, stored in memory | Drawing on screen, then helpers built from the interview | Editable in Settings > Shortcuts (v1.0.37, v1.0.48) | Connected later in Settings > Integrations | Interview can be skipped out loud (v1.0.51). Replay from Settings > General |
| **Comet** ([Tom's Guide](https://www.tomsguide.com/ai/perplexity/how-to-use-perplexity-comet), **unverified**) | Import offered, profile name and look, default browser, account | Profile name | Not found | None | Import with "Do this later" | Yes |
| **Dia** ([guide](https://computingforgeeks.com/install-dia-browser-macos/), **unverified**) | Import from Arc/Chrome in onboarding, memory is opt-in | Memory, local, opt-in | Not found | Not found | Import only | Yes |
| **Sunsama** ([setup](https://help.sunsama.com/docs/setting-up-your-sunsama)) | Account, calendar, daily reminder time, guided first plan. Other task tools connect "later during the first planning session" | Reminder time | Plan today in the first session | None | **Deferred** to first use | Yes |
| **Cursor** (**unverified** guides) | Sign in, import VS Code settings, keybindings, privacy mode | Import | Not found | Pick keybindings at first launch | None | Import re-runnable in Settings |
| ChatGPT Mac, Rewind/Limitless, Linear, Things, Arc | No reliable teardown found | | | | | |

### 2.2 HeyClicky screenshots from the user

- **Permission panel** (`…5088e2bf….png`): three-segment progress pill, "I need accessibility permissions." and "Drag me into the Accessibility list." with one `Open` button. First person, five words per line.
- **Drag helper** (`…e873275e….png`): a floating panel pinned to the bottom of the System Settings window. It reads "I'm HeyClicky — drag me into the list above." and holds a draggable app tile with a hand cursor over it. The list behind it is titled "Device Control and Data Access". **Surprise:** on macOS 27 the Accessibility list appears under that name. Perry opens `Privacy_Accessibility` by URL (`OnboardingCoordinator.swift:73`). Whether that anchor still lands on the right list on macOS 27 is **unverified**. Test it.
- **Settings sidebar** (`…34901b52….png`): "‹ Back" and a "Settings" title, then Account, General, Invite & Earn, group HEYCLICKY (Voice, Microphone, Dictation, Shortcuts, Cursor), group WORK (Agents). The Integrations pane shows a search field, "Add custom connector", and one row per app with a blue **Connect** button and a one-line description.

### 2.3 Patterns that repeat

1. Permissions come right after sign-in, never at the start. Only the ones the first action needs: mic and Accessibility for dictation apps.
2. **The shortcut step ends in a live test with the real action** (Superwhisper practice message, Claude double-tap test, Wispr practice demos).
3. Integrations that matter for the first win go inside onboarding (Granola calendar). The rest are deferred (Sunsama) or offered with "Do this later" (Comet).
4. The aha is the product's real output, not a sandbox (Granola demo meeting, Superwhisper pasted words, HeyClicky drawing).
5. HeyClicky shortened its tour in v1.1.1. **(inference)** Long onboarding costs users, even a good one.

### 2.4 Permission helper: sourced design

Open-source implementations of the HeyClicky-style helper:
- **agent-desktop PR #299** ([link](https://github.com/lahfir/agent-desktop/pull/299)): finds the Settings window with `CGWindowList` (needs no permission). Shows the app icon as a real drag source. Polls once per second and advances on grant. Notes that on macOS 26 the prompt APIs did not add the app to either list, so a real drag was needed. The drop opens a Touch ID or password prompt, and that confirmation turns the permission on. If no grant appears in 15 s after a cancelled drop, the instructions return.
- **LobeHub PR #20932** ([link](https://github.com/lobehub/lobehub/pull/20932)): non-activating `NSPanel` pinned to the bottom of the Settings content. Tracks the window every frame. Handles "user left this page", Settings closed, and cancelled Touch ID. **Pitfall:** calling the ask-for-access API first adds the app to the list switched off, and macOS reports only granted or not, so "not listed" and "listed but off" look the same. Their fix: drop the pre-register call. Reduce Motion stops the animation.
- **T3 Code PR #11289** ([link](https://github.com/pingdotgg/t3code/pull/11289)): one helper for Screen Recording, Accessibility and Full Disk Access.

Perry calls `requestAccessibility()` and then opens the pane (`OnboardingCoordinator.swift:68-82`). That is the pre-register path the LobeHub notes warn about. **(inference)** The user must then find the Perry row and switch it on by hand. A drag from a helper skips that search.

---

## 3. Personalization by conversation

### 3.1 What others do

| System | How it learns | What it stores | How the user sees it |
|---|---|---|---|
| HeyClicky | Interview in onboarding, "four quick questions about yourself and your work" (v1.0.49). Also learns from chat: tell it "you talk too much" and it remembers (v1.0.52) | `PROFILE.md` and `VOLATILE.md` memory files (v1.0.33). Memory covers "everything you said in the onboarding interview" (v1.0.49) | Replay tour and interview from Settings > General (v1.0.51). I found no profile viewer |
| ChatGPT | Saved memories plus chat history | Memory summary and individual items | Settings > Personalization > Memory. Ask "What do you remember about me?". Delete one, clear all, or turn off. Temporary Chat skips memory. Deleted logs may persist up to 30 days ([OpenAI help](https://help.openai.com/en/articles/11146739-how-does-reference-saved-memories-work), via search summary, **unverified**) |
| Claude | Memory import from other providers: copy a prompt, run it in ChatGPT, paste back ([TechCabal](https://techcabal.com/2026/05/27/4-easy-steps-to-move-your-chatgpt-memory-to-claude/), **unverified**) | Not found | Settings > Memory (**unverified**) |
| Dia | Opt-in memory of browsing, local per its makers (**unverified**) | | |
| Pi, Character apps | I found no source on first-run flow. Not covered | | |

### 3.2 Design for Perry

Principles drawn from the above:
1. **Ask by voice, in the user's words, and keep it short.** Three questions. HeyClicky asks four and later shortened onboarding.
2. **Never store the transcript.** Store extracted facts only. This matches Perry's existing promise for the wake word: "keeps no transcript" (`SettingsView.swift:164`).
3. **Show what was learned before saving**, as chips the user can delete or edit. ChatGPT shows memory only after the fact. Showing it first is the stronger trust move. **(inference)**
4. **Say where it goes.** On the On this Mac brain the notes never leave. On a cloud brain they travel with each question. The consent line must say so.
5. **Pin it.** Profile facts go in a pinned slot that `promptContext` always includes, ahead of the 12 recent records.
6. **One home for edits:** a "You" page in Settings (section 5). It lists the chips, and has "Redo the interview" and "Erase what Perry knows".
7. **Let preferences be learned in chat** ("talk less"), then show a "Perry will remember: shorter answers" toast with Undo. HeyClicky v1.0.52 does the first half.

### 3.3 How the learning goal becomes the first task

The user's own question is the best aha available. Route by goal type (the model classifies it once; **(inference)** this is a prompt, not new code):

| Goal type | Example | First task |
|---|---|---|
| Skill in an app on this Mac | "Figma auto layout" | Guide mode. Open the app, point at the first control, one instruction per step (tone sheet: `docs/tone-sheet.md`, Guide mode) |
| Topic | "Spanish", "how options work" | Spoken three-line starter plan plus one question back. Save the goal to the pinned profile |
| A thing to produce | "write a pitch" | Do mode with the normal approval tiers |

After the first task, offer a repeat once, never by default: "Want a 10-minute nudge on this each morning?" with "Yes, keep it going" and "Not now". HeyClicky ships the same consent pattern for routines (v1.0.53). Perry already has Routines and named helpers ("Perrys", `NotchWorkspaceView.swift:128, 135-170`).

---

## 4. Shortcut editing UX

### 4.1 Reference behavior

| Source | Behavior worth copying |
|---|---|
| Wispr ([docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)) | Click **Change**, press combo, saves on key **release**. Up to 3 keys, must include a modifier. Rejects left+right of the same modifier. Reserved: ⌘Space, ⌘Delete, ⌘⌃F. Esc alone or X cancels. Up to 4 bindings per action. Warns when hands-free nests inside push-to-talk. Double-tap push-to-talk starts hands-free. Secure Keyboard Entry blocks key chords but not modifier-only holds like fn |
| Superwhisper ([settings](https://superwhisper.com/docs/get-started/settings)) | One key does both: press-and-hold records, a quick tap toggles. Separate Cancel and Change-mode shortcuts. Warns that global and per-mode shortcuts are separate |
| Raycast ([settings](https://manual.raycast.com/settings)) | Recorder rebuilt to accept a single **fn tap**, "better conflict detection", and an **overwrite a conflicting shortcut** option. Click a specific left or right modifier. A central Shortcuts tab filtered by category |
| Claude desktop ([help](https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac)) | Presets (double-tap Option, ⌥Space, custom) and a test in the same dialog. A risky binding (Caps Lock) is off by default |
| sindresorhus/KeyboardShortcuts ([repo](https://github.com/sindresorhus/KeyboardShortcuts)) | Recorder stores to `UserDefaults` and "warns the user if the chosen keyboard shortcut is already used by the system or the app's main menu". Advises against a preset default in public apps and suggests a first-launch welcome screen. **(inference)** It records key chords. Perry's holds are modifier-only, so it would cover only the wake chord. Adding it needs approval (`AGENTS.md`: no new third-party dependencies) |
| Rectangle ([repo](https://github.com/rxhanson/Rectangle)) | MASShortcut recorder. "Ignore app" lets a conflicting app win. Not needed for Perry |
| HeyClicky | v1.0.48: "any held combo or a double-tap". v1.0.53: Control+C and Control+arrow stop counting as a double-tap. Perry already cancels a hold on a chorded key (`ModifierHoldMonitor.swift:3-10`) |

### 4.2 Recommended design

**One row per gesture. A pill shows the keys. Click the pill to record.**

States of the pill:
1. Idle: `Hold ⌃⌥`. Hover shows a pencil.
2. Recording: accent border, text `Press the keys…`. Esc cancels. ⌫ resets to default.
3. Captured: shows the combo, a green tick, and the live status line. Saves on release.
4. Conflict: amber line under the pill, with two buttons, `Pick another` and `Use anyway`.

Rules (adopt Wispr's, they are tested):
- Hold gestures: one to three modifiers, left or right, allowed alone (fn, right ⌥, ⌃⌥).
- Chord gestures: at least one modifier plus a key.
- Reject ⌘Space, ⌘⌃F, and anything Perry already uses. Name the owner: "That is Dictation."
- Conflict sources, in order: Perry's own gestures, `SymbolicHotkeys.load()` (already used at `SettingsView.swift:287`), then a short list of known app defaults (Spotlight ⌘Space, Raycast ⌥Space, Claude double-⌥). The last list is **(inference)** and needs a maintenance owner.
- Under each pill, **preset chips** for people who do not want to record: `Hold fn`, `Hold right ⌥`, `Hold ⌃⌥`, `Custom…`. The chips are today's pickers, kept as the easy path.
- Perry's talk gesture (⌃⌥ hold, ⌃ double-tap) becomes editable. Strings such as `TalkGesture.talk` ("Hold ⌃⌥ to talk") must read the saved value (`ModifierHoldMonitor.swift:11-16`).

**Live "press it now" check in onboarding:**
- Show the prompt "Hold ⌃⌥ and say hi."
- While the key is down the pill glows and the status reads `Listening…`.
- On release: `Heard you.`
- The check must read the **real** capture path. If the event tap is dead and only the fallback runs (`PushToTalkController.CaptureMode`), show: `I can only hear that key inside Perry. Turn on Input Monitoring.` and open the drag helper for Input Monitoring. Do not mark success.
- Drop the current finale keycaps, which light on a local monitor only (`OnboardingParts.swift:275`).

Layout: one card, two rows (Talk, Dictate). Wake chord and type gesture live in Settings > Shortcuts. **(inference)** Four shortcuts on one onboarding screen is what made the old one ugly.

---

## 5. Settings information architecture

### 5.1 Comparison

| App | Structure |
|---|---|
| HeyClicky | Left sidebar: Account, General, Invite & Earn; group HEYCLICKY: Voice, Microphone, Dictation, Shortcuts, Cursor; group WORK: Agents, Integrations. Lives inside Home ("Settings, at home", v1.0.49; ⌘, opens it, v1.0.51) |
| Raycast ([manual](https://manual.raycast.com/settings)) | Account, General, Launcher, Shortcuts (central, filterable), Keyboard, Advanced, Organizations, About, AI, Applications and Extensions. Each extension gets its own sidebar entry |
| Wispr Flow | Shortcuts at Settings > General > Shortcuts ([docs](https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts)). Full tab list not retrieved |
| Superwhisper ([docs](https://superwhisper.com/docs/get-started/settings)) | Configuration (shortcuts, app behavior), Sound, Advanced. Mic picker sits top-right on every page |
| macOS System Settings | Sidebar of nouns, one pane per noun, search at top. **(inference, from general knowledge)** |
| Apple HIG | Page would not load. General guidance from memory (**unverified**): put rare options in Settings, keep commonly used controls in the main UI |

Lessons: a sidebar beats a tab strip once you pass about five sections. Group by job, not by implementation. One central Shortcuts page. Account/About/Updates belong in Settings, not the menu.

### 5.2 Proposed sidebar for Perry

```
‹ Back         Settings

General
You

PERRY
Voice
Dictation
Shortcuts

WORK
Brain
Apps

TRUST
Privacy & Safety
```

Eight items. Where every current control goes:

| New page | Contains | Moved from |
|---|---|---|
| **General** | Open at login. Show Perry in the notch (eyes). Quick peek on hover. Check for Updates, What's New. Replay the intro. Version | Login: `SettingsView.swift:145-160`. Menu: Notch status `StatusMenuController.swift:160-163`, What's New `:148`, Updates `:149-152` |
| **You** | Pinned profile chips (name, work, apps, learning goal, style). Memory on/off and 3 category toggles. Browse and delete memory items. Redo the interview. Erase what Perry knows | Memory toggles `SettingsView.swift:474-492`. Menu Memory `StatusMenuController.swift:155-158`. New viewer and chips |
| **Voice** | Speak replies, voice list, speed, captions. `Advanced` disclosure: realtime BYOK | Voice out `SettingsView.swift:301-342`, realtime `:344-387` |
| **Dictation** | Microphone with a live level meter (replaces text-only "Test microphone"), language, word list | `SettingsView.swift:396-470` |
| **Shortcuts** | Talk, Type, Dictate, Wake chord. Recorder pills. Wake word toggle. Conflict messages | Wake and PTT pickers `SettingsView.swift:161-200`. New: talk and type gestures |
| **Brain** | Conversation model (cloud or this Mac). Agents. Screen helper. `Advanced`: custom driver path, sign-in commands | Models tab `SettingsView.swift:538-611` |
| **Apps** | Integration rows. Custom connectors. App skills (per-app notes, folder link) | Apps tab `:660-681`. Skills `:612-650` |
| **Privacy & Safety** | Permissions (4 rows, with the drag helper as the fix). Always-blocked apps. Workspace folder. Activity log. Diagnostics. Report a problem. Erase all Perry data | Permissions `:211-250`, Safety `:683-717`, Memory tab Activity block `:493-504`. Menu workspace `StatusMenuController.swift:99-104` |

### 5.3 Deleted or demoted

- Delete the tab strip and `SettingsTab` cases `general, voice, runtimes, integrations, memory, safety` (`SettingsView.swift:10-28`). **(inference)** Callers of `openSettings(tab:)` (`:871-874`) need a one-to-one map to the new pages.
- Delete the duplicate menu entries for Memory, Erase, Diagnostics (they stay in Settings).
- Demote to `Advanced` disclosures: realtime voice BYOK (8 fields), Cua driver path, sign-in command buttons.
- Replace "Test microphone" text result with a level meter. **(inference)** Better feedback for the same control.

### 5.4 Layout fit (inference)

The workspace is 560 pt minimum with a 210 pt rail (`NotchWorkspaceView.swift:21, 69`). A second sidebar leaves about 200 pt of content. Do what HeyClicky does: when Settings opens, **replace** the rail with the settings sidebar and show `‹ Back` at its top. The rail returns on Back. No nested sidebars.

### 5.5 What moves into the notch instead

| Item | Notch form |
|---|---|
| Retry last task | A `Retry` button on the failure card |
| Show full guide | A chip: `Walk me through this window` |
| Recording a routine | Stop button in the notch status while recording (state already exists in `NotchStatusController`) |
| Background tasks | A count pill, already in the rail (`NotchWorkspaceView.swift:127`) |
| Update available | An `Update` pill. HeyClicky shows an orange **Update app** pill on its notch (`…de4ff87c….png`) |

---

## 6. Menu proposal

Best practice from the sources I could read: Raycast's menu bar icon offers only "Settings, check for updates, and quit" ([manual](https://manual.raycast.com/settings)). Superwhisper uses the icon for Settings and mic switching ([docs](https://superwhisper.com/docs/get-started/settings)). **(inference)** A menu of 5 to 8 verbs fits one glance. Apple's HIG page did not load, so I cite no HIG rule.

### 6.1 The new menu

```
Talk to Perry                    ⌥⌘P
Ask or do something…
Background tasks (2)             (only when > 0)
Record a routine…                (becomes "Stop recording")
─────────────
Open Home
Settings…                        ⌘,
─────────────
Update available                 (only when true)
Quit Perry                       ⌘Q
```

Seven always-on items, two conditional. In debug builds, collapse the five debug items into one `Developer ▸` submenu.

### 6.2 Every current item mapped

| # | Current item | Decision | Destination |
|---|---|---|---|
| 1 | Wake Perry (⌥⌘P) | **Keep**, rename | `Talk to Perry` |
| 2 | Ask Perry… | **Merge** | `Ask or do something…` |
| 3 | Guide me… | **Merge** | Mode chip in the composer |
| 4 | Show full guide | **Move to notch** | Chip `Walk me through this window` |
| 5 | Do a task… | **Merge** | Mode chip in the composer |
| 6 | Run in background… | **Delete** | Already a toggle on the composer send action (`StatusMenuController.swift:349-353`) |
| 7 | Background tasks | **Keep**, conditional | Shows only when a task runs, with the count |
| 8 | Retry last task | **Move to notch** | `Retry` on the failure card |
| 9 | Workspace: ~/PerryDemo | **Move to Settings** | Privacy & Safety > Workspace folder |
| 10 | Choose workspace folder… | **Move to Settings** | Same row |
| 11 | Watch & Learn ▸ | **Keep one item** | `Record a routine…`. Import, run, export and delete live on the Routines page (rail item 2) |
| 12 | History | **Delete** | Rail (`NotchWorkspaceView.swift:131`), reached from `Open Home` |
| 13 | Export diagnostics… | **Move to Settings** | Privacy & Safety (already there, `SettingsView.swift:495`) |
| 14 | What's New | **Move to Settings** | General, plus an after-update card |
| 15 | Check for Updates… | **Move to Settings** | General. Menu shows `Update available` only when true |
| 16 | Settings… | **Keep** | `Settings…` ⌘, |
| 17 | Memory: on/off | **Move to Settings** | You |
| 18 | Notch status ✓ | **Move to Settings** | General |
| 19 | Erase all Perry data… | **Move to Settings** | Privacy & Safety (already there, `SettingsView.swift:500-504`) |
| 20 | Quit Perry | **Keep** | `Quit Perry` ⌘Q |

Net: 20 to 7 (+2 conditional). New item: `Open Home`.

---

## 7. Recommended onboarding sequence

Total target: **about 125 s setup, then about 40 s of the first real task.** Times are estimates **(inference)**. Measure with the existing marks: `scripts/lab/latency-report.py <markers.jsonl> --pair onboarding.start:onboarding.finish`. Add marks per beat.

Copy follows `docs/tone-sheet.md`: Perry is terse, no emoji, no exclamation marks, never calls itself an AI.

### Step 1. Hello (8 s). Skippable: name only

- Ink greeting (keep `HelloGreetingView`).
- Title: `Hi, I'm Perry.`
- Body: `I live in your notch. What should I call you?`
- Field prefilled from `NSFullUserName()` first name. Button `Continue`. Enter accepts.

### Step 2. Brain (12 s, up to 60 s with sign-in). Skippable: `Later`

- Title: `How should I think?`
- Card A, `ChatGPT`: `Sharper answers. Uses your ChatGPT account.` Button `Connect ChatGPT`.
- Card B, `On this Mac`: `Private and offline. Simpler answers.` Disabled with the reason if unavailable (`HomeOnboardingView.swift:400`).
- Footer: `You can switch in Settings.`
- Default highlight: the route that is ready now. If neither is ready, highlight ChatGPT.
- Why first: every later step talks to the model (inference, section 1.1 evidence).
- If the user skips, the interview falls back to typed chips and a canned first answer.

### Step 3. Access (25 s). Skippable: `Not now, I'll type`

- Title: `I need to see what you see.`
- Rows: `Accessibility` (`Read buttons, menus and fields`) and `Microphone` (`Hear you`). Screen Recording is **not** here.
- Microphone uses the normal system prompt. Accessibility uses the **drag helper**.

**Drag helper spec (from section 2.4):**
1. Open the Accessibility pane by deep link. Do not call `requestAccessibility()` first. It pre-registers Perry switched off (LobeHub pitfall).
2. Find the Settings window with `CGWindowList`. This needs no permission.
3. Show a non-activating `NSPanel` pinned to the bottom of the Settings content. Track the window as it moves. Show only while Settings is frontmost.
4. Panel copy: `Drag me into the list above.` A real draggable Perry icon (file URL of the app bundle). One dashed ring or arrow cue. Stop motion under Reduce Motion.
5. Poll the existing 1 s probe (`OnboardingDirector.swift:152-157`). On grant, show `Got it.` and close after about 1 s.
6. States: user left the pane (`Go back`), Settings closed (`Open Settings`), cancelled password (`Drag me again`).
7. Test the deep link on macOS 27, where the list is titled "Device Control and Data Access". **Unverified.**
8. Settings > Privacy & Safety reuses the same helper as the fix action on each red permission row.

### Step 4. Shortcuts (20 s). Skippable: `Keep defaults`

- Title: `Hold ⌃⌥ and say hi.`
- One card, two rows: `Talk` and `Dictate`. Recorder pills plus preset chips (section 4.2).
- Live status: `Listening…`, then `Heard you.`
- If the event tap is dead: `I can only hear that key inside Perry. Turn on Input Monitoring.` and open the drag helper for Input Monitoring. Do not pass the step.
- Footer: `Change these any time in Settings > Shortcuts.`
- No keycap art. No wake chord, no type gesture on this screen.

### Step 5. Interview (45 s). Skippable at every question, by button or by saying "skip"

Consent line before the first question:
> `Tell me about you. I keep short notes on this Mac so I can help your way. You can read and delete them any time.`
> If cloud brain: `I send these notes with your questions to ChatGPT.`

Questions, one at a time, hold the talk key or tap the mic. Typed fallback with suggestion chips:

1. `What do you do?` Chips: `Student`, `Designer`, `Developer`, `Founder`, `Something else`.
2. `Which apps do you spend your day in?` Chips from installed apps (Notion, Figma, Xcode, Gmail in a browser). **(inference)** Reading installed apps needs no permission.
3. `What's something you've been wanting to learn lately?` No chips. This is the user's own idea.

Close:
- Show a card, `Here's what I got.` Rows are editable chips: Name, Work, Apps, Learning goal.
- Buttons: `Looks right` and `Edit`. `Not saved yet` appears until the user confirms.
- Save facts only, no transcript. Write to `.preference` records plus the pinned profile slot (section 3.2).
- Style learning ("shorter answers") comes later from chat, not from a question.

### Step 6. Apps (15 s with one connect). Skippable: `Later`

- Title: `Want me to reach into your apps?`
- Show only apps the user named, plus Google if mail or calendar was named. Tiles: `Gmail`, `Google Calendar`, `Notion`, `Slack`, `Linear` with the one-line description and `Connect`. Google tiles share one grant.
- Sub-copy: `Read-only to start. I ask before I change anything.` Matches `writesEnabledByDefault: false` (`RemoteIntegrations.swift`, catalog).
- Cap at one required-looking connect. The rest show `Later in Settings > Apps`.
- OAuth opens the browser and returns. Budget 20 to 40 s per connect.
- Footer: `Skip`.

### Step 7. First goal (about 40 s). Skippable: `Not now`

- Perry says, with the learning goal from step 5: `Let's start with {goal}.` Then route by goal type (section 3.3).
- **Screen Recording is requested here, just in time**, only if the goal needs screen sight: `To show you, I need to see your screen. Drag me into the list.` Use the drag helper. If macOS needs a relaunch, the saved beat and goal resume it (`OnboardingDirector.swift:58-60`). Whether macOS 27 needs a relaunch is **unverified**. Test it.
- Onboarding ends when the first task starts. No separate finale beat.
- Closing notch line (3 s): `I'm up here whenever you need me.`
- Optional once: `Want a 10-minute nudge on this each morning?` `Yes, keep it going` / `Not now`.

### Skippability and time

| # | Step | Time | Skippable | Result if skipped |
|---|---|---|---|---|
| 1 | Hello | 8 s | Name only | Uses system first name |
| 2 | Brain | 12 s | Yes | Typed chips and a canned first answer |
| 3 | Access | 25 s | Yes | Typing works, no screen sight |
| 4 | Shortcuts | 20 s | Yes | Defaults, key may be unverified |
| 5 | Interview | 45 s | Per question | No profile, goal step asks once |
| 6 | Apps | 15 s | Yes | Connect later in Settings |
| 7 | First goal | 40 s | Yes | Notch rests |
| | **Total** | **about 165 s** | | |

### Delete list

- `PracticeWindow.swift`, `PracticeStep`, `practiceHint`, the practice beat view (`HomeOnboardingView.swift:475-512`), `beginPractice`/`endPractice` effects (`OnboardingCoordinator.swift:83-86`).
- The finale beat and `LargeShortcut` keycaps (`HomeOnboardingView.swift:515-570`, `OnboardingParts.swift:318-337`).
- The `firstTalk` beat as a separate step. Its job moves into step 4 and step 5.
- Old saved beat names (`firstTalk`, `screenAccess`, `brainChoice`, `practice`, `finale`) decode to nil and restart at Hello (`OnboardingDirector.swift:59`). Acceptable for users who have not finished.

### Risks and checks before building

1. Hold-fn conflict with the macOS Globe key setting. **(inference)** Test on the target Mac.
2. Whether the Accessibility deep link and "Device Control and Data Access" naming match on macOS 27. **Unverified.**
3. Whether Screen Recording needs a relaunch on macOS 27. **Unverified.**
4. Interview quality on the on-device model. If weak, run extraction only when a capable route exists. **(inference)**
5. Pinned profile injection changes prompts. Needs a memory-store test.
6. Run builds and tests on the remote test Mac, not the user's MacBook (see `no-local-tests-while-in-use` memory).
7. Add per-beat `PerfMark`s and run `scripts/lab/latency-report.py`. Confirm the 3-minute target with a stopwatch.

---

## 8. Sources

- HeyClicky changelog: https://heyclicky.com/changelog
- Wispr Flow setup: https://docs.wisprflow.ai/articles/3152211871-setup-guide
- Wispr Flow shortcuts: https://docs.wisprflow.ai/articles/2612050838-supported-unsupported-keyboard-hotkey-shortcuts
- Superwhisper quickstart: https://superwhisper.com/docs/get-started/quickstart
- Superwhisper settings: https://superwhisper.com/docs/get-started/settings
- Raycast quickstart: https://manual.raycast.com/quickstart
- Raycast Windows getting started: https://manual.raycast.com/windows/getting-started
- Raycast settings: https://manual.raycast.com/settings
- Raycast 1.26 Walkthrough: https://www.raycast.com/changelog/macos-v1/1-26-0
- Granola setup: https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time
- Claude Quick Entry: https://support.claude.com/en/articles/12626668-use-quick-entry-with-claude-desktop-on-mac
- Sunsama setup: https://help.sunsama.com/docs/setting-up-your-sunsama
- KeyboardShortcuts: https://github.com/sindresorhus/KeyboardShortcuts
- Rectangle: https://github.com/rxhanson/Rectangle
- Permission helper PRs: https://github.com/lahfir/agent-desktop/pull/299, https://github.com/lobehub/lobehub/pull/20932, https://github.com/pingdotgg/t3code/pull/11289
- OpenAI memory help (search summary only): https://help.openai.com/en/articles/11146739-how-does-reference-saved-memories-work
- Comet, Dia, Cursor, Claude memory import (secondary, unverified): https://www.tomsguide.com/ai/perplexity/how-to-use-perplexity-comet, https://computingforgeeks.com/install-dia-browser-macos/, https://techcabal.com/2026/05/27/4-easy-steps-to-move-your-chatgpt-memory-to-claude/
- User screenshots: `/Users/hridyaagrawal/.t3/userdata/attachments/58557fdf-…-34901b52….png` (HeyClicky settings), `…5b8bcb5e….png` (Perry menu), `…5088e2bf….png` and `…e873275e….png` (HeyClicky permission helper), `…639be2d6….png` (weak first answer)
- Perry docs: `docs/heyclicky-feature-audit.md:50-52`, `docs/heyclicky-teardown.md`, `docs/tone-sheet.md`

**Gaps.** No access to Mobbin, Pageflows or Growth.Design pages. No teardown found for ChatGPT Mac, Rewind/Limitless, Linear, Things, Arc, Pi or Character apps. Apple HIG pages returned no body text. I could not confirm HeyClicky's exact interview questions or whether it shows a profile viewer. Time estimates are mine.
