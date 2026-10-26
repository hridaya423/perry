# Perry vs HeyClicky: why it does not feel premium, and where it is crammed

Pixel-level design review. Read-only. Written 2026-10-26.
Tools I built for measuring: `/tmp/audit/tools/px.swift` (CoreGraphics pixel probe: row/column runs, text-line bands, bounding boxes, colour clusters). Extracted source text: `/tmp/audit/src/`. Crops: `/tmp/audit/crops/`.

## 0. Bottom line

1. HeyClicky's notch panel is not simpler by control count. It has 8 interactive controls, Perry's peek has 9 to 12. It reads as premium because of five measurable things: **row pitch 63 pt vs 47 pt**, **46 pt image tiles vs 22 pt SF Symbols**, **outer margin 28 pt vs 18 pt**, **two text sizes vs four**, and **no text field in the glance state**. Perry's peek stacks rows + composer + two chips + four icon buttons in 237 to 284 pt.
2. Perry has real objective defects a careful human sees even if they cannot name them: the right-edge icons sit on **five different x positions** (spread 26 pt), the composer placeholder is **brighter than the secondary text** (#C8C8D0 vs #A0A098), the onboarding header is **8 pt asymmetric** (Back 17 pt from edge, close 25 pt), the title baseline **jumps 119 / 143 / 163 px between beats**, a floating **clipped character head** at y=24, and a **clipped second option card** in the guide question.
3. Several things I expected to be wrong are fine. Icon/text baselines in chips are within 1 px. Contrast is no worse than HeyClicky's. Title/body sizes in the peek rows match HeyClicky's. The serif + SF pairing is defensible (section 4). I say so below so the fix list is not padded.
4. Separate lists: section 6 splits **objective defects** from **taste calls for the owner**.

## 1. Primary sources and the rule each one teaches

Apple HIG pages did not render through WebFetch (JS shell). I pulled the text from Apple's own JSON endpoint `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json` with curl and flattened it. Quotes below are verbatim from that text.

| # | Source | Quote (verbatim) | Rule I apply |
|---|---|---|---|
| S1 | HIG Typography https://developer.apple.com/design/human-interface-guidelines/typography | Table: "macOS \| 13 pt \| 10 pt" (default, minimum). Text styles: "Body 13 / Callout 12 / Subheadline 11 / Footnote 10 / Caption 1 10 / Caption 2 10". "Minimize the number of typefaces you use, even in a highly customized interface. Mixing too many different typefaces can obscure your information hierarchy". "Adjust font weight, size, and color as needed to emphasize important information". | 10 pt is a floor, not a target. SwiftUI `.caption` and `.caption2` are 10 pt on macOS. Hierarchy comes from few sizes plus weight and colour. |
| S2 | HIG Layout https://developer.apple.com/design/human-interface-guidelines/layout | "Group related items to clearly express related information or functions. For example, you might use negative space, container shapes, or separator lines". "Use progressive disclosure to make layouts cleaner and easier to interact with. An interface with too much content and too many choices makes it harder to find information quickly". "Align elements to make them easier to scan... People assume that aligned items are related to each other". | Gap between groups must exceed gap within groups. Cut choices from the first view. Shared edges mean shared meaning, so stray edges mean noise. |
| S3 | HIG Designing for macOS https://developer.apple.com/design/human-interface-guidelines/designing-for-macos | "the viewing distance can range from about 1 to 3 feet". "maintaining a comfortable information density that doesn't make people strain to view the content they want." | Small grey text on a dark overlay is judged at arm's length, not at retina-zoom. |
| S4 | HIG Buttons https://developer.apple.com/design/human-interface-guidelines/buttons | "Keep the number of prominent buttons to one or two per view. Presenting too many prominent buttons increases cognitive load". "a button needs a hit region of at least 44x44 pt". "Use style, not size, to visually distinguish the preferred choice". | One cream primary per view (Perry mostly obeys). 44 pt is the HIG's general figure; the 28/32/44 table on that page is visionOS only, so I treat Perry's 26 to 28 pt pointer targets as a taste call, not a defect. |
| S5 | HIG Dark Mode https://developer.apple.com/design/human-interface-guidelines/dark-mode | "make sure the contrast ratio between colors is no lower than 4.5:1. For custom foreground and background colors, strive for a contrast ratio of 7:1, especially in small text." "Avoid using hard-coded color values or colors that don't adapt." (The page does **not** say "avoid pure black"; I do not claim it.) | Small text on dark should target 7:1. |
| S6 | HIG Color https://developer.apple.com/design/human-interface-guidelines/color | "Consider choosing a limited color palette that coordinates with your app logo. Subtle use of color can help you communicate your brand while deferring to the content." (Another passage on reserving colour for "status indicators or primary actions" is written about Liquid Glass; I cite it only as supporting.) | One accent, used for state and primary action. |
| S7 | HIG Onboarding https://developer.apple.com/design/human-interface-guidelines/onboarding | "design a flow that's fast, fun, and optional." "Postpone nonessential setup flows or customization steps. Provide reasonable default settings so most people can immediately start interacting". "if you try to teach too much, people can feel overwhelmed". "Otherwise, present a permission request when people first access the specific function that relies on private data". | Perry's 7 beats plus a 3-question interview plus apps is the opposite of this. |
| S8 | HIG Motion https://developer.apple.com/design/human-interface-guidelines/motion | "Add motion purposefully, supporting the experience without overshadowing it." "Aim for brevity and precision in feedback animations." "In apps, generally avoid adding motion to UI interactions that occur frequently." "Let people cancel motion... don't make people wait for an animation to complete." | Hover-to-open happens many times a day. Keep it short, no overshoot. |
| S9 | SwiftUI `ConcentricRectangle` https://developer.apple.com/documentation/swiftui/concentricrectangle | "A rounded corner of a rectangle is [concentric] relative to the container shape's adjacent corner when the corner's radius shares a common center with the containing shape's rounded corner radius." Secondary arithmetic (Cloud Four https://cloudfour.com/thinks/the-math-behind-nesting-rounded-corners/): `--inner-radius: calc(var(--outer-radius) - var(--padding))`. | Inner radius = outer radius − inset. |
| S10 | WWDC20 10175 "The details of UI typography" https://developer.apple.com/videos/play/wwdc2020/10175/ | "We designed SF Text for small sizes below 20 points and SF Display for 20 points and above." "Throughout the system, we have used New York and SF Pro Rounded in our apps, like here with the Books and Reminders app. But it is worth noticing that they don't just work as stand-alone typefaces, they work really well with our text styles too." | Evidence that serif display + SF body is an Apple-sanctioned pairing. |
| S11 | WWDC17 802 "Essential Design Principles" https://developer.apple.com/videos/play/wwdc2017/802/ | "The principle of consistency is about representing similar design features in similar ways... Consistency also applies to the location and the configuration of controls." | Same control, same place, same size, same hover. I could not verify a talk titled exactly "Principles of great design"; 802 is the closest I could open. |
| S12 | WWDC18 803 "Designing Fluid Interfaces" https://developer.apple.com/videos/play/wwdc2018/803/ | "people are really, really sensitive to latency. You know? If you introduce any amount of lag, things all of a sudden just kind of fall off a cliff". | Do not put a 120 ms delay before panel content appears. |
| S13 | Rauno Freiberg, Invisible Details of Interaction Design https://rauno.me/craft/interaction-design | "Fitts's Law states that the time to click on something depends on distance and size." "magic corners... because the target area is infinitely large." "I removed motion from core interactions and suddenly felt like I was moving much faster." | Controls pinned to a screen edge (the notch panel's top corners) should extend their hit area to the edge. Frequent motion costs. The fetched page does not cover optical alignment or hit areas; I do not attribute those to Rauno. |
| S14 | Emil Kowalski, 7 practical animation tips https://emilkowal.ski/ui/7-practical-animation-tips | "A scale of 0.97 on the :active pseudo-class should do the job". "Don't animate from scale(0)... 0.9+". "If you are animating something that is entering or exiting the screen, use ease-out." "UI animations should generally stay under 300ms." "Use blur when nothing else works". Also https://emilkowal.ski/ui/good-vs-great-animations: "you should default to ease-out in most cases." | Check Perry's curves and durations against these. |
| S15 | Linear, How we redesigned the Linear UI https://linear.app/now/how-we-redesigned-the-linear-ui | "to reduce visual noise, maintain visual alignment, and increase the hierarchy and density of navigation elements." "return to a more neutral and timeless appearance." "instead of having to define 98 specific variables for each theme, we defined three: base color, accent color, and contrast." "aligning labels, icons, and buttons, both vertically and horizontally". | Few colour variables. Alignment of icons and labels is a stated goal of a premium redesign. |
| S16 | Raycast, A fresh look and feel https://www.raycast.com/blog/a-fresh-look-and-feel | "we have three design principles: fast, simple, and delightful." "The icons follow the same rules for stroke width and corner radii." | One rule set for icon weight and radii. |
| S17 | Refactoring UI (secondary summaries only; I could not open the book) https://dev.to/updivision/book-review-refactoring-ui-by-adam-wathan-steve-schoger-2f7m | Summaries state: start with more white space than you think you need; use a constrained spacing scale; "close together means related". | Treated as supporting, not primary. |

Could not open: Cultured Code's own Things writing (search returned only third-party reviews: MacStories, Sweet Setup, MacRumors; they agree on "lots of white space"). Raycast's post does not discuss spacing or colour, so I cite it only for icon rules. Emil's "great animations are fast" section was not on the fetched page; the 300 ms figure comes from his tips page above.

## 2. Measurement method and caveats

- Perry renders are 1x offscreen PNGs, so 1 px = 1 pt. The shadow, the dialogs rendered on white (dialog-inline, dialog-stacked, dialog-ok-only), and 1 px capsule-end ticks are harness artifacts; I did not judge them.
- HeyClicky `5088e2bf` (permission card) and `e873275e` (drag helper) are 144 dpi, 2x, so pt = px / 2 exactly.
- HeyClicky `b7e37725` (peek) and `34901b52` (settings) are 2000 px wide full-screen grabs. I infer 1.157 px/pt (a 1728 pt display): the menu bar "F" cap height measures 11 px, SF cap height for 13 pt is 9.2 pt, so 11 px / 1.157 = 9.5 pt. **Treat those pt values as ±10%.** Ratios between HeyClicky elements are exact either way.
- Gaps are ink-to-ink (glyph bounds), not layout boxes.
- Distinct text sizes for Perry are read from cap heights and confirmed against `PerryTheme.Scale`; HeyClicky sizes come from cap heights only.

## 3. Measured table: R (HeyClicky) vs C (Perry current)

### 3a. Notch peek, the daily glance

| Metric | R: HeyClicky peek (b7e37725) | C: Perry peek-working | C: Perry peek-needs-you |
|---|---|---|---|
| Body size | 441 x 251 pt (510 x 290 px) | 404 x 237 pt | 404 x 284 pt |
| Fill | #1C1C1B, black at top fading to #1C1C1B by 92 pt | #000000 flat | #000000 flat |
| Outer margin L / R / bottom | 28.5 / 30 / 20.7 pt | 18 / 18 / 15 pt | 18 / 18 / 15 pt |
| Header chrome band | y 9 to 36 px (23 pt pill + two glyphs), content starts 53 pt | y 7 to 17 (glyphs only), content starts 44 | same |
| Row pitch | 63 pt (73 px) | 47 pt | 47 pt |
| Row leading visual | 46 pt image tile (53 px) | 22 pt SF Symbol | 22 pt SF Symbol |
| Gap within group (title to subtitle, ink) | 8.6 pt | 7 pt | 7 pt |
| Gap between groups | 21.6 (header to row), 35 (rows to footer) | 16 (row to row), 17 (rows to composer), 10 (composer to chips) | same |
| Group / within ratio | 2.5 to 4.1 | 1.4 to 2.4 | same |
| Title size/weight | cap 12 px, about 13.5 pt semibold | 14 pt semibold | 14 pt semibold |
| Body size | cap 11 px, about 12 pt | 12.5 pt | 12.5 pt |
| Distinct text sizes in view | 2 (about 13.5, 12) | 4 (15 composer, 14, 13 chips, 12.5) | 4 |
| Distinct greys (surface, text, stroke) | 5 (#1C1C1B panel, #282828 chip, #3A3A3A divider, #E8-F0 text, #909098 sub) | 8 (#000, #161618 composer, #222226 chip, #2A2A2D border, white 8% divider, white 8% hover, #F0F0E8, #A0A098) | 8 |
| Competing focal points | 2 (avatar column, one pale-green CTA) | 3 (row titles #F0F0E8; composer placeholder #C8C8D0; chips #A6A49E) | 4 (adds cream "Review" pill) |
| Interactive controls | 8 (Update app, info, gear, 2 rows, Apps+, Invite and Earn, expand) | 9 (…, ×, 2 rows, field, mic, Apps, History, expand) | 12 (3 rows, plus the above) |
| Panel bottom radius | about 16 pt | 22 pt (NotchShape.open) | 22 |
| Inner radii | chips and CTA capsule | field 14, row hover 10, chips capsule | same |
| Footer button height | 32 pt chips, 34 pt CTA | 28 pt chips | 28 pt chips, 26 pt "Review" |
| Colour accents in view | 3 (orange pill, blue play, pale green CTA) | 1 (mint spinner) | 1 to 2 (amber/white "!", cream pill) |

Reading: control count and accent count do **not** explain the gap. Space, tile size, size count and the missing field do.

### 3b. Permission card / helper

| Metric | R: HeyClicky card (5088e2bf, 2x exact) | C: Perry onboarding-3 access | R: HeyClicky helper (e873275e, 2x) | C: Perry helper (accessibility-instruction) |
|---|---|---|---|---|
| Headline | cap 21 px = 10.5 pt, about 15 pt bold | 26 pt serif | about 13 pt medium, one line, 261 pt wide | 15 pt bold title, 2 body lines 12 to 13 pt, 11 pt footer |
| Body | about 13 pt, grey #9090A0 | 14 pt rows + 12 pt detail | none | inline bold span in body |
| Distinct text sizes | 2 | 4 (26, 14, 13, 12) | 1 | 4 (15, 13, 12, 11) |
| Controls | 1 button (81 x 42 pt), 3 pills, … and × | Back, ×, 2 Allow, Not now, 7 progress pills | arrow chip, drag chip (app icon + name) | ×, drag row, "List not showing?", arrow |
| Panel | n/a (full-width crop) | 524 x 399 pt | 517 x 112 pt | 358 x 172 pt |
| Text items | 2 | 8 | 2 | 6 |
| Gaps (ink) | dots to title 13 pt, title to sub 9, sub to button 18.5 | art to title 20 px, title to rows 13 px, rows 9 px, rows to "Not now" 30 px | n/a | title to body 7, body lines 6, body to drag row 16, row to footer 14 |
| Button | glossy blue gradient capsule | cream capsule 180 x 47 | n/a | n/a |

Note: HeyClicky's permission card uses glossy Aqua-style pills and a blue-tinted grey (#9090A0). That is a stylistic bet. I do not recommend copying it. The takeaway is **two text items**, not the gloss.

### 3c. Onboarding frames (Perry only, measured)

| Beat | Title top (y px) | Title size | Elements | Notes |
|---|---|---|---|---|
| 1 hello | script art 83 to 166 | ink | art, 2 body lines, field, Continue | character head clipped flat at y=24 |
| 2 brain | 119 | 26 serif | 2 option cards 112 tall, Continue | |
| 3 access | 163 (art 69 to 143 above) | 26 serif | art, 2 rows, Not now | |
| 4 shortcuts | 119 | 26 serif + 15 sub | card 99 tall, checkbox, Continue | |
| 5 interview | 143 | 26 serif | 2 body lines, Start, Skip | |
| 6 apps | 119 | 26 serif | 1 sub + rows (not rendered here) | 146 px void in this render |
| 7 firstGoal | 143 | 26 serif | field, Start, Not now | |

Title top moves 119, 163, 119, 143, 119, 143. Header: Back chevron left edge x=51 (17 pt from body edge 34); close glyph right edge x=533 (25 pt from body edge 558).

### 3d. Workspace (conversation / history)

Body 524 x 399 pt, sidebar 148 pt wide (27%). Sidebar: wordmark (18 pt SF Rounded), search + compose, 5 nav rows at 29 pt pitch, "Recent" row, "Perrys" section label (11 pt), "Make a helper", Apps, gear. 13 controls in the rail. Section labels cap 8 px = 11 pt. Main pane title at x=354, 21 pt from the divider. Empty-state character is 47 px in a 364 px pane.

### 3e. Radii and type census (grep of `App/`)

- `cornerRadius` values in use: 5, 7, 8, 10, 12, 14, 20, 22 (eight values; 12 used 17 times, 8 used 14 times). Plus capsule.
- `Font.system(size:)` sizes: 11, 12, 12.5, 13, 14, 15, 18, 20, 26. Semantic `.caption`/`.caption2` (10 pt on macOS): 9 call sites. `PerryTheme.Typography.note` (= `.caption`, 10 pt): 15 uses, concentrated in `IntegrationRow.swift`, `SystemCalendarRow.swift`, `CustomConnectorsSection.swift`.
- Inline animation curve/duration pairs: about 28 distinct, 12 of them named tokens.
- `onHover` appears 5 times against 38 `.buttonStyle(.plain)`.

## 4. Crammed audit

Rules used: S2 (group gap > within gap, progressive disclosure), S1 (size floor, few sizes), S3 (1 to 3 ft viewing).

| View (file) | What breaks | Evidence | Fix with values |
|---|---|---|---|
| **peek-needs-you** (`App/Notch/NotchPeekView.swift:77-112`) | 12 interactive controls and 4 bright elements in 284 pt. S2 progressive disclosure. | Bands: rows at y 45/91/138, field y 186 to 230, chips y 241 to 268; ink gap field to chips 10 px. | Show at most 2 rows (`PeekRow.rows` already prefixes 2 tasks; also cap `needsYou + setup`). Delete the chip row at `:99-108`. Put mic and expand inside the field row (field trailing: mic 28, expand 28). Row pitch 47 to 60. Panel 284 to about 250. |
| **peek-working** (same) | Field and chips stack under 2 rows; ink gaps 16 / 17 / 10 / 15 are not a scale. | y bands 91-122 / 139-183 / 194-221, panel bottom 237. | `VStack(spacing: 10)` at `:77` to 16. Chip row removed. Bottom inset 16 to 20 (`NotchLayout.swift:30`). |
| **task-working** (`App/Notch/…` task view, render task-working.png) | 8 items in 213 pt and ink gaps 7 / 11 / 11 / 21 / 13 px. No rhythm. | y bands 37-69, 76-79 (progress), 90-116 (3 buttons), 127 (hairline), 148-167 (hint), 180-192. | Gaps 8 / 16 / 16. Drop the hairline. Merge "Hold ^⌥ to steer" and "Type instead" into one 11 pt secondary line; "Take over" stays, "Pause" and "Stop" become icon-only 28 pt buttons. |
| **guide-question** (`guide-question.png`) | Second option card is cut off at the panel bottom (visible 34 px of about 40). Reads as a rendering bug. | y 126 to 159, panel bottom 175, no bottom border on card 2. | Size the panel to content (`NotchLayout.size` uses `entry.contentHeight`; this entry under-reports by about 8 pt) or add a 16 pt bottom fade and make the list scroll with a visible edge. Minimum two full cards. |
| **approval-long** | 3-line body clipped with "…." plus "Show more" plus two buttons; fine structurally. Body 13 pt #A0A098 is OK. | bands 38 / 61 / 95 / 127 | Only change: gap label to title 13 to 8 px (label and title are one group), title to Target 22 to 16. |
| **Permission helper** (`App/Permissions/PermissionHelperPanel.swift:141`, `AppBundleDragView.swift:116`) | 6 text items, 4 sizes, plus ×, plus a link. HeyClicky does the job with 2 items. S2, S7. | 358 x 172 pt vs 517 x 112 pt; text bands 15 / 10 / 10 / 11 px. | Keep: arrow, one 13 pt medium line ("Drag Perry into the list above."), the drag row. Move "Then switch it on in Device Control and Data Access" and "macOS will ask for your password" into the drag row's trailing text at 12 pt, delete the footer row, move "List not showing?" behind a "?" icon. Panel 172 to about 120. |
| **Settings rows** (`IntegrationRow.swift:56-153`, `SystemCalendarRow.swift:22-51`) | 10 pt descriptions (`Typography.note` = `.caption`). Cap height 7 px measured in apps.png. At the S1 floor, tertiary colour under S5's 7:1. | apps.png 'E' cap 7 px, title 'C' cap 10 px, colour #A0A098 on #161618 = 7.3:1; tertiary #8B8A85 on #232326 = 4.5:1. | `PerryTheme.Typography.note` to `Font.system(size: 12)` (S1 Callout). Row heights grow about 2 pt. Use `textSecondary` not `textTertiary` for any text under 12 pt. |
| **Sidebar labels** (`NotchWorkspaceView.swift:149,182,189,385`) | 11 pt semibold section labels ("Recent", "Perrys") cap 8 px, plus "Perrys" is a plural invented word. | conversation.png y 271 to 278 | 11 pt is above the floor; use `textSecondary`. Rename "Perrys" to "Helpers" (taste; the button below already says "Make a helper"). |
| **Workspace rail** (`NotchWorkspaceView.swift`) | 13 controls in 148 pt; five peer nav rows including Suggestions whose own content is an off-by-default toggle and a fake example card. | suggestions.png | Fold Suggestions into Tasks as a section, fold Files into Tasks. Rail: Tasks, Routines, History. Product call. |
| **Onboarding** (`OnboardingDirector.Beat`, `InterviewBeat.swift:248`) | 7 beats, then a 5-screen interview, with a second progress indicator (same pill style) inside beat 5 while the top bar shows the 7-beat one. 12 screens before first use. S7. | `OnboardingProgress` used at `OnboardingNotchView.swift:20` and `InterviewBeat.swift:248`. | Keep hello, brain, access, shortcuts, firstGoal. Move interview and apps to a card after the first completed task ("Make Perry yours"). One progress indicator per screen. |
| **Status menu** (owner screenshot 5b8bcb5e) | 19 rows at that time, mixing user commands with "Retry last task", "Memory:…", "Erase all Perry data…" next to "Notch status". | Old screenshot; I did not re-verify the current menu. | Re-check `StatusMenuController.swift`. Target 8 rows: Ask, Tasks, History, Settings, Check for Updates, Quit, plus a Developer submenu. |

## 5. Premium audit

### 5.1 Typography

**Keep the serif display + SF body.** Reasons:
- S10: Apple says New York and SF "work really well with our text styles too" and ships the pairing in Books and Reminders.
- Perry uses the serif only at 20 and 26 pt (`PerryTheme.Scale.heading`, `.display`), where New York's display optical size is active (S1: dynamic optical sizes). Body stays SF.
- It is the one thing that makes Perry not look like every other dark AI panel. HeyClicky uses a 15 pt bold sans headline; Perry's serif headline is the single most distinctive move in the product.

**Fix the family count.** S1 says minimize typefaces. Perry runs New York, SF, SF Rounded (`Scale.wordmark` at `PerryTheme.swift:55`, `Scale.keycap` at `:62`) and SF Mono, plus a hand-drawn ink "hello." Four voices in the first minute. Make the wordmark `design: .serif` 18 semibold (match the headings) and make `keycap` plain SF 12 medium.

**Size count.** Peek: 4 sizes (15, 14, 13, 12.5) vs 2 for HeyClicky. Collapse to row title 14 semibold, secondary 12, chip 12 medium, composer 14. That drops `Scale.input` 15 and `Scale.chip` 13 and `Scale.secondary` 12.5 in notch views. `12.5` is a half-point size that exists nowhere in S1's table; use 12.

**Floors.** Move `Typography.note` (10 pt) to 12 and `monoSmall` (10 pt) to 11. Replace `textTertiary` for sub-12 pt text with `textSecondary` (S5 7:1 target; tertiary is 5.2:1 on surface, 4.5:1 on chip).

### 5.2 Colour

- **Notch black.** The hardware notch is black, so a pure-black closed state and crown is right. The open panel being pure black too is a choice: surface steps are 1.16:1 (#161618 vs #000), border 1.47:1 (#2A2A2D). HeyClicky lifts the body to #1C1C1B (1.23:1 over black) and fades from black at the notch edge over 92 pt, so the panel melts out of the notch and still reads as a slab. Perry's `NotchShape.surface(crown:)` (`NotchShape.swift:40-53`) already has that fade but `PerryTheme.Colors.canvas` is `0x000000`, so the fade does nothing. **Taste call**: the commit `6bb68cc` ("black notch") chose black deliberately. Render both before deciding.
- **Undertones disagree.** Text is warm (#F5F2EA, #A6A59F has B 7 below R), surfaces are cool (#161618 +2 B, #222226 +4 B, #2A2A2D +3 B), and the rendered placeholder is #C8C8D0 (cool). HeyClicky's panel is neutral warm (R=G, B−1). Pick one. Recommendation: warm surfaces `surface 0x181817`, `chip 0x242423`, `separator 0x2D2D2B`.
- **Greens.** Character fill #98C8B0 (sage), accent #78E0B8 (neon mint, measured in the progress pill and "Allowed"), input border #487C68, `success` #5FD38D. Three greens plus a tint. The accent is not overused per frame (2 to 3 touches), the problem is that it does not match the character it sits next to. Set `accent` dark to a value on the character's hue (148 degrees), for example `0x9ADBBE`, and map `success` to `accent`.
- **Two oranges.** "Needs your OK" renders #F89030 (`systemOrange`, `PerryTheme.swift:22`), while `caution` is #FFB020 (`:21`). Pick one.
- **Contrast.** Perry: text 18.8:1, secondary 8.5:1, tertiary 6.1:1 on black. HeyClicky subtitle #909090 on #1C1C1B: 5.3:1. Perry is at least as readable; do not "fix" contrast to match.
- **Placeholder.** Rendered #C8C8D0 on #161618 = 10.9:1, brighter than the row subtitle (#A0A098) and close to the title (#F0F0E8, 16:1). It is the loudest non-title element in the peek.

### 5.3 Materials and depth

- Shadow stack (`NotchShape.swift:51-52`): 2 pt / 1 pt at 35% and 18 pt / 8 pt at 45%. Fine over light content. Over a dark window (the T3 window in HeyClicky's own screenshot, pixels 10 to 20) a black panel with a bottom border at #0D0D0D has no visible edge, so it reads as a hole. HeyClicky's #1C1B1B over the same window has a visible lift (28 vs 11).
- The 1 px top-to-bottom gradient border (`white 0 to 10%`) peaks at about #1A1A1A at the bottom edge, measured #0D0D0D in peek-working (col x=300, y=237). Raise the bottom end to `white 0.16`.
- No materials (vibrancy/blur) are used. That is consistent for a notch that must match hardware black. Do not add them.

### 5.4 Motion (read from `PerryTheme.Motion`, `NotchMotion`, `OnboardingNotchView.swift`)

| Token / site | Value | Against | Verdict |
|---|---|---|---|
| `PerryTheme.Motion.panelStateChange` | easeOut 0.16 | S14 ease-out, under 300 ms | Good |
| `snap` | snappy 0.16 | S14 | Good |
| `enter` (`PerryTheme.swift:107`) | cubic-bezier(0.23, 1, 0.32, 1), 0.5 s | S14 ease-out good; 0.5 s over 300 ms | Fine for once-per-install onboarding; used by the progress pill too (`OnboardingNotchView.swift:21`), shorten to 0.32 there |
| `draw` | cubic-bezier(0.65, 0, 0.35, 1), 0.9 s | decorative, one-off | Fine (S14 and S13 are about frequent motion) |
| Beat enter (`OnboardingNotchView.swift:71`) | x 36 + blur 10 + opacity | S14: "Use blur when nothing else works" | Blur 10 to 4 |
| Beat exit (`:72-73`) | cubic-bezier(0.4, 0, 1, 1), 0.2 s (ease-in) | S14: "entering or exiting... use ease-out" | Objective miss. Use (0.23, 1, 0.32, 1), 0.18 s |
| `NotchMotion.open` (`NotchMotion.swift:4`) | spring 0.38 / 0.82 | S8 frequent motion; 0.82 damping overshoots | Hover-open runs all day. Use response 0.30, damping 1.0 |
| `NotchMotion.contentIn` (`:7`) | easeOut 0.20 after 0.12 delay | S12 latency; content shows 320 ms after hover | delay 0.04, duration 0.16 (content by 200 ms) |
| `contentOut` (`:8`) | easeIn 0.10 | S14 | ease-out 0.10 |
| Other inline | about 28 distinct curve/duration pairs | S11 consistency | Fold into the 5 `PerryTheme.Motion` tokens |
| Press scale | 0.97 on InkButtonStyle | S14 | Good |
| `PeekSpinner` | linear 0.9 s | continuous spinner, linear is right | Good |

### 5.5 Character art and grain

- **Character (PerryCharacter\*.swift, rendered in mascot-\*.png, hello, access art).** Distinct and consistent; the sage fill on black is calm. Defect: the hello peek clips the head flat. `NotchPeek` (`HelloGreetingView.swift:168-171`) frames the 44 pt character to `size * 0.8` and `.clipped()`; at rest the top 20% is cut by a straight line at y=24, 24 pt **below** the panel top, so the clip edge floats in empty black (crop: `/tmp/audit/crops/hello-top-4x.png`). A "peeking from behind" gag only works if the occluder is the notch edge at y=0. Anchor the frame at y=0, or drop `.clipped()` and show the whole head.
- **Status glyphs on the peek are generic SF Symbols** (`exclamationmark.circle`, `checkmark.circle`, spinner at 15 pt medium, `NotchPeekView.swift:154-178`), which is what the owner called "sorta ugly". HeyClicky puts a 46 pt illustrated tile in the same slot. Use Perry's own character, 36 pt, with a state badge (mint dot for working, check for done, amber dot for needs-you). `PerryCharacterView(pose:size:)` is already used for `.perry` rows (`:168`).
- **SketchbookGrain** (`OnboardingParts.swift:258-273`). Specks are white at 3 to 8% alpha, 0.8 px. Measured on onboarding-2: in a 140 x 90 px empty region, 12024 of 12600 pixels are exactly #000, the rest #01 to #05; in peek-working I found at most #0C. That is under 5% luminance: invisible as texture, visible as dust on a bright display, and it makes the panel black differ from the hardware notch black. It also draws `w*h/60` rects (about 4000 in the 560 x 430 frame) every layout. **Remove** unless the owner wants a real, visible texture (then raise alpha to 0.10 to 0.16 and say so). The character art already provides the hand-made feel.

### 5.6 Small stuff

| Item | Result | Evidence |
|---|---|---|
| Icon + text baseline in chips | **Pass** (within 1 px) | Apps: icon y 204-213 (centre 208.5), cap 205-214 (centre 209.5); History: icon 202-213, 'H' 203-212, both centre 207.5; chip centre 207.5 |
| Row icon vs two-line text block | Pass | check circle y 99-113 (centre 106), text 92-119 (centre 106) |
| Right-edge icon columns in peek | **Fail, 5 edges** | content edge 480; close glyph right edge 488 (+8); Review pill 473 (−7); expand 471 (−9); mic 462 (−18, inside field). Centres: … 453.5, mic 457.5, expand 465.5, close 483.5 |
| Header symmetry in onboarding | **Fail, 8 pt** | Back glyph left edge 17 pt in; close glyph right edge 25 pt in. Cause: close uses `OnboardingLinkStyle` which adds `.padding(.horizontal, 10)` (`OnboardingParts.swift:90`) on top of the 26 pt frame and the stack's 6 pt padding (`OnboardingNotchView.swift:43`). |
| Hit target | 28 x 28 close/expand (`NotchWorkspaceView.swift:578`), 26 x 26 onboarding close (`OnboardingNotchView.swift:35`), chips 28, Review 26 | S4 says 44; macOS pointer UIs ship 24 to 32. **Taste.** The one place to act: the peek close sits at y 8 to 17 under a screen edge. S13 Fitts: extend its `contentShape` up to y=0 and right to the body edge so it is hit by throwing the cursor into the corner. |
| Hover states | **Gap** | `PeekChipStyle` (`NotchPeekView.swift:196-206`), `RowButtonStyle` (`OnboardingParts.swift:150-163`, used by Allow, Connect, Try it) and the mic have no hover; only rows and `InkButtonStyle` do. S11 consistency. |
| Focus rings | **Gap** | Only `InkButtonStyle` draws an accent capsule ring (`InkButtonStyle.swift:48-53`). The other custom styles fall back to the system rectangular ring around a capsule label. `.focusEffectDisabled()` on three fields (`FirstGoalBeat.swift:96`, `InterviewBeat.swift:269`, `OnboardingBeats.swift:93`) is paired with a custom border, which is correct. |
| Concentric radii | Partial | Panel bottom 22. The bottom-left "Apps" chip sits 16 pt up and 18 pt in with a capsule (r=14). Concentric would be 22 − 16 = 6. Capsule in a corner is a common compromise, but with the chip row removed (section 6, #1) the issue disappears. Eight distinct radii in code (5, 7, 8, 10, 12, 14, 20, 22). Ladder: 8 control, 14 card/field, 22 panel, capsule. |
| Dialogs | Not judged | The three `dialog-*.png` renders have a white background and near-invisible white text; harness artifact. Please re-render on black. |
| Eyes (closed state) | Pass | 7 x 12 pt capsules (`NotchEyes.swift:230`), 8 pt apart, in the right wing. |

## 6. Ranked 15 changes

Each row: file, exact values, source rule. **O** = objective defect (a rule or a measurement is broken). **T** = taste call for the owner.

| # | Change | File and values | Source | Type |
|---|---|---|---|---|
| 1 | Peek glance state: remove the "Apps" and "History" chips; put mic and expand inside the composer row; show at most 2 rows | `NotchPeekView.swift:99-108` delete HStack; `WorkspaceComposer` gets trailing expand button (28 pt); `PeekRow.rows` cap `urgent.prefix(2)`. Panel 237 to about 200 pt, 284 to about 250 | S2 progressive disclosure; R has no field | T (largest) |
| 2 | Bigger rows with a character tile instead of a symbol | `NotchPeekView.swift:123` `.frame(width: 36, height: 36)`, tile fill `chip`, radius 10; row `.padding(.vertical, 10)` for 60 pt pitch; divider `.padding(.leading, 54)` (`:84`); `NotchLayout.contentInset` 18 to 24 (`NotchLayout.swift:31`), peek width 440 to 480 (`:51`) | S2 whitespace; measured R pitch 63 pt, tile 46 pt, margin 28.5 pt | T |
| 3 | One right edge in the peek | Header buttons trailing padding so glyph right edge = 480: close frame right edge at 488 (i.e. trailing inset = `contentInset` − 8); expand and Review pill frame right edge = 480; mic stays inside field with 8 pt trailing | S2 alignment; S15 Linear; pixels 488 / 473 / 471 / 462 vs 480 | O |
| 4 | Placeholder is tertiary, not near-title | `WorkspaceComponents.swift:36`: `TextField("", text:, prompt: Text(placeholder).foregroundStyle(PerryTheme.Colors.textTertiary))` | S1 hierarchy by colour; pixel #C8C8D0 vs #A0A098 | O |
| 5 | Permission helper to two items | `PermissionHelperPanel.swift:141`, `AppBundleDragView.swift:116`: keep arrow, one 13 pt medium line, drag row; delete footer; "List not showing?" behind a "?" icon; 172 to about 120 pt tall | S2; S7 "request in context"; R 2 items | T |
| 6 | Type floor and contrast | `PerryTheme.swift:46` `note` to `Font.system(size: 12)`, `:48` `monoSmall` to 11, `:61` `secondary` 12.5 to 12; sub-12 text uses `textSecondary` | S1 10 pt floor and 13 pt default; S5 7:1 for small text; S3 1 to 3 ft | O (by rule) |
| 7 | Anchor the onboarding title and fix header symmetry | `OnboardingParts.swift:13-43`: one `titleTop` so titles sit at y=119 on every beat, art overlays above; close button trailing `-9` so glyph edge is 17 pt in (`OnboardingNotchView.swift:32-38`) | S11 consistency; S2 alignment; measured 119 / 163 / 143 and 17 vs 25 | O |
| 8 | Fix the floating clipped head | `HelloGreetingView.swift:170-171`: anchor frame at y=0 or remove `.clipped()` | S11; pixel: flat clip at y=24 | O |
| 9 | Guide question: no cut-off card | `NotchLayout.swift:52-55` use full content height for `.focused`; minimum two full option cards (about 88 pt) | S2 | O |
| 10 | Motion values | `NotchMotion.swift:4` response 0.30, damping 1.0; `:7` delay 0.04, 0.16 s; `:8` easeOut; `OnboardingNotchView.swift:72-73` exit (0.23, 1, 0.32, 1) 0.18 s; blur 10 to 4 (`:71-72`); `PerryTheme.swift:107` enter 0.5 to 0.32 for the progress pill; collapse inline curves to the 5 tokens | S8, S12, S13, S14 | O (rule) / T (values) |
| 11 | Cut first-run to five beats | `OnboardingDirector.Beat`: remove `.interview` and `.apps` from `allCases`, offer them after the first completed task; one progress indicator per screen (`InterviewBeat.swift:248`) | S7 "Postpone nonessential setup flows" | T |
| 12 | Hover and focus on every custom button | Add the 0.06-white overlay and `PerryTheme.Motion.snap` to `PeekChipStyle` (`NotchPeekView.swift:196`), `RowButtonStyle` (`OnboardingParts.swift:150`); capsule focus ring copied from `InkButtonStyle.swift:48-53` | S11; S13 | O |
| 13 | One green, one orange, one undertone | `PerryTheme.swift:18` accent dark `0x9ADBBE`; `:20` `success` = `accent`; `:21` `caution` = `:22` warning (pick `0xFF9F0A`); surfaces `0x181817 / 0x242423 / 0x2D2D2B` | S6, S15 "three variables: base, accent, contrast" | T |
| 14 | Lift the panel off the hardware black | `PerryTheme.swift:7` canvas dark `0x000000` to `0x1B1B1A`; `NotchShape.swift:43-48` crown fade already exists; bottom border end `white 0.10` to `0.16` (`:49`) | measured R #1C1C1B with 92 pt black fade; panel edge #0D0D0D | T |
| 15 | Radii ladder, remove grain, serif wordmark | Radii to {8, 14, 22, capsule}: 12 to 14 (17 sites), 10/7/5 to 8, 20 to 22; delete `SketchbookGrain` (`OnboardingParts.swift:258`, `OnboardingNotchView.swift:62`); `PerryTheme.swift:55` wordmark `design: .serif` | S9 concentric, S1 typefaces; grain pixels ≤ #0C | T |

Objective defects: 3, 4, 6, 7, 8, 9, 12 and the rule-based part of 10. Taste calls: 1, 2, 5, 11, 13, 14, 15 and the numbers inside 10.

If only three get done: **#1 + #2** (they decide whether the peek feels like a card or a form), **#3 + #4** (alignment and placeholder, both free), **#14 A/B** (render the lifted panel next to the black one).

## 7. What I checked and did not change my mind about

- Perry's title and body sizes are the same as HeyClicky's in the peek rows (14 / 12.5 vs about 13.5 / 12). "Make the type bigger" is the wrong fix.
- Perry's contrast is not worse than HeyClicky's (section 5.2).
- Mint accent per frame: onboarding-1 has progress pill, field border, character; onboarding-3 has ring, "Allowed", pill. Not overused. The issue is hue mismatch with the character.
- The notch eyes closed state looks right.
- Settings pages (general.png, apps.png) look orderly; the main issue there is 10 pt row descriptions.

## 8. Limits of this review

- HeyClicky screenshots show one state each. I cannot judge its motion, hover, or focus behaviour, only Perry's code.
- 1x renders hide subpixel antialiasing and hover/focus states. Anything about hover and focus comes from code, not pixels.
- The status-menu count comes from an older owner screenshot.
- I measured the closed-notch eyes at the render's 3x scale and converted using the code's 7 x 12 pt size.
- I did not run the app; per the rules, no builds or tests.
