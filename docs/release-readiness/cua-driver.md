# Cua Driver acquisition

Perry pins the Apple Silicon Cua Driver to the official `trycua/cua` release below. The lock file is the acquisition contract; the fetch script does not query a latest endpoint, use a moving tag, or execute the upstream installer.

| Field | Pinned value |
| --- | --- |
| Version | `0.38.0` |
| Target | `aarch64-apple-darwin` |
| Release tag | [`cua-driver-rs-v0.38.0`](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.38.0) |
| Asset | `cua-driver-rs-0.38.0-darwin-arm64.tar.gz` |
| Asset URL | `https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.38.0/cua-driver-rs-0.38.0-darwin-arm64.tar.gz` |
| Archive SHA256 | `5f71191c082ca07c9dfc13b7c9a6eec60a82818c245a93534cc0eb7911471d72` |
| Binary member | `cua-driver-rs-0.38.0-darwin-arm64/cua-driver` |
| Archive member SHA256 | `92067848d0eeb9de76929fbd06a137af801b0ff6caedbb3109bd7a6cc84a1f9f` |
| Distribution binary SHA256 | `6320105f0df8174175f75b68e59523fece754b83e62936ee9fbdead98fe15d9c` |
| Signing identifier | `cua-driver` |
| Signing team | `YCK386LBJ7` |
| Source revision | [`85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19`](https://github.com/trycua/cua/commit/85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19) |

The archive SHA256 is published by the release in [`checksums.txt`](https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.38.0/checksums.txt). The archive member is universal despite the asset name. Perry verifies its hash and Cua AI signature, extracts its arm64 slice, then verifies the derived hash, exact architecture, signing identifier, and signing team before installation. The slice-specific Cua signature remains valid after thinning.

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
