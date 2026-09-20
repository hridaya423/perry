# Cua Driver acquisition

Perry pins the Apple Silicon Cua Driver to the official `trycua/cua` release below. The lock file is the acquisition contract; the fetch script does not query a latest endpoint, use a moving tag, or execute the upstream installer.

| Field | Pinned value |
| --- | --- |
| Version | `0.22.1` |
| Target | `aarch64-apple-darwin` |
| Release tag | [`cua-driver-rs-v0.22.1`](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.22.1) |
| Asset | `cua-driver-rs-0.22.1-darwin-arm64.tar.gz` |
| Asset URL | `https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.22.1/cua-driver-rs-0.22.1-darwin-arm64.tar.gz` |
| Archive SHA256 | `1ef80b48b0b4ccd3b2eadd72c3c66735a65e15306db92816fb04f963d202155d` |
| Binary member | `cua-driver-rs-0.22.1-darwin-arm64/cua-driver` |
| Archive member SHA256 | `3bb9fb04c147cefa92bb5e83365b233110762b0d2a295a3f761d66147f88486d` |
| Distribution binary SHA256 | `c8343fb4ce61af8091bd3a08d8c6c812b5b45488f78a72d110685e5eb2b80cc9` |
| Signing identifier | `cua-driver` |
| Signing team | `YCK386LBJ7` |
| Source revision | [`c60ef6ad2db8774fb342938843e2f17f26c68240`](https://github.com/trycua/cua/commit/c60ef6ad2db8774fb342938843e2f17f26c68240) |

The archive SHA256 is published by the release in [`checksums.txt`](https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.22.1/checksums.txt). The archive member is universal despite the asset name. Perry verifies its hash and Cua AI signature, extracts its arm64 slice, then verifies the derived hash, exact architecture, signing identifier, and signing team before installation. The slice-specific Cua signature remains valid after thinning.

Run the checks from the repository root:

```sh
scripts/fetch-cua-driver.sh --check-lock
scripts/fetch-cua-driver.sh --check
scripts/test-cua-driver.sh
scripts/test-cua-host-lifecycle.sh /absolute/path/Perry.app
```

`--check-lock` validates the complete contract without touching the network. `--check` requires macOS on arm64, then checks only `App/Resources/CuaDriver/bin/cua-driver` and its `.version` marker; a missing or changed payload fails closed and never invokes `curl`. `--fetch` downloads the exact asset URL into a temporary directory, verifies the archive and member hashes, validates the upstream signature, derives the arm64 distribution binary, and verifies that output before installation.

The default destination matches `CuaDriverConfiguration`'s bundled lookup path. The script deliberately does not invoke `https://cua.ai/driver/install.sh`, because a piped installer would add an unpinned network-controlled step to the release path.

Perry runs the pinned executable as one direct MCP worker. The worker receives bounded permission mode, the reviewed capability manifest, and Perry's host identity through Cua's documented embedding environment. There is no reusable daemon socket or second proxy process. Closing Perry's stdio channel ends the worker, including when Perry is forcibly terminated; the lifecycle test reproduces that boundary against a built app.
