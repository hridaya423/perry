#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-/tmp/PerryTortureFixture.app}
rm -rf "$out"
mkdir -p "$out/Contents/MacOS"
cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.perry.torture-fixture</string>
<key>CFBundleName</key><string>PerryTortureFixture</string>
<key>CFBundleExecutable</key><string>PerryTortureFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
swiftc -O "$here/main.swift" -o "$out/Contents/MacOS/PerryTortureFixture"
codesign -s - "$out"
echo "$out"
