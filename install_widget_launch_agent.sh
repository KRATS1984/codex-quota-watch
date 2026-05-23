#!/usr/bin/env bash
set -euo pipefail

LABEL="com.lumike.codex-quota-watch-widget"
APP_DIR="$HOME/.codex-quota-watch"
WIDGET_DIR="$APP_DIR/widget"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

prepare_electron_binary() {
  local electron_bin="$1"
  local dist_app="$2"

  if [[ -d "$dist_app" ]]; then
    "$electron_bin" --version >/dev/null
    return
  fi

  local electron_version
  electron_version="$(PACKAGE_JSON="$WIDGET_DIR/package.json" node -e 'const p=require(process.env.PACKAGE_JSON); console.log(p.devDependencies.electron.replace(/^[^0-9]*/, ""))')"

  local arch
  case "$(uname -m)" in
    arm64) arch="arm64" ;;
    x86_64) arch="x64" ;;
    *)
      echo "Unsupported macOS architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac

  local zip_name="electron-v${electron_version}-darwin-${arch}.zip"
  local expected_sha
  expected_sha="$(CHECKSUMS_JSON="$WIDGET_DIR/node_modules/electron/checksums.json" ZIP_NAME="$zip_name" node -e 'const c=require(process.env.CHECKSUMS_JSON); console.log(c[process.env.ZIP_NAME] || "")')"
  if [[ -z "$expected_sha" ]]; then
    echo "Cannot find checksum for $zip_name" >&2
    exit 1
  fi

  local url
  if [[ -n "${ELECTRON_MIRROR:-}" ]]; then
    url="${ELECTRON_MIRROR%/}/${electron_version}/${zip_name}"
  else
    url="https://github.com/electron/electron/releases/download/v${electron_version}/${zip_name}"
  fi

  local zip_path="$WIDGET_DIR/$zip_name"
  echo "Downloading Electron runtime: $url"
  curl -L --fail --progress-bar -o "$zip_path" "$url"

  local actual_sha
  actual_sha="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Checksum mismatch for $zip_name" >&2
    echo "expected: $expected_sha" >&2
    echo "actual:   $actual_sha" >&2
    exit 1
  fi

  rm -rf "$WIDGET_DIR/node_modules/electron/dist"
  mkdir -p "$WIDGET_DIR/node_modules/electron/dist"
  ditto -x -k "$zip_path" "$WIDGET_DIR/node_modules/electron/dist"
  printf "Electron.app/Contents/MacOS/Electron" > "$WIDGET_DIR/node_modules/electron/path.txt"
  rm -f "$zip_path"
  "$electron_bin" --version >/dev/null
}

CODEX_BIN="${CODEX_CLI:-}"
if [[ -z "$CODEX_BIN" ]]; then
  CODEX_BIN="$(command -v codex || true)"
fi
if [[ -z "$CODEX_BIN" ]]; then
  echo "Cannot find codex. Install Codex CLI or set CODEX_CLI=/path/to/codex." >&2
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "Cannot find npm. Install Node.js before installing the widget." >&2
  exit 1
fi

mkdir -p "$WIDGET_DIR" "$HOME/Library/LaunchAgents"
rsync -a --delete "$SCRIPT_DIR/lib/" "$WIDGET_DIR/lib/"
rsync -a --delete "$SCRIPT_DIR/desktop/" "$WIDGET_DIR/desktop/"
install -m 644 "$SCRIPT_DIR/package.json" "$WIDGET_DIR/package.json"
install -m 644 "$SCRIPT_DIR/package-lock.json" "$WIDGET_DIR/package-lock.json"

if [[ ! -f "$APP_DIR/config.json" ]]; then
  install -m 600 "$SCRIPT_DIR/config.example.json" "$APP_DIR/config.json"
fi

(
  cd "$WIDGET_DIR"
  npm ci --omit=optional --include=dev
)

ELECTRON_BIN="$WIDGET_DIR/node_modules/.bin/electron"
if [[ ! -x "$ELECTRON_BIN" ]]; then
  echo "Electron was not installed at $ELECTRON_BIN" >&2
  exit 1
fi

prepare_electron_binary "$ELECTRON_BIN" "$WIDGET_DIR/node_modules/electron/dist/Electron.app"

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
    <string>$ELECTRON_BIN</string>
    <string>$WIDGET_DIR/desktop/main.mjs</string>
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
  <string>$WIDGET_DIR</string>
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
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "Installed $LABEL"
echo "Widget: $WIDGET_DIR"
echo "Config: $APP_DIR/config.json"
echo "Logs:   $APP_DIR/widget.log and $APP_DIR/widget.err.log"
