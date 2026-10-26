# Perry copy audit

Author: research sub-agent. Date: 2026-10-26. Scope: every user-facing string in `App/Onboarding`, `App/Notch`, `App/Home`, `App/Permissions`, `App/Shortcuts`, `App/Settings`, `ProfileExtraction.swift`, plus the failure, approval, guide, voice and finalizer strings those surfaces show (`ExecutionFinalizer`, `IntentCard*`, `FailureNotice`, `AgentActivityStrip`, `TalkSession`, `GuideSessionCoordinator`, `RoutineRunCopy`, `PromptAssembler`).

Method. I read the strings in the Swift files, then read them again in the PNG renders under `/tmp/audit-renders/` and in the four HeyClicky screenshots. Line widths below are measured from those 1x renders. I did not build or run Perry. Strings that only exist in code paths with no render (for example `PerryCaptureError`) are marked "if surfaced".

---

## 1. The verdict in one page

Perry's individual strings are often better than HeyClicky's. Perry's permission helper, its approval card, its "Move Perry to Applications first." state and its empty states are specific and actionable. The copy still reads as slop because **no single narrator owns it**. A user who walks from onboarding to a failure to settings meets five different writers:

| # | Root cause | Evidence (all verified in code and renders) | Source rule |
|---|---|---|---|
| 1 | **Three narrators.** "I" (onboarding, mic errors, guide questions), "Perry" in third person (peek, approvals, failures, routine review body), and bare imperative. Sometimes inside one card. | Routine review: title "Review what **I** learned", body "**Perry** asks for typed text each time it runs" (`notch-rebuild-evidence/routine-review.png`). Mic errors: `TalkSession.swift:740` "**I** didn't hear anything", `:757` "**Perry** couldn't hear that.", `:456` "**Perry** couldn't finish this answer." Guide: `GuideSessionCoordinator.swift:766` "**Perry** won't guide inside it." vs `:934` "**I** couldn't see anything". | HIG Writing: "try not to switch perspectives." |
| 2 | **"I" means two people.** In onboarding "I" is Perry. In Settings and the helper editor "me" and "I" are the user. | `BrainSettingsPage` "Ask **me** before using the cloud" (render `settings-pages/brain.png`) vs `OnboardingBeats.swift:77` "I live in your notch." `PerryEditorView` "Only when **I** ask" (`perry-editor-new.png`). | HIG Writing: possessive pronouns "consistently throughout your app". |
| 3 | **One referent, many names.** The model is "Brain", "model", "agent", "runtime", "engine", "provider" and "On this Mac". A helper is "a Perry", "Perrys", "helper" and "small helper". A unit of work is task, job, request, thread, session, run, goal, conversation. | See the glossary in section 6. `PromptAssembler.swift:198` tells a user to open "Settings › Models". No such tab exists. The tab is "Brain" (`SettingsPage.swift:40`). | HIG Writing: "Create a list of common terms, and reference that list to keep your language consistent." |
| 4 | **Labels that do not say what happens.** | "Allow" opens a drag helper (`OnboardingBeats.swift:176`). "Looks right" saves (`InterviewBeat.swift:344`). "Open Privacy settings" for any pane (`FailureNotice.swift:11`). Peek pill "Review" under "Perry needs your OK" with no object named. | HIG Privacy and Alerts (quoted below). NN/g: explicit label as "just-in-time help". |
| 5 | **Internal vocabulary leaks.** | "Trust tier", "Read-back", "Sandboxed and supervised" (`AgentActivityStrip.swift:128,339,370`). "Cua could not read the target window, so I couldn't paint the path." (`GuideSessionCoordinator.swift:941`). "context estimate" (`ModelTypes.swift:176`). "agent runner" is spoken aloud (`ForegroundTaskController.swift:397`). A notification titled "Perry task (completed)" prints a raw enum (`ExecutionFinalizer.swift:123`). | Basecamp: "Don't sound like an engineer talking to another engineer." |
| 5b | **Robotic recovery copy.** | "Safe next step: review what changed, then retry the goal." and "the stopped action's effect is uncertain" (`ExecutionFinalizer.swift:138-148`). | HIG Writing: avoid "robotic error messages". MS WAC: "Don't blame users", "ideally what to do". |
| 6 | **Cute or vague where precision is needed.** | "How should I think?", "Want me to reach into your apps?", "A head start on your day", "Sharper answers" (an unmeasured comparative), "needs real attention" (`IntentCardWindow.swift:130`), "Task storage needs attention" (`BackgroundTasksView.swift:54`). | HIG Writing: "avoid the temptation to be too cute or clever with your labels." Mailchimp: "it's always more important to be clear than entertaining." |
| 7 | **Mechanical inconsistency.** Straight and curly apostrophes, "could not" next to "couldn't", three path separators (`›`, `→`, `>`), "Set up" vs "Connect" for one action, period or no period on row descriptions, Title Case next to sentence case (`What's New` beside `What's new in Perry`). | Section 5. | HIG Writing: "Adopt capitalization rules... apply them consistently." |
| 8 | **A false privacy claim risk.** Onboarding says the microphone "Hears you only while you hold the shortcut" (`OnboardingBeats.swift:145`). Settings also offers a wake word and a mic tap-to-talk. | `ShortcutsSettingsPage.swift:15`, `InterviewBeat.swift:271`. Verify with the owner before keeping the word "only". | Prose skill: no promises the source does not state. |

The fix is mostly editorial, not visual: pick one narrator, one glossary, one button grammar, and enforce it with a test (section 7).

---

## 2. Sources and the passages I rely on

Opened and quoted. Apple HIG pages came from Apple's own JSON (`https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`), so those quotes are verbatim. Microsoft pages came back as raw markdown. NN/g, Mailchimp, Basecamp, Zach Holman and the Apple Style Guide came through a page summarizer, so their quotes are short and may be trimmed.

**[HIG-W] Apple HIG, Writing.** https://developer.apple.com/design/human-interface-guidelines/writing
- "Create a list of common terms, and reference that list to keep your language consistent."
- "Active voice and clear labels help people navigate through your app... When labeling buttons and links, it's almost always best to use a verb. Prioritize clarity and avoid the temptation to be too cute or clever with your labels. For example, just saying 'Send' often works better than 'Let's do it!'"
- "Possessive pronouns like my and your are often unnecessary... If you do use possessive pronouns, use them consistently throughout your app, and try not to switch perspectives. Avoid using we altogether because it may be unclear who the 'we' in question refers to... Something like 'Unable to load content' is much clearer."
- "Begin with language like 'Get Started' to indicate you're starting a flow... use terms like 'Continue' or 'Next,' but be consistent with what you choose. Make it clear when a flow is complete by using language like 'Done.'"
- "Choose a style for each UI element type and use it consistently throughout your app."
- Errors: "display it as close to the problem as possible, avoid blame, and be clear about what someone can do to fix it. For example, 'That password is too short' isn't as helpful as 'Choose a password with at least 8 characters.' ... Interjections like 'oops!' or 'uh-oh' are typically unnecessary and can sound insincere."
- Settings: "Describe what it does when turned on, and people can infer the opposite... If you need to direct someone to a setting, provide a direct link or button, rather than trying to describe its location."
- Empty states: "guide people on actions they can take, and give them a button or link to do so if possible."
- Fields: "Avoid robotic error messages with no helpful information, like 'Invalid name.'"

**[HIG-A] Apple HIG, Alerts.** https://developer.apple.com/design/human-interface-guidelines/alerts
- "Avoid writing a title that doesn't convey useful information, like 'Error'... but also avoid overly long titles that wrap to more than two lines."
- "Avoid explaining alert buttons. If your alert text and button titles are clear, you don't need to explain what the buttons do."
- "Aim for a one- or two-word title that describes the result of selecting the button. Prefer verbs and verb phrases that relate directly to the alert text... Always use 'Cancel' to title a button that cancels the alert's action."
- "A specific button title like 'Erase,' 'Convert,' 'Clear,' or 'Delete' helps people understand the action they're taking."

**[HIG-P] Apple HIG, Privacy.** https://developer.apple.com/design/human-interface-guidelines/privacy
- Purpose strings: "Aim for a brief, complete sentence that's straightforward, specific, and easy to understand. Use sentence case, avoid passive voice." The table rates "The app records during the night to detect snoring sounds." as good, "Microphone access is needed for a better experience." as "vague, undefined justification", and "Turn on microphone access." as "An imperative sentence that doesn't provide any justification."
- "Another type of manipulation is using a term like 'Allow' to title the custom screen's button... Use a term like 'Continue' or 'Next' to title the single button in your custom screen or window, clarifying that its action is to open the system alert."

**[HIG-O] Apple HIG, Onboarding.** https://developer.apple.com/design/human-interface-guidelines/onboarding
- "design a flow that's fast, fun, and optional."
- "Postpone nonessential setup flows or customization steps. Provide reasonable default settings so most people can immediately start interacting."

**[HIG-B] Apple HIG, Buttons and Menus.** https://developer.apple.com/design/human-interface-guidelines/buttons and `/menus`
- "Append a trailing ellipsis to the title when a push button opens another window, view, or app." and (menus) "The ellipsis character (…) signals that people need to input information or make additional choices, typically within another view."

**[ASG] Apple Style Guide.** https://support.apple.com/guide/applestyleguide/w-apsg48ccd3b3/web and `/e-apsg076a7313/web`
- "we": "Don't use first person; rewrite in terms of the reader or the product."
- ellipsis: "Use the ellipsis character (Option-Semicolon)..." and "If the name of a menu item or button ends with an ellipsis, don't include the ellipsis in running text."

**[MS-10] Microsoft Writing Style Guide, top 10 tips.** https://learn.microsoft.com/en-us/style-guide/top-10-tips-style-voice
- "Write like you speak. Read your text aloud." Example: replace "Invalid ID" with "You need an ID that looks like this: someone@example.com".
- "Use contractions like it's, you'll, you're, we're, and let's."
- "Lead with what's most important... Make customer choices and next steps obvious."
- "Default to sentence-style capitalization." "Don't use a period or a colon at the end of titles, headings, subheadings, and UI titles."
- "Most of the time, start each statement with a verb... Avoid weak phrasing like there is, there are."

**[MS-WAC] Microsoft, Windows Admin Center UI text guide.** https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/extend/guides/ui-text-style-guide (it says it builds on the Microsoft Writing Style Guide)
- Buttons: "Buttons should be one word whenever possible... Two or three is OK but try to avoid longer." "Instead of a generic 'Submit' button, use a verb corresponding to the user action."
- Errors: "Keep it brief and explain concisely what the problem is or **ideally what to do**." "Make sure that the heading relates directly to the button in case the reader ignores the body text." "Avoid using 'There was a problem' in headings." "Don't blame users for the error." Buttons: "If that's not possible, use 'Close' for the dismissal button text (instead of 'Okay' or 'Done')."
- Status: "Failure: Start with 'Couldn't' and end with what the software couldn't do."
- Null state: "Avoid 'It's lonely in here.'... questions put extra burden/pressure on the customer."
- First run: "Avoid marketing style and language." "Don't present tips if the customer doesn't need them."

**[NNg-ERR] NN/g, Error-Message Guidelines.** https://www.nngroup.com/articles/error-message-guidelines/ "Display the error message close to the error's source." "Avoid technical jargon and use language familiar to your users instead." "Concisely and precisely describe the issue." "Take a positive tone and don't blame the user." "Merely stating the problem is also not enough; offer some potential remedies."

**[NNg-UI] NN/g, UI Copy (command names).** https://www.nngroup.com/articles/ui-copy/ "Use just enough text to accurately describe the command and include no more than 2-4 words." "Lead with verbs or verb phrases that clearly outline what will happen after the command is selected." "Avoid using the generic phrase OK for button labels in confirmation dialogs." This article is about commands and menus. I apply it to buttons by analogy.

**[NNg-OK] NN/g, OK-Cancel or Cancel-OK.** https://www.nngroup.com/articles/ok-cancel-or-cancel-ok/ "It's often better to name a button to explain what it does." "An explicit label serves as just-in-time help, giving users more confidence in selecting the correct action."

**[NNg-ONB] NN/g, Mobile app onboarding.** https://www.nngroup.com/articles/mobile-app-onboarding/ "instructional onboarding should be brief, optional." "Explain why you want that data and how it will be used." "Avoid feature-promotion onboarding at first launch."

**[MC-VT] Mailchimp Content Style Guide, Voice and tone.** https://styleguide.mailchimp.com/voice-and-tone/ "You have the same voice all the time, but your tone changes." "it's always more important to be clear than entertaining." "forced humor can be worse than none at all." "If you're unsure, keep a straight face."

**[MC-WE] Mailchimp, Web elements.** https://styleguide.mailchimp.com/web-elements/ "Button copy should always include verbs." Sentence case for buttons. "Don't say things like 'Click here!'"

**[BC] Basecamp, Getting Real, "Copywriting is Interface Design".** https://basecamp.com/gettingreal/09.7-copywriting-is-interface-design "Copywriting is interface design. Great interfaces are written." "Good writing is good design." "Don't sound like an engineer talking to another engineer."

**[ZH] Zach Holman, The Apple voice** (third-party essay, not Apple). https://zachholman.com/posts/the-apple-voice/ "The Apple Voice is characterized by short, declarative sentences." He also notes "Smugness is always a gamble."

**[PROSE-IC] and [PROSE-TELL]** are the local `prose` skill references (`references/interface-copy.md`, `references/tell-catalog.md`). Used rules: verb-first buttons, one vocabulary per flow, on-state toggle labels, "System messages carry no exclamation marks and no cute interjections", "A confirmation names the object", "Name the actor; you beats people", negative parallelism, rule of three, synonym cycling.

**Sources I could not use.** Linear and Stripe publish no UI copy guide that I could find (searches returned design-philosophy essays and job postings only). I will not cite them for copy rules. Material 3 content-design pages and NN/g "microcopy" returned 404. Mailchimp's error-message and button pages 404. Microsoft's brand-voice page 404 (the welcome page and top-10 page opened and state the voice as "warm and relaxed, crisp and clear, and ready to lend a hand").

**One conflict to know about.** The local `prose` skill's STE layer bans contractions in assistant prose. Product UI is not assistant prose. [PROSE-IC] says to "match the product's... established voice", Perry's code already uses contractions heavily, and [MS-10] says to use them. Perry also speaks aloud (TTS). The voice spec in section 6 therefore uses contractions and bans the stiff forms ("could not", "cannot", "will not") in Perry's own voice.

---

## 3. HeyClicky's copy, what to copy and where it is weaker

Strings read from the four screenshots:
- Permission screen: "I need accessibility permissions." / "Drag me into the Accessibility list." / button "Open". Three progress pills above.
- Helper over System Settings: "I'm HeyClicky — drag me into the list above."
- Notch home: rows "Research Buddy / Digs into companies, markets, and competitors and…", "Shippy / Builds and ships websites and small web projects ri…", chips "Apps +", "Invite & Earn", pill "Update app".
- Settings: "Integrations" / "Apps your agents can reach into." / "Search integrations" / "Add custom connector" / "AVAILABLE INTEGRATIONS" / per-app "Connect". Sidebar: Account, General, Invite & Earn, Voice, Microphone, Dictation, Shortcuts, Cursor, Agents.

**What it does well (copy these habits).**
1. **One narrator.** Every sentence is first person from the app: "I need", "drag me", "I'm HeyClicky". There is no third-person "HeyClicky needs..." anywhere in four screens. This is the biggest gap with Perry.
2. **One instruction per screen.** "Drag me into the Accessibility list." is one imperative with one object. Perry's helper is nearly as good ("Drag Perry into the list above.") but adds a second sentence that wraps badly (see R-P1).
3. **Names the system's own label.** "the Accessibility list" matches what the user will see.
4. **Very short.** Titles are 4 to 7 words. A single-word button: "Open", "Connect".

**Where it is weaker (do not copy).**
1. **No reason.** "I need accessibility permissions." states a need and no purpose. [HIG-P] rates a bare need as weak. Perry's rows ("Reads buttons, menus and fields") are closer to a purpose, and can be better (R-O6).
2. **Jargon as the headline.** "accessibility permissions" is the OS term, not the user's goal.
3. **Bare "Open".** Open what? Perry's "Open Settings" is better, and the helper in section 4 can be better still.
4. **Em dash** in the helper line. The local rules ban it, and it adds nothing a colon or period would not.
5. **Feature-dump descriptions.** Notion row: "Search Notion pages and databases, read content, then create, update, comment on, organize, or attach uploaded files to pages, blocks, and rows." That is 24 words and six verbs, a rule-of-three list that [PROSE-TELL] flags. It gives the user no decision to make. Perry's "Read your pages and databases." is the right shape.
6. **Truncated persona blurbs** ("competitors and…", "projects ri…") and cute names ("Shippy", "Research Buddy"). [MC-VT] says forced humor costs clarity.
7. **Cute growth chips** ("Invite & Earn") in the primary peek. Not a copy-quality model.

Takeaway. HeyClicky is not better writing. It is more consistent writing. Perry can win by being consistent and more specific.

---

## 4. Audit tables

Severity: **H** misleads or hides recovery. **M** breaks terms, person, tone or capitalization. **L** isolated polish.
Rule tags refer to section 2. "Width" figures are measured from the render PNGs.

### 4.1 Onboarding, beat by beat

Beat order in code: hello, brain, access, shortcuts, interview (consent, 3 questions, review), apps, first goal, closing.

#### Beat 1: Hello (`OnboardingBeats.swift:67-116`, art `HelloGreetingView.swift`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-O1 | `OnboardingBeats.swift:77` | "Hi, I'm Perry. I live in your notch.\nWhat should I call you?" | "hello." is already drawn as 40 pt handwriting above it, so "Hi," says hello twice. Hard `\n` is fine at this width but breaks in localization. L. [MS-10] "Be brief". | "I'm Perry. I live in your notch. What should I call you?" (no manual break; keep the 340 pt max width) |
| R-O2 | `HelloGreetingView.swift:210` | a11y label "hello." | Lowercase plus period read aloud by VoiceOver as "hello period". L. | "Hello" |
| R-O3 | `OnboardingBeats.swift:101` | "Continue" | Correct per [HIG-W]. Keep. | keep |

#### Beat 2: Brain (`OnboardingBeats.swift:223-303`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-O4 | `:223` | "How should I think?" | Cute (M). The concept is "which model". Settings calls it "Brain" and "Conversation model", the prompt calls it "brain" and "Models". [HIG-W] terms list. Also "think" invites a reply the buttons cannot give. | "Which model should I use?" (echoes the guide question "Which version should I use?") |
| R-O5 | `:262-264` | ChatGPT card: "Sharper answers. Uses your ChatGPT account." Local card: "Private and offline. Nothing leaves this Mac." | "Sharper" is an unmeasured comparative (M). Settings says the same choice "Sees your screen and acts. Uses your ChatGPT plan." (`CloudBrainList.swift:44`), so "account" vs "plan" and two different descriptions of one thing. Not parallel: first card sells, second states facts. [BC], [MC-VT]. | ChatGPT: "Needs internet. Uses your ChatGPT plan." Local: "Works offline. Nothing leaves this Mac." Use the same two strings in Settings (one source of truth). Claude Code and API key rows: "Needs internet. Uses your Claude plan." and "Needs internet. Your provider bills you." |
| R-O5b | `:229` | card title "On this Mac" | Meaning is fine in context but the same phrase is also the composer chip (render `workspace.png`) where it reads as a location, not a model. M. | Card title "This Mac" is shorter but the chip needs the model name, for example "Qwen 9B". Pick the model's name, not the location. |
| R-O6 | `:300` | "Open Settings" (non-ChatGPT cloud rows) | Ambiguous: Perry Settings or System Settings. It also exits onboarding. H. [NNg-OK]. | "Set up in Settings" if it must leave. Better: keep the user in the beat and use "Skip" only. |
| R-O7 | `:230` | status "Set up later in Settings" | Fine. Keep. It tells where and when. | keep |
| R-O8 | `:276` | "Waiting for sign-in…" | The ellipsis here is a progress state, fine per [MS-WAC]. But the button is disabled and has no verb of its own. L. | "Signing in…" is a gerund the STE spec avoids. Keep. |
| R-O9 | `:248,250` | "Cancel" and "Skip" | OK. Rule: "Skip" for optional steps, "Cancel" for undoing an action in progress. Already followed. | keep |

#### Beat 3: Access (`OnboardingBeats.swift:133-181`, `OnboardingParts.swift:167`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-O10 | `:137` | "I need to see what you see." | The headline promises screen vision but the two rows are Accessibility and Microphone. Screen Recording is asked later (`FirstGoalBeat.swift:143` path). It sounds invasive (M) and overpromises. [HIG-P] "specific". HeyClicky states the need plainly. | "I need two permissions." |
| R-O11 | `:143` | Accessibility: "Reads buttons, menus and fields" | Fragment, no subject, no purpose. [HIG-P]: need a "how and why" sentence. Row title "Accessibility" does not match the pane name the helper later shows on macOS 27 ("Device Control and Data Access"), so users hunt for the wrong name. M. | Title from `PrivacyPane.displayName()` so it matches the system. Detail: "So I can read buttons, menus and fields, and click for you." |
| R-O12 | `:145` | Microphone: "Hears you only while you hold the shortcut" | "only" may be false: wake word (`ShortcutsSettingsPage.swift:15`) and mic tap (`InterviewBeat.swift:271`). Privacy claim. H until verified. | "So I can hear you when you talk to me." Add "only" back only if code confirms it. |
| R-O13 | `:176` | "Allow" | [HIG-P] names "Allow" as a manipulative label on a custom screen's button. It also does not grant anything. It opens Perry's drag helper. H. | "Turn on" (matches `PrivacySettingsPage.swift:105` and `ShortcutCheck.swift:68`) |
| R-O14 | `OnboardingParts.swift:167` | "Allowed" | Past-tense state for a toggle. Settings says "permission granted" in a11y. M. | "On" |
| R-O15 | `:158` | "Not now, I'll type" | Good. It states the consequence. Keep. | keep |

#### Beat 4: Shortcut (`OnboardingBeats.swift:350-393`, `ShortcutCheck.swift`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-O16 | `:360` | title "Hold ⌃⌥ and say hi." / body "Click the key to change it." | Good: imperative, concrete, tests the real gesture. "the key" is a keycap pill, fine. Minor: "say hi" is the only joke in the flow and it earns its place. | keep |
| R-O17 | `ShortcutCheck.swift:46,49` | "Make sure it works in other apps." / "Try it" | "Make sure" hedges. States a task, not a fact. Button label is fine. L. | "Check that it works in other apps." / "Try it" |
| R-O18 | `ShortcutCheck.swift:57` | "Heard it. ⌃⌥ works everywhere." | "everywhere" is an overclaim (secure input fields block it). M. | "Heard it. ⌃⌥ works in other apps." |
| R-O19 | `ShortcutCheck.swift:64` | "I can only hear that key inside Perry. Turn on Input Monitoring." | A key is pressed, not heard. Pane name needs the system name. M. | "I can't see that key outside Perry. Turn on Input Monitoring." |
| R-O20 | `:375,379` + `GeneralSettingsPage.swift:28` | "Open at login" / help "Open Perry when you log in to this Mac" / Settings "Open Perry when you log in" | Same setting, three phrasings. M. [HIG-W] terms list. macOS itself says "Open at Login". | "Open at login" in all three. Drop the tooltip. |

#### Beat 5: Interview (`InterviewBeat.swift`, `ProfileExtraction.swift`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-O21 | `InterviewBeat.swift:217-218` | "Tell me about you." / "Three quick questions. I keep short notes on this Mac so I can help your way, and you can delete them any time. I send these notes with your questions to ChatGPT." | 33 words under a title. In the render the body wraps at 58 characters per line and strands "I" at the end of line 1 and line 2 ("...so I / ...any time. I / send these notes..."). Privacy facts are buried. "quick", "your way" are filler. [HIG-W] "Check each word to be sure it needs to be there." H for the buried disclosure. | Body: "Three questions. I keep notes on this Mac, and you can delete them any time." Second paragraph only when a cloud model is set: "I send them to ChatGPT with your questions." (same facts, no new claim) |
| R-O22 | `:228,233` | "Start" / "Skip" | OK. "Start" begins the flow per [HIG-W]. | keep |
| R-O23 | `ProfileExtraction.swift:16` | Q1 "What do you do?" | Ambiguous: job, hobby, right now? Chips (Student, Designer...) assume job. M. | "What's your work?" |
| R-O24 | `ProfileExtraction.swift:17` | Q2 "Which apps do you use most?" | Good. Keep. | keep |
| R-O25 | `ProfileExtraction.swift:18` | Q3 "What's something you've been wanting to learn lately?" | 11 words. Wraps to two lines (render `interview-4-goal.png`, "learn lately?" alone on line 2). "something", "lately", "been wanting" are filler. The first-goal beat then asks "What do you want to learn first?" which uses another phrasing of the same question. M. | "What do you want to learn next?" (and first-goal: "What do you want to learn first?" stays; the two now read as one family) |
| R-O26 | `:265` | placeholder "Type or tap the mic" | Good. "Listening…" while recording is also fine. | keep |
| R-O27 | `:285` | a11y "Answer by voice" / "Stop listening" | Fine. | keep |
| R-O28 | reaction line, `ProfileExtraction.swift:47-52` and render `interview-3-apps-with-reaction.png` | Prompt: "React in at most 12 words. Name one specific thing they said." Render shows "Teaching chemistry, so labs fill your week." under the Q2 title. | Two problems. (a) The line comments on the previous answer but sits under the next question, so it reads as an answer to Q2. (b) "so labs fill your week" is an inference the user never said. It is the "speculative gap-fill" pattern in [PROSE-TELL] and it breaks trust. Also prompt says 12 words, `trimReaction` accepts 14. M. | Prompt: "Repeat one thing they said in at most 8 words. Do not add facts. No question, no emoji, no exclamation mark." Render example: "Chemistry teacher." Keep the line to one clause. |
| R-O29 | `:251` | "Next" | Onboarding uses "Continue" in five beats and "Next" in the interview. [HIG-W]: pick one. L. | "Continue" |
| R-O30 | `:322` | title "Here's what I got." / body "Not saved yet." | "got" is slang for "understood". "Not saved yet." is the most important fact and the weakest sentence. M. | Title: "Here's what I'll remember." Body: "I haven't saved this yet." |
| R-O31 | `:344,349` | "Looks right" / "Don't save" | "Looks right" is a statement, not a verb, and does not say it saves. [HIG-W], [NNg-UI]. H for label clarity. "Don't save" is correct. | "Save" / "Don't save" (the HIG pair) |
| R-O32 | `:342` | "Edit" / "Done" | OK. | keep |
| R-O33 | `:326-332` | row labels "Name / Work / Apps / Learning" | "Learning" is a noun where the field is "Learning goal" (`InterviewBeat.swift:118`) and Q3 asks "learn". M. | "Learning goal" |
| R-O34 | `:365` | empty value "—" | VoiceOver reads "em dash". L. | "Skipped" in tertiary text |

#### Beat 6: Apps (`AppsBeat.swift`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-O35 | `:51-52` | "Want me to reach into your apps?" / "Read-only to start. I ask before I change anything." | A yes/no question over a list of Connect buttons. "reach into" is invasive. [BC], [HIG-W]. Second line is good, keep it. M. | Title "Connect your apps". Body unchanged. |
| R-O36 | `:13-22` | "Read your pages and databases." "Read your channels and messages." "Read your issues and projects." "Read your notifications." "Read files you open with Perry." "Read the events on this Mac." | Consistent imperative, concise, honest. But Settings describes the same apps as noun phrases without periods ("Pages, databases, and workspace search", `settings-pages/apps.png`). Same app, two grammars. M. | Keep these. Reuse the same strings in Settings. |
| R-O37 | `:76,81` | "Continue" and "Skip" both call `director.skip()` when nothing is connected | Two buttons with different labels do the same thing. [HIG-W] one verb per action. M. | One button. "Skip" until something is connected, then "Continue". |
| R-O38 | `:111` | "Connect" | Good. But Settings shows "Connect" for Calendar and "Set up" for all other apps (`settings-pages/apps.png`). | See S-A1. |
| R-O39 | `:117,121` | "Opening sign-in…" / "Turn on Calendar for Perry in System Settings." | Second is good (what and where). First is fine. A failed connect shows `error.localizedDescription` raw (`:127`). H if the raw text reaches the user. | Map errors to "Couldn't connect to Notion. Try again." (MS-WAC failure form) |

#### Beat 7: First goal and close (`FirstGoalBeat.swift`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-O40 | `:84` | "What do you want to learn first?" / "Let's start with Figma auto layout." | "Let's" is a "we" [HIG-W]. L. | "I'll start with Figma auto layout." |
| R-O41 | `:49-51` | "I'll open Figma and walk you through it, one step at a time." / "I'll give you a short plan and one question to start." / "I'll get it started. I ask before I change anything." | First two are good. Third mixes future and present and "it" has no referent. "start" appears in the title too. M. | Third: "I'll start on it and ask before I change anything." Second: "I'll give you a short plan and one question." |
| R-O42 | `:91` | placeholder "Figma auto layout, Spanish, a pitch deck…" | Trailing ellipsis reads as truncated. "pitch deck" is a make-task, not a learn-task. [HIG-W] hint text. L. | "Figma auto layout, Spanish, SQL" |
| R-O43 | `:107,110,116` | "Something else" / "Start" / "Not now" | "Not now" ends onboarding without saying so. Acceptable. | keep |
| R-O44 | `:71` | "I'm up here whenever you need me." | Warm, specific (tells where Perry lives), costs nothing. This is the best line in onboarding. | keep |

### 4.2 Notch: eyes, peek, listening (`App/Notch`, `NotchPeekView.swift`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-N1 | `NotchPeekView.swift:33,38` | row title "Perry needs your OK", status "Open it to continue", pill "Review" | Does not name the object (H). Three phrases for one state across the app: "Needs your OK" (tier, `IntentCardWindow.swift:234`), "Approval needed" (`AgentActivityStrip.swift:136`), "Awaiting approval" (`:548`). Status and pill use two verbs ("Open", "Review"). Third-person "Perry" in a surface where Perry is the notch. Rows must fit 38 characters (title) and 46 (status) before truncation. [NNg-OK], [HIG-W]. | Title: the card's action, for example "Move two files into Archive". Status: "Needs your OK". Pill: "Review". If the entry has no title, use title "Needs your OK" and status "Open to review". |
| R-N2 | `:34,35` | "A guide is waiting for you" / "A routine is waiting for you" | Passive, 26 characters, no state. M. | "Guide paused" / "Routine paused", status "Open to continue" (if those are the states; confirm in `NotchPresentation`) |
| R-N3 | `:32` | "Perry is listening" | Third person; while the notch itself shows eyes. L. | "Listening" |
| R-N4 | `:20` | setup row "Finish setting up" / "Pick up where you left off" | Title and status say the same thing. L. | "Finish setup" / "2 of 7 steps left" if the count is available, else drop the status |
| R-N5 | `:41` | status "Working in the background" | Fine. | keep |
| R-N6 | `:50,51` | "Working…" / "No answer yet" | Fine. | keep |
| R-N7 | `:92,100,104` | composer "Ask Perry…" ; chips "Apps", "History" | Placeholder uses "…" which elsewhere means "needs more input" or "in progress". The same composer reads "Ask Perry anything" in the workspace (`WorkspaceComponents.swift:29`) and "Ask a follow-up" in a conversation. "Apps" does not say it opens Settings (a11y hint says "Open connected apps settings"). M. [HIG-B] ellipsis rule. | Placeholder "Ask Perry anything" in both. Chip "Connect apps". |
| R-N8 | `:219` | empty peek "Hold ⌃⌥ to talk, or type below." | Specific, imperative, 31 characters. Good. | keep |
| R-N9 | `:106` | help "Open the workspace" | "workspace" has three meanings (window, task folder, Privacy "Workspace folder"). M. | "Open Perry" |
| R-N10 | `NotchListeningView.swift:108-112` | "Getting the microphone…", "Listening…", "Thinking…", "Speaking…", "Voice failed." | The first four are fine. "Voice failed." is the "Error" pattern [HIG-A]: no cause, no step. H. | Use the specific error: "I couldn't hear that. Try again." and a "Try again" button (already at `:56`) |
| R-N11 | `:118` | "Pause when you're done." | Good. | keep |
| R-N12 | `:47-50` | help "Send now (Return)" / label "Cancel (Esc)" | Key hints in the label are fine as tooltips. The a11y label should not include "(Esc)". L. | label "Cancel" |
| R-N13 | `CompactConversationView.swift:137` | back label "Workspace" on every notch state | Appears on listening, approval, guide, error. It names a place the user never saw named. M. | "Back" |

### 4.3 Conversation and workspace home (`App/Home`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-H1 | `NotchWorkspaceView.swift:181,193,202,212` | section "Perrys", "New Perry", help "Make a Perry: a named helper with its own job, schedule, and memory", empty row "Make a helper"; editor `PerryEditorView.swift:38,89` "Job", "What should this Perry do?", "Create Perry" | "Perrys" is not a word. The product, the character and a helper instance share one name. Help text needs 14 words to define it. H for terms. | One noun: "helpers". Section "Helpers", empty row "New helper", editor title "New helper", field "What should this helper do?", button "Create helper". (Owner decision. See section 6.) |
| R-H2 | `HomeConversationView.swift:53-56` | "This task was interrupted. Review any changes in the affected app before continuing. Perry will not repeat the task automatically." / button "I've reviewed the changes" | 3 sentences, third person, "affected app", button is 4 words and a first-person claim. M. [MS-WAC] 1 to 3 words. | "I stopped before finishing. Check the app for changes before you continue. I won't repeat the task on my own." Button: "Mark as reviewed" |
| R-H3 | `:140-152,159-161` | "Saved requests" / "These requests haven't started. Review one in the composer when you're ready." / "Use in composer" / "Discard" / dialog "Discard this saved request?" / "Discard request" | "request" vs "message" (`HomeView.swift:439` "Requests not saved"); "composer" is jargon. M. | "Saved messages" / "I haven't sent these. Restore one when you're ready." / "Restore" / "Discard" / dialog "Discard this message?" / "Discard message" |
| R-H4 | `HomeView.swift:439-441` | "Requests not saved" / "Keep Perry open or copy your text. Saving again won't send it." | Good recovery copy. Term only. | "Messages not saved" |
| R-H5 | `HomeConversationView.swift:89` | "Working on it" / "Stopping…" | Good. | keep |
| R-H6 | `:176,191,193` | "\(model) selected" / "You can change this choice in model settings." / "Connect your ChatGPT account" / "Use your existing account to talk with Perry. You can switch models any time." | "selected" is passive. Two "model" phrases in one box. M. | "Using Claude Code" / "Change it in Settings." / "Connect ChatGPT" / "Sign in with your ChatGPT account. You can switch models any time." |
| R-H7 | `:207,229-232` | button "Other models"; chip label "Connect ChatGPT" for Model; help "Model" | The Model chip's label becomes an action when signed out, a11y says "Model: Connect ChatGPT". M. | Chip always shows the model name or "Choose model" |
| R-H8 | `NotchWorkspaceView.swift:471-473` | chip "Window" / help "Choose which window Perry can inspect" | Label names a noun, not an action or state. "inspect" is jargon (elsewhere "see"). M. | Chip "Choose window" until set, then the window name. Help: "Choose which window Perry can see." |
| R-H9 | `:631-632` | help "Ask, guide, or do" / modes "Ask", "Guide", "Do", "Do in background" | Help repeats the labels. "Do" vs suggestions "Do it" (`HomeView.swift:77`). L. | Help: "Choose whether I answer, guide you, or act." |
| R-H10 | `:171` | "No matches" | [PROSE-IC]: a search empty state names the query. L. | "No matches for “{query}”" |
| R-H11 | `:502,510,516,526,535` | "Pick a thread", "History unavailable", "Background tasks unavailable", "Settings unavailable", "Perrys unavailable" | Dead ends with no cause or step. "thread" is a term nobody else uses. L (rare states). | "Pick a conversation" and "Couldn't load History. Reopen Perry." |
| R-H12 | `:134-138` vs `StatusMenuController.swift:25,38` | sidebar "Tasks" vs menu bar "Background tasks (N)" | One thing, two names. M. | "Tasks" in both |
| R-H13 | `StatusMenuController.swift:37` | "Ask or do something…" | "something" is filler and the "…" claims more input. M. | "Ask Perry…" |
| R-H14 | `NotchWorkspaceView.swift:415-421` | greeting "Evening, Hridya." | Warm and short. Keep. Period on a heading breaks [MS-10] but is a deliberate display line. | keep |
| R-H15 | `HomeView.swift:21-23` | "A head start on your day" / "Each morning Perry reads recent activity in your connected apps and suggests a few useful tasks. It never watches your screen." | Cute title, no noun. "useful" is filler. "It never watches your screen" is a negation reassurance [PROSE-TELL] and "It" is ambiguous. Toggle has no on-state label. M. | Title "Morning suggestions". Body "Each morning Perry reads recent activity in your connected apps and suggests tasks. It doesn't read your screen." |
| R-H16 | `:46,336` | "Nothing yet today" / "No files yet" + "Files Perry makes for you show up here. Drag one into any app." | Both are good: orient, explain how content arrives, one action. Keep. [HIG-W] empty states. | keep |
| R-H17 | `:147-149`, `HistoryView.swift:40` | "Teach Perry a routine" / "Show Perry once. You check every step before it's saved." / "Record a routine"; "Ask Perry something" | The routine empty state is the model: specific, explains the trust step. "Ask Perry something" is the vague one. | History button: "Ask Perry" |
| R-H18 | `BackgroundTasksView.swift:21-23` | "Nothing in the background" / "Long jobs you hand to Perry keep running here while you work." / "Give Perry a job" | "job" and "hand to" cost a term. M. | "No tasks running" / "Tasks you start run here while you work." / "Start a task" |
| R-H19 | `:54-57` | "Task storage needs attention" / "Resolve the storage issue shown below, then reopen Perry. Keep the task files for recovery." | "needs attention" says nothing [HIG-A]. "storage issue shown below" points. H. | "Couldn't read saved tasks" / "Reopen Perry. Don't delete the task files." plus the specific cause on its own line |
| R-H20 | `HistoryView.swift:94` | "Removes the selected sessions from history and deletes their stored transcripts from this Mac. This cannot be undone." | "sessions" is a stray term. "Removes... deletes" are two verbs for one act. "cannot". M. | Dialog "Delete 3 items?" body "I'll delete them and their transcripts from this Mac. This can't be undone." Button "Delete 3 items" |
| R-H21 | `HistoryView.swift:207` vs `AgentActivityStrip.swift:187` | "Check needed" vs "Needs checking" | Synonyms for one state. L. | "Needs checking" |
| R-H22 | `WhatsNewView.swift:9-11,19` | "What's New" (top bar) next to "What's new in Perry" (heading); "A companion by your cursor / It listens, points and works beside you in any app."; "Connect any MCP server in Settings → Apps." | Title Case beside sentence case in one screen. "companion" is brand fluff. "MCP" undefined. "→" is the second path separator. M. | "What's new" in both places. "Works next to your cursor" / "I listen, point and work beside you in any app." / "Connect any MCP server in Settings > Apps." (one separator, see section 5) |
| R-H23 | `PerryEditorView.swift:50,84` | "Open this Perry and ask it anything. It keeps its own conversation and memory." / "Its schedule and memory are removed. Its past conversation stays in History." | Clear. Only the noun changes (R-H1). | follow R-H1 |

### 4.4 Approvals and task strip (`IntentCard*`, `AgentActivityStrip`, `SystemNotifier`, `BackgroundTasksView`)

Card width in the render fits about 50 characters per body line.

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-A1 | `IntentCardPresenter.swift:57,73` | title "About to \(actionSummary)" | Reads like a log line. [MS-WAC] confirmations: "define the possible outcomes as a question or a statement about what will happen next". | "Move two files into Archive?" |
| R-A2 | `IntentCardWindow.swift:159,226` + `SystemNotifier.swift:32-33` + `BackgroundTasksView.swift:207` | decline: "Don't allow" (card), "Deny" (notification and task row), approve: "Approve" (fallback), "Run" (plan card), action phrase (`approveLabel`) | Four words for approve, three for decline. M. [HIG-A], [NNg-OK]. Also `approveLabel: request.actionSummary` can be a full sentence, over the 1 to 2 word target. | Pair the action: "Move files" / "Don't move". If no verb: "Approve" / "Deny" everywhere. Retire "Don't allow". |
| R-A3 | `IntentCardWindow.swift:232-235` | tiers "Read only", "Small change", "Needs your OK", "High stakes" | Not parallel: three describe the action, one describes the user's job. "Needs your OK" repeats the card's whole purpose. M. | "Reads only", "Small change", "Changes your files" (state the noun), "Can't be undone" (the red tier is about reversibility, which the card already shows) |
| R-A4 | `:95` | row label "Target" | Developer word. The value is the files. M. | Name the thing: "Files", "Folder", "Window", chosen per action type |
| R-A5 | `:99-100` | "Reversible: Yes" / "No. This cannot be undone." | Fine. "cannot" vs "can't" elsewhere. L. | "Can I undo it? Yes" is cute. Keep as is, change to "can't" |
| R-A6 | `:130` | "This one needs real attention. Type "\(phrase)" exactly; I won't take a voice yes for this." | "real attention" is filler. Semicolon splice. Straight quotes around the phrase. "I" in a card whose title is third-person. M. | "Type “\(phrase)” to confirm. Voice can't approve this." |
| R-A7 | `:136` | placeholder "Type it here to confirm" | "it" repeats the instruction above. L. | "Type the phrase" |
| R-A8 | `:147,150` | "Edit" / "Replay" with a11y "Re-observe the targets and show the preview again" | "Replay" does not say what is replayed. a11y hint is the real label. M. | "Edit goal" / "Preview again" |
| R-A9 | `AgentActivityStrip.swift:68-69,119-120,128` | "Starting safely" / "Preparing your request" / "You have 5 seconds to stop" / "Sandboxed and supervised" | "safely" is an unprovable adverb. "Sandboxed" is a jargon claim. The 5-second line is the useful one. M. [BC]. | Title "Starting" / "You have 5 seconds to stop" ; drop "Sandboxed and supervised" |
| R-A10 | `:104-162` | "Task finished", "Task complete", "Task stopped", "Task failed", "Saving your report", "Preparing your report" | "finished" and "complete" are synonyms for one state. "report" is a new noun (History calls it a session). M. | "Done", "Stopped", "Failed" with the task name as the title, detail "Saving to History" |
| R-A11 | `:339,370,513-514` | "Read-back: …", "One-way · Trust tier 2", "Verified: …", "Needs checking: …" | Internal tier jargon in a user surface. H for comprehension. [BC]. | "Checked: …" / "Needs checking: …" / "Can't be undone" (no tier number) |
| R-A12 | `:394-396,422` | "Hold ⌃⌥ to steer" / "Type instead" | Good and short. "steer" is a consistent metaphor with "Steer before the next step". Keep. | keep |
| R-A13 | `:434-464` | Pause / Resume / Take over / Stop / Try again | Good verbs. a11y labels add "task" ("Retry task") while the button says "Try again", and the card says "Retry when the connection returns" (R-E3). Choose "Try again". L. | a11y "Try again" |
| R-A14 | `:491,492` | "Perry didn't change anything." / "Waiting for the first step." | Third person. Good fact. | "I didn't change anything." |
| R-A15 | `TaskQuestionPresenter.swift:78` | "Stop task" | Fine. | keep |

### 4.5 Errors, failures and what Perry says when it stops

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-E1 | render `failure-notice.png`, source `FailureNotice.swift:11` | "Perry can't see your screen, so it answers from window text only. Turn on Screen Recording for Perry." / buttons "Dismiss", "Open Privacy settings" | 3 lines at about 34 characters. Third person. Button names a generic pane ("Privacy") for any permission. H. [HIG-W] link instead of location. [MS-WAC] heading relates to button. | Title "I can't see your screen." Body "Until you turn on Screen Recording, I answer from window text." Button "Open Screen Recording" (pane name from `PrivacyPane`). Cancel button "Dismiss" is fine, but [HIG-A] says use "Cancel" for cancel. Keep "Dismiss" for a notice with nothing to cancel. |
| R-E2 | render `listening-failed.png`, `TalkSession.swift:740,873` | "I didn't hear anything. Check that your microphone is on, then try again." | Wraps to 3 lines with "again." alone. "then try again" repeats the "Try again" button. [HIG-A] "Avoid explaining alert buttons". M. | "I didn't hear anything. Check your microphone." Button "Try again". |
| R-E3 | render `task-failed.png` | "The connection was interrupted" / "Your request is saved. Retry when the connection returns." / button "Try again" / footer "Perry didn't change anything." | Passive title. "Retry" vs "Try again" on one card. Footer is third person. The footer is the best fact and is smallest. H for ordering. [NNg-ERR] "what to do". | Title "I lost the connection." Body "Your message is saved. I didn't change anything." Button "Try again". |
| R-E4 | `TalkSession.swift:284,456,643,757,819`, `TalkSession+Ask.swift:143` | "Perry couldn't hear that." / "Perry couldn't finish this answer." / "Perry couldn't start listening." / "Perry couldn't answer that." / and `:740,763,776` "I didn't catch that. Try again." | Same file, same kind of event, two narrators. M. Also no cause, no step. | "I couldn't hear that. Try again." / "I couldn't finish that answer. Try again." / "I couldn't start listening. Check your microphone." |
| R-E5 | `TalkSession.swift:637` | "Enable microphone and speech recognition for Perry in System Settings › Privacy & Security, then try again." | Describes a location in prose. [HIG-W]: "provide a direct link or button, rather than trying to describe its location." H. | "I need the microphone and speech recognition." Button "Open Microphone" |
| R-E6 | `DictationController.swift:593-603` | "Perry needs microphone and speech recognition access to hear you." | States the need, no step. Others in this enum are good ("Choose another microphone in Settings."). M. | "I need microphone and speech recognition access to hear you." + the same button |
| R-E7 | `HotkeyController.swift:138-148` | "macOS could not install Perry's shortcut handler (\(status))." / "That shortcut could not be registered (\(status)). Choose another shortcut." / "The wake shortcut needs ⌃, ⌥, ⇧ or ⌘ together with a key. Choose another shortcut." | First: jargon ("handler") and OSStatus in the sentence; no step. Straight apostrophe. Third is the model: rule plus step. M. [MS-WAC]: put codes below the body. | "I couldn't set that shortcut. Choose another shortcut." and a second line "Error code: -9878" |
| R-E8 | `ExecutionFinalizer.swift:82-89,138-148` | "Finished, but Perry could not independently verify: …." / "Stopped: …." / "…No actions ran, so nothing was changed. Safe next step: adjust the goal and try again." / "3 of 5 actions finished and were verified; the stopped action's effect is uncertain, and everything after it was left untouched. Safe next step: review what changed, then retry the goal." | The strings end up in History and the notification body. "independently verify", "Safe next step", "the goal", "effect is uncertain" are procedure-manual voice. "steps" and "actions" mix. One sentence carries 3 facts and a semicolon. H. [HIG-W] robotic. [MS-WAC] "Focus on giving the facts first." | Done: "Done. I ran 3 steps." / unverified: "Done, but I couldn't confirm it worked: …" / no action: "I didn't change anything. Rephrase the task and try again." / partial: "I finished 3 of 5 steps and checked each one. I can't tell whether step 4 took effect. I didn't touch the rest. Check what changed, then try again." |
| R-E9 | `ExecutionFinalizer.swift:123` | notification title "Perry task (completed)" | Prints a raw enum in parentheses. M. | Title: the task name. Body: "Done" or "Stopped". |
| R-E10 | `RoutineRunCopy.swift:6,19-28` | "Done. That worked. I will remember it." / "I stopped before the first step." / "I stopped at step 2. I could not find 'Save'." | Right person. "I will", "I could not" are stiff against `couldn't` elsewhere. Straight single quotes around the label. "it" has no referent. M. | "Done. I'll remember this routine." / "I stopped at step 2. I couldn't find “Save”." |
| R-E11 | `GuideSessionCoordinator.swift:766,961,934,941,1068,1002,793` | "That window is protected, so Perry won't guide inside it." / "I couldn't see anything to point at there." / "Cua could not read the target window, so I couldn't paint the path." / "That step's target is no longer where the map put it." / "Here's the visible path, N steps." / "Cua could not start the guide: …" | Mixed person, a vendor name ("Cua"), and internal metaphors ("map", "paint the path", "target"). H. [BC]. | "That window is protected, so I can't guide inside it." / "I couldn't see anything to point at." / "I couldn't read that window. Try again." / "That step moved. Tap Find it again." / "Here's the path: N steps." |
| R-E12 | `AgentCoordinator.swift:473-481` | "Stopped. Review any changes before trying again." / "Paused." / "Stopped at the action limit. Review the result before continuing." / "Stopped at the time limit. …" | No number for the limit. "Paused." tells the user what they did. Third sentence verb "Review" is fine. M. | "I stopped. Check for changes before you try again." / "I stopped at the 40-action limit. Check the result before you continue." (use the real number) |
| R-E13 | `HomeController.swift:221,281,446,500` | "Interrupted task closed after your review. Its effects have not been independently verified." / "Conversation storage is unavailable. The suggestion is still here." / "This conversation is still working. Stop it or wait before asking another question." / "Stopped before starting. Your request is still here." | Lines 446 and 500 are the model: state, then what is safe or what to do. Line 221 is passive jargon. 281 gives the fact and the reassurance. | 221: "You reviewed this task. I haven't confirmed its changes." Keep 281, 446. 500: "I stopped before starting. Your message is still here." |
| R-E14 | `BackgroundTaskRecoveryNotice.swift:21,27-31` | "Saved task can't resume" / "Perry restored an older task record and can't tell which actions finished. This task can't resume. Check the target app before starting a new task." / "…saved by an older Perry version… Replan it to run with the current engine." | "task record", "target app", "engine". Three "can't"s in four sentences. M. | "This task can't resume" / "I can't tell which steps finished. Check the app, then start a new task." / "An older version of Perry saved this task. Replan it to run it." |
| R-E15 | `ModelTypes.swift:176` | "Perry's context estimate exceeds this model's limit. Shorten the request or choose a model with more context. Your conversation is still saved." | "context estimate" and "context" are jargon. Last sentence is good. M. [NNg-ERR]. | "That's too long for this model. Shorten your message or choose a model that takes more text. Your conversation is saved." |
| R-E16 | `PromptAssembler.swift:75-81,198` | "This model cannot use Perry's tools." / "I don't have a brain connected yet, so I can't answer. Sign in with ChatGPT or add an API key in Settings › Models." | "tools" breaks the prompt's own rule ("Never say tool names", `:identity`). "Settings › Models" names a tab that does not exist: the tab is "Brain" (`SettingsPage.swift:40`). "brain" is the only place a user hears the word spoken. H (dead end). | "This model can't click or type for me. Choose a different model." / "I don't have a model yet. Sign in with ChatGPT or add an API key in Settings > Model." (rename the tab per section 6) |
| R-E17 | `ForegroundTaskController.swift:397-398,606` | spoken: "Perry's agent runner is unavailable." / "You're in control. Choose Continue with Perry when you're done." | First is read aloud and is pure jargon. Second is good but "Continue with Perry" is third-person button text. M. | "I can't run tasks right now. Restart Perry." / keep the second |
| R-E18 | `VoiceController.swift:267,283`, `DictationInsertion.swift:35` | "Allow microphone access and I'll listen." / "Couldn't start listening: \(error.localizedDescription)" / "I couldn't read your voice dictionary, so I stopped before dispatching that request." | Raw system error appended. "voice dictionary", "dispatching" are jargon. Settings calls the same list "Your words" and "Replacement phrase". M. | "I couldn't start listening. Check your microphone." / "I couldn't read your word replacements, so I didn't send that." |
| R-E19 | `PerryCaptureError.swift:15-38` (if surfaced) | "Capture refused because a sensitive window is visible." / "Capture returned no image." / "The image data could not be decoded." / "Vision text recognition failed: …" | Engineer voice. "sensitive window" is unexplained (Privacy page says banking, sign-in, payment). | "I didn't capture the screen because a password or payment window is open. Close it and try again." / "I couldn't capture the screen. Try again." |
| R-E20 | `HomeConversationView.swift:36-40,97-100` | error `Label` with icon in secondary color | Style note: an error in secondary grey is the quietest text on the screen. [NNg-ERR] visibility. L. | Use the caution color and the same sentence pattern as the failure card |

### 4.6 Guide (`GuideControlsWindow.swift`, render `guide-step.png`, `guide-question.png`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-G1 | `:64` | "Step 2" | No total, so the user cannot judge the length. The task strip says "Step 2 of 5" (`AgentActivityStrip.swift:125`). M. | "Step 2 of 5" |
| R-G2 | `:81,87` | "Done" / "Let Perry do it" | "Done" is correct (completes the step). "Let Perry do it" is third person in a surface where the question is first person ("Which version should I use?"). M. | "Do it for me" |
| R-G3 | `:93-96,122` | "Back" / "Find it again" / "Skip this step" / "Pick a step to start from" | Good, verb-led, specific. Keep. | keep |
| R-G4 | `:115` | "Stop guide (Esc)" | Fine. | keep |
| R-G5 | render `guide-question.png` | "Which version should I use?" + options + "Stop task" | Good. First person, a real question, option text is the user's words. | keep |

### 4.7 Permission helper (`App/Permissions/PermissionHelperPanel.swift:190-211`, renders under `permission-helper-evidence/`)

Panel is 440 px wide; the second line holds about 39 characters.

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| R-P1 | `:196,208` | "Drag Perry into the list above." / "Then switch it on in Device Control and Data Access." | The first line is as good as HeyClicky's. The second wraps in the middle of the pane name ("...Device Control and / Data Access.") in the render. The user is already looking at that pane, so the name adds length, not help. M. | "Drag Perry into the list above." / "Then turn it on." If you keep the pane name, bind it with non-breaking spaces. |
| R-P2 | `:197,209` | "That didn't go through." / "Drag Perry into the list again." | Vague about what failed [HIG-A]. The title blames nothing and says nothing. M. | "Perry isn't in the list yet." / "Drag Perry in again." |
| R-P3 | `:198,210` | "System Settings closed." / "Open it again to finish turning on \(name)." | Title is a fact with no action. [MS-WAC] heading should be "ideally what to do". M. | "Reopen System Settings." / "Then turn on Perry in \(name)." |
| R-P4 | `:144` | button "Open Settings" | Perry Settings or System Settings? H. | "Open System Settings" |
| R-P5 | `:136,139` | "List not showing?" | A question as a button label. [HIG-W] verb. [MS-WAC] questions add pressure. M. | "Reopen list" |
| R-P6 | `:134` | "macOS will ask for your password." | Good. A useful warning. Keep. | keep |
| R-P7 | `:199-201` | "Move Perry to Applications first." / "Then open it from there and try again." / "Restart Perry to finish." / "Choose Quit & Reopen if macOS asks, or restart here." / button "Restart Perry" | Best strings in the app: action first, heading matches the button. | keep |
| R-P8 | `:201` | "Perry has access." | State, fine. | "Perry is on." only if the pane shows "On" |
| R-P9 | `AppBundleDragView.swift:92,115` | a11y "Perry. Drag into the list in System Settings." / chip "Drag" | Good. | keep |

### 4.8 Settings (`App/Settings`, renders under `settings-pages/`)

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| S-G1 | `SettingsPage.swift:40` | tab "Brain" | The only place the word is used as a tab. Prompt says "Settings › Models". Onboarding says "How should I think?". M. | "Model" |
| S-G2 | `SettingsPage.swift:42,47` | "Privacy & Safety" and "Privacy" for the same page | Two names. L. | "Privacy" |
| S-G3 | `SettingsPage.swift:65-67` | groups "Perry", "Work", "Trust" | "Perry" holds voice and shortcuts; "Work" holds models and apps. Vague. L. | Drop group titles or use "Talk", "Connect", "Trust" |
| S-G4 | `GeneralSettingsPage.swift:40,46,55` | "Replay the intro" / "Replay" ; "Check for Updates" ; "What's New" / "Show" | Title Case for two buttons and a row, sentence case elsewhere. M. [MS-10]. | "Replay the intro" / "Replay" ; "Check for updates" ; "What's new" |
| S-G5 | `:17,23` | "Perry's eyes rest beside the camera and show when Perry is busy." / "Point at the notch to see what Perry is doing." | Good: describes the on state. Second is fine. | keep |
| S-B1 | render `brain.png`, `BrainSettingsPage.swift:38` | "Sign in with ChatGPT from Conversation model above." | "above", a third name for the model section ("Brain" heading, "Conversation model" label). M. | "Sign in with ChatGPT in Model." |
| S-B2 | render | "How much memory can Perry keep ready?" with option "Nothing" | "Memory" means RAM here and notes in You > Memory. "Nothing" reads as "no memory at all". One word, two meanings. H. [HIG-W] terms. | Section "Keep the model loaded". Options "Unload when idle" (detail "I unload it after 30 idle minutes. The next answer takes a few seconds longer."), "Keep the small model (up to 2 GB)", "Keep the main model (about 7 GB)". Footer "Perry also unloads the model when macOS runs low on memory." |
| S-B3 | render | "Only the small helper stays ready." | "helper" is now a fourth meaning (see R-H1, "Screen helper"). M. | "small model" |
| S-B4 | render | "Set up on this Mac" row + button "Download and set up" | Title and button repeat each other and the button is four words. L. [MS-WAC]. | Row "Local model" / button "Download" |
| S-B5 | render | "API key…" | Ellipsis implies it opens a form. Rows are radio choices. L. | "API key" |
| S-B6 | `BrainSettingsPage.swift:52,58,75,83,107` | "Screen helper" / "The screen helper (Cua Driver) lets Perry see the screen and act in other apps." / "Run the copied command in Terminal, then choose Check again." / "Cua Driver path (optional)" / "Perry could not copy the authentication command. Open Terminal and run the runtime's official sign-in command manually." | Vendor name, "runtime", "authentication command", "manually". Developer voice. M. [BC]. | "Screen control" / "Lets Perry see your screen and act in other apps." / developer fields behind Advanced / "I couldn't copy the sign-in command. Open Terminal and run it yourself." |
| S-B7 | render | "Apple Intelligence: Text answers. Reads windows as text. Can't act." | Fragments, telegraphic. [PROSE-TELL]. Fine for a dense list; flagged only for the missing subject. L. | "Answers in text. Reads windows as text. Can't click or type." |
| S-A1 | render `apps.png` | Calendar "Connect", all others "Set up" | One action, two verbs. Onboarding uses "Connect" for all. H. | "Connect" for all |
| S-A2 | render | section "Connected apps" listing apps that are not connected | Title lies. M. | "Apps" (or split into "Connected" and "Available") |
| S-A3 | render | row details: "Events from your calendars on this Mac, Google and iCloud included" / "Pages, databases, and workspace search" / "Read access to mail. Needs your own Google OAuth app until Google reviews Perry" | Noun phrases, no periods, and the third is jargon ("OAuth app"). Onboarding uses imperatives with periods. M. | Reuse onboarding strings. Gmail: "Read your mail. You need your own Google setup until Google reviews Perry." |
| S-A4 | `AppsSettingsPage.swift:13` | "Connections stay in this Mac's Keychain. Each service starts read-only, and every change Perry makes still asks you first." | Good facts. "still" is filler. L. | "Connections stay in this Mac's Keychain. Each app starts read-only. Perry asks before it changes anything." |
| S-A5 | render | "Custom connectors / Add any MCP server. Perry asks before any tool that might change something." | "MCP" undefined. "tool" vs "app". M. | "Connect any MCP server. Perry asks before it changes anything." |
| S-A6 | `AppsSettingsPage.swift:82` | "Perry could not open the local skills folder." | "could not". L. | "I couldn't open the skills folder." (or "Perry couldn't" if Settings stays third-person, see section 6) |
| S-P1 | render `privacy.png` | rows "Device Control and Data Access", "Screen & System Audio Recording", "Microphone", "Input Monitoring", button "Turn on…" | System names, correct. Onboarding uses "Accessibility" for the first (R-O11). "Turn on…" has an ellipsis, correct per [HIG-B] because it opens another view. | keep, after R-O11 |
| S-P2 | `PrivacySettingsPage.swift:16-22` | "Lets Perry read and act on whatever you point at." / "Lets Perry see window contents so answers stay grounded." / "Lets Perry hear you for talk and dictation." / "Lets Perry hear the dictation key while other apps are focused." | Purpose given for each, which is the standard [HIG-P] asks for. "grounded" is jargon. "hear the dictation key" is the same mis-verb as R-O19. M. | Second: "Lets Perry see what's in your windows so answers match your screen." Fourth: "Lets Perry notice the dictation key when another app is in front." |
| S-P3 | render | "Always blocked" / each row "Never" | The column repeats the section title. L. | Remove the "Never" column |
| S-P4 | render | "Records" / "Something wrong?" | "Records" is vague. "Something wrong?" is a question as a row label [MS-WAC]. L. | "Export and report" / "Report a problem" (button already says it) |
| S-P5 | `:84-90` | dialog "Report a problem" / "Perry never uploads anything automatically. Export the redacted diagnostics file, then attach it to a new issue in Perry's GitHub repository." / buttons "Export diagnostics first", "Open GitHub issues", "Cancel" | "first" inside a button label is instruction text [HIG-A: do not explain buttons]. "never... automatically" is a negation reassurance. Rendered as three stacked buttons, primary is the longest. M. | Body "Export the diagnostics file, then attach it to a new issue on GitHub. Perry doesn't upload anything." Buttons "Export diagnostics", "Open GitHub", "Cancel" |
| S-P6 | `:72` | "Erase all Perry data" / "Tasks, history, memory, approvals, preferences, credentials and temporary files. Perry asks you to confirm first." | A list of seven nouns (rule of three, [PROSE-TELL]) but each is a real thing that goes. Keep the list. Drop "Perry asks you to confirm first" (the button already says "Erase…"). | detail: "Deletes tasks, history, memory, approvals, preferences, credentials and temporary files." |
| S-Y1 | `YouSettingsPage.swift:14,35,66,74-76` | tab "You" with card "Memory" ; "Remember context between conversations" ; "Erase what Perry knows" ; dialog "Perry forgets every note and your profile. This can't be undone." | Tab is "You", card is "Memory", row is "what Perry remembers", button "Erase", per-note "Forget this". Four verbs and two nouns. M. | Tab "Memory". Verbs: "Forget" for one note, "Erase all" for the wipe. Dialog button "Erase memory". |
| S-Y2 | `:35` | "Nothing yet. Perry adds notes as you work together." / "Nothing. Memory is off." | Second is good. First has "work together" filler. L. | "Nothing yet. Perry adds notes as you use it." |
| S-D1 | `DictationSettingsPage.swift:52,78,81` | card "Your words" / "When you say the first phrase, Perry types the second." / fields "Spoken phrase", "Replacement phrase", prompts "When I say" / "Type" | Three names for one list ("Your words", "voice dictionary" in R-E18, "replacement"). The prompts mix user "I" and imperative "Type". M. | Card "Replacements". Fields "When you say" / "Type". Footer unchanged (it is good). |
| S-V1 | `VoiceSettingsPage.swift:42` | "This voice sounds robotic. Enhanced and Premium voices sound far more natural, and they're free." | "far more", "robotic": judgmental. The offer is useful. L. | "Enhanced and Premium voices sound more natural and are free in System Settings." |
| S-K1 | `ShortcutRole.swift:13-16,22-25` | roles "Talk", "Type", "Dictate", "Wake"; owner names "talk shortcut", "typing shortcut", "dictation shortcut", "wake shortcut" | "Type" and "Dictate" both mean getting words into a box. "Type" collides with the task strip's "Type instead". M. Needs owner confirmation of what "Type" does before renaming. | Name each by its result, for example "Talk to Perry", "Type to Perry", "Dictate into any app", "Wake word" |
| S-K2 | `ShortcutRecorder.swift:184,188,190,200` | "Perry's typing shortcut already uses this." / "Pick another" / "Use anyway" / "\(keys) belongs to \(owner). Pick another." | Good: states conflict and two actions. Wraps to 3 lines at 280 px in `shortcuts-conflict-narrow.png`. L. | "The typing shortcut already uses this." |
| S-K3 | `ShortcutRecorder.swift:51-52,179` | "Press the keys…" / "Tap the keys…" / "Hold the keys…" | Good. | keep |
| S-K4 | `Gesture.swift:128-130` | "Release ⌃⌥ when you're done" / "Tap ⌃⌥ when you're done" | Good. | keep |

### 4.9 Menus, notifications, spoken lines

| ID | Location | Current | Problem | Rewrite |
|---|---|---|---|---|
| M-1 | `StatusMenuController.swift:36-48,77,82` | "Talk to Perry", "Ask or do something…", "Background tasks (N)", "Record a routine…", "Settings…", "Update available", "Quit Perry" | See R-H12, R-H13. "Update available" is a notice, not a command. L. | "Update Perry" |
| M-2 | older screenshot `5b8bcb5e…png` (history) | "Watch & Learn", "Memory:…", "Workspace: ~/PerryDemo", "Choose workspace folder…", "Retry last task" | Older build. "Watch & Learn" survives in code comments and class names. Three names for one feature: "Watch & Learn", "Record a routine", "Teach Perry a routine". "Memory:…" shows a broken label. The code has moved on, but the term list should not let "Watch & Learn" back in. M. | "routine" only |
| M-3 | `SystemNotifier.swift:32-33` | "Approve" / "Deny" | See R-A2. | per R-A2 |
| M-4 | `UpdateNoticeController.swift:86` | spoken "Perry updated. See what's new?" | A spoken question with no way to answer by voice. L. | "Perry updated. Open What's new from the menu." |
| M-5 | `RoutineOffer.swift:35-50` | "Show me one thing you do often." / "Do it once while I watch. I will write down the steps. You check them before I save anything." / "Not now" / "Show me" / "Works best for steps inside one app window. I cannot see passwords." | Strong voice. Short, concrete, honest limit. Only the stiff forms: "I will", "I cannot". "Show me" is first-person user voice on a button that works as dialogue. Acceptable. | "I'll write down the steps." / "I can't see passwords." |
| M-6 | `PromptAssembler.swift` identity | "warm, plain and brief, like a capable friend. Lead with the answer... No filler and no apologies... Never say tool names." | The system prompt already states a better voice than the UI does. Use it as the seed for section 6. A capability refusal like the one in the older screenshot ("I cannot read apps or files, control the screen...") is a prompt and capability-block problem; R-E16 fixes its sources. | n/a |

---

## 5. Mechanical punctuation findings (fix with a lint, not by hand)

| Issue | Examples | Rule |
|---|---|---|
| Straight apostrophes in user-facing strings | `HotkeyController.swift:141` "Perry's", `GuideSessionCoordinator.swift:766,934,961,1068,1002`, `RoutineLibraryController.swift:208`, `ForegroundTaskController.swift:397,606`, `VoiceController.swift:267,283`, `DictationInsertion.swift:35`, `AgentActivityStrip.swift:418` | Use ’ everywhere, as the rest of the code does. [ASG] ellipsis note shows Apple is typographic about characters. |
| Straight single quotes around a label | `RoutineRunCopy.swift:24` `'Save'` | Use “ ” |
| "could not" / "cannot" / "will not" in Perry's voice | `RoutineRunCopy.swift:6,24`, `RoutineOffer.swift:37,50`, `IntentCardWindow.swift:100`, `GuideSessionCoordinator.swift:793,941`, `HistoryView.swift:94`, `Perry could not…` in `BrainSettingsPage.swift:107`, `AppsSettingsPage.swift:82`, `YouSettingsPage.swift:83,104` | Contract: "couldn't", "can't", "won't" ([MS-10]) |
| Path separators | `›` (`AppsBeat.swift:52`, `PrivacySettingsPage`, `TalkSession.swift:637`), `→` (`WhatsNewView.swift:11`, `DebugStateFixtures.swift:57`), `>` (`SystemCalendar.swift:22`, `PerryCaptureError.swift`) | One: " > " |
| Ellipsis meaning | "…" used for four things: more input ("Export…"), in progress ("Working…"), placeholder ("Ask Perry…"), truncated example ("a pitch deck…") | [HIG-B]: "…" only where a control opens another view for more input. Progress states keep it. Placeholders and examples do not. Confirmations ("Erase…", "Delete…" that open an alert) are a judgment call: macOS keeps the ellipsis for "needs more information", a bare confirm does not count. Pick one and apply. |
| Three dots vs the character | none found: all use U+2026 | keep |
| Title vs sentence case | "What's New" / "What's new in Perry", "Check for Updates", "Update available" | Sentence case for all UI ([MS-10], [HIG-W] "choose a style for each UI element type"). |
| Periods in headings | Onboarding titles end in a period ("Tell me about you."), settings titles do not | Onboarding titles are one-sentence display lines. [HIG-A]: "If the title is a complete sentence, use sentence-style capitalization and appropriate ending punctuation." Keep periods on onboarding titles that are sentences, drop them from every Settings and peek label. |
| Periods in row descriptions | "Sees your screen and acts. Uses your ChatGPT plan." (period) vs "Pages, databases, and workspace search" (none) | Complete sentences end with a period. Noun phrases do not. Do not mix in one list (S-A3). |
| Em dash | Placeholder "—" for empty fact (`InterviewBeat.swift:365`). HeyClicky uses one in copy. | Use none in copy. |
| Wrap / widow | Interview consent ("I" at line end twice); mic failure ("again." alone); helper detail (pane name split); Q3 "learn lately?" alone | Keep notch body copy to two lines at its measured width: peek 38/46, failure notice 34 per line, helper 39 per line, onboarding body 58 per line. Add `.lineBreakStrategy(.pushOut)` or non-breaking spaces to names. |

---

## 6. Voice spec for Perry

**Principle.** [MC-VT]: same voice always, tone changes with the moment. [HIG-W]: "Determine your app's voice... Create a list of common terms." Perry's system prompt already says "warm, plain and brief, like a capable friend. Lead with the answer." The UI should say the same thing.

### 6.1 Person
- **Perry speaks as "I".** This covers onboarding, the notch, voice, guide, questions, errors Perry owns, notifications, and History summaries of what Perry did. HeyClicky is consistent on this and Perry is not.
- **The user is "you" and "your".** Never "me" or "my". Replace "Ask me before using the cloud" with "Ask before using the cloud". Replace "Only when I ask" with "Only when you ask".
- **Settings labels and system-facing instruction use no pronoun for Perry.** Use a verb-first label or a state ("Open at login", "Read-only to start"). When a setting description needs a subject, use the product name: "Perry also unloads the model when macOS runs low on memory." Do not use "I" in a description of a setting. This is the only place "Perry" third person is allowed, and it keeps the setting readable as a fact about the product.
- **Permission helper.** Keep "Drag Perry into the list" because it names the object the user must drag. It is an instruction, not Perry speaking.
- **No "we".** [HIG-W], [ASG]. "Let's" becomes "I'll".

### 6.2 Tense, length, mood
- Present tense for state ("I stopped" for a finished event, "I'm working" is avoided in favor of "Working…" as a status).
- Future only for a promise Perry will keep right now ("I'll open Figma and walk you through it").
- Sentences: at most 14 words in a notch or helper, 20 in Settings, one idea each. Two sentences per message at most in the notch. The measured line widths are the budget.
- Lead with the fact or the step, not with the apology or the reason ([MS-10] "Get to the point fast").
- Contractions: always where natural ("can't", "couldn't", "I'll"). Never "cannot", "could not", "will not" in Perry's voice.
- No exclamation marks, no "Oops", no "Sorry" ([HIG-W], [PROSE-IC]). No em dashes.
- Humor: at most one earned line per flow (the "Hold ⌃⌥ and say hi." beat). Never in errors, approvals, permissions or data loss ([MC-VT]: "If you're unsure, keep a straight face").

### 6.3 Button grammar
- Verb first, sentence case, no ending period, one to three words ([HIG-A], [MS-WAC], [MC-WE]).
- Name the result: "Save" / "Don't save", "Move files" / "Don't move", "Delete 3 items", never "OK", "Yes", "Looks right", "Allow" on a custom screen ([HIG-A], [HIG-P], [NNg-OK]).
- One verb per action across the product: **Connect** (an app), **Turn on** (a permission), **Continue** (next beat), **Skip** (optional step), **Not now** (defer a request), **Try again** (retry), **Cancel** (undo an action in progress), **Dismiss** (close a notice), **Delete** (destroy a thing), **Remove** (take out of a list), **Erase** (wipe all, only two places), **Discard** (unsaved drafts only), **Forget** (one memory note), **Open** + the object ("Open Screen Recording").
- Approve and decline pair on the action's verb. Fallback: "Approve" / "Deny" everywhere.
- Ellipsis only when the control opens another view for more input ([HIG-B]).
- Toggles are labeled with the on-state ("Open at login") ([PROSE-IC], [HIG-W]).

### 6.4 Error grammar
Three parts, in this order, each optional except the first: **what happened** (in "I" voice, plain noun), **what is safe or unchanged**, **one next step, as a button when possible**.
- Heading is a complete sentence with a period, never "There was a problem" or "Error" ([MS-WAC], [HIG-A]).
- Say what Perry did not change when that is true. This is Perry's strongest reassurance ("I didn't change anything.").
- A step is a button, not a path described in prose ([HIG-W]). "Open Microphone", not "System Settings › Privacy & Security › Microphone".
- No vendor or internal nouns in the sentence ("Cua", "runtime", "tool", "tier", "target", "context", "handler"). Put codes on a separate line ("Error code: -9878", [MS-WAC]).
- Never blame the user ([NNg-ERR], [HIG-W]).
- Data loss and security: neutral and explicit, with the consequence on the button ("Delete 3 items").

### 6.5 Terms (one referent, one word)

| Referent | Use | Retire |
|---|---|---|
| the AI that answers | **model** | Brain, brain, agent (for a model), runtime, engine, provider, "On this Mac" as a label |
| a coding agent such as Codex | **agent** (only for these) | |
| the character and product | **Perry** | "a Perry", "Perrys" |
| a named, scheduled job-runner | **helper** (owner decision) | "Perry" as a noun for it, "job" |
| a chat | **conversation** | thread, session |
| something Perry does in apps | **task** | job, request, run (noun), goal |
| saved replayable steps | **routine** | Watch & Learn, "demonstration" |
| a walk-through | **guide** | |
| what the user types and sends | **message** | request |
| macOS pane name | the system's own name (`PrivacyPane.displayName()`) | "Accessibility" when macOS shows "Device Control and Data Access" |
| macOS Settings vs Perry Settings | "System Settings" vs bare "Settings" (Perry's own) | bare "Settings" for System Settings |
| the user's work folder | **work folder** | "workspace" (window, folder, task folder) |
| RAM | **memory** | |
| what Perry remembers about the user | **notes** or **Memory** (tab) | "memory" for RAM |
| connecting an app | **Connect** | Set up (reserve for the local model), Sign in (a step inside Connect) |
| decline | **Deny** or "Don't {verb}" | Don't allow |
| needs the user's approval | **Needs your OK** (one phrase) | Approval needed, Awaiting approval |
| needs the user to check | **Needs checking** | Check needed |

### 6.6 Five before and after pairs

| Before | After | Rules met |
|---|---|---|
| Failure card (`failure-notice.png`): "Perry can't see your screen, so it answers from window text only. Turn on Screen Recording for Perry." button "Open Privacy settings" | "I can't see your screen." / "Until you turn on Screen Recording, I answer from window text." button "Open Screen Recording" | One narrator ([HIG-W]). Heading says what happened, button names the exact pane, heading relates to the button ([MS-WAC]). Fits two lines at 34 characters. |
| Interview review (`interview-5-review.png`): "Here's what I got." / "Not saved yet." / "Looks right" / "Don't save" | "Here's what I'll remember." / "I haven't saved this yet." / "Save" / "Don't save" | Verb on the primary button, HIG pair ([HIG-A], [NNg-UI]). Title states the consequence. |
| Access beat (`onboarding-3-access.png`): "I need to see what you see." / "Reads buttons, menus and fields" / button "Allow" | "I need two permissions." / "So I can read buttons, menus and fields, and click for you." / button "Turn on" | Specific title, purpose sentence ([HIG-P]), no "Allow" on a custom button ([HIG-P]), one verb for permissions across onboarding, Settings and the helper. |
| Finalizer (`ExecutionFinalizer.swift:138-148`): "3 of 5 actions finished and were verified; the stopped action's effect is uncertain, and everything after it was left untouched. Safe next step: review what changed, then retry the goal." | "I finished 3 of 5 steps and checked each one. I can't tell whether step 4 took effect. I didn't touch the rest. Check what changed, then try again." | Facts first, one fact per sentence, "I" voice, one term ("steps"), no procedure-manual phrasing ([MS-WAC], [HIG-W]). Same facts, no new claims. |
| Peek (`peek-needs-you.png`): "Perry needs your OK" / "Open it to continue" / pill "Review" | "Move two files into Archive" / "Needs your OK" / pill "Review" | Names the object ([NNg-OK], [PROSE-IC] "A confirmation names the object"), one phrase for the state, no third-person Perry in Perry's own surface. Title 28 characters, fits the 38-character row budget. |

---

## 7. What to do, in order

1. **Adopt the section 6 glossary and person rule.** It is a one-page decision, not code. Two owner decisions are needed: (a) "helper" as the name for a Perry instance, (b) what the "Type" shortcut does, so it can be renamed.
2. **Fix the H items first.** R-O10, R-O12, R-O13, R-O21, R-O31, R-N1, R-N10, R-E1, R-E3, R-E5, R-E8, R-E11, R-E16, R-A11, R-H1, R-H19, S-B2, S-A1. These misname a concept, hide the next step, or point to a screen that does not exist.
3. **Single-source strings that appear twice**: model descriptions (onboarding vs Settings), app descriptions (onboarding vs Settings), "Open at login" (three places), permission pane names. One `Strings.swift` per surface with the glossary terms removes the drift at the source.
4. **Add a copy test** (the local rule says to encode repeat corrections where they cannot be ignored). A unit test that scans the Swift files in scope for string literals and fails on: a straight apostrophe between letters, `could not|cannot|will not` inside strings that start with "I" or "Perry", `Settings ›|Settings →`, the retired terms in the section 6.5 table, `Allow` as a button title, and a button title longer than three words. About 40 lines. This is the item that stops the copy from rotting again.
5. **Render check.** Re-render the notch states after the rewrites and look for widows at the measured widths (peek rows 38 and 46 characters, failure notice 34 per line, helper 39 per line). I did not render anything, so the rewrites are budgeted by character count but not visually verified.

## 8. Evidence limits and open questions

- I did not run Perry. Everything is from code and PNGs. The renders are 1x offscreen and some contain fixture text (for example the repeated "Review this document before saving changes..." in `approval-long.png`), which I did not audit.
- `NotchPresentation` may not carry an action title for the peek "needs you" row (R-N1). Confirm before promising the rewrite.
- R-O12 (the microphone "only" claim) needs a code check against wake word, click-to-talk and dictation before I would call it false. I flag it as unverified.
- Older screenshots show a menu with "Memory:…" and "Watch & Learn". The current `StatusMenuController` has neither. I used them only as history (M-2).
- Linear and Stripe: no primary copy source found, so I make no claim about them. For "teams known for copy", I relied on Apple, Microsoft, Mailchimp and Basecamp.
- NN/g's "UI Copy" article is about command names; I apply it to buttons by analogy. Mailchimp's guide has no error-message page that opened.
