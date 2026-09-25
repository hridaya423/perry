# AGENTS.md: Perry execution contract

macOS 27 / Xcode 26.6, arm64 only. XcodeGen-generated project.

## Verified commands

```sh
build/tools/xcodegen/bin/xcodegen generate --spec project.yml          # regenerate project
xcodebuild build -project Perry.xcodeproj -scheme Perry -configuration Debug \
  -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64'
swift test --package-path Packages/PerryCore        # also PerryGuide, PerryOverlay,
                                                    # PerryCapture, PerryRuntimes
scripts/performance/self-test.sh                    # perf tooling unit tests
```

## Rules

- `Perry.xcodeproj` is generated, so never hand-edit it. Add files under `App/`
  or `Packages/` and regenerate with xcodegen.
- Reuse `build/debug-p1` DerivedData; no clean builds.
- The XCUITest runner hangs in `_dyld_start` on macOS 27 / Xcode 26.6
  (testmanagerd never ready). Do not gate on the PerryUI scheme; drive the real
  app with `scripts/lab/` + `cua-driver` instead.
- Never commit `.devin/`, `.audit/`, or `build/`. No `git push`.
- No new third-party dependencies without approval.

## Lab (scripts/lab/)

- `perry-drive.sh {launch|hotkey <combo>|windows|quit}`: launch sets
  `PERRY_PERFORMANCE_EVENT_LOG` to `docs/evidence/lab/perf-<ts>.jsonl`, which
  makes `PerfMark.mark(...)` append `{name, captured_at}` rows to
  `<log>.markers.jsonl`.
- `latency-report.py <markers.jsonl> [--pair a:b] [--json]` prints n/p50/p95/max ms.
- `idle-probe.sh [--seconds 60]` enforces budgets: avg CPU <= 0.5%, max RSS <= 180 MB.
- `record.sh <name> [seconds]` screen-records to `docs/evidence/recordings/`.
