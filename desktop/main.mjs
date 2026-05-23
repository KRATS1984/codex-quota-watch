import { app, BrowserWindow, Menu, Tray, ipcMain, nativeImage, screen } from "electron";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { DEFAULT_CONFIG_PATH, loadConfig, readJson, writeJson } from "../lib/config.mjs";
import { getWeeklyQuota, queryRateLimits } from "../lib/quota-client.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DEFAULT_BOUNDS = { width: 226, height: 226 };

let config;
let widgetState = {};
let mainWindow;
let tray;
let pollTimer;
let lastPayload = null;

function parseArgs(argv) {
  const args = { configPath: DEFAULT_CONFIG_PATH };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--config") args.configPath = argv[++i];
  }
  return args;
}

async function bootstrap() {
  const args = parseArgs(process.argv.slice(2));
  config = await loadConfig(args.configPath);
  widgetState = await readJson(config.widget.statePath, {});

  if (process.platform === "darwin") app.dock.hide();

  createWindow();
  createTray();
  await refreshQuota();
  pollTimer = setInterval(refreshQuota, config.widget.pollIntervalSeconds * 1000);
}

function createWindow() {
  const bounds = normalizedBounds(widgetState.bounds);
  const hidden = widgetState.hidden === true || config.widget.showOnLaunch === false;

  mainWindow = new BrowserWindow({
    ...bounds,
    frame: false,
    transparent: true,
    resizable: false,
    fullscreenable: false,
    minimizable: false,
    maximizable: false,
    hasShadow: false,
    skipTaskbar: true,
    show: !hidden,
    alwaysOnTop: config.widget.alwaysOnTop,
    backgroundColor: "#00000000",
    title: "Codex Quota Watch",
    webPreferences: {
      preload: join(__dirname, "preload.mjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  mainWindow.setAlwaysOnTop(Boolean(config.widget.alwaysOnTop), "floating");
  mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  mainWindow.loadFile(join(__dirname, "index.html"));
  mainWindow.on("moved", persistBounds);
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

function createTray() {
  tray = new Tray(createTrayIcon());
  tray.setToolTip("Codex weekly quota");
  tray.on("click", toggleWindow);
  updateTrayMenu();
}

function updateTrayMenu() {
  if (!tray) return;
  const visible = Boolean(mainWindow?.isVisible());
  const menu = Menu.buildFromTemplate([
    { label: visible ? "Hide Widget" : "Show Widget", click: toggleWindow },
    { label: "Refresh Now", click: refreshQuota },
    { type: "separator" },
    { label: "Quit", click: quitApp },
  ]);
  tray.setContextMenu(menu);
}

function normalizedBounds(savedBounds) {
  const display = screen.getPrimaryDisplay().workArea;
  const width = DEFAULT_BOUNDS.width;
  const height = DEFAULT_BOUNDS.height;
  const fallback = {
    width,
    height,
    x: display.x + display.width - width - 32,
    y: display.y + 72,
  };

  if (!savedBounds) return fallback;
  const x = Number(savedBounds.x);
  const y = Number(savedBounds.y);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return fallback;
  return {
    width,
    height,
    x: Math.max(display.x, Math.min(x, display.x + display.width - width)),
    y: Math.max(display.y, Math.min(y, display.y + display.height - height)),
  };
}

function createTrayIcon() {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
    <defs><linearGradient id="g" x1="4" y1="4" x2="28" y2="28"><stop stop-color="#65f4ff"/><stop offset="1" stop-color="#9cff6f"/></linearGradient></defs>
    <circle cx="16" cy="16" r="13" fill="#101820"/>
    <path d="M16 3a13 13 0 1 1-9.19 3.81" fill="none" stroke="url(#g)" stroke-width="3" stroke-linecap="round"/>
    <text x="16" y="20" text-anchor="middle" font-family="Arial" font-size="11" font-weight="700" fill="#ffffff">Q</text>
  </svg>`;
  return nativeImage.createFromDataURL(`data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`);
}

async function refreshQuota() {
  try {
    const result = await queryRateLimits(config, "codex-quota-watch-widget");
    const quota = getWeeklyQuota(result, config, "codex");
    if (!quota) throw new Error("Weekly Codex quota window is unavailable");

    lastPayload = {
      ok: true,
      offline: false,
      checkedAt: new Date().toISOString(),
      ...quota,
    };
    console.log(
      `[widget] weekly remaining=${lastPayload.remainingPercent}% used=${lastPayload.usedPercent}% reset=${lastPayload.resetsAtText}`,
    );
    sendUpdate(lastPayload);
    updateTrayTitle(lastPayload);
  } catch (error) {
    console.error(`[widget] quota refresh failed: ${error.message}`);
    const payload = {
      ok: false,
      offline: true,
      checkedAt: new Date().toISOString(),
      error: error.message,
      lastKnown: lastPayload,
    };
    sendUpdate(payload);
    updateTrayTitle(payload);
  }
}

function sendUpdate(payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send("quota:update", payload);
  }
}

function updateTrayTitle(payload) {
  if (!tray) return;
  if (payload.ok) {
    tray.setToolTip(`Codex weekly remaining: ${payload.remainingPercent}%`);
  } else if (payload.lastKnown) {
    tray.setToolTip(`Codex weekly remaining: ${payload.lastKnown.remainingPercent}% (offline)`);
  } else {
    tray.setToolTip("Codex weekly quota offline");
  }
}

async function persistState() {
  await writeJson(config.widget.statePath, widgetState);
}

function persistBounds() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  widgetState.bounds = mainWindow.getBounds();
  persistState().catch((error) => console.error(error));
}

function showWindow() {
  if (!mainWindow) createWindow();
  mainWindow.showInactive();
  mainWindow.setAlwaysOnTop(Boolean(config.widget.alwaysOnTop), "floating");
  widgetState.hidden = false;
  persistState().catch((error) => console.error(error));
  updateTrayMenu();
}

function hideWindow() {
  if (mainWindow) mainWindow.hide();
  widgetState.hidden = true;
  persistState().catch((error) => console.error(error));
  updateTrayMenu();
}

function toggleWindow() {
  if (mainWindow?.isVisible()) hideWindow();
  else showWindow();
}

function quitApp() {
  if (pollTimer) clearInterval(pollTimer);
  app.quit();
}

ipcMain.handle("quota:refresh", refreshQuota);
ipcMain.on("widget:hide", hideWindow);

app.whenReady().then(bootstrap).catch((error) => {
  console.error(error);
  app.quit();
});

app.on("before-quit", persistBounds);
app.on("window-all-closed", () => {});
