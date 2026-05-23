# Codex Quota Watch

Unofficial macOS quota refresh notifier for Codex.

This tool reads Codex quota windows from the local Codex app-server method `account/rateLimits/read`, then sends a macOS notification when usage is low or when a quota refresh is detected. Optional mobile notifications can be enabled through webhook-based services such as Bark, ntfy, Pushover, Telegram, or WeCom bot.

Tested with Codex CLI `0.133.0` on macOS.

## Status

This is an unofficial, best-effort utility. It uses Codex local app-server internal protocol, not a public stable API. Future Codex updates may change or remove the method this tool depends on.

## Features

- Checks Codex quota every 5 minutes through `launchd`.
- Alerts when remaining quota is below 20% or 10%.
- Detects refreshes when `usedPercent` drops from a high value to a low value, or when the reset timestamp changes and usage decreases.
- Sends macOS notifications by default.
- Supports optional phone notifications through Bark, ntfy, Pushover, Telegram, WeCom bot, and generic webhooks.
- Stores runtime state locally so alerts are not repeated on every check.

## Requirements

- macOS.
- Codex CLI installed and logged in.
- Node.js available in `PATH`, or the bundled Codex Node runtime at `/Applications/Codex.app/Contents/Resources/node`.

## Install

```bash
./install_launch_agent.sh
```

Installed files:

- Runtime script: `~/.codex-quota-watch/codex-quota-watch.mjs`
- Local config: `~/.codex-quota-watch/config.json`
- State file: `~/.codex-quota-watch/state.json`
- Logs: `~/.codex-quota-watch/watch.log`
- Error logs: `~/.codex-quota-watch/watch.err.log`
- LaunchAgent: `~/Library/LaunchAgents/com.lumike.codex-quota-watch.plist`

The LaunchAgent runs once every 300 seconds. It is normal for `launchctl print` to show `state = not running` between checks.

## Manual Check

```bash
node ~/.codex-quota-watch/codex-quota-watch.mjs --print --no-notify
```

## Test Notifications

```bash
node ~/.codex-quota-watch/codex-quota-watch.mjs --test-notify
```

If macOS notifications do not appear, enable notification permission for Terminal, iTerm, or the app that runs the command.

## Mobile Notifications

Mobile notification credentials belong in `~/.codex-quota-watch/config.json`, not in this repository.

### Bark

Bark is the simplest iPhone option.

```json
{
  "mobile": {
    "bark": {
      "enabled": true,
      "url": "https://api.day.app/REPLACE_WITH_YOUR_KEY",
      "sound": "bell",
      "group": "Codex"
    }
  }
}
```

### ntfy

ntfy works across platforms. Use a private, hard-to-guess topic.

```json
{
  "mobile": {
    "ntfy": {
      "enabled": true,
      "url": "https://ntfy.sh/REPLACE_WITH_A_PRIVATE_TOPIC",
      "token": "",
      "priority": "high"
    }
  }
}
```

### WeCom Bot

```json
{
  "mobile": {
    "wecomBot": {
      "enabled": true,
      "url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REPLACE_WITH_KEY"
    }
  }
}
```

Pushover, Telegram, and generic webhook examples are included in `config.example.json`.

## Security

- Do not commit `~/.codex-quota-watch/config.json`; it may contain webhook URLs, bot tokens, or push service credentials.
- `config.example.json` contains placeholders only.
- `.gitignore` excludes local config, state, logs, `.env` files, and the local install directory.
- This tool starts a local Codex app-server process and reads account rate limit metadata from your existing Codex login. It does not need your GitHub token or OpenAI API key.

## Service Status

```bash
launchctl print gui/$UID/com.lumike.codex-quota-watch
tail -f ~/.codex-quota-watch/watch.log
tail -f ~/.codex-quota-watch/watch.err.log
```

## Uninstall

```bash
./uninstall_launch_agent.sh
```

Remove config and logs as well:

```bash
./uninstall_launch_agent.sh --purge
```

## Notes

The quota response currently includes fields such as `usedPercent`, `resetsAt`, `windowDurationMins`, `credits`, and `rateLimitsByLimitId`. These fields are internal to Codex app-server and may change without notice.
