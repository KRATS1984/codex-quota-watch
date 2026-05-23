#!/usr/bin/env bash
set -euo pipefail

LABEL="com.lumike.codex-quota-watch-widget"
APP_DIR="$HOME/.codex-quota-watch"
WIDGET_DIR="$APP_DIR/widget"
APP_BUNDLE="$WIDGET_DIR/CodexQuotaWatch.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CODEX_BIN="${CODEX_CLI:-}"
if [[ -z "$CODEX_BIN" ]]; then
  CODEX_BIN="$(command -v codex || true)"
fi
if [[ -z "$CODEX_BIN" ]]; then
  echo "Cannot find codex. Install Codex CLI or set CODEX_CLI=/path/to/codex." >&2
  exit 1
fi

mkdir -p "$WIDGET_DIR" "$HOME/Library/LaunchAgents"
rm -rf \
  "$WIDGET_DIR/desktop" \
  "$WIDGET_DIR/lib" \
  "$WIDGET_DIR/node_modules" \
  "$WIDGET_DIR/package.json" \
  "$WIDGET_DIR/package-lock.json"

if [[ ! -f "$APP_DIR/config.json" ]]; then
  install -m 600 "$SCRIPT_DIR/config.example.json" "$APP_DIR/config.json"
fi

if [[ -d "$SCRIPT_DIR/dist/CodexQuotaWatch.app" ]]; then
  rm -rf "$APP_BUNDLE"
  rsync -a --delete "$SCRIPT_DIR/dist/CodexQuotaWatch.app/" "$APP_BUNDLE/"
else
  "$SCRIPT_DIR/scripts/build_widget_app.sh" "$WIDGET_DIR" >/dev/null
fi

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/CodexQuotaWatch" ]]; then
  echo "Native widget app was not built at $APP_BUNDLE" >&2
  exit 1
fi

: > "$APP_DIR/widget.log"
: > "$APP_DIR/widget.err.log"

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
    <string>$APP_BUNDLE/Contents/MacOS/CodexQuotaWatch</string>
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
  <key>WorkingDirectory</key>
  <string>$APP_DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$APP_DIR/widget.log</string>
  <key>StandardErrorPath</key>
  <string>$APP_DIR/widget.err.log</string>
</dict>
</plist>
PLIST

chmod 644 "$PLIST"

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
for _ in {1..30}; do
  if ! launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 &&
     ! pgrep -f "$APP_BUNDLE/Contents/MacOS/CodexQuotaWatch" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "Installed $LABEL"
echo "Widget: $APP_BUNDLE"
echo "Config: $APP_DIR/config.json"
echo "Logs:   $APP_DIR/widget.log and $APP_DIR/widget.err.log"
