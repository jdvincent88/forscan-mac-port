#!/usr/bin/env bash
# Builds FordLink.app (SwiftUI) + the `fordlink` CLI into ./dist on macOS.
#   scripts/build-app.sh            # release build for this Mac's architecture
#   UNIVERSAL=1 scripts/build-app.sh  # arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname)" == "Darwin" ]] || { echo "Run this on macOS (needs SwiftUI)."; exit 1; }
command -v swift >/dev/null || { echo "Install Xcode or the Command Line Tools: xcode-select --install"; exit 1; }

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP=dist/FordLink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FordLinkApp" "$APP/Contents/MacOS/FordLink"
cp "$BIN_DIR/fordlink" dist/fordlink

VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FordLink</string>
  <key>CFBundleDisplayName</key><string>FordLink</string>
  <key>CFBundleIdentifier</key><string>com.cafecotillion.fordlink</string>
  <key>CFBundleExecutable</key><string>FordLink</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>FordLink connects to Bluetooth LE OBD adapters such as OBDLink CX.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>FordLink connects to Wi-Fi OBD adapters on the local network.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper lets it launch locally (right-click › Open the first time).
codesign --force --deep --sign - "$APP"
codesign --force --sign - dist/fordlink

echo "Built:"
echo "  $APP"
echo "  dist/fordlink   (try: dist/fordlink setup sim:mache)"
