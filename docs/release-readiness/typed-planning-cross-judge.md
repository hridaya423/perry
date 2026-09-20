# Typed planning cross-judge

Compared with `typed-planning-grounding.md` and the current runtime call graph. Scores are for the frozen candidates; 5 means the criterion is directly satisfied. The central production gap is concrete: `queueBackgroundTask` casts `selection.runtime` to `LocalTaskPlannerRuntime`, but the selector returns a provider adapter, while existing seeded tests bypass queue creation.

| Criterion | Capability candidate | Result candidate |
| --- | ---: | ---: |
| Real production reachability | 4/5 | 3/5 |
| Planning/execution authority and malformed-input fail-closed behavior | 4/5 | 5/5 |
| File-only no-capture and context ownership | 5/5 | 5/5 |
| Cancellation, metadata, and identity preservation | 4/5 | 4/5 |
| Interface depth and migration toward typed M1 | 2/5 | 4/5 |

The capability candidate is the smaller immediate repair. A typed-first requirement removes the impossible concrete cast, keeps file-only metadata targetless, and makes malformed recognized input stop before fallback or capture. Its optional capability, requirement enum, route projections, and two selector queries create a second planning authority. The typed probe can also select differently from the later contextual route unless provider identity and explanation continuity are explicit. It is a good bridge, not the final M1 boundary.

The result candidate is the stronger base. `PlanningRequest` binds task, workspace, and context; `PlanningResult` makes typed versus legacy authority explicit; and provider validation rejects wrong identity, escaped workspace, malformed typed output, and typed-to-legacy fallback. As written, its compatibility bridge is underspecified: existing `TaskPlanner` callers, `AgentRuntime`, `DoSupervisor`, adapters, providers, and tests all require `plan(goal:context:) -> Plan`.

The proposed graft resolves that gap at bounded cost: rename the old protocol `LegacyTaskPlanner`, introduce typed `TaskPlanner`, keep `AgentRuntime` on the legacy planner plus executor, and let each `RuntimeProvider` retain both planners. The default wraps the legacy planner; Local registers both explicitly; the selector owns the selected provider and exposes typed planning plus its computed legacy runtime. This adds dual fields, initializers, and latency-descriptor updates, but avoids fake IDs/workspaces and any typed-to-legacy conversion. Once implemented, reachability is 4/5 rather than the frozen candidate’s 3/5.

## Recommendation

Use the result candidate as base and apply that graft. Keep context retry on the same selected provider handle; an unrelated second selection can retain stale route metadata. Validate exact normalized workspace identity required by `WorkspaceFileRuntime`, leave file-only target metadata nil, and acquire Cua only for an explicit context-required result. Malformed recognized input must fail before legacy planning, capture, enqueue, or persistence. Keep `.legacy` for existing callers during migration, but never use it as the new typed background authority.

Reject the capability candidate as the final contract, the concrete-runtime cast, generic legacy-to-typed conversion, and weaker descendant-only workspace checks. Neither candidate yet supplies a real multi-action production planner; the result boundary supplies the migration seam, while provider-specific multi-action decoding remains separate work.
