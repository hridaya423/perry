# Demo script — Milestone 1–6 gate

One take, no cuts. Everything here runs from the current repo state.

## Setup (before recording)

1. `xcodegen generate && open Perry.xcodeproj` — build once so DerivedData is warm.
2. Terminal ready at repo root.
3. Finder window open on a folder with three files: `perry-demo-a.txt`, `-b`, `-c`.

## Beat 1 — the skeleton works (30s)

```bash
cd Packages/PerryRuntimes && swift run perry-demo
```

Narrate over the output: seven steps, planned, trust-guarded (green point, yellow writes), executed on disk, logged. Point at the activity log lines — tiers visible.

## Beat 2 — the brain is tested (20s)

```bash
for p in PerryCore PerryRuntimes PerryOverlay PerryCapture PerryGuide; do (cd Packages/$p && echo "== $p" && swift test 2>&1 | grep "Executed .* tests"); done
```

Six packages, every suite green. Say the number out loud.

## Beat 3 — the transplants are real (30s)

Open `docs/transplant-inventory.md`. Show the before/after line counts and the two hard rules held: zero CompanionManager references in Perry code (`grep -r CompanionManager Packages/ | wc -l` → 0 outside comments), capture refusal enforced at the pixel layer.

## Beat 4 — trust is not a settings page (40s)

Run the cleanup scenario test with verbose output; show the orange-tier confirmation card flow and the blocked-window denial (Bitwarden frontmost → task stops, nothing trashed). This is the Cursorly posture inherited by Perry.

## Beat 5 — honest hardware (20s)

Show `HardwareProbe.evaluate` output for an 8GB config: specific reason, alternatives offered. PRD principle 1 in one screen.

## Close

"Perry knows where everything is, asks before it does anything irreversible, never watches between sessions, and tells you the truth about your Mac. That's the skeleton. Guide mode ships next."
