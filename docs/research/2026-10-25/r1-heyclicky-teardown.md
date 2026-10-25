# HeyClicky teardown: first-run and everyday UX (2026-10-25)

Scope: product and UX evidence for the Perry team. This report extends `docs/heyclicky-teardown.md` and `docs/heyclicky-feature-audit.md`. It does not repeat them.

Rules followed: no GUI app was launched or driven. Evidence comes from file reads, `strings`, `plutil`, `defaults read`, `assetutil`, `ffprobe`, `ffmpeg` frame grabs, the four user screenshots, and web pages.

## Evidence key

- `[bundle: path]` is a file under `/Applications/HeyClicky.app/Contents/`.
- `[strings: Lnnnn]` is a line in `/tmp/r1-strings.txt`, the output of `strings` on `MacOS/HeyClicky`. Line numbers are reproducible with the same command. The strings are compiled copy, so they show wording and flow. They do not show timing numbers or screen order.
- `[shot1]` to `[shot4]` are the user screenshots, in the order given in the task. They are in `/Users/hridyaagrawal/.t3/userdata/attachments/` with prefix `58557fdf-a5e5-49e3-a1d1-4bcef3a8136e-`.
- `[web: url]` is a web page. The changelog is `https://www.heyclicky.com/changelog`.
- "Inferred" marks a claim that no source states directly.

## 0. Corrections to the prior Perry docs and the task brief

1. **Version.** The installed app is **1.1.1 (build 66)**, not 1.0.53. `CFBundleShortVersionString` is 1.1.1 and `CFBundleVersion` is 66 `[bundle: Info.plist]`. The preferences show `pendingUpdateInstall.fromVersion = 1.0.53`, `toVersion = 1.1.1`. The app updated itself on 2026-10-23 (Sparkle, `SUAutomaticallyUpdate = true`). The screenshots show 1.0.53 (64) `[shot4]`. The changelog lists 1.1.1 as the newest release, dated Oct 23, 2026 `[web: changelog]`. The Settings window has no visible version change, but Home, voice and onboarding all changed in 1.0.49 to 1.1.1.
2. **`ClickyModelInstructions.md` is not the voice companion's prompt.** It is the brief for the background worker: "You're a helper HeyClicky started on this person's Mac to do one piece of work in the background" `[bundle: Resources/ClickyModelInstructions.md]`. The file is 3.5 KB. The old teardown called it a 20 KB "prompt contract for their agent mode". That file no longer exists in this form. The voice persona prompt is not a bundle file. Part of it is compiled into the binary (section 7). The rest is probably server-side behind `/brain/turn`, `/brain/compact`, `/brain/prewarm` and `/brain/session-end` `[strings: L10955-10958]` (inferred).
3. **Menu bar item is gone.** The changelog says: "The menu-bar icon is gone. The notch is now HeyClicky's only home" (v1.0.27) and "the legacy menu-bar panel is gone" (v1.0.21) `[web: changelog]`. A flag `ClickyUseLegacyMenuBarPanel` and a `LSUIElement = true` Info.plist key remain `[bundle: Info.plist]`. No `NSStatusItem` string is in the binary. See section F.
4. **The notch is not "tabs and pinned skills" any more.** The audit listed `ClickyNotchHomeTab`. Version 1.0.52 replaced hover-open with a small "peek", and 1.1.1 put Home, chat and Settings in one notch `[web: changelog]`.
5. **Voice count.** The audit said 8 realtime voice previews. The bundle has 10: alloy, ash, ballad, cedar, coral, echo, marin, sage, shimmer, verse `[bundle: Resources/realtime-voice-preview-*.mp3]`. It also has 13 older `voice-preview-*.mp3` files (bright, bubbly, cheerful, expert, fun, gentle, hope, kid, lumen, original, polished, smooth, techy). These older files are not referenced by the voice picker strings (inferred: legacy).
6. **A wake word is not evidenced.** The audit row "Wake word | shipped contract" has no support in this build. The only hands-free routes found are double-tap dictation and triple-tap Control "always-on" (section D).
7. **Realtime model stack.** The binary opens `wss://api.openai.com/v1/realtime` with an ephemeral token minted at `/agent/realtime/session` `[strings: L20839]`. Greg Brockman's quote on the site names GPT Realtime 2 `[web: heyclicky.com]`. The helper agents run on Codex with a model catalog of 14 entries (GPT-6 and GPT-5.x names) `[bundle: Resources/ClickyCodexModelCatalog.json]`. A new in-house loop called "H1" exists as a Developer setting `[strings: L8546]`.

## A. Resting notch presence

What is documented:

- There is a type named `NotchRestingMarkSurface` with a `NotchRestingMarkState`, and a flag `lastObservedRestingMarkIsWorking` `[strings: L2217, L120341, L120395]`. A resting mark exists, and it changes state when work runs.
- Related notch surfaces: `NotchActivityIndicatorView`, `NotchCountdownRingView`, `NotchDwellRingLayers`, `NotchLiveEventCornerGlow`, `NotchVoicePill`, `NotchSilhouetteShape`, `NotchPillShape` `[strings: L2467-2800]`.
- The closed notch can be "tucked". Analytics events name "pointer at the top edge while tucked", "the notch folded away", and "the welcome tour showing the notch" `[strings: L5961-5990]`.
- A "Skills in notch" setting pins "active skill logos inside the notch" `[strings: L8527-8529]`.
- A meeting setting adds "A meeting countdown notch before each Google Calendar event" `[strings: L8532]`.
- A "dwell ring" draws progress while the pointer rests on the notch (`notchDwellRing.fill`, `NotchHoverDwellState`) `[strings: L11801, L3695]`. The changelog says: "the notch waits a beat longer before expanding on hover" (v1.0.19) `[web: changelog]`.
- A live-event corner glow exists for the notch (`NotchCornerGlowTiming`, `NotchCornerGlowAppearance`) `[strings: L2467-2800, L11882]`.

What is NOT documented, and why:

- No screenshot of the idle notch exists in the user's set. I did not launch the app, so I could not capture one.
- The idle look (eyes, logo, plain black) is therefore **unknown**. Inference: the idle notch is mostly plain black with a small mark. The mark's own eyes belong to the Home "brand mark", which has `brandMarkEye`, `brandMarkMouth`, `brandMarkLook` and `brandMarkTapBlink` layers `[strings: L11841]`. The portrait characters have `idleBlink`, `breathing`, `sleep`, `sleepy` and `blinksOnPointerEntry` `[strings: L6661, L7764, L117805]`.
- The pointer in `[shot3]` and `[shot4]` is a blue triangle (#3280FF sampled at (1062,73) in `[shot3]`). It is HeyClicky's floating cursor, not the system cursor. The setting "Hide floating cursor — Hides the cursor and stops it from following you" confirms this `[strings: L8606, L8670-8672]`.

Recommended next step to close this gap: ask the user for one idle-state screenshot and one while-listening screenshot.

## B. Open notch (the "peek")

Source: `[shot3]` for layout, `[web: github.com/prasanthsasikumar/openclicky/issues/10]` for the behavior text of v1.0.52.

Behavior (documented):

- Hover opens a small "quick peek" that shows Suggestions, pins, every Clicky, and apps. Each Clicky row ends with a small pile of its three newest files. A hover on a file shows what it is. A click opens it. A drag moves it into another app.
- The pointer leaving the notch tucks the peek back in. A fix keeps the first peek after launch from folding up under the pointer.
- A user setting, **Settings > General > "Quick peek on notch hover"**, turns the peek off and restores the older behavior (from the v1.0.52 notes; the string is absent from the 1.1.1 binary, so verify in the live app).
- The expand button ("Expand Home") opens full Home. Home is resizable by dragging edges, and the size is remembered (v1.0.51).
- Escape closes the expanded panel and keeps it closed until the cursor moves away (v1.0.50).
- Cmd+, opens Settings from the notch (v1.0.51). Control+Command+A opens Home from anywhere (v1.0.49).
- A drag of a file onto the notch opens a chat with that file (v1.0.23). Analytics event names show open routes: `file_drop`, `file_drag`, `composer_click`, `double_control` `[strings: L10860-10870]`.
- "The notch now stays put when you switch or reconnect displays" (v1.0.42).

"Optimized for what the user wants to see": the sources never use that phrase. The nearest evidence is the 1.0.52 change from "full Home on hover" to a "smaller notch" peek. The changelog calls the notch a design under test `[web: openclicky issue 10, via search summary]`. The reason is inferred: a hover is a glance, so the peek shows who is working and what exists, not a full chat.

Measured layout of the peek in `[shot3]` (a 2000 px wide screenshot; the menu bar is 37 px tall; I use pixels and ratios, not points; convert with your own display scale):

| Item | Measure |
| --- | --- |
| Panel | x 745 to 1255, so 510 px wide. y 0 to 290, so 290 px tall. Centered on the screen (center x = 1000). |
| Top edge | Flush with the screen top. The panel grows out of the notch line. |
| Bottom corners | Large radius, about 28 px (estimate from the crop). |
| Fill | Near black at the top (#010100 at (1000,40)), then charcoal (#1C1C1B at (1100,120)). Inference: a vertical gradient or a translucent layer over a dark window. The app has `ClickyPanelBackground`, `TransparentPanesEnabled` and `VisualEffectBackground` preference keys, so the fill depends on a user option. |
| Header row | Left: orange gel pill "Update app" with a down-arrow icon, about 118 x 26 px. Right: info (i) icon and gear icon, about 16 px, white. |
| Agent row | Avatar circle about 54 px (light blue #A8D8F0-ish with a peach cloud face and closed "^^" eyes). Title in white semibold, about 17 px. One-line description in gray, about 16 px, truncated with an ellipsis. Row pitch about 73 px. |
| Divider | One hairline between rows. It starts at the text column, not the avatar, and stops about 12 px short of the right edge. |
| Footer | "Apps +" dark pill (#2E2E2E-ish, gray text and grid icon). "Invite & Earn" mint gel pill (#C8F0CF, matches `#C9F0CF` in the binary, dark text, gift icon). Pills are about 36 px tall. A circular expand button (about 38 px, dark fill, inner highlight ring, diagonal-arrows icon, #BABBBC) sits at the far right. |
| Cursor | Blue triangle (#3280FF) with a soft blue glow. |

Row copy seen in `[shot3]`: "Research Buddy — Digs into companies, markets, and competitors and…" and "Shippy — Builds and ships websites and small web projects ri…".

How it avoids clipping (inferred from strings): the app watches the display layout (`NotchScreenGeometry`, `NotchMenuBarCoverageProbe`, `clickyFullscreenHostDisplayChanged`) and reads `menuBarHeight`, `hardwareNotch` and `hardwareNotchTopInset` `[strings: L2477, L117135-117136, L119777]`. A system overlay coordinator hides the notch UI behind Spotlight, Control Center, the screenshot UI and Notification Center (bundle ids for those are listed) `[strings: L10890-10930]`. The panel text uses truncation with an ellipsis, not wrapping.

Motion: no easing or duration values are recoverable from `strings`. Documented only: a dwell ring before hover-open; "Clicks at the start and end of the notch UI chimes" (v1.0.37); `clicky-text-open.wav` (0.70 s) and `clicky-text-close.wav` (0.85 s) exist for the text composer `[bundle]`. `reduceMotion` is a named animation case `[strings: L6803]`.

## C. Onboarding

Order below mixes three sources. The pre-sign-in screens and permission copy come from strings. The tutorial steps come from strings. The 1.1.1 changes come from the changelog. Exact screen order inside the binary is not recoverable, so treat the order as inferred where marked.

### C1. Pre-sign-in intro

- Intro video: `onboarding-intro-v2.mp4`, 117.8 s, 1280x720, h264+aac `[bundle: Resources]`. Frame grabs (`/tmp/r1-frames/onb-1.png`, `onb-2.png`) show a single talking-head shot of Farza (green cap, round glasses, lavalier mic, wooden window) with a thin blue progress bar along the bottom edge. No UI is shown. Copy cards: "Meet HeyClicky" / "Turn your sound on and tap the button below." / button "Let's start" `[strings: L10885-10887]`.
- Paywall video: `paywall-intro-v2.mp4`, 32.3 s. A second talking-head (brick wall, white fleece) with two office B-roll cuts near the end (`/tmp/r1-frames/pay-1.png`).
- Tour music: `ff.m4a`, 281.5 s. The log line "failed to play tour music" and the toggles "Turn tour music off / on" show that music plays under the tour `[strings: L17219-17221]`.
- Headline strings: "I live in your notch now." / "Need permissions to get started." / "A tiny AI buddy that lives on your Mac." / "Sees your screen, talks back, runs your apps." `[strings: L10883-10889, L19355]`.

### C2. Permission flow (`PermissionFlowCoordinator`, `PermissionGuideAssistant`)

Four steps. The step count is in analytics (`permission_step_index`, `permission_step_count`). The hero assets are `permission-screen-content-hero`, `permission-microphone-hero`, `permission-screen-recording-hero`, `permission-accessibility-hero`.

| Step | Headline (verbatim) | Support line (verbatim) |
| --- | --- | --- |
| Microphone | "This lets me hear your voice." | "Only while you're holding the shortcut." |
| Screen content (ScreenCaptureKit picker) | "I need screen share." | "I only see your screen when you press the hotkey." Hint: "Pick a display to finish." |
| Screen recording | "Complete screen access" (step title); "Flip my toggle on." | Button "Grant Screen Recording". "Drag me into the Screen Recording list." Warning: add to "Screen & System Audio Recording, not the audio-only list." After toggle: "Click Quit & Reopen to finish Screen Recording." |
| Accessibility | "I need accessibility permissions." | "Drag me into the Accessibility list." "This lets me work in any app." Button "Open". |

All strings above are from `[strings: L19973-20075]`. `[shot1]` shows the Accessibility step: black panel, three-segment progress, headline, support line, gel "Open" button, "..." and "x" at the top right.

Details of `[shot1]` (1102 px capture, roughly 2x retina; inferred from System Settings text size in `[shot2]`):

- Progress: three pills about 44 x 13 px with 10 px gaps. Done pills are periwinkle gel (#A0BAEA sampled) with a navy rim. The pending pill is gray (#48484A).
- Headline: bold white (#ECECEF), about 26 px. Support line: gray (#9093A0 token), about 21 px, one line.
- Button: gel "Open", about 161 x 80 px, pill radius, black semibold text with a white text-shadow.
- Background: pure black (#020101 sampled).

**The drag-into-list helper** (`[shot2]`, `PermissionGuideAssistant`):

1. HeyClicky opens the exact System Settings pane (`x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility`, same for `Privacy_ScreenCapture`) `[strings: L20054-20060]`.
2. A floating dark card attaches to the bottom of the Settings window. It stays attached ("The guide will stay attached to System Settings while you drag HeyClicky into the list above") `[strings: L20040-20046]`.
3. The card holds an up-arrow icon in a circle, the line "I'm HeyClicky — drag me into the list above.", and a row with the app icon and the name "HeyClicky". A hand-grab cursor sits on that row `[shot2]`.
4. Measured in `[shot2]` (1706 px capture): card about 1040 x 225 px, corner radius about 28 px, dark translucent fill, inner row about 980 x 100 px with a lighter fill and a hairline rim. The card overlaps the lower part of the Settings list on purpose, so the user's eye goes from the card up to the list.
5. If the app does not show automatically: "reveal it in Finder and drag from there" `[strings: L19996]`.
6. Recovery copy exists for each fail path: "If you close the alert instead, this row will quietly switch to Open so you can retry the handoff yourself." and "Waiting for the Mac handoff." `[strings: L20041-20052]`.
7. The Screen Recording row uses the same card with "Drag me into the Screen Recording list." and the line "m HeyClicky — turn my toggle on above" for the toggle-only case `[strings: L20069-20075]`.

Why it works (inferred): the mascot speaks in first person ("drag me"), the card is the draggable thing itself, and one sentence names the exact action. The user never reads a multi-step instruction.

Preferences show the permission snapshot is stored (`persistedPermissionSnapshot.*.prod`), `clicky.permissionIntro.acknowledged.v2 = 1`, and `hasScreenContentPermission = 1` `[defaults]`. So a returning user skips the flow.

### C3. After permissions (inferred order from strings)

1. **Sign in with Google.** Heading "Next up, sign up to make sure we don't lose your setup." Gel button "Power me up" / `sign_in_with_google` `[strings: L19349, L19428]`.
2. **Voice picker.** Title "Hi, friend." / "Hi, [name]". A "Voice slider" and a "Voice discovery map" ("Drag to discover voices, or use arrow keys to move between voices.", "Each step is a different HeyClicky voice.") play a spoken preview per voice. Each preview is one pitch line. Cedar ("Warm default"): "Hi, I'm HeyClicky. I can help teach tough ideas calmly." Marin: "…I can help plan your learning sprint." Echo: "…I can summarize tabs and find next actions." Verse: "…I can launch agents for background work." `[strings: L19300-19340, L20540-20600]`.
3. **Character and color.** "Click one to bring me to life. Choose wisely." / "Pick a color" / "Sometimes HeyClicky gets lost". There are six portrait packs (Storybook Spirits, Dreamy Cloud, Cloud Club, Arcade All-Stars, Ki Crew, Puff Pals) with names such as "Sunny — Pocket-sized sunshine. Two buns of optimism." and "Mochi — Cloud-soft hair. An excellent listener." `[strings: L7735-7960]`. Version 1.1.1 says: "The tour is shorter and skips the style step" `[web: changelog]`. Preferences show `classicClouds` assigned by default `[defaults]`.
4. **"What should HeyClicky be good at?"** A skill picker: "We've pre-selected good first choices. Add more if you need custom HeyClicky skills." `[strings: L19347-19350, bundle: Resources/ATTRIBUTION.md]`. The skills are vendored Hermes skills. Selection is saved to `selectedHermesSkillIDs`.
5. **Discovery survey.** "Where'd you hear about us? (optional)" and "We're a tiny team, and knowing where you heard about us helps a ton." `[strings: L19352, L19377]`.
6. **Dock or menu bar.** "If you have too many things in the menubar, you won't see HeyClicky. You can add it to your Dock if your menubar is too crowded." Buttons "Add it to your Dock" / "All good, keep menubar" `[strings: L19354, L19434-19436]`. This copy still mentions the menu bar although the icon was removed (v1.0.27). Treat it as stale copy (inferred).
7. **"Give me a home" / "Start Clickying".** The final pre-tour button (`give_clicky_a_home`, `runGiveClickyHomeSequence()`). Heading "Welcome to HeyClicky." / "I'm HeyClicky." / "Try it out! Hover your Mac's notch up top and you'll see me in my new home." `[strings: L19348-19366, L19355, L19433-19440]`.

### C4. Hands-on tutorial (`OnboardingTutorialWindow`, added in v1.0.40)

Changelog framing: "HeyClicky is a hard product to explain. There's no window and no buttons to click around, it lives in your voice and your keyboard shortcut" `[web: search summary of changelog v1.0.40]`. The tutorial is a window with step cards, a step dots control ("Go to step n"), a "Skip demo" button and a mic level meter.

| Step | Card copy (verbatim) | Task for the user |
| --- | --- | --- |
| Mic check | "First, can I hear you?" "Say anything out loud. If the bars dance, your mic works. I hear best on built-in or wired mics: Bluetooth ones get flaky." Prompt: "Testing, testing, 1, 2, 3". Fallback: "You'd see me talking and hear nothing. One click fixes it before we start." | Speak. A level meter shows the bars. |
| Talk | "This is how you talk to me" "Hold the keys down, say hi or tell me your name, then let go. I'm listening the whole time you hold them." Placeholder: "your words land here". | Hold Control+Option, say hi. |
| Help | "Here's how I'd help you" "I see what you see. Hold the keys, ask, and watch your screen." Prompt: "Show me how you'd help me". | Ask. The app draws on the real screen. |
| Circle | "Circle anything, ask about it" "Hold the keys, circle something on your screen with the cursor, and ask about it. Like this:" plus the 5 s clip `clicky-spatial-demo.mp4`. | Circle and ask. |
| Drive | "I can drive your computer too" "Ask me to do it and I'll take the mouse while you watch. Move it anytime and it's yours again." Prompt: "Please drive my computer and make a list". The app says "Alright, I'm taking over your mouse now. Just watch me." and "You watch. Esc takes it back." | Watch a scripted demo, then take the mouse back. |
| Text mode | "Press ⌃… and you can just talk to me ChatGPT style. But, just a note I use Claude in the background!" "Not in the mood to talk? Type" "Double-tap control" | Double-tap Control and type. |
| Dictation | "Next, screen dictation." "I read what's on your screen and write the text for you, right at your cursor. Works anywhere." "You can also dictate word-for-word" "I type exactly what you say, clean it up, and instantly put it into any box." A fake Gmail reply window ("Please write a reply to this email") is the practice target. | Dictate a reply. |
| Bridge | "There's one more thing..." "Voice, drawing, text mode, agents: you've seen it all. But, hey, can I show you one more thing?" | Click yes. |
| Draw | "Next: draw on your screen" The app narrates about 12 beats of marks on the real screen (ring, trace, arrow, highlight), then wipes them and draws three picture cards for the user's own week. | Watch. |
| Interview | "I'm curious about you." "Four quick questions about you, so I can make this whole thing actually useful for you." The fourth question is fixed: "Have you used an AI agent before, like Claude Code or Codex, or mostly ChatGPT?" Voice reply: "Switch to voice mode, then hold the keyboard shortcut to answer. Release to send." Typed reply: "Or type here". | Answer by voice or text. |
| Reveal | "Meet your Clickys." "They live in your Home, up in the notch, with a few first things you could hand them. I'll show you around at the end of the tour." Then "One moment, setting up your Clickys". | Wait about a few seconds. |
| Home tour | The notch opens on Home and the voice narrates one beat per Clicky in at most 25 words. The opener is "Okay, check this out. So, I live in your Mac's notch. It looks like this." The goodbye names the notch and the shortcut: "All of this lives up here in your Mac's notch, so hover it any time. Wherever you are on your Mac, just hold Control and Option and talk to me. Good luck!" | Listen. The notch folds and the desktop returns. |

All rows: `[strings: L17090-17300, L19640-19860, L11300-11372]`.

Prompt rules for the tutorial turns (short excerpts, `[strings: L17205-17228]`):

- Talk step: make the reply "a LITTLE funny", and "do NOT introduce yourself on this turn in any form".
- Draw step: "Never say 'feature', 'agent', 'AI', 'use case' or 'drawing'."
- Wrap-up: "Farza 2026-10-21: the wrap felt abrupt" is quoted inside the prompt as the reason for a longer goodbye. The team writes its own feedback into the prompt text.
- Draw step promise rule: "Promise ONLY what you're great at on this step" (the model once offered to debug a user's code).

### C5. Personalization ("tell me about yourself")

- The interview has four questions. The opener is spoken by the mascot. The sample interview in the bundle: "Hi, I'm Clicky. I'm not real, of course, but I'm a buddy that exists to help you work on your ideas. So what are you working on these days?" and "Oh I love that. What would winning look like for you?" `[strings: L11246-11252]`.
- Each reply is told to "React to what they ACTUALLY said first, in a few specific words that prove you heard it, then ask ONE easy, friendly question that grows out of that answer" `[strings: L17140-17142]`.
- The answers feed `/onboarding/starter-plan`. The server returns a JSON plan with `goal_line`, `clickys` (name, role, description, `intro_messages`, `reveal_line`), and `suggested_agents` (title, `agent_prompt`, optional `routine`) `[strings: L19700-19800]`. The user gets three personalized agents ("Clickys"). Example names in the sample JSON: "Sample Scout", "Brand Radar", "Launch Lab".
- Rule for these first jobs: "finish it start to finish without asking anything". If an app is not connected, "do the strongest app-free version now" and then name the one app to connect `[strings: L17128-17130]`.
- The user can skip the interview by voice (v1.0.51) and replay the whole tour from Settings > General ("Replay the welcome tour") `[strings: L8653-8660, web: changelog]`.
- Two default Clickys come first ("Research Buddy", "Shippy" in `[shot3]`). The tour "introduces the two default Clickys first and ends in the notch" (v1.0.52).

### C6. First task and shortcut setup

- The first task is the scripted "Please drive my computer and make a list" demo and the personalized suggested jobs. Starter jobs wait on the dock until the user clicks them ("OFFERED, NOT STARTED: it waits on the dock until they click it") `[strings: L6090-6110]`.
- Shortcut setup is passive: the shortcut (hold Control+Option) is taught in the tutorial and stated again in the goodbye. A recorder in Settings changes it later (section E).

### C7. Model or account step, and integrations

- No model picker exists. The text step says "I use Claude in the background!" `[strings: L19720-19760]`, and the app routes models by itself (v1.0.45 router `[web: changelog]`).
- Account: Google sign-in only. Without it: "Sign in with Google" in Settings > Account `[strings: L8682]`.
- Integrations are not part of the tutorial. They sit in Settings > Integrations ("Apps your agents can reach into.") and in suggestion popups. The tour's job cards may reach for Gmail, Notion, Calendar, Sheets, Linear and GitHub, and the prompt says "Assume NOTHING is connected" `[strings: L17130]`.

## D. Voice

Documented modes:

| Mode | Gesture | Evidence |
| --- | --- | --- |
| Push to talk | Hold **Control + Option**. Release to send. | "Hold to talk to HeyClicky. Release to send." `[strings: L8620]`; tutorial copy; goodbye line. |
| Text mode | Press the text shortcut, or **double-tap Control**. | "Press to type to HeyClicky instead of talking." `[strings: L8625]`; tour copy. |
| Dictation, hold | Hold a dictation combo. Release to insert. | "Hold and speak. Release to insert what you said at your cursor." `[strings: L8618]` |
| Dictation, hands-free | Double-tap a modifier (Fn + Control by default in v1.0.37), press again to stop. | "Dictate without holding a key down. Press to start, press again to stop." `[strings: L8619]`; `[web: changelog v1.0.37]` |
| Always-on | **Triple-tap Control**. Headphones only. Experimental. | "always-on needs headphones. plug them in and triple-tap control again. heads up: it's experimental, so expect some bugs." `[strings: L17614]`; "Always On is headphones-only for now" (v1.0.31). |
| Voice follow-up on a job | Hold the voice keys while a Clicky card or its reply is open. | "Hold your voice keys on a finished agent's card to send a follow-up" (v1.0.53). |

End of speech:

- **Push to talk uses the key release, plus a tail.** Log: "PTT end: scheduling 400ms tail, then commit" `[strings: L17593]`. Audio keeps flowing for 400 ms after release, then the app commits the buffer. A "short-tap PTT cancel" drops taps that are too short, and a "silent PTT release" path handles releases before the session is ready `[strings: L17613, L18386]`.
- **Always-on uses OpenAI server VAD.** Session config strings: `turn_detection`, `server_vad`, `threshold`, `prefix_padding_ms`, `silence_duration_ms`, `create_response`, `interrupt_response`, `noise_reduction` with `far_field` and `near_field` `[strings: L20792-20881]`. The numeric values are compiled constants and are not in `strings`. A literal `0.72` sits next to these keys, so a 0.72 VAD threshold is likely (inferred).
- **Local gates on top of server VAD.** Counters named `speechLike`, `alwaysOnSpeechLike`, `bargeInSpeechLike`, and thresholds `always=` and `barge=` run before a turn counts. Logs: "always-on speech_start did not pass barge-in gate" and "always-on commit rescued as user barge-in after full audio gate" `[strings: L17732, L18318-18320, L20640-20702]`. Result: a cough or a TV does not cancel a reply.
- **No semantic turn detection** (e.g. `semantic_vad`, `eagerness`) appears in the strings.
- Stated latency: "Replies start a couple of seconds after you stop speaking" (v1.0.45 to 1.1.1) `[web: changelog]`. The app pre-warms a session (`/brain/prewarm`, "tutorial prewarm") and reuses a healthy one ("PTT begin: reusing healthy session").

Barge-in:

- Documented in always-on mode: "In always-on mode you can now interrupt HeyClicky mid-sentence" (v1.0.22). The client sends `response.cancel`, then `conversation.item.truncate` with `audio_end_ms` so the model knows what was heard `[strings: L20619-20915]`.
- A spoken "wait" holds the voice off (v1.0.53).
- Escape interrupts running work through a dedicated event tap `[strings: L17026-17034]`.
- Echo handling: macOS voice processing "duplex AEC engine" with a probe, a promotion and a "zombie topology" cache; falls back to a "legacy pipeline" `[strings: L20839-20870]`.

Visual and audible feedback while listening:

- A voice pill (`NotchVoicePill`), a cursor waveform (`cursorWaveform.idleBreath`, `cursorWaveform.levelEase`), thinking dots (`thinkingDots.*`), and a mascot state set (`listening`, `thinking`, `speaking`) in the tutorial `[strings: L11790-11800, L19790-19800]`.
- A recording-start chime plays once per session (`hasPlayedVoiceRecordingStartChimeForCurrentSession`) and a receive chime plays once per answer (`hasPlayedTextReceiveChimeForCurrentResponse`) `[strings: L123776-123777]`.
- Settings > Microphone has a test card whose bars "should move as HeyClicky hears you".
- A muted Mac gets a clipboard copy and an "Unmute" button: "Your Mac is muted / The answer is on your clipboard. Press ⌘V to paste" `[strings: L17586-17590]`.
- Optional captions: "Captions while HeyClicky talks" shows words "at the bottom of your screen, word by word" (v1.1.1) `[strings: L8644-8647]`.
- Filler words: the realtime path can speak "One sec." / "Mm-hm." / "Okay." while work runs `[strings: L20898-20900]`.

## E. Settings window

Reached from the notch gear or Cmd+,. In 1.1.1 it is a page inside the notch panel. In `[shot4]` it is a dark panel, about 1012 x 652 px, with a "Back" pill and the title "Settings".

Sidebar (from `[shot4]`, `[strings: L8694-8700, L8653-8660]`):

| Group | Item | Subtitle in app (verbatim) |
| --- | --- | --- |
| (top) | Account | "Your plan, usage, and account." |
| (top) | General | "How HeyClicky behaves on your Mac." |
| (top) | Invite & Earn | referral page |
| HEYCLICKY | Voice | "The voice HeyClicky answers in, and how fast it talks." |
| HEYCLICKY | Microphone | "Which microphone HeyClicky listens through." |
| HEYCLICKY | Dictation | "Languages and the words HeyClicky should spell right." |
| HEYCLICKY | Shortcuts | "The keys that summon HeyClicky." |
| HEYCLICKY | Cursor | "The HeyClicky cursor that lives on your screen." |
| WORK | Agents | "Where agents work and how much rope they get." |
| WORK | Integrations | "Apps your agents can reach into." |
| WORK | Routines (page exists) | "Things HeyClicky does on repeat, on this Mac." |
| (hidden) | Developer | "Previews and debug tools." |

A small version label sits at the bottom of the sidebar: "HeyClicky 1.0.53 (64)" `[shot4]`.

Controls per page (all `[strings: L8425-8720]`):

- **Account:** plan text ("You're on the Free plan."), usage ("Talk to HeyClicky n times a month and send n agent messages."), Upgrade, Manage subscription, View your team, Fix payment, Sign in with Google, Delete account ("Permanently erase your account and all its data."), Quit HeyClicky.
- **General:** Community (Welcome tour, Request a feature, Report a bug "Sends diagnostics along so we can actually fix it.", Replay the welcome tour, WhatsApp community, Reddit), App updates (What's new, Check for updates, Install & Relaunch), Show in Dock ("Turn off to keep HeyClicky notch only."), Show in screen recordings. The 1.0.52 notes also name a toggle "Quick peek on notch hover". That string is **not** in the 1.1.1 binary, so the toggle may have been renamed or removed (inferred). "Skills in notch" and "Upcoming meetings" are Developer-page toggles in this build `[strings: L8527-8532]`.
- **Voice:** voice grid with "Select and preview this voice" ("Tap a voice to hear it. The pick applies to future spoken replies."), Speech speed (0.5x, 0.75x, 1x, 1.25x, 1.5x; "Takes effect on the next spoken reply."), "Read answers aloud", "Captions while HeyClicky talks".
- **Microphone:** input device list, "Test microphone" ("Speak normally — the bars should move as HeyClicky hears you.").
- **Dictation:** language list with search, "Auto-detect language" ("HeyClicky figures out the language as you speak."), Dictionary ("Up to 50 words. HeyClicky leans toward these spellings — names, jargon, product words."), "Add a word".
- **Shortcuts:** four rows: Talk to HeyClicky ("Hold to talk to HeyClicky. Release to send."), Text mode, Dictation, Hands-free dictation; "Reset to defaults".
- **Cursor:** "Hide floating cursor", cursor color ("Sets the cursor and app accent color"), "Pick a color".
- **Agents:** Workspace folder ("Where agents spawn and put the things they make."), "Choose Agent Folder", Announcements ("HeyClicky stays quiet while you're on a call or sharing your screen…"), "Speak when a job starts or finishes", "Show updates beside the cursor", "Auto-approve extra usage", "Suggest agent tasks" ("Fresh task suggestions every 24 hours, announced through the morning notch."), and "What agents can reach" (macOS permission list: "Tap one to review it in System Settings.").
- **Integrations:** "Search integrations", "Add custom connector" (any MCP server), a card list with Connect buttons. `[shot4]` shows Notion, Linear, GitHub, Google Docs, Google Calendar, LinkedIn. Multiple accounts per app with labels (v1.0.53).

Visual style of Settings (`[shot4]`, same 2000 px scale):

- Sidebar about 232 px wide. Row pitch about 51 px. Icon plus label. Group labels are tiny gray caps with wide tracking ("HEYCLICKY", "WORK").
- Page title about 22 px semibold ("Integrations"). Subtitle about 14 px, gray.
- Content cards: rounded rectangles (about 18 px radius), fill about #292929, rows split by hairlines, about 77 px row pitch.
- Search field: full-pill, fill about #2E2E2E, gray magnifier.
- "Connect": blue gel pill about 94 x 34 px. "Add custom connector": white gel pill (#E2E1E1, dark text).
- Top-right icon buttons: pop-out window and close (x).
- A row component set exists by name: `HomeSpaceSettingsScaffold`, `Group`, `Row`, `ToggleRow`, `ActionRow`, `ChipPicker`, `PillButton`, `RowDivider` `[strings: L1200-1230]`. The set shows that settings are built from six reusable parts.

Shortcut recorder UX (documented parts only): a `ClickyHotkeyRecorder` records modifier combos, double-tap modifiers ("pressed twice") and single keys; rows read "Press your keys"; a conflict message says "Already used by [action]. Pick a different combo."; "Reset to defaults" restores all four `[strings: L6626-6650, L8610-8620]`. Stored in `clicky.hotkeys.voiceHold.v1`, `textTrigger.v1`, `dictationHold.v1`, `handsFreeDictation.v1` `[defaults]`. Key-cap glyph color token `#404040` appears near the recorder strings (inferred: key-cap fill).

## F. Menu bar item

- **There is none in 1.1.1.** The changelog removed it (v1.0.21, v1.0.27) `[web: changelog]`. `LSUIElement = true`, so no Dock icon by default. "Show in Dock" is an option ("Turn off to keep HeyClicky notch only") `[strings: L8671]`.
- The legacy panel is behind `ClickyUseLegacyMenuBarPanel` `[strings: L14710]`.
- Overflow menu: the notch header "..." (ellipsis) holds "Check for Updates" and "Log Out", plus "Report a Bug", "Request a Feature" and "Install Update & Relaunch" `[strings: L10893-10897, L19391-19395]`. The same "..." and "x" appear at the top right of the permission card in `[shot1]`.
- Download page says macOS Sonoma 14.2 or later `[web: heyclicky.com]`, matching `LSMinimumSystemVersion = 14.2`.

Perry note: `docs/heyclicky-feature-audit.md` lists a menu-bar fallback. Do not copy it. HeyClicky dropped it because crowded menu bars hid the icon (their own copy says so).

## G. Agent and system prompt

Evidence limits: the voice companion's main prompt is not a bundle file. Fragments below come from `strings`. The background helper brief is in the bundle.

### G1. Helper brief (`ClickyModelInstructions.md`, short excerpts)

- Role: "You're a helper HeyClicky started on this person's Mac to do one piece of work in the background. They usually asked by voice, and HeyClicky wrote you the brief."
- Ask rule: "do the part that doesn't depend on it, then ask one bundled set of specific questions. Never invent their facts."
- Approval rule: "Their request is the approval: do the writes they asked for … Confirm first only before deleting or archiving their data, overwriting what they didn't ask you to change, sending something to other people … or spending money."
- Honesty: "Never say something happened unless it did".
- Output rule: "Lead with the result … then only what helps … Write plainly and warmly, like a capable friend, with no filler." The first sentence "may be read aloud".
- Naming rule: "Name apps the way they know them (Gmail, Notion), never your tools or steps."

### G2. Voice-side fragments (`strings`)

- Voice-only narrator: "You are the voice of Clicky, a friendly companion who draws on the user's screen while explaining. Your only job is to read the given narration line aloud … No preamble, no greeting, no filler, no follow-up question. Speak warmly and naturally, at a steady, unhurried pace." `[strings: L20920-20930]`
- Update relay: "Say the [clicky update] above to the user as one or two short, natural spoken sentences in your own warm voice. Never read it out word for word, never read brackets, ids or slugs aloud" `[strings: L20925]`.
- Acknowledge-then-route: "In ONE short, warm, natural sentence, acknowledge it in your own voice as if you're about to do it yourself … Do NOT mention agents, routing, or 'passing it along'" `[strings: L20735-20745]`.
- Morning invite: "at most TWO short sentences and 40 words total … Sound like a helpful friend offering to take a little work off their plate, not an announcer or a sales pitch." `[strings: L17090-17097]`
- Home tour beats: "Use at most 25 words in one or two short sentences, then stop." The prompt also bans recaps and promises.
- Everyday line length: "this step's lines may run longer than your everyday 6 to 12" words `[strings: L11365]`. So a normal spoken line is 6 to 12 words.

### G3. How it answers "what can you help me with"

No literal Q&A for this question exists in the evidence. What the strings show about capability framing:

- Capability pitches are one line each and start with "I can …", in the voice previews: "I can turn notes into study cards", "I can launch agents for background work", "I can summarize tabs and find next actions" `[strings: L20540-20600]`.
- The draw step names exactly three promises: guide the user through any program, think an idea through as a picture, answer anything with a drawing or a 3D model. "Never offer to write or debug their code, fix their app, do their work for them or anything that runs in the background." `[strings: L11350]`.
- Forbidden words in the tour: "feature", "agent", "AI", "use case", "drawing".
- Capability is shown, not listed: "This step SHOWS what you can do; it never advises them. No tips, no 'you should'." `[strings: L11358]`.
- Honest limits: "I can't see the screen right now.", "You're out of agent messages for now, so I stopped here.", "I lost the connection partway, so I stopped there." `[strings: L10980-11000]`.
- Model honesty rule: "honest 'what model are you' answers" (v1.0.24) `[web: changelog, via prior audit]`.

## H. Sound design and personality

Bundle sounds: 80 `.wav` files plus `enter.mp3` and `eshop.mp3` `[bundle: Resources]`. Event mapping is recoverable only by file name and a few strings. Durations from `ffprobe`:

| Sound | Duration | Use (documented or inferred) |
| --- | --- | --- |
| `clicky-text-open.wav` | 0.70 s | Text composer opens (name; inferred). |
| `clicky-text-close.wav` | 0.85 s | Text composer closes (name; inferred). |
| `clicky-text-send.wav` | 0.50 s | User sends a typed message (name; inferred). |
| `clicky-text-receive.wav` | 0.70 s | Answer arrives, once per response (`hasPlayedTextReceiveChimeForCurrentResponse`). |
| `clicky-question.wav` | 0.85 s | Clicky asks something (name; inferred). |
| `clicky-surprised.wav` | 0.50 s | Surprised expression (name; inferred). |
| `agent-launch.wav` | 0.80 s | A job starts. |
| `agent-done.wav` | 1.04 s | A job finishes ("sounds for task starts, finishes, and help requests were refreshed", v1.0.49). |
| `agent-needs-you.wav` | 1.08 s | A job waits for the user's answer. |
| `agent-close.wav` | 1.12 s | A job window closes (name; inferred). |
| `connection-question.wav` | 1.50 s | Ask to connect an app (name; inferred). |
| `home-reveal.wav` | 1.76 s | Home opens in the tour (name; the string "[reveal] notch opened on Home"). |
| `reveal-boot.wav` | 1.36 s | Start of the tour reveal (name; inferred). |
| `skill-up.wav` / `skill-down.wav` | 0.79 s / 0.75 s | A skill turns on or off (`skill_on:` / `skill_off:` events). |
| `badge-pop-1..3`, `gel-pop-1..4` | 0.30 s, 0.35 s | Tiny pops for badges and gel buttons. |
| `paper-place-1..3`, `whoosh`, `copy-tick` | 0.30 to 0.60 s | Tour job cards: the strings pair `paper-place`, `whoosh`, `badge-pop`, `copy-tick` with card actions. |
| Drawing set: `pen-flick`, `highlighter`, `tape`, `stamp`, `sparkle`, `build-3d`, `ding`, `eraser-bed`, `handwriting-bed`, `pencil-paper-bed`, `pen-screen-bed`, `paper-unfold`, `page-turn`, `scissor-snip` | 0.4 to 6 s | `ScreenDrawingSoundPlayer`. "Bed" loops sit under a stroke, and one-shots mark events. |

Mechanics:

- A `ClickyChimeWarmer` primes the audio output so the first chime does not lag. Failure logs name each load step `[strings: L14388-14397]`.
- A toggle `ClickyNotchSoundsEnabled` exists. Chimes stay silent in calls and screen sharing (v1.0.51). The morning chime is 30% quieter (v1.0.51).
- The v1.0.37 note says: "Clicks at the start and end of the notch UI chimes."

Personality and expressions:

- The mascot has a face set: Concerned, Heart eyes, Focused, Laughing, Excited, Skeptical, Surprised, Sleepy, Happy, Listening, Curious, Wink, plus actions Dance, Celebrate, Giggle, Boop `[strings: L7735-7960]`. Pointer hover makes it look around ("Move the pointer to look around. Click to say hello.").
- Portrait packs, with hair, outfit and eye options and named characters with one-line bios (for example "Probably has a plan. Definitely has a cowlick.").
- Cat mode: a sprite atlas and a state machine with `idleBlink`, `notchListen`, `notchSpeak`, `notchThink`, `agentRun`, `guideSuccess`, `sleep`, `drowsy`, `stretch`, `apologize` and more `[strings: L6657-6830, bundle: Assets.car `catmode-red-notch-atlas` 1280x864]`.
- Cursor-side lines: "hi, im heyclicky", "right here!", "this one!", "over here!", "click this!" `[strings: L19856-19861]`.
- Release notes use kaomoji and credit each reporter by handle `[web: changelog, prior audit]`.
- Fonts: SF Pro system text for UI. Drawing uses bundled Barlow (Regular, Medium, SemiBold) and Patrick Hand `[bundle: Resources/ClickyDraw-*.ttf]`.

## I. Fifteen transferable details, ranked

Ranking is by how much each detail raises first-run trust and everyday feel per hour of Perry work.

1. **First-person permission helper.** The card says "I'm HeyClicky — drag me into the list above." It floats over System Settings and holds the draggable app row. Copy the exact pattern. (C2)
2. **One headline plus one support line per permission, in the mascot's voice.** "I need accessibility permissions." / "Drag me into the Accessibility list." No paragraphs. A matching 3-pill progress sits above. (C2)
3. **Say why, in one short line, per permission.** "Only while you're holding the shortcut." "I only see your screen when you press the hotkey." The privacy promise doubles as the permission pitch. (C2)
4. **Recovery copy for every permission fail path.** Closing the alert switches the row to "Open". Screen Recording says "Quit & Reopen" and explains it is normal. (C2)
5. **Teach by doing, in a real window.** Mic check with live bars, then hold-and-say-hi, then circle-and-ask, then a scripted mouse takeover with "Esc takes it back." Each step has one task and an escape ("Skip demo"). (C4)
6. **A short get-to-know-you chat that changes the product.** Four questions, spoken. The answers create three named helper agents and the first jobs. The reply "react to what they ACTUALLY said" makes it feel heard. (C5)
7. **A dumb-simple core gesture, stated twice.** Hold Control+Option. The tutorial and the goodbye both say it, word for word. (C4)
8. **Peek, not window, on hover.** A 510 px wide black panel grown from the notch, with two agent rows, a footer of two pills and an expand button. A dwell ring and "wait a beat" before opening stop accidental opens. A setting turns it off. (B)
9. **One component language.** A gel pill (5-stop aqua, indigo rim, gloss strip, 1.03 hover scale in 0.15 s), a gel switch, a mint accent for the referral button, a white gel for secondary actions. The tokens are in the bundle: label #ECECEF, secondary #9093A0, tertiary #5C5E6A, hairline rgba(255,255,255,.08), page glow rgba(46,104,214,.22). (B, E; `[bundle: ClickyBrowserExtension/ui.css, ClickyBrowserSetup.html]`)
10. **Push-to-talk with a 400 ms tail and a short-tap cancel.** No clipped last word, and no junk turn from an accidental tap. (D)
11. **Earned sound, tiny and warm.** Open, send, receive, launch, done, needs-you each have a 0.5 to 1.1 s sound. The output is pre-warmed so the first chime is on time. Calls and screen share mute them. (H)
12. **Tell the user honestly what ran and what failed.** "I stopped there." "You're out of agent messages for now." No fake success. (G3)
13. **Spoken lines are 6 to 12 words, tour lines 8 to 16, invites at most 40.** Hard limits sit in the prompt. (G2)
14. **A face that reacts.** A cloud mascot with 12 expressions, blinks, breathing, sleep and pointer-follow. The "^^" happy eyes in `[shot3]` carry warmth in a 54 px avatar. (H, B)
15. **A quiet muted-speaker fallback.** The answer lands on the clipboard with an Unmute button. A user who cannot hear still gets the result. (D)

## Open gaps (need user action or a launch to close)

- Idle and listening notch visuals: need two screenshots from the user, or a lab capture when the Mac is free.
- Notch open and close motion: numbers are compiled constants. A screen recording at 60 fps would give curve and duration.
- VAD numbers (`silence_duration_ms`, `prefix_padding_ms`): need disassembly of the session-config builder or a network trace of the `session.update` event.
- Real screen order of onboarding steps: need a walk-through recording of a fresh install on a clean user account.
- Reviews on Reddit, Product Hunt and Hacker News: the searches returned none. Treat third-party notes (explainx, therundown, aibyaakash, macfolio, hokai) as low-grade and unverified.

## Sources (web)

- https://www.heyclicky.com/ , /features , /trust , /changelog
- https://github.com/prasanthsasikumar/openclicky/issues/10 (mirror of the v1.0.52 release notes)
- https://isaacflath.com/building/how-clicky-works (about the older open-source Clicky; it describes the blue triangle cursor and push-to-talk release)
- https://explainx.ai/blog/heyclicky-voice-control-mac-gpt-realtime-2-demo-2026 (editorial; flagged as speculation on turn detection)
- https://www.therundown.ai/tools/clicky , https://www.aibyaakash.com/p/clicky
- https://x.com/FarzaTV/status/2048203459976188261 (not readable: HTTP 402)
