# Attended approval card — live drill (2026-10-01)

Debug build (post-`f3858f8`), pid 6859, Ollama `qwen3:4b` probed
text+tools earlier in the same session.

## Drive

1. `cghidEventTap` cmd+option+P → `invoke.keydown` → `wake.pinned` →
   `wake.overlay` → `panel.visible` markers in
   `docs/evidence/lab/perf-20261001T045202Z.jsonl.markers.jsonl`.
2. Peek-panel composer (`window 2`, text field at 1464,808): typed
   `perry, do move the file drill-proof-2.txt to the trash`, pressed the
   send button via AX → `home.question.sent` at 05:26:57Z.
3. `GuideIntentParser` maps the `perry, do` prefix to `.doTask`; the Home
   runner falls through `default:` to `agentCoordinator.run` on the
   `.agent` surface, attended (`unattended: false` default).

## What happened

- The model called `files.trash` — an orange-tier tool — so
  `ToolApprovalPresenter.present` showed `IntentCardWindow` near the
  cursor (window at 1279,700 size 437×148). Screenshot:
  `approval-card.png`. Orange tier dot, title "Perry wants to run
  files.trash", Target row `files.trash: drill-proof-2.txt`, tool
  description, and three decisions: Stop / Always allow / Approve
  (Always allow present because consentScope = threadID).
- AXPress on Approve → the tool executed: `drill-proof-2.txt` moved from
  the workspace into `workspace/.trash/1790832672427-drill-proof-2.txt`
  (verified on disk). The recorded `elementLabels` carry the real tool
  result including its `files.move` undo descriptor.
- The post-observation summarization request then timed out after the
  120 s `HTTPStreaming` budget; the turn recorded `.failed` with
  `failureReason: "The request timed out."` — honest bookkeeping: the
  mutation happened, the answer never arrived, nothing was fabricated.

## Verified

- Attended orange-tier approval renders, blocks the tool until decision,
  and an Approve really executes (file moved, undo recorded).
- Timeout path records `.failed` — consistent with the fabrication
  guard contract: no phantom success.

## Open wrinkle

- qwen3:4b's post-tool summary exceeded 120 s here (first call was
  ~90 s of thinking before the card appeared). A faster model or a
  shorter agent prompt would avoid it; the turn failing while the
  mutation already landed is honest but is the kind of rough edge the
  Phase-10 polish pass should smooth (e.g. report "done, summary timed
  out" rather than a bare failure).
