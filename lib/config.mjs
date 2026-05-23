import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import os from "node:os";

export const VERSION = "0.3.0";
export const DEFAULT_CONFIG_PATH = "~/.codex-quota-watch/config.json";
export const DEFAULT_STATE_PATH = "~/.codex-quota-watch/state.json";
export const DEFAULT_WIDGET_STATE_PATH = "~/.codex-quota-watch/widget-state.json";

export const DEFAULT_CONFIG = {
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
  widget: {
    pollIntervalSeconds: 300,
    showOnLaunch: true,
    alwaysOnTop: true,
    size: 96,
    idleOpacity: 0.55,
    activeOpacity: 0.94,
    edgeSnap: true,
    snapMargin: 12,
    statePath: DEFAULT_WIDGET_STATE_PATH,
  },
  mobile: {
    bark: { enabled: false, url: "", sound: "bell", group: "Codex" },
    ntfy: { enabled: false, url: "", token: "", priority: "high" },
    pushover: { enabled: false, appToken: "", userKey: "" },
    telegram: { enabled: false, botToken: "", chatId: "" },
    wecomBot: { enabled: false, url: "" },
    webhooks: [],
  },
};

export function expandHome(value) {
  if (!value) return value;
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return join(os.homedir(), value.slice(2));
  return value;
}

export function deepMerge(base, override) {
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

export async function readJson(path, fallback) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw error;
  }
}

export async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

export async function loadConfig(configPath = DEFAULT_CONFIG_PATH) {
  const expanded = expandHome(configPath);
  const fileConfig = existsSync(expanded) ? await readJson(expanded, {}) : {};
  const config = deepMerge(DEFAULT_CONFIG, fileConfig);
  config.configPath = expanded;
  config.statePath = expandHome(config.statePath || DEFAULT_STATE_PATH);
  config.widget ||= {};
  config.widget.statePath = expandHome(config.widget.statePath || DEFAULT_WIDGET_STATE_PATH);
  config.widget.pollIntervalSeconds = Math.max(15, Number(config.widget.pollIntervalSeconds || 300));
  config.widget.showOnLaunch = config.widget.showOnLaunch !== false;
  config.widget.alwaysOnTop = config.widget.alwaysOnTop !== false;
  config.widget.size = Math.max(56, Math.min(160, Number(config.widget.size || 96)));
  config.widget.idleOpacity = Math.max(0.25, Math.min(1, Number(config.widget.idleOpacity || 0.55)));
  config.widget.activeOpacity = Math.max(
    config.widget.idleOpacity,
    Math.min(1, Number(config.widget.activeOpacity || 0.94)),
  );
  config.widget.edgeSnap = config.widget.edgeSnap !== false;
  config.widget.snapMargin = Math.max(0, Math.min(64, Number(config.widget.snapMargin || 12)));
  config.limitIds = Array.isArray(config.limitIds) ? config.limitIds : ["codex"];
  config.thresholdsRemaining = Array.isArray(config.thresholdsRemaining)
    ? config.thresholdsRemaining
    : [20, 10];
  return config;
}
