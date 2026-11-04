# Perry website: the inkwell

The site is the product, shown honestly. Every character, color, eye and surface here is taken from
the app in `../perry`. When this file and the app disagree, the app wins: fix this file.

Sources of truth
- Character geometry and faces: `perry/Packages/PerryOverlay/Sources/PerryOverlay/PerryCharacter.swift`
- Notch, eyes and moods: `perry/App/Notch/NotchEyes.swift`, mockups in `perry/docs/design/2026-10-25-notch-mockups/`
- Palette and type: `perry/App/PerryTheme.swift`
- Voice: `perry/docs/tone-sheet.md`. Claims: `perry/PRD.md`. Gestures: `perry/App/Shortcuts/Gesture.swift`

## Concept card

Idea:        The Mac notch is Perry's home. Perry is the only thing on the page that is alive.
Metaphor:    Wet ink over precise native UI. Help is drawn on top of the real thing, never instead of it.
Signature:   The wordmark paints itself, its two r's open Perry's capsule eyes, then the word drains up
             into the notch and the eyes move to the notch wing. Later, the site demos Perry on itself.
Emotion:     A small "oh" in the first three seconds, then calm. One jaw-drop per beat, never two.
Motion verb: Flow and settle. Pour, pinch off, land with a little squash, dry still.

## Perry, the character

- A sage drop whose tip is a real pointer tip: tip (-0.30, -0.40), circle centre (0.101, 0.124),
  radius 0.285 in a unit square. Fill sage #9CCBB6, carbon outline #0C0D0E at 0.055, white rim at
  0.15 with a soft shadow. Never recolor it, never boil or wobble its outline.
- Eyes are vertical carbon capsules 0.15 long, 0.09 wide, 0.19 apart. Faces: open, wide (0.2),
  focused (0.06), happy (arc eyes plus arc mouth), asleep (down arcs). Gaze moves the eyes as a pair.
- Website code: `src/mascot.js` mirrors the Swift geometry. Moods: open, wide, focus, happy, closed.
- He points with his tip. Poses change with meaning (lean, squash on landing, hop when happy).

## The notch

- Black crown with real notch shoulders. With eyes present, one 38px wing grows to the right, and two
  capsule eyes sit in it: 7x12 warm white #F4F1E8, mint glow at 0.3. That is the resting state.
- Moods, set in `main.js` from what the notch is doing: listening (sage, 8x14, glow 0.55),
  needs review (#FF9F0A, 7x14, no glow), asleep (2.5px slits at 60%, used while reading privacy).
- Hover swells the plate (+6 x +4) and the eyes (x1.12). Panels expand from the crown, 26px corners.
- The wordmark's eyes are the same capsules, cut into the ink: paper by day, the night sky by night.

## Palette (PerryTheme)

| Role | Day (page) | Night (finale, product surfaces) |
| --- | --- | --- |
| canvas | #F5F3EE | #0C0D0E (page), #1B1B1A (panels) |
| surface | #FFFEFA | #252524 |
| text | #202420 | #F5F2EA |
| secondary | #666D66 | #A6A59F |
| separator | #DCDDD5 | #343432 |
| accent, guide ink | #3C7765 | #9CCBB6 |
| caution (needs review only) | #A05A00 | #FF9F0A |
| eye | #F4F1E8 | #F4F1E8 |

Ink #1C1E1B is the wordmark by day; ivory #F3F0E8 by night. Guide ink is the accent: circles,
arrows, numbers and focus rings only. Caution is never decoration.

## Type

- Display: Young Serif, the web stand-in for the app's semibold system serif (`PerryTheme.display`).
- Copy and site UI: Bricolage Grotesque 400 to 600.
- Anything that is product UI (notch panels, the app window, chips inside the notch) uses the system
  font stack, sized like the app: 13 to 15 body, 11 to 12 metadata.
- The wordmark is drawn ink, never a font. No handwriting fonts.

## Story

1. Hero: wordmark paints in, capsule eyes open and follow the pointer. H1 and one action.
2. Drain: the word flows into the notch; the eyes reappear in the notch wing.
3. Statement: one sentence revealed word by word, underlined in guide ink.
4. Stage, pinned: one Logic Pro window. Ask, Learn, Do. Perry leaves the notch, points with his
   tip, and returns. The notch carries the conversation and shows the matching eye mood. The
   session is playable: the audio is real, so the sidechain pump is heard, not described.
5. Privacy: plain facts from the PRD; the notch eyes close while you read.
6. Night: after the FAQ the page fades to night.
   Its eyes open in the dark and follow you; "Say hello to Perry." rises word by word, then one action
   and a one-line footer. No FAQ in the finale. Reduced motion shows the finished night frame.

Anywhere: Ask this page. Click the notch, press /, or double-tap ⌃. Perry flies to the answer on the page and
circles it in guide ink. Answers come only from the page copy. ⌥⌘P wakes Perry beside your cursor; hold ⌃⌥
shows the listening notch (no web voice: it would leave the Mac). Selecting text gets a guide-ink circle.
The wall's "this one." ends with every other control falling away. "Seen, then gone." crumples a screenshot.
Interface sounds are opt-in from the menubar.

## The app window

- One window, one task, real controls. 12px corners, macOS traffic lights, layered shadow.
- It must survive a screenshot comparison with the real app: true metrics, native type, no lorem.
- No fake menu bar, no Dock, no Apple app icons drawn by hand.

## Motion

One easing family (expo/power3 out, expo inOut for pinned beats). One scroll-linked pattern per
beat. Idle: eyes blink (3.2 to 7.5 s, 15% doubles) and glance; nothing else moves at rest.
Product timing: feedback 100 to 150 ms, panels 180 to 240 ms.

## Rules

- Every claim is from perry/PRD.md. Default gestures: hold ⌃⌥ to talk, double-tap ⌃ to type, ⌥⌘P.
- Reduced motion: no paint, no drain, no flight; the stage steps between finished frames, sound
  never starts by itself.
- Sound is opt-in, starts only from a click, and is off again when the stage leaves the screen.
