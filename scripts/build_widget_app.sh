#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="CodexQuotaWatch"
OUTPUT_PARENT="${1:-$REPO_DIR/build/widget}"
APP_DIR="$OUTPUT_PARENT/$APP_NAME.app"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build/native-widget}"
MODULE_CACHE="$BUILD_DIR/module-cache"
SOURCE="$REPO_DIR/native-widget/CodexQuotaWatch.swift"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Cannot find swiftc. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
  echo "Cannot find the macOS SDK. Install or repair Xcode Command Line Tools." >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.lumike.codex-quota-watch-widget</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Quota Watch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.3.0</string>
  <key>CFBundleVersion</key>
  <string>0.3.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if ! swiftc \
  -O \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  "$SOURCE" \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"; then
  cat >&2 <<'MSG'

Swift build failed. If the error mentions an unsupported SDK or SwiftShims,
repair the local Xcode Command Line Tools, then retry:

  sudo xcode-select --switch /Library/Developer/CommandLineTools
  xcode-select --install

MSG
  exit 1
fi

chmod 755 "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"
