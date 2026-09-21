# Performance notes

Budgets and measurements as of M6. Re-measure after any transplant refresh.

## Capture path

- The upstream Cua Driver owns window enumeration, screenshot capture, AX grounding, and background input. Perry keeps one direct MCP worker and task-scoped sessions so repeated steps reuse the driver’s target and snapshot lifecycle without a reusable daemon.
- Cua returns the target-window image directly; Perry passes that image to OCR or the optional multimodal planner without writing it to disk or recapturing the desktop.

## Overlay choreography

- One NSWindow per screen, hosting view sized to the screen frame. Window level sits just below the drag layer (`PerryWindowLevels.cursorOverlay`); do not raise it above drag images or drop previews vanish.
- Glass cursor tracking samples NSEvent.mouseLocation on a userInteractive queue and hops to main only when the pointer moved. Keep that pattern — direct tracking must not enqueue per-tick animation work.
- Annotations draw in ~200ms per PRD §9; spring(response: 0.16, dampingFraction: 0.72) is the house curve for position changes.

## Runtime adapter latency classes

- Scripted/file-ops runtimes: sub-millisecond plan, fast execute.
- CLI runtime: dominated by process startup (~300ms) plus model time; timeout defaults 120s, kill verified by tests.
- BYOK planner: network-bound; the injected transport exists partly so tests never wait on TLS.
- Local tier: gated behind the 16GB floor precisely because below it, 4–7B quantized models miss usable latency. The gate *is* the performance feature.

## Memory & logs

- Screenshots live only in memory during a session (PRD §8). Cua image data and the compatibility `PerryScreenCapture` geometry value must never gain a disk write without revisiting that promise.
- Activity log persists JSON atomically after every entry; fine for interactive volumes. If Do mode ever batches thousands of steps, move to append-only NDJSON.
