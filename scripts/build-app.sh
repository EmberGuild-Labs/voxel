#!/bin/bash
# Assembles CoreAudioHelper.app from the SPM build.
#
# SwiftPM can't produce an .app bundle, and there's no Xcode on this machine, so
# we lay the bundle out by hand. That's fine -- the agent has no resources, no
# nib, and no UI. It needs exactly two things a bare executable can't provide:
# LSUIElement (no Dock icon) and a stable bundle identifier.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
OUT="$ROOT/build"
APP="$OUT/CoreAudioHelper.app"
VERSION="0.1.0"

echo "==> Building ($CONFIGURATION)"
cd "$ROOT"
swift build -c "$CONFIGURATION"
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CoreAudioHelper</string>
    <!-- Honest identifier. The *display* name is CoreAudioHelper so the process
         reads as boring in Activity Monitor; the identifier is not disguised,
         because impersonating an Apple daemon is what makes security tooling
         flag a binary. -->
    <key>CFBundleIdentifier</key>
    <string>com.emberguild.voxel.helper</string>
    <key>CFBundleName</key>
    <string>CoreAudioHelper</string>
    <key>CFBundleDisplayName</key>
    <string>CoreAudioHelper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Agent: no Dock icon, no menu bar, no windows. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

cp "$BIN/CoreAudioHelper" "$APP/Contents/MacOS/CoreAudioHelper"
cp "$BIN/voxel" "$OUT/voxel"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo ""
echo "Built:"
echo "  $APP"
echo "  $OUT/voxel"
echo ""
echo "Run the agent:   open $APP"
echo "Run in console:  $APP/Contents/MacOS/CoreAudioHelper"
echo "Stop it:         pkill -x CoreAudioHelper"
