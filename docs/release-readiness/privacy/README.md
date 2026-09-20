# Privacy capture evidence

Perry ships no third-party crash or product telemetry. Diagnostics stay local and export is user-initiated. The captures in this directory prove the app opens no external network connection from the recorded builds.

`telemetry-opt-out-2026-08-29.json` records an eight-second process-level `nettop` capture from an arm64 Debug build on macOS 26.5.1. The matching CSV contains eight headers and no connection rows, so the Perry process opened no external TCP or UDP connection during the sampled startup window.

`telemetry-persisted-opt-out-2026-08-29.json` records the same executable with the then-current telemetry preference persisted as false. Its matching capture also contains eight headers and no connection rows.

`telemetry-opt-out-60-sample-2026-08-29.json` records the rebuilt Debug executable over 60 samples. Its matching capture contains 60 headers and no external TCP or UDP connection rows.

`telemetry-opt-out-1800/metadata.json` records an immutable copy of the arm64 Release app over 1,800 one-second samples. Its raw `nettop.csv` contains exactly 1,800 headers and no external rows, and the metadata binds the executable and all four raw capture files by SHA-256.

The capture names retain their historical `telemetry-opt-out` prefix: they were recorded while opt-out behavior was being verified. Post-removal, the same artifacts stand as evidence that Perry's recorded builds made zero external network connections. They do not prove provider-side behavior, live user configuration, or a signed release candidate.
