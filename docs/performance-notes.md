# Performance notes

Budgets and measurements as of M6. Re-measure after any transplant refresh.

## Capture path

- SCShareableContent enumeration costs 80–200ms cold. The donor's 3-second cache is preserved in `PerryScreenCaptureUtility`; keep it. Prewarm on session start, not key-down.
- Screenshot downscale to 1280px max dimension happens inside the SCScreenshotManager configuration — do not capture full-res then resize.

## Overlay choreography

- One NSWindow per screen, hosting view sized to the screen frame. Window level sits just below the drag layer (`PerryWindowLevels.cursorOverlay`); do not raise it above drag images or drop previews vanish.
- Buddy cursor tracking samples NSEvent.mouseLocation on a userInteractive queue and hops to main only when the pointer moved. Keep that pattern when replacing donor visuals with Perry sprite art.
- Annotations draw in ~200ms per PRD §9; spring(response: 0.16, dampingFraction: 0.72) is the house curve for position changes.

## Runtime adapter latency classes

- Scripted/file-ops runtimes: sub-millisecond plan, fast execute.
- CLI runtime: dominated by process startup (~300ms) plus model time; timeout defaults 120s, kill verified by tests.
- BYOK planner: network-bound; the injected transport exists partly so tests never wait on TLS.
- Local tier: gated behind the 16GB floor precisely because below it, 4–7B quantized models miss usable latency. The gate *is* the performance feature.

## Memory & logs

- Screenshots live only in memory during a session (PRD §8). The JPEG data in `PerryScreenCapture` must never gain a disk write without revisiting that promise.
- Activity log persists JSON atomically after every entry; fine for interactive volumes. If Do mode ever batches thousands of steps, move to append-only NDJSON.
