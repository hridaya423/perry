# Keychain credential lifecycle — live drill (2026-10-01)

Debug build, pid 69178. Settings → Models & Advanced (opened via
`perry.settings.open` on the MCP socket).

## Save

- Filled Model ID `perry-test-model` + a throwaway API key in the
  Direct AI provider card; pressed Save credential.
- UI settled on "Credential saved in Keychain. Perry verifies it when
  the next planning request starts."
- `security find-generic-password -s dev.perry.keys -a byok.vision`
  returned the real login-keychain entry (cdat 2026-10-01T06:36:08Z).
  The `-w` secret read triggered a macOS keychain ACL prompt for the
  `security` binary (expected — ACL is app-scoped); denied cleanly.

## Remove

- "Remove credential…" → confirmation dialog: "Remove the OpenAI
  credential? Perry removes this API key from Keychain. You'll need to
  enter it again before using this provider." → Remove credential.
- `security find-generic-password` then returned
  `SecKeychainSearchCopyNext: could not be found` — entry gone.
- UI settled on "No credential is saved for direct planning."

## Verified

- Save → real Keychain write → in-app read-back status.
- Remove → confirmed delete → real Keychain deletion → empty state.
- BYOK secrets never touch plists/defaults (PRD §4).

## Also visible in capture

`settings-keychain.png` — Local skills section lists bundled app
skills (Final Cut Pro, Messages, Notes, …) with `· bundled` source
badges and per-skill enable toggles.
