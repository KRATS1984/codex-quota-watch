#!/usr/bin/env bash
set -euo pipefail

LABEL="com.lumike.codex-quota-watch-widget"
APP_DIR="$HOME/.codex-quota-watch"
WIDGET_DIR="$APP_DIR/widget"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$WIDGET_DIR" "$APP_DIR/widget-state.json" "$APP_DIR/widget.log" "$APP_DIR/widget.err.log"
  echo "Uninstalled $LABEL and removed widget files"
else
  echo "Uninstalled $LABEL. Kept widget files in $WIDGET_DIR"
fi
