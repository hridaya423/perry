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

**Shipped:** hotkey wake, wake-word gate (off by default), type/talk panel, Guide engine (AX step-follows-you, show-me-everything), Do supervisor + trust tiers + intent cards (typed confirm at red), activity log, memory store + wipe, background runner + notifications, permission probes + onboarding flow, blocked-window capture refusal, CLI runtime probe, vendored codex runtime, Finder demo suite. 66 tests.

**Partial:** dictation (bare STT; missing custom words, language picker, auto-detect), voice out (voice quality picker done; missing sound design entirely, no output warm-up), panel (restyled; no style preferences), buddy (sprite exists, **not wired into the live overlay**), onboarding (state machine solid; zero magic-moment media).

**Missing (candidate):** real Settings window (**Perry ships `Settings { EmptyView() }`**), push-to-talk hold-to-talk, agent cards/activity strip UI, concurrent threads + resume/steer, proactive suggestions, computer-use executor, integration/MCP layer, marketplace, history browser, diagnostics reporter, remote config.

**Rejected by PRD §5 (stay rejected):** notch stack, widgets, team/cloud accounts, hosted inference, billing/paywall, Windows.

## 3. Polish deficit ranking (where we feel cheapest)

1. **No settings surface at all** — every toggle lives in code or a bare menu.
2. **Silence** — HeyClicky invests heavily in audio (warmer, topology, crafted wavs); Perry has none of it. First-run feels dead.
3. **Buddy invisible** — sprite exists but the transplanted overlay never shows him; users see machinery, not a companion.
4. **Copy drift** — remaining strings still generic; intent card doesn't follow confirmation format.
5. **Onboarding ends in a wall of text**, no demo moment.

## 4. Punch list executed this pass (P0)

1. Settings window: runtimes status, wake word, memory, dictation language placeholder, voice, data wipe — replaces EmptyView.
2. Sound design: generated-in-repo chime set (wake, send, done, fail) synthesized to CAF assets, played through a tiny SoundPlayer; no third-party audio.
3. Wire PerrySpriteView into AppController's overlay presence so the buddy actually appears during sessions.
4. Intent-card copy per tone sheet ("About to … · Approve/Stop" shape, red-tier line verbatim).
5. Copy pass on remaining spoken/menu strings.

Deferred (P1+, needs own sessions): push-to-talk event tap, dictation custom words/languages, history tab, agent activity strip, BYOK/local runtime tiers (PRD M5), computer-use spike, onboarding demo video, diagnostics reporter. Marketplace/integrations/notch/paywall remain out per PRD.

## 5. P1 punch list revised after changelog review

The changelog reorders priorities. New items in bold:

1. **Failure-path choreography (biggest real gap):** mic failover + spoken
   explanation, audio-route change survival, first-word pre-roll warm-up,
   clipboard fallback when output is muted. Perry currently has none of this.
2. **Latency posture:** pre-warm runtime/session paths at launch; stream
   responses; route easy questions cheap. **Perry's router idea maps directly:
   ScriptedFinder/CLIRuntime for demos, codex for depth.**
3. **Dictation hardening:** custom dictionary, language auto-detect,
   terminal-newline safety, paste layout safety.
4. **Draw-on-screen teaching loop:** click-detection advances the step (we have
   advanceGuide; wire it to AX click observation), per-app teaching skills,
   hand-drawn stroke style (our scribble path already supports it).
5. **Spatial context:** let the user draw on screen as part of the question
   (overlay already renders user ink; pipe it into context).
6. **Memory shape:** PROFILE.md + VOLATILE.md two-file model is better than our
   category JSON for LLM injection; keep local-only.
7. **Guided hands-on tutorial:** replace text cards with 2-minute do-things
   flow (say hello aloud, watch a draw, try dictation).
8. **"See what's new" after update** via Sparkle + changelog feed; release
   notes crediting reporters; honest impact numbers once we have users.

Still out of scope: notch, marketplace, teams, paywall, proactive anything
(their own arc proves the point), cloud accounts.
