#!/usr/bin/env bash
set -euo pipefail

LABEL="com.lumike.codex-quota-watch"
APP_DIR="$HOME/.codex-quota-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$APP_DIR"
  echo "Uninstalled $LABEL and removed $APP_DIR"
else
  echo "Uninstalled $LABEL. Kept config and logs in $APP_DIR"
fi
