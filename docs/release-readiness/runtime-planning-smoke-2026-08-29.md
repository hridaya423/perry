# Runtime planning smoke: 29 August 2026

Revision: dirty Perry 1.0 implementation wave

Machine: Apple Silicon macOS test host

Harness: `LiveRuntimePlanningSmokeTests`

The harness asks each configured CLI runtime for one read-only typed action. It uses the same planner adapter as Perry and disables Claude tools for the request.

| Runtime | Result | Evidence |
| --- | --- | --- |
| Claude Code | Passed | Authenticated planning returned one `pressKey` action in 10.2 seconds. |
| Bundled Codex | Not run | Perry's isolated `CODEX_HOME` is not signed in. The harness did not read or copy credentials from the user's global Codex home. |
| OpenCode | Failed | The CLI reached its configured provider, which rejected the request because the account had insufficient balance. |
| OpenAI direct | Not run | Explicit test key and model variables were absent. |
| Anthropic direct | Not run | Explicit test key and model variables were absent. |
| Gemini direct | Not run | Explicit test key and model variables were absent. |
| OpenRouter direct | Not run | Explicit test key and model variables were absent. |

This run proves the Claude planning adapter against a live authenticated CLI. It also proves that each direct-provider smoke refuses to read implicit credentials. It does not prove runtime routing, delegated execution, bundled Codex authentication, OpenCode planning, direct API providers, or release packaging.
