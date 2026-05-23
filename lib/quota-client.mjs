import { spawn } from "node:child_process";
import { VERSION } from "./config.mjs";

export function queryRateLimits(config, clientName = "codex-quota-watch") {
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
        clientInfo: { name: clientName, version: VERSION },
        capabilities: {
          experimentalApi: true,
          optOutNotificationMethods: [],
        },
      },
    });
  });
}

export function selectSnapshots(result, config) {
  const byId = result.rateLimitsByLimitId || {};
  const snapshots = [];
  for (const limitId of config.limitIds) {
    const snapshot = byId[limitId] || (result.rateLimits?.limitId === limitId ? result.rateLimits : null);
    if (snapshot) snapshots.push(snapshot);
  }
  if (!snapshots.length && result.rateLimits) snapshots.push(result.rateLimits);
  return snapshots;
}

export function selectSnapshot(result, limitId = "codex") {
  return result.rateLimitsByLimitId?.[limitId] || (result.rateLimits?.limitId === limitId ? result.rateLimits : null);
}

export function clampPercent(value) {
  if (!Number.isFinite(value)) return null;
  return Math.max(0, Math.min(100, Math.round(value)));
}

export function formatTime(epochSeconds, timeZone) {
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

export function summarizeSnapshots(snapshots, config) {
  return snapshots.map((snapshot) => ({
    limitId: snapshot.limitId,
    limitName: snapshot.limitName,
    planType: snapshot.planType,
    primary: summarizeWindow(snapshot.primary, config),
    secondary: summarizeWindow(snapshot.secondary, config),
    credits: snapshot.credits || null,
    rateLimitReachedType: snapshot.rateLimitReachedType || null,
  }));
}

export function getWeeklyQuota(result, config, limitId = "codex") {
  const snapshot = selectSnapshot(result, limitId) || result.rateLimits;
  const window = snapshot?.secondary;
  if (!window || typeof window.usedPercent !== "number") {
    return null;
  }

  const usedPercent = clampPercent(Number(window.usedPercent));
  const remainingPercent = clampPercent(100 - usedPercent);
  return {
    limitId: snapshot.limitId || limitId,
    limitName: snapshot.limitName || null,
    planType: snapshot.planType || null,
    usedPercent,
    remainingPercent,
    resetsAt: window.resetsAt ?? null,
    resetsAtText: formatTime(window.resetsAt, config.timeZone),
    windowDurationMins: window.windowDurationMins ?? null,
  };
}

function summarizeWindow(window, config) {
  if (!window) return null;
  const usedPercent = clampPercent(Number(window.usedPercent));
  return {
    usedPercent,
    remainingPercent: usedPercent === null ? null : clampPercent(100 - usedPercent),
    resetsAt: window.resetsAt,
    resetsAtText: formatTime(window.resetsAt, config.timeZone),
  };
}

function sendJson(child, value) {
  child.stdin.write(`${JSON.stringify(value)}\n`);
}
