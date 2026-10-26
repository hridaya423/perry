# Perry icons: why they look worse than HeyClicky's, and the system to fix it

Scope: App/ (Notch, Onboarding, Home, Settings, Permissions, Brain, Shortcuts), the renders in /tmp/audit-renders, HeyClicky screenshots R1 to R4 (attachment ids `5088e2bf`, `e873275e`, `b7e37725`, `34901b52`). Read-only. No build, no run.

Scratch tools and crops: /tmp/audit-work (measurement binaries `tools/meas`, `tools/px`, `tools/rgb`; crops in `crops/`).

---

## 0. Verdict

Perry's glyphs are not "badly drawn". They are SF Symbols at sane sizes. They look cheap for five reasons, in order of impact.

1. **Wrong tool for the job.** HeyClicky puts *colour art* where it needs identity: 40 pt circular avatars in the notch rows, real brand logos (Notion, Linear, Google Docs, Calendar) at about 20 pt in Settings. Perry puts a monochrome hairline symbol in the same slot (peek rows) or nothing at all (Settings > Apps rows), or a letter tile "N" / "L" (onboarding apps beat). Identity is carried by art, status by symbol. Perry has them swapped.
2. **Icon tone equals secondary-text tone.** Every Perry utility glyph is `textSecondary` = #A6A59F. I measured peak luminance 164 to 166 for every utility glyph (rail, chips, mic, x, expand, "..."). HeyClicky's chrome glyphs measure 210 to 220, while its description text measures 94 to 164. HeyClicky keeps icons brighter than captions. Perry merges them into one grey, so the panel reads as "everything is a caption".
3. **No single rule, so every surface drifts.** Same role, different spec: two chip styles (10 px icon vs 15 px icon, measured), two close buttons (12 semibold in 26 vs 13 medium in 28), an AppKit "..." at 13 semibold next to SwiftUI "x" at 13 medium, rail icons at 13 regular next to composer icons at 13 medium, bottom-bar icons in text colour (225 to 243) next to rail icons in grey (166). The eye catches this as "slop" even when nobody can name it.
4. **Fill and outline mixed for the same meaning.** "OK" is `checkmark.circle.fill` in 9 places and `checkmark.circle` in 5. "Warning" is `exclamationmark.circle` (about 13), `exclamationmark.triangle` (6) and `.triangle.fill` (2). Apple: fill signals selection or emphasis; outline sits next to text.
5. **Point size used where Apple intends scale.** `Icon.inline` is a hand-made "small scale" (11 pt semibold) beside 13 pt medium text. Apple's weight-matching and cap-height centring only work when the symbol uses the *same point size and weight as the text* and varies emphasis with `imageScale`.

What HeyClicky is *not* doing: it is not using a better icon set. Its sidebar and chrome icons are ordinary SF Symbols (gear.fill, info.circle, waveform, mic, command, cursorarrow, grid, gift). It is also not perfect: the GitHub logo in its integrations list is effectively invisible (measured below), and it mixes `info.circle` outline with `gearshape.fill` in the same top bar. Perry can beat it with a stricter system and fewer glyphs.

**Recommendation in one line:** keep SF Symbols for chrome, define seven roles with one spec each, move identity to art (Perry character, app icons via `NSWorkspace`, bundled brand marks), and add one `Colors.icon` token that is brighter than `textSecondary`. Do not adopt Phosphor, Lucide, Tabler or Heroicons wholesale.

---

## 1. Inventory

54 `Image(systemName:)` sites, about 45 more via `Label(_, systemImage:)`, `Button(_, systemImage:)`, and 9 `Image(nsImage:)` app-icon sites. No custom icon assets exist (`App/Assets.xcassets` holds only `AppIcon`). Character art is `PerryCharacter*`. No site sets `symbolRenderingMode`, `symbolVariant` or `imageScale`. Rendering mode is monochrome everywhere, scale is medium everywhere, and the only knobs used are point size, weight and colour.

Current tokens (`App/PerryTheme.swift:68-72`):

| Token | Value |
|---|---|
| `Icon.toolbar` | system 13 medium |
| `Icon.row` | system 15 medium |
| `Icon.inline` | system 11 semibold |

Text it sits next to (`PerryTheme.swift:52-65`): body 13 regular, rowTitle 14 semibold, chip 13 medium, secondary 12.5 regular, meta 11 medium, section 11 semibold.

### 1a. Notch surfaces (what the owner called ugly)

| Symbol | file:line | Size / weight | Mode | Color | Context | Problem |
|---|---|---|---|---|---|---|
| `exclamationmark.circle` | Notch/NotchPeekView.swift:158 | 15 medium (`Icon.row`) | mono | `caution` (render shows white 255) | peek row lead, 22 pt slot | hairline circle; title is 14 semibold (weight mismatch, medium vs semibold) |
| `checkmark.circle` | NotchPeekView.swift:164 | 15 medium | mono | `success` (render shows white 255) | peek row lead | same |
| `arrow.forward.circle` | NotchPeekView.swift:170 | 15 medium | mono | `accent` | "Finish setting up" lead | third look-alike circle |
| `lightbulb` | NotchPeekView.swift:174 | 15 medium | mono | `textSecondary` | suggestion lead | bbox 9x15 px, taller and narrower than the circles beside it |
| PeekSpinner (Shape) | NotchPeekView.swift:182-194 | 13 ring, 1.6 stroke, 16 frame | n/a | `accent` | working lead | different construction from the SF circles in the same column |
| PerryCharacterView | NotchPeekView.swift:168 | 22 | art | brand | perry row lead | 22 pt, vs 40 pt avatars in HeyClicky |
| `square.grid.2x2`, `clock.arrow.circlepath` | NotchPeekView.swift:100,104 | 11 semibold (`Icon.inline` via `PeekChipLabelStyle` :208-213) | mono | `textSecondary` | peek chips next to 13 medium text | icon font != text font; measured icon 10x10 px |
| `arrow.up.left.and.arrow.down.right` | NotchPeekView.swift:106 -> NotchWorkspaceView.swift:576 | 13 medium in 28x28 | mono | `textSecondary` | expand | fine in size, dim in tone |
| `ellipsis` | NotchPresentation.swift:83-84 (AppKit `NSPopUpButton`) | 13 **semibold** | mono | `secondaryLabelColor` | "More" | only glyph on the notch at semibold; every neighbour is medium |
| `xmark` | NotchWorkspaceView.swift:364 -> :576 | 13 medium in 28x28 | mono | `textSecondary` | close | ok |
| `mic` | Home/WorkspaceComponents.swift:70-73 | 13 medium in 28x28 | mono | `textSecondary` | composer | ok size; 166 tone |
| `arrow.up` on circle | WorkspaceComponents.swift:56-60; Notch/NotchListeningView.swift:39-43 | 13 medium on 28 `primaryAction` disc | mono | `onPrimaryAction` | send | duplicate implementation in two files |
| `waveform` / `exclamationmark` / `ellipsis` | Notch/NotchEyes.swift:217-219 | 11 semibold | mono | accent / caution | closed-notch status glyph, left of the camera | the most-seen glyph; renders as three 3 px dots or a 2 px "!" (eyes-notch-working.png, eyes-notch-needs-you.png); duplicates what the eye colour already says |
| `magnifyingglass` | Home/NotchWorkspaceView.swift:105 | default (13 regular) | mono | `textSecondary` | search field | |
| `square.and.pencil` | NotchWorkspaceView.swift:120 | 13 medium | mono | `textSecondary` | new conversation | |
| `checklist`, `repeat`, `folder`, `lightbulb`, `clock.arrow.circlepath` | NotchWorkspaceView.swift:134-138 via `railLink` :376-379 | **no font** = 13 regular | mono | `textSecondary` (166) vs label `text` (245) | rail | regular weight vs medium everywhere else; icon dimmer than its own label |
| `plus` | NotchWorkspaceView.swift:189 | 11 semibold | mono | default | "Perrys" header | third weight on one surface |
| `square.grid.2x2`, `gearshape` | NotchWorkspaceView.swift:270,279 | body 13 regular | mono | `text` (225 / 243) | bottom bar | brighter than rail icons directly above them |
| `bubble.left`, `hand.point.up.left`, `bolt`, `tray.and.arrow.down` | Home/HomeModel.swift:32-39 -> NotchWorkspaceView.swift:619-625 | chip font, medium scale | mono | `textSecondary` | composer mode chip | chip icons here are 15x14 px; peek chip icons 10x10 px (two chip styles) |
| `macwindow` | NotchWorkspaceView.swift:469 | chip | mono | `textSecondary` | "Window" target chip | a symbol where the targeted app's own icon belongs |
| `cpu` | Home/HomeConversationView.swift:238 | chip | mono | | model chip | onboarding uses `laptopcomputer` for the same "On this Mac" idea (OnboardingBeats.swift:229) |
| `chevron.left`, `chevron.up` | CompactConversationView.swift:137,146 | label / 13 medium | mono | | guide / compact header | |
| `cursorarrow.motionlines`, `ellipsis`, `xmark` | GuideControlsWindow.swift:87,98,115 | label, 13 medium, 13 medium | mono | | guide controls | |
| `pause`, `play`, `hand.raised`, `stop` | AgentActivityStrip.swift:434-461 | label | mono | | activity strip | |

### 1b. Onboarding and permissions

| Symbol | file:line | Size / weight | Color | Context | Problem |
|---|---|---|---|---|---|
| `hand.point.up.left` | Onboarding/OnboardingBeats.swift:143,169 | 15 medium | `text` | Accessibility row lead | wrong metaphor; `accessibility` exists (SF Symbols 5, macOS 14) |
| `mic` | OnboardingBeats.swift:145,169 | 15 medium | `text` | Microphone row lead | ok |
| `cloud`, `laptopcomputer` | OnboardingBeats.swift:228-229, :310-312 | **20 regular** | text / accent | brain choice cards | 20 regular next to 14 semibold title |
| `largecircle.fill.circle` / `circle` | OnboardingBeats.swift:314 | 15 medium | accent / textTertiary | radio | one of 5 hand-rolled radios |
| `checkmark` | Onboarding/OnboardingParts.swift:167 | 13 medium (label font) | accent | "Allowed" | outline-free, good |
| `return` | OnboardingParts.swift:53-55; InkButtonStyle.swift:102 | 11 semibold at 0.45 opacity; caption semibold | | keycap hint | two different treatments |
| `xmark` | OnboardingNotchView.swift:33-35 | **12 semibold in 26x26** | | close | a second close button spec |
| `chevron.left` | OnboardingNotchView.swift:26 | label font | | Back | |
| `arrow.up` / `exclamationmark.circle` / `arrow.clockwise` / `checkmark.circle` | Permissions/PermissionHelperPanel.swift:174-190 | 13 medium | accent / caution / success | helper lead | outline circles again |
| `Image(nsImage:)` app icon | Onboarding/AppsBeat.swift:149-151 | 28 | | app tile | only works if the app is installed |
| monogram "N", "L" | AppsBeat.swift:152-157 | 14 semibold in 28 chip | `text` on `chip` | fallback tile | this is what the render shows (apps-tiles.png): grey squares with a letter |

### 1c. Settings, Home, Brain

| Symbol | file:line | Size / weight | Color | Context | Problem |
|---|---|---|---|---|---|
| page icons `gearshape person.crop.circle waveform mic command sparkles square.grid.2x2 lock` | Settings/SettingsPage.swift:50-61, :156-158 | default 13 regular, 18 frame | text / textSecondary | sidebar | ok in size; tone rule differs from the notch rail |
| `chevron.left`, `chevron.right` | SettingsPage.swift:108,287-288 | 11 semibold next to 13 regular text | textSecondary | back, disclosure | weight mismatch with text |
| (no icon) | IntegrationRow.swift:44-50 | | | 8 integration rows | text only; HeyClicky shows a logo per row |
| `checkmark.circle.fill` | IntegrationRow.swift:61, :269; SystemCalendarRow.swift:28; CustomConnectorsSection.swift:86; Settings/BrainSettingsPage.swift:29; Settings/PrivacySettingsPage.swift:101; Brain/LocalBrainView.swift:47,104; Home/HistoryView.swift:229 | label / default | success | OK state | fill |
| `checkmark.circle` | NotchPeekView.swift:164; BackgroundTasksView.swift:263; PermissionHelperPanel.swift:188; Shortcuts/ShortcutCheck.swift:55; HomeConversationView.swift:182 | | success | OK state | outline: same meaning, different look |
| `exclamationmark.triangle.fill` | IntegrationRow.swift:272; CustomConnectorsSection.swift:89 | | | warning | |
| `exclamationmark.triangle` | BackgroundTasksView.swift:54,258; HistoryView.swift:207; HomeView.swift:414,439; NotchWorkspaceView.swift:343 | | | warning | |
| `exclamationmark.circle` | HomeConversationView.swift:37,98,215; PerryEditorView.swift:74; AcpAgentSection.swift:46; ModelProfilesSection.swift:34,78; ShortcutCheck.swift:62; NotchStatusController.swift:197 | | | warning | third warning shape |
| `largecircle.fill.circle` / `circle` | Brain/CloudBrainList.swift:96; Brain/ModelProfilesSection.swift:50; Brain/BrainChoiceSection.swift:33; Brain/LocalBrainView.swift:125; OnboardingBeats.swift:314 | 15 medium | | radios | one control, five implementations |
| `lock.fill` in chip tile | PrivacySettingsPage.swift:36-42 | 11 semibold in 20 tile | textSecondary on chip | "Always blocked" apps | 5 of 7 rows show the same padlock tile (privacy.png); real icon only when the app is installed |
| `play.fill`, `checkmark`, `arrow.right` | VoiceSettingsPage.swift:96,120; DictationSettingsPage.swift:56 | | | | `play.fill` beside outline `trash` (routines-populated.png) |
| `person`, `xmark` | YouSettingsPage.swift:52 | 11 semibold | | remove chip | |
| `key.fill` | CustomConnectorsSection.swift:55 | | | | fill used as decoration |
| `Image(systemName: iconName)` 6 states | Home/BackgroundTasksView.swift:110-113, :257-282 | 14 semibold in 24 | `.secondary`, `systemBlue` (`Colors.active`), warning, success | task state | six unrelated shapes (`clock`, `arrow.triangle.2.circlepath`, `pause.circle`, `checkmark.circle`, `hand.raised.circle`, `xmark.circle`) and a blue that is not in the palette |
| two leading icons per row | Home/HistoryView.swift:179-193 | app icon 22 + outcome `*.circle.fill` 20 | | history row | two lead icons side by side, no hierarchy |
| `app.dashed` | HistoryView.swift:185; HomeView.swift:268 | | | missing-app fallback | |
| `change.symbol` in 30 pt tinted tile | Home/WhatsNewView.swift:26-30 | 13 medium on accent 0.12 | | what's new | **the one good pattern in the codebase**; reuse it |
| NSWorkspace app icons | HomeView.swift:262-270,370; HistoryView.swift:243; PrivacySettingsPage.swift:35 | 16 / 22 / 20 | | | three different sizes for "app icon in a row" |

---

## 2. Pixel measurements

Method: Swift/CoreGraphics scratch tools read PNGs (sRGB), find bounding boxes of pixels whose luminance differs from the local background, report peak luminance and run lengths. Perry renders are 1x offscreen, so 1 px = 1 pt. HeyClicky screenshots are 2000 px wide; the red traffic-light dot is 16 px, which matches a 12 pt dot at about 1.32 px/pt (1512 pt wide display scaled to 2000 px). I use 1.3228 px/pt for HeyClicky. All HeyClicky pt values are therefore approximate (about 5 to 10 percent).

### 2a. Icon tone against adjacent text (peak luminance, 0 to 255)

| Element | Perry | HeyClicky |
|---|---|---|
| Utility / chrome glyph | **164 to 166** (every one: rail, chips, mic, x, expand, "...") | **210 (info.circle), 220 (gear.fill)** |
| Primary row title | 242 to 245 | 236 to 244 |
| Secondary / description text | 164 to 166 | 94 (settings rows), 164 (pill labels) |
| Sidebar icon vs its label | icon 166, label 245 (icon is 32 percent dimmer) | icon 147, label 146 (identical) |
| Bottom-bar Apps / gear (Perry) | 225 / 243 | |

Perry's glyphs and its captions are the same grey. HeyClicky separates them by 100+ levels in the top bar and equalises icon and label in the sidebar. Contrast against black: #A6A59F is about 8.5:1; #D3D3D3 is about 14:1. Both pass 3:1, so this is hierarchy, not accessibility.

### 2b. Icon box sizes

| Role | Perry (pt) | HeyClicky (px, about pt) |
|---|---|---|
| Notch row lead | 15x15 circle glyph in 22 slot (peek-needs-you.png, x121-135, y52-66) | avatar 53x54 px, **about 40 pt**, colour art (b7e37725) |
| Top-right chrome | x 11x11, "..." 11x3, expand 13x13 | info.circle 17x17 px, **about 13 pt**; gear.fill 16x16 px, about 12 pt |
| Chip icon | peek: 10x10; workspace chips: 15x14 | grid 12x11 px, about 9 pt; gift 11x12 px, about 9 pt |
| Sidebar glyph | 14x13 to 15x12 | 13x13 to 13x14 px, about 10 pt tall (13 pt symbol, medium scale) |
| Brand logo in a list row | **none** (8 integration rows) / 28 grey letter tile (onboarding) | Notion 24x27 px, Linear 23x23, Docs 20x28, Calendar 28x31: **about 17 to 23 pt, native colours, no uniform container** |

### 2c. Stroke weight relative to text

Horizontal run lengths of the glyph stroke: Perry peek circles 2 px at 1x (about 1.5 to 2 pt with antialiasing); HeyClicky info.circle 2 to 3 px at 1.32 px/pt (about 1.5 to 2.3 pt). **Stroke thickness is not the gap.** Perry's 13 medium glyphs are within measurement noise of HeyClicky's. The gap is tone (2a), role (2b) and consistency (section 0, point 3). The 1x renders make Perry look thinner than it will on Retina; judge in pt, not px.

### 2d. Alignment defects found in pixels

* Peek row divider starts at x=146; the row text starts at x=152 to 153. The divider is 6 px short of the text (NotchPeekView.swift:84 uses `.padding(.leading, 34)`; real text start is 6 + 22 + 12 = 40). The lightbulb (9x15) is centred in its slot but stands 2 to 3 px taller than the circles in the same column.
* Rail icons: left edge at x=201 to 202 for checklist / repeat / folder / history but the lightbulb starts at x=205, because the symbol is narrower and centred in an 18 pt frame. Fine by Apple's rules (centre alignment), but it is visible next to flat-left neighbours.
* Peek chip icons are 10x10 against 13 medium text with cap height about 9 to 10 px; workspace chip icons are 15x14 against the same text. Two chip implementations (`PeekChipStyle`, NotchPeekView.swift:200-213 and `ContextChipStyle`, WorkspaceComponents.swift:111-141).

### 2e. HeyClicky defects (so we do not copy them)

* GitHub logo in the Integrations list: logo pixels (36,41,47) / (40,42,43) on a (41,41,41) row. Luminance difference under 3 of 255; it is invisible (R4, row 3).
* Brand marks have no shared container: Notion is a white tile, Linear a bare purple disc, Docs a bare blue page. Perry can normalise.

### 2f. Discrepancy to resolve on device

In `peek-needs-you.png` and `peek-working.png`, the row-lead symbols measure pure white (255,255,255), not `caution` (#FFB020) or `success` (#5FD38D). Code says `foregroundStyle(caution)` / `success` (NotchPeekView.swift:158-165) and the spinner next to them correctly renders `accent` (123,227,189). Either the offscreen render path drops tint on these `Image(systemName:)` views, or the render predates the code (render 18:59, file 18:32; `git diff` shows no uncommitted change to that file). I could not run the app. Check on a real notch before trusting either reading. If the tint is lost on device too, that alone explains "ugly": three white identical circles.

---

## 3. Primary sources

### 3a. Apple HIG (fetched from `developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`, the JSON behind the pages)

SF Symbols: https://developer.apple.com/design/human-interface-guidelines/sf-symbols

* Weights and scales: "Each of the nine symbol weights — from ultralight to black — corresponds to a weight of the San Francisco system font, helping you achieve precise weight matching between symbols and adjacent text, while supporting flexibility for different sizes and contexts."
* "Each symbol is also available in three scales: small, medium (the default), and large. The scales are defined relative to the cap height of the San Francisco system font."
* "Specifying a scale lets you adjust a symbol's emphasis compared to adjacent text, without disrupting the weight matching with text that uses the same point size." (This is the rule `Icon.inline` breaks.)
* Variants: "Outline is the most common variant in SF Symbols. An outlined symbol has no solid areas, resembling the appearance of text." "The outline variant works well in toolbars, lists, and other places where you display a symbol alongside text." "The solid areas in a fill variant tend to give a symbol more visual emphasis, making it a good choice for iOS tab bars and swipe actions and places where you use an accent color to communicate selection." "Symbols that use an enclosing shape — like a square or circle — can improve legibility at small sizes."
* Rendering modes: "Hierarchical — Applies one color to all layers in a symbol, varying the color's opacity according to each layer's hierarchical level." "Confirm that a symbol's rendering mode works well in every context. Depending on factors like the size of a symbol and its contrast with the current background color, different rendering modes can affect how well people can discern the symbol's details."
* "Regardless of rendering mode, using system-provided colors ensures that symbols automatically adapt to accessibility accommodations and appearance modes like vibrancy and Dark Mode."
* Custom symbols: "Create a custom symbol that's consistent with the ones the system provides in level of detail, optical weight, alignment, position, and perspective." Also: "the prohibition against using symbols — or images that are confusingly similar — in app icons, logos, or any other trademarked use." (SF Symbols are not for brand marks.)

Icons: https://developer.apple.com/design/human-interface-guidelines/icons

* "Maintain visual consistency across all interface icons in your app. Whether you use only custom icons or mix custom and system-provided ones, all interface icons in your app need to use a consistent size, level of detail, stroke thickness (or weight), and perspective. Depending on the visual weight of an icon, you may need to adjust its dimensions to ensure that it appears visually consistent with other icons."
* "In general, match the weights of interface icons and adjacent text. Unless you want to emphasize either the icons or the text, using the same weight for both gives your content a consistent appearance and level of emphasis."
* "Some icons — especially asymmetric ones — can look unbalanced when you center them geometrically instead of optically... Adjustments for optical centering are typically very small, but they can have a big impact on your app's appearance."
* "an interface icon typically uses streamlined shapes and touches of color to communicate a straightforward idea."

Sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars

* "Consider using familiar symbols to represent items in the sidebar... If you need to use a custom icon, consider creating a custom symbol rather than using a bitmap image."
* "By default, sidebar icons use your app's accent color... if you use them sparingly, fixed colors can help clarify the meaning of an icon or draw attention to it. For example, the VIP icon in Mail uses a yellow color."
* macOS: "A sidebar's row height, text, and glyph size depend on its overall size, which can be small, medium, or large."

Toolbars: https://developer.apple.com/design/human-interface-guidelines/toolbars

* "Prefer system-provided symbols without borders... Borders (like outlined circle symbols) aren't necessary because the section provides a visible container." This argues against circle-wrapped glyphs in toolbar rows; it does not forbid a tinted disc as a status badge in a content row.

### 3b. WWDC sessions (transcripts read at developer.apple.com)

* WWDC19 session 206, "Introducing SF Symbols": https://developer.apple.com/videos/play/wwdc2019/206/ . "So with iOS 13, we turned this into a system. We call these scales -- small, medium, and large. It's important to notice here that the point size of the symbol is still the same. It's just the scale that changes." "Each scale remains weight-matched with the text... the stroke thickness is adjusted to the weight of the text, and the other great benefit is that using scales means that automatically they're optically vertically-centered to the cap height." "Symbol point sizes are expressed as font point sizes. They're typographical in nature."
* WWDC20 session 10207, "SF Symbols 2": https://developer.apple.com/videos/play/wwdc2020/10207/ . "Small symbols are approximately 20 percent smaller than the medium scale and large symbols are about 30 percent larger than the medium scale. But... only scaling the symbol will make them appear to have different weights... we make some weight compensations which allow us to maintain the same stroke thickness." Hand-resizing a symbol with point size (what `Icon.inline` does at 11 vs 13) loses that compensation.
* WWDC21 session 10097, "What's new in SF Symbols": https://developer.apple.com/videos/play/wwdc2021/10097/ . Hierarchical: "uses a single color with varying opacities that add visual hierarchy to a symbol". Palette: "gives the possibility to use two or more contrasting colors". Neither helps a 13 pt glyph on black; stay monochrome.

### 3c. Alternatives (licence from the GitHub API / LICENSE files, fetched today)

| Set | Licence | Fit for native macOS | Verdict |
|---|---|---|---|
| **SF Symbols** | Apple SF Symbols licence; use limited to Apple-platform UI, never in logos or app icons (HIG quote above) | Weight and scale match system text, optical centring, vibrancy, Dynamic Type, VoiceOver for free, no dependency | **Default. Keep.** |
| Phosphor | MIT (phosphor-icons/core; Swift package `phosphor-icons/swift` MIT, latest release 2.1.0 on 2024-04-01) | 6 weights incl. duotone. Icons arrive as resizable template images, not font glyphs, so no cap-height alignment or weight matching with text; new dependency | Good *source of SVG shapes* if Perry wants a custom symbol with a friendlier voice. Not as a runtime package |
| Lucide | ISC; some icons derived from Feather under MIT (LICENSE file) | 24 grid, 2 px stroke. At 13 pt the stroke is about 1.1 pt and cannot be tied to text weight. No first-party Swift package found | No |
| Tabler | MIT | Same constraint as Lucide; very large set | No |
| Heroicons | MIT | Two styles only; Tailwind-flavoured | No |
| Custom drawn | yours | Highest cost; best brand fit; HIG says build as a *custom SF Symbol* from the template so scale and weight still work | **Yes, for at most 6 to 8 Perry-specific glyphs** (guide cursor, needs-you, working, routine, helper) once the roles are fixed |
| **Simple Icons** | CC0 for the repository, but the DISCLAIMER states: "Simple Icons is released under CC0 - though that doesn't mean to imply that all icons within the project are also CC0" and "Simple Icons cannot be held responsible for any legal activity raised by a brand... We ask that our users seek the correct permissions". Monochrome only | Single-colour logos; legal burden stays with you | Not as the shipping source. Use official brand kits or installed-app icons |
| **NSWorkspace app icons** | Public API; shows the user's own installed app | Real, correct, free | **First choice** when the app is installed |
| Official brand kits | per brand | Required for the apps Perry integrates | Second choice, unaltered. See below |

Brand-use terms (read, not legal advice):

* Linear, https://linear.app/brand : "Do not alter these files in any way", no combining "with any other graphics without written consent", no use "in a way that implies a relationship, affiliation, or endorsement", but "it is acceptable to use this stylized icon with an appropriate corner radius." Page has no integration clause.
* GitHub, https://brand.github.com/foundations/logo : "The Invertocat and our wordmark should only appear in white, black, or in few cases grey or green." "Do not use GitHub trademarks, logos, or artwork without GitHub's prior written permission." Allowed: "Using a permitted logo to link to GitHub, or to show your project integrates with GitHub." So: white mark on a dark tile is within the colour rule; do not tint it.
* Slack, https://slack.com/terms-of-service/slack-brand : "Most uses require a specific written license" (search summary of the page; I did not open the logo files). Prefer the installed Slack icon and a monogram fallback.
* Google Workspace, https://developers.google.com/workspace/marketplace/terms/branding : Google logos "or altered versions" cannot be your app's logo; I found no dedicated page for showing Calendar/Drive/Gmail icons in third-party integrations. Unverified; check before shipping.
* Notion: I did not find Notion's trademark page (only community-guideline mirrors). Unverified.

### 3d. How other Mac apps handle it (only what I could verify)

* Raycast ships its **own** 16 px icon set with light and dark variants, and exposes system app icons separately via `fileIcon`. Source: https://developers.raycast.com/api-reference/user-interface/icons-and-images and the docs source https://github.com/raycast/extensions/blob/main/docs/api-reference/user-interface/icons-and-images.md (asset names `icon-*-16@dark.svg` / `@light.svg`; `icon={{ fileIcon: __filename }}`; `mask: Image.Mask.Circle`). Takeaway: one fixed grid, per-appearance tone, real app icons for apps.
* Linear's UI redesign post: "making our text and neutral icons darker in light mode and lighter in dark mode" and "I also spent time aligning labels, icons, and buttons, both vertically and horizontally in the sidebar and tabs." https://linear.app/now/how-we-redesigned-the-linear-ui . Takeaway: neutral icons were moved *toward* higher contrast and alignment was a stated task. This supports a brighter `Colors.icon`.
* boring.notch (open-source notch app, GPL-3.0): uses SF Symbols for chrome (`Image(systemName: "gear")` in BoringHeader.swift, `speaker.wave.2.fill` in InlineHUD / TestView, `info.circle`, `calendar`, `camera.fill`). Verified with `gh search code "systemName" --repo TheBoredTeam/boring.notch`. Takeaway: the notch-app category uses SF Symbols, not a third-party set.
* **Not verified** (no primary source fetched): Things 3, Craft, Arc, CleanShot, Alcove, NotchNook, Dynamic Island. I make no claim about them.

---

## 4. Icon spec for Perry

One system. Monochrome rendering everywhere (HIG warns that other modes can hurt legibility at small sizes and on contrast; 13 pt glyphs on black gain nothing from layer opacity). Outline by default. Fill only for a selected state or the send button's disc. Symbol point size equals the adjacent text's point size; emphasis changes through `imageScale`, not `.font(size:)`.

New token (dark values chosen to land at about 210 luminance, the measured HeyClicky chrome tone; light value gives about 7:1 on #F5F3EE):

```swift
Colors.icon = color(light: 0x4A504A, dark: 0xD2D0C9)
```

Keep `textSecondary` for captions. Use `Colors.icon` for any glyph that is not inside a caption.

| Role | Where | Point size / weight | Scale | Mode | Color | Container | Alignment to text |
|---|---|---|---|---|---|---|---|
| **R1 Row lead (status)** | peek rows, tasks, routines, history, permission helper | glyph 13 semibold (matches 14 semibold title) | medium | mono | status colour (`caution` / `success` / `accent` / `danger`) on a 28 pt disc of the same colour at 0.18 | 28x28 circle, no stroke (pattern already exists at WhatsNewView.swift:26-30) | slot centre on the vertical centre of the title+subtitle block; text starts at padding + 28 + 12; divider `leading` = that same sum |
| **R1b Row lead (identity)** | Perry row, agent row, app row | art, 28 pt | n/a | art | native | Perry character as is; app icons via NSWorkspace, no extra mask | same slot as R1 |
| **R2 Rail / sidebar item** | notch rail, Settings sidebar | 13 regular (equals 13 regular label) | medium | mono | `Colors.icon` at rest; `text` when selected | none; 18x18 frame, selection pill behind row | HStack centre; glyph is cap-height centred by the scale rule; spacing 10 |
| **R3 Toolbar / utility** | close, more, expand, compose, mic, guide controls | 13 medium | medium | mono | `Colors.icon`; `text` on hover | none; 28x28 hit area, hover fill white 0.08 r7 (already `RailRowStyle`) | centre in the 28 hit area; one close button spec for every surface |
| **R3b Primary send** | composer, listening | 13 semibold | medium | mono | `onPrimaryAction` | 28 disc `primaryAction` | same as R3 |
| **R4 Inline with text** | chips, meta lines, buttons with icon, links | **same font as the text**, nothing smaller | **small** (`.imageScale(.small)`) | mono | inherits the text colour | none (chip capsule is the container) | scale rule handles cap-height; HStack spacing 5 (chip) / 4 (meta) |
| **R5 Inline status** | "Connected", "Allowed", validation, notices | text font, semibold | medium | mono | success / caution / danger | none | `checkmark` for OK, `exclamationmark.triangle` for needs attention, `xmark` for failed. **Outline only, no circles, no fills** |
| **R6 Empty state / hero** | empty tasks, history, onboarding | Perry character art at 48 to 56 pt; card glyphs 20 regular | n/a | art / mono | brand / `Colors.icon` | none | centred on the title axis |
| **R7 App / brand** | onboarding apps, Settings > Apps, Privacy list, target chip, history rows | 28 (rows) / 20 (dense lists) / 16 (inline) | n/a | art | native | NSWorkspace icon unmasked; bundled brand mark in a continuous rounded tile (radius 0.225 x size) on a neutral surface; monogram tile only as last resort | 28 slot shares geometry with R1 so the two never sit side by side at different sizes |

Resolution order for R7: installed app icon, then bundled official mark, then monogram tile. GitHub is white on a dark tile; Notion keeps its white tile; Linear and Google marks go in at native colours with the corner radius Linear's page allows. Slack and Google marks stay out until their terms are checked.

Replace tokens: delete `Icon.row` and `Icon.inline`; `Icon.toolbar` becomes `Icon.utility`; add `Icon.rail` (13 regular), `Icon.status` (13 semibold), `Icon.slot = 28`, `Icon.hit = 28`.

---

## 5. Ranked fix list

Rank = first-impression impact on the notch, then onboarding, then Settings. "Check" is the external measurement or rule that proves it.

| # | file:line | Current | Replacement | Check |
|---|---|---|---|---|
| 1 | Notch/NotchPeekView.swift:123, 156-177, 182-194 | 22 pt lead slot; four hairline SF circles at 15 medium (`exclamationmark.circle`, `checkmark.circle`, `arrow.forward.circle`, `lightbulb`); spinner is a separate shape | Slot 28. R1 disc + bare glyph: `exclamationmark` / `checkmark` / `arrow.right` / `lightbulb` at 13 semibold inside a `Circle().fill(color.opacity(0.18))` 28 pt. Spinner ring 14 pt, 1.8 stroke, same slot. Perry row: character at 28 | Re-render peek-needs-you.png. Each lead is 28x28 +/-1 px; stroke of the glyph equals the title stem width (HIG "match the weights of interface icons and adjacent text"); disc peak chroma differs from the black by more than 3:1; three leads no longer share a silhouette |
| 2 | Notch/NotchPeekView.swift:84 | `.padding(.leading, 34)` | `.padding(.leading, 6 + 28 + 12)` = 46 (read from the same constants as the row) | Divider start x equals text start x in a render (today 146 vs 152) |
| 3 | PerryTheme.swift:68-72 and Colors block | `Icon.row/inline/toolbar`; no icon colour | Add `Colors.icon`; new `Icon` tokens from section 4 | Measured peak luminance of every R2/R3 glyph is 205 to 220 in dark renders (today 164 to 166); contrast >= 3:1 non-text (WCAG) holds in light mode too |
| 4 | Home/NotchWorkspaceView.swift:576-582 (`WindowControlButton`), :120-121, :105; WorkspaceComponents.swift:70-73; GuideControlsWindow.swift:98-100; NotchPresentation.swift:70,83-84 | `textSecondary` / `secondaryLabelColor`; "..." at 13 **semibold** | `Colors.icon` everywhere; set `NSPopUpButton.contentTintColor` from the same token; ellipsis weight 13 medium | Same luminance as item 3; "..." stem width equals the "x" stem width in the same header (today semibold vs medium) |
| 5 | NotchWorkspaceView.swift:376-379; :270-272, :279-282 | Rail icons 166 vs label 245; bottom-bar icons 225 / 243 | R2 on both: `Colors.icon` at rest, `text` when selected; remove the font-less default | Rail and bottom-bar glyph luminance within 5 levels of each other; rail icon luminance within 40 of its label (HeyClicky sidebar: 1) |
| 6 | NotchPeekView.swift:208-213 and WorkspaceComponents.swift:111-141 | Two chip styles; peek chip icons use `Icon.inline` 11 semibold (10x10 px) vs workspace chips 15x14 px | One `ChipStyle`. Remove `.font(Icon.inline)`; icon inherits chip font 13 medium with `.imageScale(.small)` | Both chip rows measure the same icon height (+/-1 px) and icon height is within 1 px of the label's cap height (HIG: scales are "defined relative to the cap height") |
| 7 | Notch/NotchEyes.swift:215-221 | SF `waveform` / `exclamationmark` / `ellipsis` at 11 semibold to the left of the camera | Delete the symbol. The eyes already encode state by colour and shape. If a glyph stays, draw it as capsules with the eyes' corner radius | eyes-notch-*.png: no sub-4 px marks left of the camera; state still readable from eyes alone in greyscale (shape differs: tall amber vs round mint) |
| 8 | Onboarding/AppsBeat.swift:144-157 | `NSWorkspace` icon else a grey monogram tile ("N", "L") | `BrandMark(id:)`: installed icon, then bundled official mark, then monogram | apps-tiles.png: no letter tiles for Notion, Linear, GitHub, Google Drive, Microsoft; every tile 28x28; GitHub mark contrast vs tile >= 7:1 (HeyClicky's is under 1.1:1) |
| 9 | IntegrationRow.swift:44-50 | No leading icon on 8 rows | 28 pt `BrandMark` leading, 12 pt gap | apps-with-perry-sign-in.png: logo present on all 8 rows; title x-offset shifts by 40 px consistently |
| 10 | Onboarding/OnboardingNotchView.swift:33-35; Notch/NotchListeningView.swift:50; PermissionHelperPanel.swift:124 | Onboarding close is 12 semibold in 26; others use `WindowControlButton` 13 medium in 28 | Use `WindowControlButton` in onboarding | onboarding-2-brain.png x glyph equals notch x glyph size (11x11 px) and hit area 28 |
| 11 | Onboarding/OnboardingBeats.swift:143,169 | `hand.point.up.left` for Accessibility | `accessibility` (exists, SF Symbols 5 / macOS 14, listed in CoreGlyphs `name_availability.plist`) | Glyph matches the Accessibility icon people see in System Settings; check in SF Symbols app |
| 12 | Brain/CloudBrainList.swift:96; Brain/ModelProfilesSection.swift:50; Brain/BrainChoiceSection.swift:33; Brain/LocalBrainView.swift:125; OnboardingBeats.swift:314 | Five hand-rolled `largecircle.fill.circle` / `circle` radios at 15 medium | One `RadioMark(selected:)` view (13 medium, `accent` when selected, `Colors.icon` otherwise) | One definition; renders identical across Brain and onboarding cards |
| 13 | All OK / warning sites in 1c (`checkmark.circle*` x14, `exclamationmark.circle/triangle*` x21) | Three shapes for warning, two variants for OK | One `StatusMark(.ok/.attention/.failed)` = R5: `checkmark` / `exclamationmark.triangle` / `xmark`, outline, text font, status colour | grep finds zero `.fill` status symbols; Settings and notch show one warning shape |
| 14 | Home/HistoryView.swift:179-193, :227-232 | App icon 22 plus outcome `*.circle.fill` 20 side by side | One lead: app icon 28; outcome as an R5 mark in the meta line | Row has one lead; icon column width 28, text starts at 40 |
| 15 | Home/BackgroundTasksView.swift:110-113, :257-282 | Six unrelated state symbols, `systemBlue` for running | R1 disc keyed by state: running = accent spinner, queued = `clock` grey, paused = `pause`, blocked = `hand.raised`, done = `checkmark`, failed = `xmark`; replace `Colors.active` | tasks render: all states share the 28 slot and one palette (no `systemBlue`) |
| 16 | Settings/PrivacySettingsPage.swift:33-43 | 5 of 7 rows show the same `lock.fill` chip tile | Show the real app icon via `BrandMark`; if missing, drop the leading tile, keep one lock in the card header | privacy.png: no row repeats the same glyph |
| 17 | Home/NotchWorkspaceView.swift:469; Home/HomeView.swift:262-270; HistoryView.swift:185 | `macwindow` / `app.dashed` for "which app" | The targeted app's NSWorkspace icon at 16; fallback a monogram, not `app.dashed` | "Window" chip shows the app Perry is looking at |
| 18 | Home/HomeConversationView.swift:238; OnboardingBeats.swift:229 | `cpu` vs `laptopcomputer` for "on this Mac" | `laptopcomputer` in both | one metaphor per concept |
| 19 | Onboarding/OnboardingParts.swift:51-55; InkButtonStyle.swift:102 | `return` hint: 11 semibold at 0.45 in one, caption semibold secondary in the other | One keycap hint: label font, `.imageScale(.small)`, text colour at 0.55 | same hint pixel size on both button styles |
| 20 | Settings/SettingsPage.swift:108,287-288; NotchWorkspaceView.swift:189 | chevrons and `plus` at 11 semibold beside 13 regular / 11 semibold text | text font + `.imageScale(.small)` | chevron stem equals adjacent label stem |
| 21 | Sites that read colour (all of 1a to 1c) | Single `foregroundStyle` per symbol | Confirm tint renders on device (section 2f) | peek row glyphs measure caution / success colours, not 255,255,255 |

---

## 6. Caveats and what I did not do

* Perry renders are 1x offscreen; strokes look thinner than on Retina. I compared in pt where I could. HeyClicky measurements assume 1.3228 px/pt, calibrated on a 16 px traffic-light dot.
* I did not run Perry, so tint behaviour (2f) and hover states are unchecked.
* HeyClicky evidence comes from four screenshots only (permission prompt, helper, home notch, settings). I saw no closed-notch HeyClicky state, so nothing here compares closed-notch glyphs.
* I could not verify the Slack, Google or Notion logo-use terms beyond the snippets quoted. Treat item 8's brand list as "needs a trademark pass before any bundled mark ships".
* "No new third-party dependencies" (AGENTS.md) rules out Phosphor/Lucide as packages. Bundled official brand SVGs are assets, not packages, but they still want owner sign-off.
* SF Symbol availability checked against `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist` on this machine: `accessibility` (2023), `laptopcomputer`, `cpu`, `hand.point.up.left`, `cursorarrow.motionlines`, `app.dashed`, `checkmark`, `exclamationmark` all present; Perry targets macOS 14, which covers the 2023 release.
