#!/bin/bash
# ci.sh — the one command that must be green before a task is done:
# XcodeGen (if needed) → Debug build → swift test for every local package
# → the hosted PerryTests bundle. Exits non-zero on the first failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

XCODEGEN="$REPO_ROOT/build/tools/xcodegen/bin/xcodegen"
[ -x "$XCODEGEN" ] || XCODEGEN="$(command -v xcodegen || true)"
[ -n "$XCODEGEN" ] || { echo "ci: xcodegen missing — run scripts/fetch-xcodegen.sh --fetch" >&2; exit 2; }

DESTINATION='platform=macOS,arch=arm64'
DERIVED="build/debug-p1"

echo "== xcodegen =="
"$XCODEGEN" generate --spec project.yml

echo "== preferences guard =="
if grep -rnE 'UserDefaults\.standard|AppStorage\("perry\.|forKey: *"perry\.' App --include='*.swift' | grep -v 'App/PerryPreferences.swift'; then
    echo "ci: raw UserDefaults key outside App/PerryPreferences.swift" >&2
    exit 1
fi

echo "== type and palette guard =="
if grep -rn '\.system(size:' App/Notch App/Home App/CompactConversationView.swift; then
    echo "ci: fixed font size in a notch view; use PerryTheme.Scale or PerryTheme.Icon" >&2
    exit 1
fi
if grep -rn '\.font(\.system(size:' App/AgentActivityStrip.swift App/IntegrationRow.swift App/IntentCardWindow.swift App/Settings; then
    echo "ci: fixed font size outside the theme; use a PerryTheme token" >&2
    exit 1
fi
if grep -rnE '\b(NS)?Color\.black\b' App/Notch App/Home App/CompactConversationView.swift; then
    echo "ci: notch view paints black directly; use PerryTheme.Colors.crown or a palette token" >&2
    exit 1
fi

echo "== build (Debug arm64) =="
xcodebuild build -project Perry.xcodeproj -scheme Perry -configuration Debug \
    -derivedDataPath "$DERIVED" -destination "$DESTINATION" 2>&1 | tail -3

for pkg in PerryCore PerryBrain PerryGuide PerryOverlay PerryRuntimes; do
    echo "== swift test: $pkg =="
    swift test --package-path "Packages/$pkg" 2>&1 | tail -3
done

echo "== PerryTests =="
xcodebuild test -project Perry.xcodeproj -scheme Perry -configuration Debug \
    -derivedDataPath "$DERIVED" -destination "$DESTINATION" \
    -only-testing:PerryTests 2>&1 | tail -12

echo "== ci: all green =="
