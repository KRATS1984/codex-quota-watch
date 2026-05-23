#!/usr/bin/env node

import { spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import os from "node:os";
import http from "node:http";
import https from "node:https";

const VERSION = "0.1.0";
const DEFAULT_CONFIG_PATH = "~/.codex-quota-watch/config.json";
const DEFAULT_STATE_PATH = "~/.codex-quota-watch/state.json";

const DEFAULT_CONFIG = {
  codexPath: process.env.CODEX_CLI || "codex",
  timeoutMs: 20000,
  timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || "Asia/Shanghai",
  limitIds: ["codex"],
  thresholdsRemaining: [20, 10],
  refreshDropFromUsedPercent: 50,
  refreshDropToUsedPercent: 15,
  alertOnFirstRunBelowThreshold: true,
  notifyOnErrorAfterFailures: 6,
  localNotifications: true,
  localNotificationSound: "Glass",
  statePath: DEFAULT_STATE_PATH,
  mobile: {
    bark: { enabled: false, url: "", sound: "bell", group: "Codex" },
    ntfy: { enabled: false, url: "", token: "", priority: "high" },
    pushover: { enabled: false, appToken: "", userKey: "" },
    telegram: { enabled: false, botToken: "", chatId: "" },
    wecomBot: { enabled: false, url: "" },
    webhooks: [],
  },
};

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

function expandHome(value) {
  if (!value) return value;
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return join(os.homedir(), value.slice(2));
  return value;
}

function deepMerge(base, override) {
  if (!override || typeof override !== "object" || Array.isArray(override)) {
    return override === undefined ? base : override;
  }

  const out = { ...base };
  for (const [key, value] of Object.entries(override)) {
    if (
      value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      base &&
      typeof base[key] === "object" &&
      !Array.isArray(base[key])
    ) {
      out[key] = deepMerge(base[key], value);
    } else {
      out[key] = value;
    }
  }
  return out;
}

async function readJson(path, fallback) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw error;
  }
}

async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

async function loadConfig(configPath) {
  const expanded = expandHome(configPath);
  const fileConfig = existsSync(expanded) ? await readJson(expanded, {}) : {};
  const config = deepMerge(DEFAULT_CONFIG, fileConfig);
  config.configPath = expanded;
  config.statePath = expandHome(config.statePath || DEFAULT_STATE_PATH);
  config.limitIds = Array.isArray(config.limitIds) ? config.limitIds : ["codex"];
  config.thresholdsRemaining = Array.isArray(config.thresholdsRemaining)
    ? config.thresholdsRemaining
    : [20, 10];
  return config;
}

function sendJson(child, value) {
  child.stdin.write(`${JSON.stringify(value)}\n`);
}

function queryRateLimits(config) {
  return new Promise((resolve, reject) => {
    const child = spawn(config.codexPath || "codex", ["app-server", "--listen", "stdio://"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        TERM: process.env.TERM && process.env.TERM !== "dumb" ? process.env.TERM : "xterm-256color",
      },
    });

    let stdout = "";
    let stderr = "";
    let settled = false;

    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (!child.killed) child.kill("SIGTERM");
      if (error) reject(error);
      else resolve(result);
    };

    const timer = setTimeout(() => {
      finish(new Error(`Timed out reading Codex rate limits after ${config.timeoutMs} ms`));
    }, config.timeoutMs);

    child.on("error", (error) => finish(error));
    child.on("close", (code) => {
      if (!settled) {
        const detail = stderr.trim() || stdout.trim() || `exit code ${code}`;
        finish(new Error(`Codex app-server exited before returning rate limits: ${detail}`));
      }
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
      while (stdout.includes("\n")) {
        const idx = stdout.indexOf("\n");
        const line = stdout.slice(0, idx).trim();
        stdout = stdout.slice(idx + 1);
        if (!line) continue;

        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue;
        }

        if (message.id === 1 && message.result) {
          sendJson(child, { method: "initialized" });
          sendJson(child, { id: 2, method: "account/rateLimits/read", params: null });
        } else if (message.id === 1 && message.error) {
          finish(new Error(`Codex initialize failed: ${message.error.message || JSON.stringify(message.error)}`));
        } else if (message.id === 2 && message.result) {
          finish(null, message.result);
        } else if (message.id === 2 && message.error) {
          finish(new Error(`Codex rate limit read failed: ${message.error.message || JSON.stringify(message.error)}`));
        }
      }
    });

    sendJson(child, {
      id: 1,
      method: "initialize",
      params: {
        clientInfo: { name: "codex-quota-watch", version: VERSION },
        capabilities: {
          experimentalApi: true,
          optOutNotificationMethods: [],
        },
      },
    });
  });
}

function selectSnapshots(result, config) {
  const byId = result.rateLimitsByLimitId || {};
  const snapshots = [];
  for (const limitId of config.limitIds) {
    const snapshot = byId[limitId] || (result.rateLimits?.limitId === limitId ? result.rateLimits : null);
    if (snapshot) snapshots.push(snapshot);
  }
  if (!snapshots.length && result.rateLimits) snapshots.push(result.rateLimits);
  return snapshots;
}

function formatTime(epochSeconds, timeZone) {
  if (!epochSeconds) return "unknown";
  return new Intl.DateTimeFormat("zh-CN", {
    timeZone,
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(epochSeconds * 1000));
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

function summarizeSnapshots(snapshots, config) {
  return snapshots.map((snapshot) => ({
    limitId: snapshot.limitId,
    limitName: snapshot.limitName,
    planType: snapshot.planType,
    primary: snapshot.primary
      ? {
          usedPercent: snapshot.primary.usedPercent,
          remainingPercent: 100 - snapshot.primary.usedPercent,
          resetsAt: snapshot.primary.resetsAt,
          resetsAtText: formatTime(snapshot.primary.resetsAt, config.timeZone),
        }
      : null,
    secondary: snapshot.secondary
      ? {
          usedPercent: snapshot.secondary.usedPercent,
          remainingPercent: 100 - snapshot.secondary.usedPercent,
          resetsAt: snapshot.secondary.resetsAt,
          resetsAtText: formatTime(snapshot.secondary.resetsAt, config.timeZone),
        }
      : null,
    credits: snapshot.credits || null,
    rateLimitReachedType: snapshot.rateLimitReachedType || null,
  }));
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
