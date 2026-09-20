# Perry design language

Perry is a quiet companion: spatial mint-and-ink marks drawn directly on the user's screen, native macOS surfaces, one canonical identity, one focal action per surface. It teaches by pointing (Guide) and works under supervision (Do). Nothing decorates that does not also inform.

Source of truth for tokens: `App/PerryTheme.swift` and `PerryOverlayTheme` in `Packages/PerryOverlay`. This document records stable intent and usage rules; component APIs stay in code.

## Principles

- **One canonical Perry.** One accent, one buddy, one panel shape. Per-user accent themes, novelty caption fonts, and alternate avatar styles are out of scope — they dilute recognition and multiply test surfaces.
- **One focal action.** Every surface presents exactly one primary button. Secondary actions exist but never share the prominent style. The invocation panel has one Start; the intent card has one Approve; dialogs have one recovery path.
- **Honest states.** A surface always says which of loading / empty / denied / planning / running / paused / approval / verified / unverified / failed / recovered / erased it is in. No silent transitions, no spinner without a status line.
- **Ink on glass, not chrome.** Spatial marks (strokes, halos, numbered targets) draw over the user's windows in high-contrast mint ink. Panels use system materials and stay out of the way.
- **Native macOS operation.** Rounded system type, standard controls, real panels and menus. Nothing that looks ported.

## Colors

| Role | Token | Value | Use |
|---|---|---|---|
| accent | `PerryOverlayTheme.Colors.accent` | rgb(0.204, 0.827, 0.600) mint | The single product accent: primary actions, focus ring, guide ink, buddy glow. The only decorative color Perry owns. |
| accentForeground | `PerryTheme.Colors.accentForeground` | rgb(0.024, 0.110, 0.070) | Text/icons on accent fills. |
| primaryText | `Color.primary` | system | All primary copy. |
| secondaryText | `Color.secondary` | system | Supporting copy, metadata. |
| panelSurface | `controlBackgroundColor` | system | Panel/window backgrounds. |
| mutedSurface | `underPageBackgroundColor` | system | Inset wells, secondary fills. |
| success | `systemGreen` | system | Verified results, completed steps. |
| caution | `systemYellow` | system | Warnings, unverified results. |
| warning | `systemOrange` | system | Orange-tier approvals. |
| danger | `systemRed` | system | Red-tier approvals, failures, destructive scope. |
| active | `systemBlue` | system | Running/active indicators. |
| focusRing | `accent` | mint | Focus indication always mint, never blue. |

Rules: trust-tier colors (green/yellow/orange/red) are semantic, never decorative. Mint is the only hue Perry asserts; everything else defers to the system palette so dark/light/increase-contrast modes stay correct.

## Typography

System-rounded for product voice, system text for everything else. Sizes scale with the user's text-size preference — never fixed points.

| Token | Face | Use |
|---|---|---|
| panelTitle | `.headline` rounded bold | Surface titles ("Perry"). |
| panelBody | `.body` | Prompts, primary copy. |
| panelSubtitle | `.subheadline` | Secondary lines, transcript preview. |
| panelMetadata | `.caption` medium | Status lines, progress. |
| action | `.callout` medium | Buttons. |
| note | `.caption` | Detail lines on cards. |
| mono / monoSmall / value | `.caption`/`.caption2` monospaced | Paths, identifiers, durations — data, not prose. |

Rules: the title face is the only rounded variant; novelty caption fonts are out of scope. Copy follows `docs/tone-sheet.md` — terse, factual, present tense in Do; encouraging one-instruction steps in Guide.

## Spacing

| Token | Value | Use |
|---|---|---|
| label | 1 | Icon-to-label gap. |
| tight | 2 | Dense pairs. |
| control | 6 | Between related controls. |
| inline | 8 | Grid gaps, button pairs. |
| header | 10 | Header row internals. |
| section | 12 | Between content sections. |
| panelInset | 16 | Panel content padding. |
| cardInset | 18 | Card content padding. |

## Layout & elevation

- Session panel: 390×320 min, corner radius 18, floats at panel level near the cursor — companion geometry, not a window you manage.
- Settings: 760×520 (min 680×480), standard toolbar categories.
- Intent card: 388pt wide, `.ultraThickMaterial`, radius 12, modal panel level — the only surface allowed to interrupt.
- Surfaces float only while relevant; no always-on-top chrome in idle.

## Motion

- Feedback (state changes, dots, progress): ≤150 ms. `panelStateChange` = easeOut 0.16s.
- Entrances: ≤300 ms, transforms + opacity only — no layout animation.
- Guide ink draws itself in ~200 ms; pointer glides use spring easing.
- Reduced motion removes travel and bounce; opacity/color feedback stays. No ease-in entrances, no 0.5s fades.

## Sound

Five cues (`wake`, `send`, `receive`, `done`, `fail`), each a short `.caf` under `App/Resources/Sounds`. Sounds are decorative confirmation, never the only channel — every cue has a visual counterpart. Respects system output; no ducking of user audio.

## States & components

- **Buddy**: one geometric platypus-derived sprite; states idle / listening / thinking / acting / failed read at a glance (pulse, shimmer, focus ring). No triangle cursor avatars.
- **Invocation**: Guide/Do segmented control, one prompt field focused on open, one Start. Background scope is a Do choice, not a separate action. Runtime is automatic by default.
- **Intent card**: one line of action + scope ("About to move 34 files to Trash"), Approve / Stop. Red tier requires typing the required phrase — voice never confirms red.
- **Guide marks**: numbered targets only when grounded in the current AX snapshot; a marker that loses its target is removed, never re-pointed silently.
- **Status language**: per `docs/tone-sheet.md`. Failures state what happened, what changed, what did not, and one safe next action.

## Do's and don'ts

- Do keep every surface to one primary action; don't offer parallel actions that differ only in routing.
- Do derive color from the semantic roles above; don't hardcode per-component hues or per-app accents.
- Do respect reduced motion, increase-contrast, and text scaling on every surface; the UI test fixtures prove it.
- Don't add settings for appearance variants — canonical identity is the product.
- Don't animate layout; animate transform and opacity.
- Don't let a marker, sound, or status line outlive the state that created it.
