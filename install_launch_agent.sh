#!/usr/bin/env bash
set -euo pipefail

LABEL="com.lumike.codex-quota-watch"
APP_DIR="$HOME/.codex-quota-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_BIN="${NODE_BIN:-}"
if [[ -z "$NODE_BIN" ]]; then
  NODE_BIN="$(command -v node || true)"
fi
if [[ -z "$NODE_BIN" && -x "/Applications/Codex.app/Contents/Resources/node" ]]; then
  NODE_BIN="/Applications/Codex.app/Contents/Resources/node"
fi
if [[ -z "$NODE_BIN" ]]; then
  echo "Cannot find node. Install Node.js or set NODE_BIN=/path/to/node." >&2
  exit 1
fi

CODEX_BIN="${CODEX_CLI:-}"
if [[ -z "$CODEX_BIN" ]]; then
  CODEX_BIN="$(command -v codex || true)"
fi
if [[ -z "$CODEX_BIN" ]]; then
  echo "Cannot find codex. Install Codex CLI or set CODEX_CLI=/path/to/codex." >&2
  exit 1
fi

mkdir -p "$APP_DIR" "$HOME/Library/LaunchAgents"
install -m 755 "$SCRIPT_DIR/scripts/codex-quota-watch.mjs" "$APP_DIR/codex-quota-watch.mjs"

if [[ ! -f "$APP_DIR/config.json" ]]; then
  install -m 600 "$SCRIPT_DIR/config.example.json" "$APP_DIR/config.json"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$APP_DIR/codex-quota-watch.mjs</string>
    <string>--once</string>
    <string>--config</string>
    <string>$APP_DIR/config.json</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODEX_CLI</key>
    <string>$CODEX_BIN</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>StandardOutPath</key>
  <string>$APP_DIR/watch.log</string>
  <key>StandardErrorPath</key>
  <string>$APP_DIR/watch.err.log</string>
</dict>
</plist>
PLIST

chmod 644 "$PLIST"

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "Installed $LABEL"
echo "Config: $APP_DIR/config.json"
echo "Logs:   $APP_DIR/watch.log and $APP_DIR/watch.err.log"
