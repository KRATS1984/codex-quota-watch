# Codex 额度刷新提醒

这个目录里是一套本地 Codex 额度监控脚本。它不爬网页，而是调用 Codex 本地 app-server 的 `account/rateLimits/read` 内部接口读取额度窗口。

当前监控逻辑：

- 每 5 分钟读取一次 Codex 额度。
- 剩余额度低于 20% 或 10% 时提醒。
- `usedPercent` 从高值降到低值，或重置时间变化且已用比例下降时，提醒“额度已刷新”。
- 默认发 macOS 本机通知。
- 手机提醒通过配置 webhook 开启，支持 Bark、ntfy、Pushover、Telegram、企业微信群机器人和通用 webhook。

## 安装

```bash
./install_launch_agent.sh
```

安装后文件位置：

- 运行脚本：`~/.codex-quota-watch/codex-quota-watch.mjs`
- 配置文件：`~/.codex-quota-watch/config.json`
- 日志：`~/.codex-quota-watch/watch.log`
- 错误日志：`~/.codex-quota-watch/watch.err.log`

## 手动检查

```bash
node ~/.codex-quota-watch/codex-quota-watch.mjs --print --no-notify
```

## 测试通知

```bash
node ~/.codex-quota-watch/codex-quota-watch.mjs --test-notify
```

如果 macOS 弹不出通知，到系统设置里给 Terminal、iTerm 或 Script Editor 打开通知权限。

## 手机提醒

最省事的 iPhone 方案是 Bark：

1. 在 iPhone 安装 Bark。
2. 打开 Bark，复制 `https://api.day.app/...` 形式的地址。
3. 编辑 `~/.codex-quota-watch/config.json`：

```json
{
  "mobile": {
    "bark": {
      "enabled": true,
      "url": "https://api.day.app/你的BarkKey",
      "sound": "bell",
      "group": "Codex"
    }
  }
}
```

Android 或跨平台可以用 ntfy：

```json
{
  "mobile": {
    "ntfy": {
      "enabled": true,
      "url": "https://ntfy.sh/一个足够随机的私有topic",
      "token": "",
      "priority": "high"
    }
  }
}
```

如果你更习惯企业微信，可以建一个群机器人，然后配置：

```json
{
  "mobile": {
    "wecomBot": {
      "enabled": true,
      "url": "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=你的key"
    }
  }
}
```

配置文件里可能放 token，权限默认是 `600`，不要提交到 Git。

## 查看服务状态

```bash
launchctl print gui/$UID/com.lumike.codex-quota-watch
tail -f ~/.codex-quota-watch/watch.log
tail -f ~/.codex-quota-watch/watch.err.log
```

## 卸载

```bash
./uninstall_launch_agent.sh
```

彻底删除配置和日志：

```bash
./uninstall_launch_agent.sh --purge
```

## 注意

`account/rateLimits/read` 是 Codex app-server 的内部协议，不是公开稳定 API。脚本已经把失败写进日志，并在连续失败 6 次后提醒；如果以后 Codex 升级改了协议，需要跟着更新脚本。
