# Fabricated tool transcripts fail honestly — live drill

Date: 2026-10-01 · Instance: debug build pid 24457 (perry-drive) · Thread: `Threads/802BA629-B642-4996-BAD1-DED94E3DD168.json`

## Defect

A foreground "Do" turn streamed a fake tool transcript — `Files.create drill-alpha.txt` lines and a "files now contain the word perry" claim — with **zero real tool calls**, and the turn recorded `outcome: completed`. First seen on thread `CC1B9E19-…`; workspace contained none of the claimed files.

`AgentLoop.looksFabricatedToolTranscript` already guarded fake transcripts but matched only a narrow grammar: `[Observation:…]`/`[Action:…]` with a colon, lowercase tool names requiring `name(` at line start, and verb→object claim order ("created the file").

## Observed evasion shapes (three live runs, same prompt)

1. `Files.create drill-alpha.txt` — capitalized, paren-less, line-start.
2. Fake listing `drill-alpha.txt: "perry"` + reversed claim "Files created as requested." + "Each file now contains …".
3. `[Files.list]` / `[UI.action]` bracket labels + `list = files.list("…")` mid-line assignment form.

## Fix (shared seam)

- `name(` call syntax is flagged **anywhere** in the answer (case-insensitive), not just line start.
- Bare tool names at line start (optional `-`/`*`/`•` bullet, parens optional) are flagged.
- A line that is only a bracketed dotted label (`[Files.list]`) is flagged.
- Mutation claims match object→verb order too ("Files created", "3 files were saved") and plural objects.
- Postcondition state claims flag: "each/all/N files (now) contain/hold/include …".

Boundary kept deliberate: prose *naming* a tool mid-sentence still completes; quoting live call syntax in a zero-call turn does not — it asserts a call that never ran.

## Verification

- `AgentLoopTests`: 30 tests green, including new regression tests carrying each observed evasion verbatim (`testCapitalizedParenlessToolLine`, `testBulletedFakeToolLines`, `testBracketedToolLabelsAndMidlineCalls`, `testFakeListingWithReversedClaim`, `testPostconditionStateClaim`).
- Live re-drill (fixed build): same prompt → model produced `- files.list workspace → no output` style fake `Actions:` block → turn recorded **failed** with "The answer describes actions Perry did not run — nothing was executed. Retry, or choose a different model in Settings." Workspace contains no drill-alpha/beta/gamma files.

Unattended path noted separately: scheduled Perrys currently fail earlier ("No on-device model supports this request") because no local model passes the `[.tools]` probe — different gate, tracked under the Codex/model-entitlement blocker.
