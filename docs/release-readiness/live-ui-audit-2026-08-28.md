# Live UI audit, 2026-08-28

Scope: unsigned Apple Silicon Release build on macOS, dark appearance, default text size, one local account. The sample covered onboarding steps 1 and 2 plus the Voice & Input and Runtimes settings tabs. Inspection used the macOS accessibility tree, pointer activation, scrolling, and screenshots. This is a representative sample, not a WCAG conformance result or a full VoiceOver journey.

## Verified in this sample

- Onboarding opened as a key-capable dialog with a named progress element, one heading, a scroll area, and a named Continue button.
- The Accessibility permission step exposed named Back, Grant in System Settings, and Retry controls. Continue stayed disabled while the permission probe failed.
- Voice controls exposed names and values for both sliders after their duplicate visible labels were removed.
- Bundled app-skill switches exposed human-readable accessibility descriptions such as “Visual Studio Code, bundled skill” while retaining their bundle identifiers as secondary visible metadata.
- The sampled screens did not clip at the default window size. Long settings content remained reachable through a named scroll area.

## Fixed during the audit

- Voice speed, realtime response speed, and caption opacity rendered their labels twice because both the row and Slider displayed the same text. The Slider labels are now hidden visually but remain in the accessibility tree.
- Most app skills were announced only by bundle identifier. Every bundled skill now has a product name, and each switch has an explicit accessibility label.

## Still unproven

- Light appearance, increased contrast, reduced transparency, reduced motion, 200% text, and pseudo-localized copy.
- Complete keyboard-only and VoiceOver journeys, including focus restoration after dialogs and errors.
- All onboarding steps, permission recovery after changing System Settings, and the verified Finder demo.
- Integrations, Memory & Privacy, Appearance, Safety & Advanced, task execution, approvals, history, and failure surfaces.
