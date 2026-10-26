# Perry copy glossary

One referent, one word. This list replaces section 6.5 of `docs/audits/2026-10-26/copy.md`. `AppTests/CopyLintTests.swift` enforces the retired terms in the screens named in that test.

## Voice

- Perry speaks as "I". The user is "you".
- A Settings description uses "Perry" when it needs a subject. It never uses "I".
- Buttons start with a verb: Turn on, Save, Connect. Three words at most.
- An error says what happened, what did not change, and offers one step. A step is a button when one exists.
- Contractions in Perry's voice: couldn't, can't, won't, I'll. Never "could not", "cannot", "will not".
- Curly apostrophes and quotes in every string.
- A path in prose uses one separator: `Settings > Brain`.

## Terms

| Referent | Use | Retired |
|---|---|---|
| The AI that answers | **brain** | model, agent, runtime, engine, provider (in UI copy) |
| Where a brain runs | **Cloud**, **On this Mac** | local model, remote model |
| A coding agent the user picks | its product name (Codex, Claude Code), or **coding agent** | agent runner, runtime |
| The character and the product | **Perry** | a Perry, Perrys |
| A named, scheduled Perry | **helper** | Perry (as a noun), job |
| A chat | **conversation** | thread, session |
| Something Perry does in apps | **task** | job, request, run (noun), goal |
| Saved replayable steps | **routine** | Watch & Learn, demonstration |
| A walk-through | **guide** | |
| What the user sends | **message** | request |
| What Perry keeps about the user | **notes**, in the **Memory** tab | memory for RAM |
| Loading a brain into RAM | **loaded**, **unload** | keep in memory |
| Controlling other apps | **screen control** | screen helper, Cua, driver, computer use |
| Permission names | the system's own name (`PrivacyPane.displayName()`) | Accessibility when macOS shows Device Control and Data Access |
| macOS Settings and Perry Settings | **System Settings** and bare **Settings** | bare Settings for System Settings |
| The folder for file tasks | **work folder** | workspace |
| Connecting an app | **Connect** | Set up, Sign in (as the button) |
| Turning a permission on | **Turn on** | Allow, Enable |
| Decline an approval | **Deny** | Don't allow |
| Approve an approval | **Approve** | Allow, Run, a full sentence |
| Needs the user's approval | **Needs your OK** | Approval needed, Awaiting approval |
| Needs the user to check | **Needs checking** | Check needed |
| A checked result | **Checked** | Verified, Read-back |
| Risk tiers | **Reads only**, **Small change**, **Bigger change**, **High stakes** | Trust tier, green, orange |
| Finished task states | **Done**, **Stopped**, **Failed** | Task finished, Task complete |
| Ending a notice | **Close** or **Dismiss** | OK, Okay |
| Memory tab | **Memory** | You |

## Names decided for the owner

- **helper** names a scheduled Perry. It is short, a layperson already knows it from "helper" in everyday speech, and it does not clash with the **routine** (saved steps) or the **task** (one piece of work).
- **Type to Perry** names the shortcut that was called "Type". The code shows what it does: a double-tap of ⌃ opens the text box so the user can type a message instead of speaking. The other shortcut names follow the same pattern: **Talk to Perry** (hold to speak), **Dictate anywhere** (types what the user says into any app), **Open Perry** (a key combination that starts a session).

## Microphone line

The onboarding line is "So I can hear you when you talk to me." It is true with the hold-to-talk shortcut, the mic button, dictation and the optional wake word. It makes no claim about when the microphone is off, because the wake word listens continuously when the user turns it on.
