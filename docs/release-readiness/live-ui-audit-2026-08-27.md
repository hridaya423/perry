# Live UI audit: 2026-08-27

This audit sampled the Debug application built from the dirty worktree based on `4b768c95cb778f2a3fd41430695acdfd4785e112`. It ran on arm64 macOS 26.5.1 (25F80) through the macOS accessibility tree and exact application screenshots.

## Scope

- Onboarding steps 1 and 2 at the default 520 × 500 window size
- Settings navigation at 760 × 520
- General, Voice & Input, and Safety & Advanced settings
- Accessibility names, roles, enabled state, reading order, visible clipping, and scroll exposure
- Dark appearance

## Results

- Onboarding opened as a key-capable dialog with a named progress element, scroll area, heading, body text, and named actions. The required Accessibility step exposed Back, Grant in System Settings, Retry, and a disabled Continue action in reading order.
- Settings exposed all seven release categories without toolbar overflow: General, Voice & Input, Runtimes, Integrations, Memory & Privacy, Appearance, and Safety & Advanced.
- Voice & Input exposed named switches, pickers, sliders, text fields, secure fields, and disabled state for an incomplete dictionary entry. Dictation and per-utterance language controls appeared in the same category as speech output and realtime voice.
- Safety & Advanced presented customer-readable application names before bundle identifiers and kept experimental hosted operations outside the default General surface.
- No sampled text or control clipped at the default sizes. Long settings content remained reachable through a named scroll area.

## Open coverage

This sample does not prove the complete M7 gate. Keyboard traversal depends on the host's macOS keyboard-navigation setting and still needs a controlled test account. VoiceOver speech order, light appearance, increased contrast, reduced transparency, reduced motion, 200% text, pseudo-localized copy, every settings category, and every error state remain untested.
