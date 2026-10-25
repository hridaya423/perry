# R5: Cloud runtimes for the onboarding brain step

Date: 2026-10-25. Scope: read-only audit of Perry, T3 Code and ACP research, and a redesign recommendation.
Nothing was built, run or signed in. `[inferred]` marks a claim that no code or document proves.

## Summary

- Onboarding offers exactly two choices: "On this Mac" and "ChatGPT". Claude Code, ACP agents and API keys exist in code, but only in Settings, Models.
- The reply "I cannot read apps or files…" comes from `AgentLoop.request` when the chosen model lacks the `tools` capability. In practice that is Apple Intelligence, the onboarding default.
- Perry already detects Claude Code (path, Anthropic signature, `claude auth status`). It has no in-app Claude sign-in, no ACP sign-in, and no "signed in" state for either in the brain controller.
- T3 Code lists Codex, Claude, Cursor, Grok Build, OpenCode, Antigravity, Pi, Muse and any ACP registry agent. It never stores their credentials. It reuses each CLI's own login.
- Recommendation: a Cloud card with three kinds of row (ChatGPT, detected CLIs and agents, API key) and a This Mac card beside it. Only rows that work today are shown.

## Part 1. Perry today

### 1.1 Supported brains

`BrainController.ModelChoice` has five cases (`App/Brain/BrainController.swift:11-23`). The saved choice defaults to `chatGPT` (`App/PerryPreferences.swift:56`, `BrainController.swift:109`).

| Choice | Provider | Detected by | Authenticated by | Selected by | Onboarding? |
|---|---|---|---|---|---|
| `chatGPT` | `CodexAppServerProvider` from the bundled `CodexRuntime/bin/codex`, private `CODEX_HOME` in Application Support (`BrainController.swift:595-605`, `App/RuntimeCatalog.swift:48-50`) | Binary exists in the app bundle. SHA-256 pinned (`RuntimeExecutableVerifier.swift:7-35`) | In-app browser sign-in: `account/login/start` returns `authUrl`, Perry opens it, waits for `account/login/completed` (`Packages/PerryBrain/Sources/PerryBrain/Codex/CodexAccount.swift:62-71,100-115`, `BrainController.swift:442-508`). State is `.signedIn(email, plan)`, `.signedOut` or `.unknown` | `modelChoice` picker (`BrainModelSettingsView.swift:8-15`) | Yes (only cloud option) |
| `claudeCode` | `ClaudeCodeProvider` runs the `claude` CLI per turn, with Perry tools through `perry-mcp` | `CLIRuntime.locateExecutable` checks `~/.claude/local/claude`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` (`Packages/PerryRuntimes/Sources/PerryRuntimes/CLIRuntime.swift:120-144`) | The CLI's own login. Terminal command `claude auth login` (`App/RuntimeInventory.swift:210`). Status probe `claude auth status` JSON `loggedIn` (`CLIRuntime.swift:56-78`) | Picker only | No. Only a `claudeCodeAvailable` flag is read (`HomeOnboardingView.swift:384`) |
| `acp` | `AcpAgentProvider` speaks ACP v1 over stdio (`AcpAgentProvider.swift:146-153`) | `AcpAgent.known` is Cursor `cursor-agent acp`, Gemini CLI, OpenCode, Goose (`AcpAgentProvider.swift:27-32`). Search paths `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `/usr/bin` (`:43-46`). Registry list from `cdn.agentclientprotocol.com`, `npx`/`uvx`/darwin-aarch64 binary only (`AcpRegistry.swift:45-77`). Custom command | None by Perry. The agent keeps its own login. A failed turn with "auth" in the error is mapped to `.unauthenticated` (`AcpAgentProvider.swift:195`) | `AcpAgentSection` (`App/Brain/AcpAgentSection.swift`) | No (only the `acpAgentAvailable` flag) |
| `direct` | `ModelProfile` with one `ProviderPreset`: OpenAI, Anthropic, Gemini, OpenRouter, xAI, Groq, Cerebras, Mistral, DeepSeek, Together, Fireworks, plus Ollama, LM Studio, llama.cpp, vLLM, Jan, Custom (`ProviderPreset.swift:20-38`) | n/a | API key pasted into Keychain (`BrainController.swift:134-143`). "Check" probe tests text, image, tool call (`ModelCapabilityProbe`, `BrainController.swift:170-193`) | `ModelProfilesSection` | No |
| `local` | Apple `FoundationModels` (macOS 26+, `AppleFoundationModelProvider.swift:7-16`) and discovered Ollama or LM Studio models | `LocalServerDiscovery`; `SystemLanguageModel.default.availability` | None needed | Picker; auto-chosen by `preferOnDeviceModelIfUnchosen` (`BrainController.swift:284-289`, called at `OnboardingDirector.swift:194`) | Yes |

Other runtime records are bookkeeping only. `RuntimeCLIDefinition.production` lists Bundled Codex, Claude Code and OpenCode (`App/RuntimeInventory.swift:180-222`). The file header says nothing routes through providers there (`:9-11`). Settings, Models shows those records with a "Copy sign-in command" button (`App/SettingsView.swift:550-575`). OpenCode is pinned to version 1.18.32 by SHA-256 (`OpenCodeRuntime.swift:5-6`).

`DirectAIProvider` (OpenAI, Anthropic, Gemini, OpenRouter) is a second, older list used only to name a runtime (`RuntimeInventory.swift:34-37`, `RuntimeCatalog.swift:176-179`). It duplicates `ProviderPreset` `[inferred: dead weight for this task]`.

### 1.2 Capabilities per brain (`ModelCapabilities`)

| Provider | vision | tools | Source |
|---|---|---|---|
| Codex (ChatGPT) | yes | yes if dynamic tools supported (default true) | `CodexAppServerProvider.swift:94-96` |
| Claude Code | yes | yes | `ClaudeCodeProvider.swift:6` |
| ACP agent | yes | yes (image prompt only if the agent reports `promptCapabilities.image`, `AcpAgentProvider.swift:153`) | `:52` |
| Anthropic, Gemini, OpenAI Responses (API key) | yes | yes | `AnthropicMessagesProvider.swift:7`, `GeminiProvider.swift:7`, `OpenAIResponsesProvider.swift:7` |
| OpenAI-compatible profile | default yes/yes/yes until a check runs, then only what passed | | `BrainController.swift:562` |
| Local server model | only what the check passed; unchecked models are not routed | | `BrainController.swift:567-569` |
| Apple Intelligence | **neither** (`.local, .streaming`) | | `AppleFoundationModelProvider.swift:10` |

### 1.3 What onboarding exposes

- Beats: `greet, firstTalk, screenAccess, brainChoice, practice, finale` (`OnboardingDirector.swift:8`).
- `BrainChoiceBeat` (`App/Home/HomeOnboardingView.swift:373-472`) shows two 214x56 option buttons: "On this Mac" (disabled when `onDeviceRouteAvailable` is false) and "ChatGPT" with a cloud icon (`:400-402`).
- The primary button is "Continue" when ready, else "Connect ChatGPT" (`:418-425`). A footer link "Other models" calls `openSettings` (`:412`).
- The copy says "Start on this Mac or connect ChatGPT. Switch any time in Settings." (`:393`).
- `ready` for `claudeCode`, `acp` and `direct` is computed (`:380-388`), but no onboarding control can select them. The finale card handles them (`:531-535`).
- Settings only: Claude Code, ACP agents, ACP registry, all API-key providers, local server checks, runtime records, OpenCode, realtime voice key.

### 1.4 The reply "I cannot read apps or files…"

- Source: `Packages/PerryBrain/Sources/PerryBrain/Tools/AgentLoop.swift:75-76`. In `request(...)`, if `!provider.capabilities.contains(.tools)`, the loop appends: "This model can answer using this conversation only. It cannot read apps or files, control the screen, or perform actions. Ask the user to paste needed text or choose a capable model in Settings." The user-visible text is the model paraphrasing that line.
- The loop also strips every tool the provider cannot call (`AgentLoop.swift:73`). Screen and UI tools need `[.tools, .vision]` (`App/Tools/ScreenTools.swift:42`, `UITools.swift:131`).
- Home chat routes with `[.streaming]` only for non-spatial turns (`App/Tools/AgentCoordinator.swift:225`). A tool-less model is accepted, so chat works but cannot act.
- Configurations that reach it:
  1. `local` with only Apple Intelligence. `.local` scope drops unchecked server models (`BrainController.swift:568`), so Apple is the only candidate. This is the onboarding default when the user never picked a brain and Apple Intelligence is available (`BrainController.swift:284-289`). Strongest match. `[inferred: I did not reproduce it]`
  2. `local` with a server model whose check ran but `tools` failed.
  3. A `direct` profile whose check ran and `tools` failed (`BrainController.swift:324-328`).
- It cannot come from ChatGPT, Claude Code, ACP or a keyed OpenAI, Anthropic or Gemini profile.
- Related (`[inferred]`): pointing questions in Talk require `[.vision, .streaming]` (`AgentCoordinator.swift:224`, `AppSubsystems.swift:263`). On Apple Intelligence alone the router throws "No on-device model supports this request" (`ProviderRouter.swift:61-63`). Onboarding's first Talk beat runs on that default.
- The onboarding card says "Private and offline" for On this Mac (`HomeOnboardingView.swift:400`). It never says Apple Intelligence cannot see the screen or use tools.

### 1.5 Surprises

1. `makeClaudeCodeProvider` only locates the file (`BrainController.swift:586-593`). The Anthropic code-signature check exists only in the Settings inventory (`RuntimeExecutableVerifier.swift:37-71`). A Claude Code run does not depend on that check.
2. Bundled Codex uses a private `CODEX_HOME`. A user already signed in to the `codex` CLI (this Mac has `/opt/homebrew/bin/codex`) must sign in again.
3. `ModelChoice` is the saved choice and `acceptsSetup` gates changes (`BrainController.swift:26-33`). A closed admission silently ignores a selection. This matters if onboarding sets a choice early.
4. `AcpAgent.known` hard-codes `gemini --experimental-acp`. The live registry lists Gemini CLI and Cursor under other launch recipes. `[inferred: flags may be stale; not run]`

## Part 2. T3 Code as the reference

Source: github.com/pingdotgg/t3code (MIT, pushed 2026-10-25), `README.md`, `docs/user/*.md`, `apps/server/src/provider/`, `packages/provider-*`.

### 2.1 Providers

- Built-in drivers: Codex, Claude, Cursor, Grok Build, OpenCode, Antigravity, Pi, Muse Code (README warning block; `docs/user/install.md` "Providers" table; packages `provider-cursor`, `provider-grok`, `provider-muse`, `provider-opencode`, `provider-pi`).
- Everything else comes through ACP: "Add provider", then search the ACP Registry, or "Local ACP command" (`docs/user/providers-acp.md`). Antigravity uses the registry entry `antigravity-acp`. Devin is also a registry entry.
- Muse is a beta, off by default. Pi needs Node 22.19+.

### 2.2 Detection

- The CLI must be on the server `PATH`. If not found, the user sets a "Binary path" in the provider card. Cursor's binary is `cursor-agent` (`install.md`).
- Setup wizard checks each computer for Claude Code and Codex. A missing or signed-out agent shows an action that opens a terminal with the command ready (`docs/user/welcome-wizard.md`).
- Cards show an installed version, a compatibility warning and "Update now". Provider status is cached and refreshed on demand (`providerStatusCache.ts`, `ProviderRegistry.ts`).
- Managed install exists only for Codex and Antigravity (`providerInstallation.ts`). Registry agents install under T3 home with a SHA-256 check when the registry gives one.

### 2.3 Sign-in per provider

| Provider | Method |
|---|---|
| Codex | "Connect with ChatGPT" (managed runtime, T3 holds a handoff and token broker, `CodexChatGptAuth.ts`) or reuse `codex login`. Remote fallback: paste the localhost callback URL (`providers-codex.md`) |
| Claude | Claude Code login only: `claude auth login`. Extra accounts through `CLAUDE_CONFIG_DIR` (`providers-claude.md`) |
| Cursor, Grok, OpenCode | `agent login`, `grok login`, `opencode auth login` (`install.md`) |
| Antigravity | In-app "Sign in with Google", no CLI (`providers-antigravity.md`) |
| Pi, Muse | Log in in the tool (`/login`, `muse login`). Muse status does not check login (`providers-muse.md`) |
| ACP agents | Generic: the agent advertises `authMethods` at `initialize`. T3 shows "Sign in", lets the user pick a method, shows a browser URL and waits, or runs a terminal method in an in-app terminal, then waits for the agent to confirm. "Sign out" if `auth.logout` is advertised. API-key agents take keys as environment variables (`providers-acp.md`, `AcpRegistryProbe.test.ts`, `ProviderAuthService.ts`) |

Rule: credentials stay in the agent's own store. T3 stores only environment overrides, marked sensitive.

### 2.4 Settings layout

`apps/web/src/components/settings/ProviderSettingsPanel.tsx` and `ProviderSettingsForm.tsx`. One panel, "Settings → Providers", with the environment selector on top. One card per provider instance, each with enable toggle, version, binary path, environment variables, account section and models. "Add provider" opens a registry search and a "Local ACP command" entry. Multiple instances per provider give multiple accounts. `[inferred from file names and docs; I did not render the UI]`

### 2.5 Agent Client Protocol in 2026

- Spec: stable protocol version is `1`. `agent-client-protocol` has `schema/v1` and `schema/v2`. Releases on 2026-10-16: `v1.12.0`, `schema-v1.26.0`, `schema-v2.0.0-alpha.9`. v2 is alpha. T3 negotiates the v2 preview and falls back to v1 (`providers-acp.md`). Apache-2.0.
- Auth (stable): `authMethods` in the `initialize` response. Types: `agent` (default), `terminal` (client runs the agent program interactively; needs `clientCapabilities.auth.terminal`), and `env_var` (seen in T3's test fixture; not described on the fetched page). `authenticate` takes a `methodId`. `logout` is stable and gated by `agentCapabilities.auth.logout` (https://agentclientprotocol.com/protocol/authentication).
- Registry: launched 2026-01-28 with Zed and JetBrains. Only agents that support authentication are listed. JSON at https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json, version 1.0.0, 43 agents on 2026-10-25. Distribution: `npx`, `uvx`, `binary` per platform. https://agentclientprotocol.com/get-started/registry
- darwin-aarch64 binaries (Perry can install without Node): amp, antigravity, cortex-code, corust, crow-cli, cursor, devin, goose, harn, junie, kilo, kimchi, kimi, mistral-vibe, opencode, opencode-v2, poolside, sigit, stakpak, vtcode.
- npx only (needs Node): claude-acp, codex-acp, gemini, github-copilot-cli, grok-build, cline, qwen-code, factory-droid, auggie, pi-acp and others. Perry's registry parser handles both shapes (`AcpRegistry.swift:62-70`).
- Agents page lists 46 agents; Claude Agent, Codex CLI, Pi and Bub through adapters (https://agentclientprotocol.com/get-started/agents).
- SDKs: Kotlin, Java, Python, Rust, TypeScript on the official site. No official Swift SDK. Community: `aptove/swift-sdk` (11 stars, pushed 2026-10-20), `Orcaryn/agent-client-protocol-swift` (0 stars).
- Swift feasibility: high without a dependency. Perry already has a JSON-RPC client and an ACP v1 client (`Packages/PerryBrain/.../Codex/JSONRPCConnection.swift`, `AcpAgentProvider.swift:140-195`). It lacks `authMethods` handling, `authenticate`, `logout` and a v2 path. AGENTS.md forbids new third-party dependencies without approval, so do not adopt a community SDK.

## Part 3. Recommendation: the brain step

### 3.1 Layout

Two side-by-side cards under "Choose how I think."

```
┌ In the cloud ──────────────┐  ┌ On this Mac ───────────────┐
│ ● ChatGPT        Sign in   │  │ Apple Intelligence         │
│ ○ Claude Code    Signed in │  │ Text only. Cannot see the  │
│ ○ Cursor         Sign in   │  │ screen or use tools.       │
│ ○ API key…                 │  │ Local models (Ollama…)     │
└────────────────────────────┘  └────────────────────────────┘
```

Rules:
- One selection across both cards. The existing `ModelChoice` model already supports it.
- Rename the On this Mac detail from "Private and offline" to the real capability. If only Apple Intelligence exists, say "Text answers only. Cannot see your screen." This prevents the reply in 1.4.
- Pre-select Cloud when any cloud row is already signed in. Pre-select This Mac only when nothing cloud is ready and an on-device route exists.
- Footer "More models" keeps opening Settings (existing `openSettings` closure).

### 3.2 Detection order (cheap first, no network)

1. ChatGPT: always listed, because the binary is bundled. State from `codex.account.status()` (already called by `BrainController.refresh`, `:225-229`). Order first: zero install, and the only in-app sign-in.
2. Claude Code: `CLIRuntime.locateExecutable`, then `RuntimeExecutableVerifier.claude`, then `claude auth status`. Show it only if the binary exists and the signature verifies. Three-state result: signed in, needs sign-in, not installed (hide).
3. ACP agents from `AcpAgent.known` whose `executable()` resolves. Show the installed ones only; Cursor is installed on this Mac. No registry fetch in onboarding (network plus an install prompt do not belong in a first-run step).
4. "API key" row: opens the existing `ModelProfilesSection` form with the first four presets (OpenAI, Anthropic, Gemini, OpenRouter). Last resort.

Run steps 2 and 3 in one task when the beat appears. `RuntimeCatalog.currentSetup()` already gathers step 2 with a 3-second timeout per probe (`CLIRuntime.swift:56-67`).

### 3.3 Sign-in with least friction

1. Reuse an existing CLI login: Claude Code (`claude auth status`, 1 call). No credential is read or copied. This is the T3 rule.
2. Perry-owned browser sign-in: ChatGPT (exists).
3. Run the CLI's own login and wait: `claude auth login` through `CLIRuntime.runProcess`, then re-run `auth status`. `[inferred: not tested; the CLI opens the browser itself]`. Fallback: the existing "copy command" path (`RuntimeSetup.swift:25-31`).
4. API key paste: last.

Do not copy `~/.codex/auth.json` or point the bundled Codex at the user's `CODEX_HOME`. T3 does the second only with explicit settings and a shadow-home design. Offer ChatGPT sign-in only.

### 3.4 "Already signed in" display

- Row subtitle: email for ChatGPT (`.signedIn(email:plan:)` already exists), "Signed in with Claude Code" for Claude, "Installed" for ACP agents without a probe.
- Do not show "Signed in" for ACP agents. Perry cannot know (see 3.6).
- Primary button: "Continue" if the selected row is ready, else "Connect <name>". The current code already switches between these two (`HomeOnboardingView.swift:418-425`). Generalise `signInWithChatGPT` to a per-row action.
- If a row is ready on open, skip the wait: the beat can enable "Continue" at once.

### 3.5 What each brain unlocks in Perry

| Capability | Needs | Unlocked by |
|---|---|---|
| Text answers | `streaming` | Every brain |
| Screen understanding (Talk, point and ask) | `vision` + `streaming` (`AgentCoordinator.swift:224`) | ChatGPT, Claude Code, ACP, keyed OpenAI/Anthropic/Gemini, checked local vision models. **Not** Apple Intelligence |
| Computer use (observe, click, type, draw) | `tools` + `vision` (`ScreenTools.swift:42`, `UITools.swift:131`) plus Accessibility and Screen Recording (`PerryPermissionSnapshot`) and the Cua driver | Same list. Needs permissions granted in the previous beat |
| Voice in and out | Not the brain. Dictation uses `SFSpeechRecognizer` (`DictationController.swift:114`), speech uses `AVSpeechSynthesizer` (`VoiceController.swift:36`) | Any brain. Realtime voice needs its own key, set separately (`SettingsView.swift:343-385`) |

Show this as one line per row, for example "Sees your screen and acts." Do not claim voice as a cloud benefit.

### 3.6 Already have vs missing

Have:
- ChatGPT in-app sign-in and status: `CodexAccount.swift`, `BrainController.swift:442-548`.
- Claude Code detection, signature check, auth status: `CLIRuntime.swift`, `RuntimeExecutableVerifier.swift`, `RuntimeInventory.swift:203-211`.
- ACP client, installed-agent detection, registry fetch with checksum install: `AcpAgentProvider.swift`, `AcpRegistry.swift`.
- API-key profiles for 11 cloud presets plus capability probe: `ProviderPreset.swift`, `ModelProfilesSection.swift`, `BrainController.swift:170-193`.
- Brain-choice beat and `ModelChoice` selection: `HomeOnboardingView.swift:373-472`.

Missing (build in this order):
1. Per-provider status in `BrainController`. Today only `account` (ChatGPT) and booleans `claudeCodeAvailable`, `acpAgentAvailable` exist (`:121-123`). Add a small `[ModelChoice: SetupState]` fed by `RuntimeCatalog.currentSetup()`.
2. Claude Code ready test must mean "verified and signed in", not "file exists" (`BrainController.swift:123,586-593`).
3. Onboarding cloud card UI. Replace the two fixed buttons in `BrainChoiceBeat.option` (`:441-471`) with a card and rows. Update `ChoiceSketch` if needed.
4. A capability line on the This Mac row (Apple Intelligence has no vision or tools).
5. In-app `claude auth login` runner (optional; the copy-command fallback works).
6. ACP auth: read `authMethods` from `initialize` (`AcpAgentProvider.swift:146`), call `authenticate`, treat `auth_required`. Needed before onboarding may show ACP sign-in states. Until then list ACP agents as "Installed" and send sign-in to Settings.
7. Not in onboarding (keep minimal): registry browsing and download, Antigravity, Pi, Muse, Grok, multiple accounts, usage limits, v2 preview.

### 3.7 Open questions for the owner

1. Should the cloud card pre-select a signed-in Claude Code over ChatGPT when both are ready? Recommended: keep the saved choice; otherwise the first ready row in the order of 3.2.
2. Should Perry run `claude auth login` itself? It is a login flow, so I did not test it.
3. Is the Claude Code unverified-binary behaviour (surprise 1) intended?

## Sources

- https://github.com/pingdotgg/t3code (README, `docs/user/install.md`, `providers-acp.md`, `providers-codex.md`, `providers-claude.md`, `providers-muse.md`, `providers-pi.md`, `welcome-wizard.md`, `apps/server/src/provider/*`, `apps/web/src/components/settings/ProviderSettingsPanel.tsx`)
- https://agentclientprotocol.com/protocol/authentication
- https://agentclientprotocol.com/get-started/registry
- https://agentclientprotocol.com/get-started/agents
- https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json
- https://github.com/agentclientprotocol/agent-client-protocol (releases, `schema/v1`, `schema/v2`)
- https://github.com/aptove/swift-sdk, https://github.com/Orcaryn/agent-client-protocol-swift
