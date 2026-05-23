#!/usr/bin/env node

import { spawn } from "node:child_process";
import http from "node:http";
import https from "node:https";
import { dirname } from "node:path";
import { mkdir } from "node:fs/promises";
import { DEFAULT_CONFIG_PATH, VERSION, loadConfig, readJson, writeJson } from "../lib/config.mjs";
import { formatTime, queryRateLimits, selectSnapshots, summarizeSnapshots } from "../lib/quota-client.mjs";

function usage() {
  console.log(`codex-quota-watch ${VERSION}

Usage:
  codex-quota-watch.mjs [--once] [--print] [--no-notify] [--test-notify] [--config PATH]

Options:
  --once         Run one check. This is the default mode.
  --print        Print the selected quota snapshots and generated events.
  --no-notify    Evaluate state but do not send local or mobile notifications.
  --test-notify  Send a test notification through enabled channels.
  --config PATH  Use a custom config JSON file.
`);
}

function parseArgs(argv) {
  const args = {
    configPath: DEFAULT_CONFIG_PATH,
    print: false,
    noNotify: false,
    testNotify: false,
    help: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--config") {
      args.configPath = argv[++i];
    } else if (arg === "--print") {
      args.print = true;
    } else if (arg === "--no-notify") {
      args.noNotify = true;
    } else if (arg === "--test-notify") {
      args.testNotify = true;
    } else if (arg === "--once") {
      // Kept for readability in LaunchAgent ProgramArguments.
    } else if (arg === "-h" || arg === "--help") {
      args.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return args;
}

function labelForWindow(kind) {
  return kind === "primary" ? "5 小时窗口" : "周窗口";
}

function limitLabel(snapshot) {
  return snapshot.limitName || snapshot.limitId || "codex";
}

function eventKey(limitId, kind, type, detail, resetsAt) {
  return [limitId || "unknown", kind, type, detail, resetsAt || "no-reset"].join(":");
}

function getWindowState(state, limitId, kind) {
  return state.lastSnapshots?.[limitId]?.[kind] || null;
}

function setWindowState(state, limitId, kind, window) {
  state.lastSnapshots ||= {};
  state.lastSnapshots[limitId] ||= {};
  state.lastSnapshots[limitId][kind] = window
    ? {
        usedPercent: window.usedPercent,
        resetsAt: window.resetsAt ?? null,
        windowDurationMins: window.windowDurationMins ?? null,
      }
    : null;
}

function markEvent(state, key) {
  state.notifiedEvents ||= {};
  state.notifiedEvents[key] = Date.now();
}

function hasEvent(state, key) {
  return Boolean(state.notifiedEvents?.[key]);
}

function pruneOldEvents(state) {
  const cutoff = Date.now() - 45 * 24 * 60 * 60 * 1000;
  state.notifiedEvents ||= {};
  for (const [key, value] of Object.entries(state.notifiedEvents)) {
    if (typeof value === "number" && value < cutoff) delete state.notifiedEvents[key];
  }
}

function buildEvent(snapshot, kind, window, type, detail, config) {
  const remaining = Math.max(0, 100 - Number(window.usedPercent || 0));
  const reset = formatTime(window.resetsAt, config.timeZone);
  const name = limitLabel(snapshot);
  const windowName = labelForWindow(kind);

  if (type === "refresh") {
    return {
      type,
      title: "Codex 额度已刷新",
      subtitle: `${name} ${windowName}`,
      body: `当前已用 ${window.usedPercent}%，剩余约 ${remaining}%。下次重置：${reset}。`,
    };
  }

  return {
    type,
    title: `Codex 剩余额度低于 ${detail}%`,
    subtitle: `${name} ${windowName}`,
    body: `当前已用 ${window.usedPercent}%，剩余约 ${remaining}%。下次重置：${reset}。`,
  };
}

function evaluateSnapshots(snapshots, state, config) {
  const events = [];
  pruneOldEvents(state);

  for (const snapshot of snapshots) {
    const id = snapshot.limitId || "codex";
    for (const kind of ["primary", "secondary"]) {
      const window = snapshot[kind];
      if (!window || typeof window.usedPercent !== "number") continue;

      const prev = getWindowState(state, id, kind);
      const currentUsed = Number(window.usedPercent);
      const prevUsed = typeof prev?.usedPercent === "number" ? Number(prev.usedPercent) : null;
      const currentRemaining = Math.max(0, 100 - currentUsed);

      const refreshDetected =
        prev &&
        ((prevUsed >= config.refreshDropFromUsedPercent && currentUsed <= config.refreshDropToUsedPercent) ||
          (prev.resetsAt && window.resetsAt && prev.resetsAt !== window.resetsAt && currentUsed < prevUsed));

      if (refreshDetected) {
        const key = eventKey(id, kind, "refresh", "drop", window.resetsAt);
        if (!hasEvent(state, key)) {
          events.push(buildEvent(snapshot, kind, window, "refresh", "drop", config));
          markEvent(state, key);
        }
      }

      for (const threshold of config.thresholdsRemaining) {
        const crossed =
          currentRemaining <= threshold &&
          ((prev && 100 - prevUsed > threshold) || (!prev && config.alertOnFirstRunBelowThreshold));
        const key = eventKey(id, kind, "threshold", threshold, window.resetsAt);
        if (crossed && !hasEvent(state, key)) {
          events.push(buildEvent(snapshot, kind, window, "threshold", threshold, config));
          markEvent(state, key);
        }
      }

      setWindowState(state, id, kind, window);
    }
  }

  state.lastSeenAt = new Date().toISOString();
  state.consecutiveFailures = 0;
  return events;
}

function appleScriptString(value) {
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

async function sendLocalNotification(event, config) {
  if (!config.localNotifications) return;
  const script = [
    "display notification",
    appleScriptString(event.body),
    "with title",
    appleScriptString(event.title),
    "subtitle",
    appleScriptString(event.subtitle || ""),
  ];
  if (config.localNotificationSound) {
    script.push("sound name", appleScriptString(config.localNotificationSound));
  }
  await runCommand("osascript", ["-e", script.join(" ")], 8000);
}

function runCommand(command, args, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "ignore", "pipe"] });
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`${command} timed out`));
    }, timeoutMs);
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`${command} exited ${code}: ${stderr.trim()}`));
    });
  });
}

function request(urlString, options = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const body = options.body ? Buffer.from(options.body) : null;
    const headers = { ...(options.headers || {}) };
    if (body && !headers["Content-Length"]) headers["Content-Length"] = String(body.length);

    const client = url.protocol === "http:" ? http : https;
    const req = client.request(
      url,
      {
        method: options.method || "POST",
        headers,
        timeout: options.timeoutMs || 10000,
      },
      (res) => {
        let responseBody = "";
        res.on("data", (chunk) => {
          responseBody += chunk.toString("utf8");
        });
        res.on("end", () => {
          if (res.statusCode >= 200 && res.statusCode < 300) resolve(responseBody);
          else reject(new Error(`${url.host} returned ${res.statusCode}: ${responseBody.slice(0, 300)}`));
        });
      },
    );
    req.on("timeout", () => {
      req.destroy(new Error(`${url.host} timed out`));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

function mobileText(event) {
  return `${event.subtitle ? `${event.subtitle}\n` : ""}${event.body}`;
}

async function sendMobileNotifications(event, config) {
  const mobile = config.mobile || {};
  const tasks = [];

  if (mobile.bark?.enabled && mobile.bark.url) {
    const base = mobile.bark.url.replace(/\/+$/, "");
    const url = new URL(`${base}/${encodeURIComponent(event.title)}/${encodeURIComponent(mobileText(event))}`);
    if (mobile.bark.group) url.searchParams.set("group", mobile.bark.group);
    if (mobile.bark.sound) url.searchParams.set("sound", mobile.bark.sound);
    tasks.push(request(url.toString(), { method: "GET" }));
  }

  if (mobile.ntfy?.enabled && mobile.ntfy.url) {
    const headers = {
      Title: event.title,
      Priority: mobile.ntfy.priority || "high",
      Tags: "warning",
      "Content-Type": "text/plain; charset=utf-8",
    };
    if (mobile.ntfy.token) headers.Authorization = `Bearer ${mobile.ntfy.token}`;
    tasks.push(request(mobile.ntfy.url, { headers, body: mobileText(event) }));
  }

  if (mobile.pushover?.enabled && mobile.pushover.appToken && mobile.pushover.userKey) {
    const form = new URLSearchParams({
      token: mobile.pushover.appToken,
      user: mobile.pushover.userKey,
      title: event.title,
      message: mobileText(event),
    });
    tasks.push(
      request("https://api.pushover.net/1/messages.json", {
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form.toString(),
      }),
    );
  }

  if (mobile.telegram?.enabled && mobile.telegram.botToken && mobile.telegram.chatId) {
    tasks.push(
      request(`https://api.telegram.org/bot${mobile.telegram.botToken}/sendMessage`, {
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: mobile.telegram.chatId,
          text: `${event.title}\n${mobileText(event)}`,
          disable_web_page_preview: true,
        }),
      }),
    );
  }

  if (mobile.wecomBot?.enabled && mobile.wecomBot.url) {
    tasks.push(
      request(mobile.wecomBot.url, {
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          msgtype: "markdown",
          markdown: { content: `**${event.title}**\n>${mobileText(event).replace(/\n/g, "\n>")}` },
        }),
      }),
    );
  }

  for (const hook of Array.isArray(mobile.webhooks) ? mobile.webhooks : []) {
    if (!hook?.enabled || !hook.url) continue;
    tasks.push(
      request(hook.url, {
        headers: { "Content-Type": "application/json", ...(hook.headers || {}) },
        body: JSON.stringify({ title: event.title, subtitle: event.subtitle, body: event.body, type: event.type }),
      }),
    );
  }

  const results = await Promise.allSettled(tasks);
  for (const result of results) {
    if (result.status === "rejected") console.error(`[mobile-notify] ${result.reason.message}`);
  }
}

async function notify(event, config) {
  await Promise.allSettled([sendLocalNotification(event, config), sendMobileNotifications(event, config)]).then(
    (results) => {
      for (const result of results) {
        if (result.status === "rejected") console.error(`[notify] ${result.reason.message}`);
      }
    },
  );
}

async function handleFailure(error, state, config, noNotify) {
  state.consecutiveFailures = Number(state.consecutiveFailures || 0) + 1;
  state.lastFailureAt = new Date().toISOString();
  state.lastFailureMessage = error.message;

  if (
    !noNotify &&
    config.notifyOnErrorAfterFailures > 0 &&
    state.consecutiveFailures === config.notifyOnErrorAfterFailures
  ) {
    await notify(
      {
        type: "error",
        title: "Codex 额度监控读取失败",
        subtitle: `${state.consecutiveFailures} 次连续失败`,
        body: error.message,
      },
      config,
    );
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return;
  }

  const config = await loadConfig(args.configPath);
  if (args.noNotify) {
    config.localNotifications = false;
    config.mobile = {};
  }

  await mkdir(dirname(config.statePath), { recursive: true });
  const state = await readJson(config.statePath, {});

  if (args.testNotify) {
    const event = {
      type: "test",
      title: "Codex 额度提醒测试",
      subtitle: "本机和手机通道",
      body: "如果你看到这条消息，通知通道已经打通。",
    };
    if (!args.noNotify) await notify(event, config);
    console.log(JSON.stringify({ ok: true, event }, null, 2));
    return;
  }

  try {
    const result = await queryRateLimits(config);
    const snapshots = selectSnapshots(result, config);
    const events = evaluateSnapshots(snapshots, state, config);
    await writeJson(config.statePath, state);

    if (!args.noNotify) {
      for (const event of events) await notify(event, config);
    }

    const summary = {
      ok: true,
      checkedAt: new Date().toISOString(),
      snapshots: summarizeSnapshots(snapshots, config),
      events,
    };

    if (args.print || events.length) {
      console.log(JSON.stringify(summary, null, 2));
    } else {
      const first = summary.snapshots[0];
      console.log(
        `[ok] ${first?.limitId || "codex"} primary used=${first?.primary?.usedPercent ?? "?"}% secondary used=${
          first?.secondary?.usedPercent ?? "?"
        }%`,
      );
    }
  } catch (error) {
    await handleFailure(error, state, config, args.noNotify);
    await writeJson(config.statePath, state);
    console.error(`[error] ${error.message}`);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(`[fatal] ${error.stack || error.message}`);
  process.exitCode = 1;
});
