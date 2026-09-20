# Runtime inventory history

### The Question

Which documented constraints shaped Perry's runtime routing and readiness, and which constraints must survive one shared inventory?

### The Code in Question

`App/AppController.swift:2191-2385` (`makeRuntime`), `:2664-2727` (`currentRuntimeSetup`), and `:2766-2881` (verified runtime status); `App/RuntimeExecutableVerifier.swift:6-147`; `App/ProductionRuntimeSelector.swift:18-35`.

The verifier and selector are uncommitted, and `AppController.swift` is modified. The current contract is in `PRD.md:59-67`.

### What We Found

- **[Direct]** The committed PRD records installed CLI/auth, Keychain BYOK, a 16GB+ Apple-silicon floor for local experimental models, and task-type routing from CLI work to vision-capable runtimes. Source: `PRD.md@HEAD (4b768c9):61-68`.
- **[Direct]** `df65aab` records the Codex split: `codex exec --json` runs read-only for plans and `workspace-write` for execution, with the runtime bundled by a fetch script. Source: commit `df65aab`.
- **[Direct]** `bc87379` records Keychain-backed BYOK, a hardware gate below the 16GB Apple-silicon floor, CLI routing for file/dev work, vision routing for GUI grounding, and local availability only when the floor and experimental flag pass. Source: commit `bc87379`.
- **[Direct]** `1c8e640` records real process-spawn and timeout-kill coverage. Source: commit `1c8e640`.
- **[Supported]** The committed PRD and runtime commits converge on capability-specific routing, bounded CLI execution, stored BYOK credentials, and hardware-gated local use. They document constraints, but do not state a complete causal rationale for the later inventory boundary.

The modified PRD is the authoritative release contract for this refactor, per the request. `grounding.md` and `opencode-authentication-2026-08-31.md` are new retrospective records authored in this thread, so they are current-contract evidence only, not independent history.

### What We Can Reasonably Infer

- **[Inferred]** The shared inventory should be a consolidation boundary, not a new routing policy. The current contract identifies duplicated assembly across task routing, Settings, picker choices, and demo preflight and requires reuse of `RuntimeProviderRegistry` (`grounding.md:5-9,28`).
- **[Inferred]** Exact executable reuse, cancellation-safe publication, and the distinction between configured and authenticated appear to be refactor acceptance criteria layered onto the earlier runtime ladder. They are explicit in the current records (`grounding.md:17-24`; `opencode-authentication-2026-08-31.md:5-7,27-31,47-51`), but no supplied historical source explains their origin.

### Competing Hypotheses

- **Hypothesis:** Capability and safety boundaries drove the original ladder. **Evidence for:** the committed PRD, `bc87379`, and `df65aab`. **Evidence against or missing:** no source states the motivating incident, alternative, or decision discussion.
- **Hypothesis:** The exact single-inventory shape is a later refactor concern. **Evidence for:** the inventory/verifier/selector are uncommitted and the duplication/rubric language is in the new `grounding.md`. **Evidence against or missing:** no historical source explicitly dates or explains that transition.

### What We Don't Know

- No historical source states why exact executable identity, official CLI login without token scraping, planning-only Claude/OpenCode, configured versus authenticated readiness, local fallback, cancellation, or exact executable reuse were chosen.
- No PR, ticket, or incident rationale was surfaced. Linear's exact `"Perry runtime"` query with `includeArchived: true` and `limit: 50` failed with `USER_NOT_LOGGED_IN`; Notion's exact workspace queries returned no results. These gaps do not show that no other rationale exists.
- Direct team-chat, Perry-native infrastructure-observability, and error-tracker MCPs were unavailable. Sites worker logs and hosted Base44/Lovable database tools were excluded because they are outside this native local-first application's infrastructure; no Perry warehouse was identified.

### Sources Consulted

- **Source control history:** Harvey's findings for `df65aab`, `bc87379`, `1c8e640`, `HEAD=4b768c9`, and `PRD.md@HEAD:61-68`; direct runtime constraints found, but no PR or ticket IDs.
- **Current local contract:** modified `PRD.md:59-67`, `grounding.md:5-32`, and `opencode-authentication-2026-08-31.md:1-61`; read as contract only, not independent historical evidence.
- **Linear:** searched exact `"Perry runtime"` with archived results capped at 50; authentication failed, so the search stopped.
- **Notion:** searched exact `"Perry runtime"`, `"Perry Codex"`, and `"Perry release specification"` in workspace mode; all returned `results: []`, so no pages were fetched.
- **Team chat, infrastructure, error tracking, and warehouse:** not searched because no matching Perry-native MCP or warehouse was available; unrelated hosted database tools were out of scope.

### Confidence Summary

Confidence is high that the committed PRD and runtime commits document the capability and safety constraints above. Confidence is low on the original causal rationale for the shared inventory and its detailed readiness rules; the user-provided release specification remains authoritative despite those historical gaps.

### Preserve

- Preserve pinned Codex and OpenCode artifacts, Claude's Anthropic identity check, and the rule that identity is checked before login or version commands (`grounding.md:17-18`).
- Preserve Codex read-only planning, workspace-write execution, private runtime home, and exact executable identity through verification and invocation (`df65aab`; `grounding.md:18-19`).
- Preserve official CLI login, planning-only Claude/OpenCode, and configured credentials as usable for planning without becoming authenticated or ready (`PRD.md:61-63`; `grounding.md:19-20`; `opencode-authentication-2026-08-31.md:5-7`).
- Preserve per-task preference, configured direct-provider preference, CLI ordering, route explanations, local-planner fallback, reinspection at task start, and cancellation without partial publication (`grounding.md:21-24`).

### Change

- Move duplicated inspection and record assembly behind one inventory consumed by task routing, Settings, picker choices, and demo preflight, while reusing provider-specific verifiers/adapters and `RuntimeProviderRegistry` (`grounding.md:5-9,28`).
- Keep the inventory deterministic and testable at its boundary; the change should reduce policy duplication without adding pass-through layers (`grounding.md:26-28`).

### Avoid

- Do not enable delegated Claude/OpenCode execution, replace the registry routing algorithm, scrape credential files or tokens, or add provider network calls, downloads, polling, persistence, or a global cache (`PRD.md:62`; `grounding.md:19-24`).
- Do not treat a Settings snapshot as authorization, a configured credential as authenticated, or an unverified executable as eligible (`grounding.md:20,23`).
- Do not present the retrospective `grounding.md` or OpenCode record as proof of original author intent.

### Risk

- The main historical risk is rationalization: the exact inventory boundary and several readiness rules have current-contract support but no recovered causal record.
- The main implementation risk is policy drift during consolidation: locating a different executable, publishing stale canceled results, running probes before identity checks, or changing fallback order and explanations would violate the current contract (`grounding.md:17-24`).
