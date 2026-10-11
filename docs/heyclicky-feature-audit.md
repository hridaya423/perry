# HeyClicky full feature audit → Perry punch list

2026-08-26. Evidence: binary string sweep (`strings -arch arm64` over the
v1.0.48 universal Mach-O, ~90k Swift symbols), Info.plist, entitlements,
Resources inventory, website mirror, **the public changelog at
heyclicky.com/changelog (mirrored to `~/honey/heyclicky-re/website`, 49
GitHub releases v1.0 → v1.0.48)**. Companion docs: `heyclicky-teardown.md`
(architecture). This doc is the working audit: every observable HeyClicky
capability, Perry's status, and the resulting punch list.

## 0. Changelog-derived features (not visible in the v1.0.48 binary alone)

The changelog is the product narrative; these shipped and matter:

- **Realtime voice harness (v1.0.21→45):** streaming voice as the default
  surface, handpicked voice picker with spoken previews (incl. kid voices),
  barge-in with echo cancellation, Bluetooth route-switch survival, speed
  control 0.5x–1.5x, session/network pre-warming for fast first response,
  "calmer voice" copy passes removing greetings/fillers.
- **Model routing (v1.0.45/47):** per-question router — fast model for quick
  questions, frontier model for deep/screen-complex ones, with honest
  "what model are you" answers (v1.0.24).
- **Dictation as a flagship (v1.0.34–48):** ~450ms streamed STT into any app,
  hold-to-talk + double-tap hands-free + customizable combos, 50+ languages
  with auto-detect, self-learning dictionary (edit within ~20s adds the word),
  two-model STT+cleanup pipeline, screen-aware dictation ("type a reply here"
  using screenshot + memories), layout-safe paste (Dvorak/Colemak), terminal
  newline collapsing so words never run as commands, long-session backups.
- **Draw-on-screen teaching (v1.0.26+):** step-by-step teacher that detects
  when you clicked where it told you and advances; skill files injected by
  foreground program; **89 app teaching skills** (v1.0.28); hand-drawn
  Excalidraw-style strokes (v1.0.40); highlight auto-clears after speaking.
- **Spatial context (v1.0.33):** user draws point/circle/scribble on screen as
  part of the question.
- **Skills library & marketplace:** ~100 community skills, one-click activate,
  create-by-typing-what-it-should-do, capability-aware creation (2.0), creator
  emails on approval, team-private sharing (v1.0.44).
- **Memory (v1.0.33):** PROFILE.md (habits/preferences) + VOLATILE.md (current
  project) injected into both voice and agent loops.
- **Integrations via connectors (v1.0.15/11):** Notion/Gmail/Linear/Slack-class
  catalog with suggestion popups (capped 3/day), native-app recognition;
  Google Workspace agent tasks; email send gated off by default.
- **Computer use (v1.0.12→48):** Cua-powered clicking, tinted overlay cursor +
  "forbidden from moving your real pointer", 5-second cancel window on agent
  spawns, retry button on failed agents, background clicks scoped to target
  window (v1.0.48 native driver).
- **Proactive agents arc (v1.0.33→46):** launched, users felt watched, fully
  removed including local tracking DB self-delete — a privacy trust move worth
  copying in spirit.
- **Onboarding guided tutorial (v1.0.40):** two-minute hands-on first run:
  say hello aloud, watch it draw, circle-and-ask, draft an email by voice, try
  dictation in a real text box. Born from "no window, no buttons" being hard
  to explain.
- **Trust & ops details:** credentials to Keychain after launch (v1.0.47),
  account deletion incl. analytics erasure, security-audit fix disclosed,
  UPI/rupee pricing, yearly billing, team dashboard pilot, in-app bug reporter
  with logs, changelog linked in Settings + "See what's new" card after update,
  region re-routing when providers geo-block, managed-Mac Codex policy
  adaptation, muted-speaker clipboard fallback with one-click unmute, mic
  failover to built-in with notched explanation, AirPods profile-switch
  pre-roll fix.
- **Polish cadence facts:** 49 releases in ~5 months; release notes written in
  product voice with kaomoji; every fix credited to the reporting user by
  handle; impact numbers cited from their own logs ("300 users hit mic
  failures"); weekly X demo videos; $10k MRR by late June.

### The polish rubric this implies

HeyClicky's polish is not visual flair — it's **failure-path choreography**:
every way audio/input/routing can fail on a real Mac (Bluetooth flips, wedged
mics, sample-format mismatches, muted speakers, strict networks, IT-managed
policies, Dvorak keyboards, Electron apps) has a detected, explained, worked-
around path, usually surfaced through the notch with a personality line. Plus
response-latency obsession (pre-warm everything, route by difficulty, stream
tokens). Perry should adopt the rubric, not the notch.

## 1. Complete HeyClicky feature inventory

### Invocation & voice input
| Feature | Evidence |
|---|---|
| Global hotkey, user-recordable w/ modifier choice | ClickyHotkeyRecorder, ClickyHotkeyModifier, ClickyShortcutSlot |
| Wake word | shipped contract; gate before agent runs |
| Global push-to-talk via event tap (hold-to-talk) | "Global push-to-talk: couldn't create event tap…" |
| Caps Lock as trigger (debug/proactive) | ClickyProactiveCapsLockDebugTriggerEnabled |
| Dictation w/ language selection + auto-detect | ClickyDictationLanguage, ClickyDictationAutoDetect |
| Custom dictionary words for STT | ClickyDictationCustomWords |
| Mic device picker, mic test card, live volume blocks | ClickyMicrophoneDeviceOption/TestCard/VolumeBlocks |
| Realtime voice previews (8 OpenAI realtime voices) | Resources/realtime-voice-preview-*.mp3 |

### Voice output & sound design
| Feature | Evidence |
|---|---|
| Pre-warmed audio output ("chime warmer") to kill first-play latency | ClickyChimeWarmer logs |
| Audio topology monitor + format conversion pipeline | ClickyAudioTopologyMonitor, ClickyFormatKeyedAudioConverter |
| Spatial/crafted UI sounds (send, receive, open, up/down, surprised…) | Resources/*.wav set |
| Spoken task-finished summaries | shipped contract |
| Voice settings page | ClickyVoiceSettingsPage |

### Guide / teach
| Feature | Evidence |
|---|---|
| Draws annotations on screen while teaching | product core; overlay internals compiled |
| Screen-as-context Q&A from screenshot | website + prompt contract |

### Do / agents
| Feature | Evidence |
|---|---|
| Bundled codex runtime supervision | CodexRuntime/, teardown doc |
| Computer-use via embedded cua-driver daemon + stdio MCP proxy | cua-driver skill + Helpers binary |
| Computer-use runtime selection UI | ClickyComputerUseRuntimeSelection |
| Local-root tool executor (dev/power flag) | ClickyLocalRootToolExecutor |
| Multiple concurrent background agent threads | prompt contract |
| Resume older threads / active-thread steering | prompt contract |
| Colorful agent cards + activity strip labels | ClickyColorfulAgentCardsEnabled, ClickyShowAgentLabelsInActivityStrip |
| Proactive agent suggestions | ClickyProactiveAgentSuggestionsEnabled |
| Auto-approve extra usage toggle | ClickyAgentAutoApproveExtraUsage |

### Skills & integrations
| Feature | Evidence |
|---|---|
| ~25 bundled workflow skills + capability skills | Resources inventory |
| Remote skill library backend | ClickySkillLibraryBackend(Error) |
| **PowerUps: full UGC skill marketplace** — creators, publish flow, review status chips, categories, search, activate/deactivate sync, share buttons | PowerUpPanel* symbol tree (~40 view functions), ClickyPowerUpManager |
| Composio-backed integrations (Gmail draft-first, Calendar, Drive, Docs, Sheets, Notion w/ file upload path, more) | prompt contract |
| Upcoming meetings on home | ClickyUpcomingCalendarBackendClient/Enabled |
| Obsidian vault path setting | ClickyObsidianVaultPath |
| Program logo registry (per-app icons in UI) | ClickyProgramLogoRegistry |

### Memory, history, context
| Feature | Evidence |
|---|---|
| User memory as markdown | ClickyCachedUserMemoryMarkdown_ |
| Response history store + backend + tab | ClickyResponseHistory*, ClickyHistoryTabEnabled |
| Library mode | ClickyLibraryModeEnabled |

### Appearance & surfaces
| Feature | Evidence |
|---|---|
| Panel style prefs (background, transparency, visual effect) | ClickyPanelBackground/StylePreference, VisualEffectBackground, TransparentPanesEnabled |
| Notch home w/ tabs, pinned skills, sounds | ClickyNotchHomeTab, SkillPinnedNotchState, NotchSoundsEnabled |
| Legacy menu-bar panel fallback | ClickyUseLegacyMenuBarPanel |
| Identity icon shape picker | ClickyIdentityIconShape |
| Active integrations shown on home | ClickyShowActiveIntegrationsOnHome |

### Platform & ops
| Feature | Evidence |
|---|---|
| Supabase auth, OAuth return via clicky:// heyclicky:// schemes | Info.plist CFBundleURLTypes |
| Keychain store | ClickyKeychainStore |
| Remote config + feature flags | ClickyAppRemoteConfigV1, AgentsTabFeatureFlags |
| Diagnostics: log capture, report, document; error reporter | ClickyDiagnostics*, ClickyErrorReporter |
| Sparkle updates, Sentry crash, dual-region PostHog | Frameworks + endpoint strings |
| Hosted onboarding/paywall videos (Mux) w/ offline fallbacks | ClickyHostedVideo, ForceHostedVideoFailure keys |
| Discovery-channel survey (onboarding, synced) | ClickyDiscoveryChannel* |
| Plans $0/$20/$100, agent quotas, maker discount | website pricing |
| Community surfaces: Canny, Reddit, WhatsApp, prefilled email | endpoint strings |

### Entitlements posture
Non-sandboxed app (app-sandbox=false), audio-input + camera entitlements,
temporary SC picker exception. Camera entitlement suggests photo/video features
not visible in strings; noted, not chased.

## 2. Perry gap analysis

Perry has automated coverage for hotkey and opt-in wake invocation, typed and spoken requests, push-to-talk, realtime voice boundaries, per-utterance routing, route fallback, spatial selection, click-advanced guides, supervised execution, confirmations, Cua/file actions, cancellation, verification, history, local memory, onboarding, notifications, runtime discovery, integrations, and diagnostics. The evidence registry records each capability separately; none of this wording upgrades an automated capability to live-tested or release-proven.

The remaining feature-level partials require live evidence or external infrastructure rather than more UI wiring. Realtime voice, language routing, route recovery, background recovery, provider authentication, and integration writes still need their published device/account matrices and latency runs. The local skill catalog remains smaller than HeyClicky's, and background work remains on-device rather than surviving outside the app process.

Remote integrations now include on-device OAuth for Google Workspace, Notion, Slack, and Linear, with provider-specific PKCE/secret and scope rules, Keychain credentials, refresh/retry, allowlisted reads, per-service write enablement that defaults off, orange confirmation for enabled writes, and redacted summaries. There is still no PowerUps marketplace backend or hosted connector service.

Perry has a pinned Sparkle updater and a user-initiated, redacted diagnostics export. It ships no crash-reporting or analytics SDK (no Sentry, no PostHog). The signed, notarized distribution and real hosted-credential run are still unproven. Remote feature flags, hosted accounts, a Perry OAuth broker, and provider-region routing remain outside the 1.0 contract.

**Rejected by PRD §5 (stay rejected):** notch stack, widgets, team/cloud accounts, hosted inference, billing/paywall, Windows.

## 3. Polish deficit ranking (where we feel cheapest)

1. The largest functional UX difference is voice: the optional realtime path now streams duplex audio with macOS voice processing and barge-in, while the local fallback remains the dependable private path.
2. Vision is now attached to the Do path through Cua screenshots and local OCR, with an optional BYOK multimodal planner for direct image reasoning; the default Codex/CLI planners still consume the screenshot's OCR rather than image tokens, and they fail closed if Cua cannot supply the target window.
3. Do mode is transparent and cancellable, and each background record has its own actor-supervised lifecycle, checkpoint, steering path, and Cua session target; it does not provide hosted workers that survive the app process.
4. Five local skills are useful coverage, not marketplace scale; user-authored Markdown works locally, while discovery and sharing do not.
5. Diagnostics are exportable and redacted. Crash and update clients are wired, but signed distribution and real hosted-credential evidence still gate release claims.

## 4. Punch list executed this pass (P0)

1. Replaced the empty Settings scene with runtime status, wake-word and shortcut controls, voice and dictation configuration, microphone selection/testing, local skill activation, memory category toggles, history export, data wipe, and redacted diagnostics export.
2. Added a local sound set, voice previews, output warm-up, muted-output clipboard fallback, audio-route recovery, and built-in-microphone failover.
3. Wired the Perry buddy and activity strip into live Guide and Do sessions, with pause, resume, steer, stop, retry, trust tiers, and verification state.
4. Connected spatial selection, AX click observation, relevance-ranked guide targets, app skills, local memory injection, and click-advanced teaching to the planner and overlay.
5. Added deterministic AX and workspace-file executors, stable target checks, cancellation-aware CLI process handling, and a local planner that completes supported tasks without an installed coding-agent CLI.

## 5. P1 punch list revised after changelog review

The remaining work is ordered by user-visible capability, not by surface area:

1. Add a first-class hosted Cua/sandbox worker only if Perry's PRD expands beyond local execution; the local Cua MCP adapter is implemented and is now the required computer-use path.
2. Add a hosted agent-worker service only if background execution must survive app termination; the local scheduler already supports independent pause, steer, resume, checkpoint, and crash recovery.
3. Add a production realtime voice relay and provider credential broker if Perry needs hosted key isolation and a managed speech service; the local-compatible duplex adapter and Apple fallback are implemented.
4. Expand local skills and add a remote marketplace/integration service only if Perry's PRD is intentionally widened beyond its current local-first scope; the first four OAuth-backed integrations are implemented on-device.
5. Run the existing Developer ID, notarization, Gatekeeper, Sparkle appcast, and hosted telemetry paths with release credentials and retain the resulting evidence.

Still out of scope: notch, marketplace, teams, paywall, proactive anything
(their own arc proves the point), cloud accounts.
