# Codex routing drill — 2026-10-01 ~18:55Z

Live MCP drill on the running app proving the chatGPT provider route works
end-to-end, and isolating exactly where model execution is blocked.

## Setup

`perry.brain.modelChoice` is a stored user preference read once into
`BrainController.selectedModel` at init (`BrainController.swift:24-31,161`) —
`defaults write` does not reach a running instance; only
`reloadPreferences()` re-reads it, and its sole caller runs post-erasure
(`AppController.swift:1733`). The drill therefore required a relaunch.

## Sequence and results

1. Probe Perry `lab-probe-2` created via `perry.createPerry` +
   `perry.schedule` (interval 70s) — MCP auth hello + JSON-RPC framing worked
   first try.
2. With `modelChoice=local`: turns at 18:46:41/18:48:41/18:50:41Z all failed
   with "No on-device model supports this request. … No remote model was
   used." Correct and honest: `local` inserts `.local` into the requirement
   (`BrainController.swift:232-234`), and no on-device provider on this
   machine offers `.tools` — `AppleFoundationModelProvider` advertises
   `[.local, .streaming]` only, and `~/.ollama/models` (which served
   qwen3:4b for the earlier phase-9a drills) has since been deleted.
3. `defaults write dev.perry.Perry perry.brain.modelChoice chatGPT` +
   relaunch → next run at 18:56:46Z reached Codex and returned a real
   upstream API response:

   > "You've hit your usage limit. Visit
   > https://chatgpt.com/codex/settings/usage to purchase more credits or try
   > again at Oct 5th, 2026 9:19 PM."

   The error text is a genuine ChatGPT/Codex service response — proving the
   chain provider route → bundled Codex app-server → account auth → network
   round-trip → honest failure surfacing → thread persistence. The account
   is signed in (`~/Library/Application
   Support/Perry/CodexRuntime/auth.json`, auth_mode `chatgpt`, subscription
   until Oct 4); ChatGPT sign-in is therefore NOT a pending user blocker.

4. Cleanup: schedule → `off`, probe Perry + thread removed, `modelChoice`
   restored to `local`, final relaunch pid 40093.

## What this verifies / does not verify

- VERIFIED: `perry.createPerry`, `perry.schedule` interval persistence,
  scheduler tick → unattended coordinator → `route()` modelChoice switch →
  Codex provider invocation → real API exchange → `failed` outcome +
  `failureReason` persisted to the Perry thread (schema v2).
- VERIFIED: Codex account sign-in is complete and tokens are valid — the
  only remaining gap is account quota (usage limit resets 2026-10-05 21:19).
- NOT verified: a completed chatGPT turn (quota-blocked), a completed local
  turn tonight (on-device tools-capable model absent — needs `ollama pull`
  of a tools-capable model; qwen3:4b worked at 05:02Z before the models
  directory was removed).
- USER ACTION to unblock completions: wait for quota reset (Oct 5) or
  re-pull a local model and select it in Settings → Models.
