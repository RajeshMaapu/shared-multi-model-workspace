import { app, BrowserWindow, Menu, dialog, ipcMain, protocol }
  from "electron";
import { mkdirSync, realpathSync, writeFileSync }
  from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WorkshopRPC } from "../Web/rpc-client.mjs";
import { createTaskAPI } from "../Web/task-api.mjs";
import { validateInvocation } from "./ipc-policy.mjs";

const DESKTOP_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.dirname(DESKTOP_DIR);
const RENDERER_DIR = path.join(ROOT, "Web", "renderer");
const SCHEME = "workshop-preview";
const ORIGIN = `${SCHEME}://app`;
const CSP = "default-src 'self'; script-src 'self'; style-src 'self'; "
  + "img-src 'self'; connect-src 'self'; object-src 'none'; "
  + "base-uri 'none'; frame-ancestors 'none'";

const CONTENT_TYPES = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".png", "image/png"],
]);

const STATIC_NAMES = new Set([
  "index.html", "app.js", "client.js", "state.js", "style.css",
]);

function parseSocketArg(argv) {
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--workshop-socket") {
      const value = argv[i + 1];
      return typeof value === "string" && path.isAbsolute(value)
        ? value
        : null;
    }
  }
  return undefined;
}

function rendererFile(url) {
  let pathname;
  try {
    pathname = new URL(url).pathname;
  } catch {
    return null;
  }
  if (/\\|\0|%00|%2e/i.test(pathname) || pathname.includes("..")) {
    return null;
  }
  let name;
  if (pathname === "/" || pathname === "/index.html") {
    name = "index.html";
  } else if (pathname.startsWith("/assets/")) {
    const asset = pathname.slice("/assets/".length);
    if (!/^[A-Za-z0-9._-]+\.png$/.test(asset) || asset.includes("/")) {
      return null;
    }
    name = `assets/${asset}`;
  } else {
    name = pathname.slice(1);
    if (!STATIC_NAMES.has(name)) return null;
  }
  const candidate = path.join(RENDERER_DIR, name);
  try {
    const real = realpathSync(candidate);
    if (!real.startsWith(realpathSync(RENDERER_DIR) + path.sep)) {
      return null;
    }
    return real;
  } catch {
    return null;
  }
}

const socketPath = parseSocketArg(process.argv);
const SMOKE = process.env.WORKSHOP_PREVIEW_SMOKE === "1";
const SMOKE_DIR = process.env.WORKSHOP_PREVIEW_SMOKE_DIR
  || path.join(ROOT, ".build", "desktop-qa");

app.setPath("userData",
  path.join(app.getPath("appData"), "Workshop-Community-Preview"));
app.setName("Workshop Preview");

const lockGranted = app.requestSingleInstanceLock();
if (!lockGranted) {
  app.quit();
}

protocol.registerSchemesAsPrivileged([{
  scheme: SCHEME,
  privileges: { standard: true, secure: true, supportFetchAPI: true,
    stream: true },
}]);

function isOwnOrigin(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === `${SCHEME}:` && parsed.hostname === "app"
      && parsed.port === "" && parsed.username === ""
      && parsed.password === "";
  } catch {
    return false;
  }
}

let win = null;
let rpc = null;
let api = null;

function sendToRenderer(channel, payload) {
  if (win && !win.isDestroyed()) {
    try { win.webContents.send(channel, payload); } catch {}
  }
}

function startSubscription() {
  const state = {
    alive: true,
    cursor: 0,
    delay: 1000,
    timer: null,
    attempt: null,
    unsubscribe: null,
  };
  const cleanup = () => {
    if (!state.alive) return;
    state.alive = false;
    if (state.timer) { clearTimeout(state.timer); state.timer = null; }
    if (state.attempt) { state.attempt.abort(); state.attempt = null; }
    if (state.unsubscribe) { state.unsubscribe(); state.unsubscribe = null; }
  };
  const connect = () => {
    if (!state.alive) return;
    state.attempt = new AbortController();
    rpc.subscribe(state.cursor, (event) => {
      if (!state.alive) return;
      if (event.type === "message.delta") {
        sendToRenderer("workshop:event", { type: "refresh" });
        return;
      }
      if (event.seq <= state.cursor) return;
      state.cursor = event.seq;
      sendToRenderer("workshop:event", event);
    }, () => {
      state.unsubscribe = null;
      state.attempt = null;
      if (!state.alive) return;
      sendToRenderer("workshop:event",
        { type: "connection", connected: false });
      state.timer = setTimeout(() => {
        state.timer = null;
        connect();
      }, state.delay);
      state.delay = Math.min(state.delay * 2, 5000);
    }, { signal: state.attempt.signal }).then((unsub) => {
      state.unsubscribe = unsub;
      if (!state.alive) { unsub(); return; }
      state.delay = 1000;
      sendToRenderer("workshop:event",
        { type: "connection", connected: true });
    }).catch(() => {
      if (!state.alive) return;
      sendToRenderer("workshop:event",
        { type: "connection", connected: false });
      state.timer = setTimeout(() => {
        state.timer = null;
        connect();
      }, state.delay);
      state.delay = Math.min(state.delay * 2, 5000);
    });
  };
  connect();
  return cleanup;
}

let stopSubscription = null;
let subscribed = false;

function wireIPC() {
  ipcMain.handle("workshop:invoke", async (event, operation, args) => {
    try {
      if (!win || event.sender !== win.webContents
          || event.senderFrame !== win.webContents.mainFrame) {
        throw new Error("Invocation sender rejected");
      }
      const { operation: op, args: callArgs } = validateInvocation({
        senderURL: event.senderFrame.url,
        mainFrame: event.senderFrame === win.webContents.mainFrame,
        operation,
        args,
      });
      const value = await api[op](...callArgs);
      return { ok: true, value };
    } catch (err) {
      const status = err && err.statusCode === 400 ? 400 : 503;
      const message = status === 400
        ? err.message
        : "Workshop daemon unavailable or request failed";
      return { ok: false, error: message, status };
    }
  });

  ipcMain.on("workshop:subscribe", (event) => {
    if (!win || event.sender !== win.webContents
        || event.senderFrame !== win.webContents.mainFrame) {
      return;
    }
    if (!isOwnOrigin(event.senderFrame.url) || subscribed) return;
    subscribed = true;
    stopSubscription = startSubscription();
  });

  ipcMain.on("workshop:unsubscribe", (event) => {
    if (!win || event.sender !== win.webContents
        || event.senderFrame !== win.webContents.mainFrame
        || !isOwnOrigin(event.senderFrame.url)) {
      return;
    }
    subscribed = false;
    if (stopSubscription) { stopSubscription(); stopSubscription = null; }
  });
}

function buildMenu() {
  const template = [
    {
      label: app.name,
      submenu: [
        { role: "about" },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    { role: "editMenu" },
    {
      label: "View",
      submenu: [
        { role: "reload" },
        { type: "separator" },
        { role: "resetZoom" },
        { role: "zoomIn" },
        { role: "zoomOut" },
      ],
    },
    {
      label: "Window",
      submenu: [
        {
          label: "New Task",
          accelerator: "CmdOrCtrl+N",
          click: () => {
            if (win && !win.isDestroyed()) {
              win.webContents.executeJavaScript(
                "document.getElementById('task-draft')?.focus()");
            }
          },
        },
        { type: "separator" },
        { role: "minimize" },
        { role: "close" },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

async function runSmoke() {
  const expected = [
    "createTask", "getCapacity", "getDecisions", "getEngineers",
    "getFiles", "getMessages", "getProposals", "getTask", "listTasks",
    "postMessage", "subscribe",
  ];
  try {
    const deadline = Date.now() + 10000;
    let probe = null;
    while (Date.now() < deadline) {
      probe = await win.webContents.executeJavaScript(`({
        node: typeof process,
        require: typeof require,
        apiKeys: Object.keys(window.workshop || {}),
        taskCards: document.querySelectorAll('.task-card').length,
        connection: (document.querySelector('.connection-status')
          || {}).textContent || '',
      })`);
      if (probe && typeof probe.connection === "string"
          && probe.connection.includes("Connected")
          && probe.taskCards > 0) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    const apiKeys = probe && Array.isArray(probe.apiKeys)
      ? probe.apiKeys.slice().sort()
      : [];
    const result = {
      pass: probe !== null
        && probe.node === "undefined"
        && probe.require === "undefined"
        && JSON.stringify(apiKeys) === JSON.stringify(expected)
        && typeof probe.connection === "string"
        && probe.connection.includes("Connected")
        && probe.taskCards > 0,
      probe: probe === null ? null : { ...probe, apiKeys },
    };
    mkdirSync(SMOKE_DIR, { recursive: true });
    const image = await win.webContents.capturePage();
    writeFileSync(path.join(SMOKE_DIR, "smoke.png"), image.toPNG());
    writeFileSync(path.join(SMOKE_DIR, "smoke.json"),
      JSON.stringify(result, null, 2));
    console.log("SMOKE_RESULT " + JSON.stringify(result));
    if (result.pass) {
      app.quit();
    } else {
      app.exit(1);
    }
  } catch (err) {
    console.log("SMOKE_RESULT " + JSON.stringify({
      pass: false,
      error: err instanceof Error ? err.message : String(err),
    }));
    app.exit(1);
  }
}

app.whenReady().then(() => {
  if (!lockGranted) return;
  if (socketPath === undefined || socketPath === null) {
    dialog.showMessageBoxSync({
      type: "info",
      title: "Workshop Preview",
      message: "Choose an isolated Workshop socket with --workshop-socket. "
        + "This preview never starts or migrates the installed daemon.",
    });
    app.quit();
    return;
  }

  protocol.handle(SCHEME, async (request) => {
    if (request.method !== "GET" || !isOwnOrigin(request.url)) {
      return new Response("Not found", { status: 404 });
    }
    const file = rendererFile(request.url);
    if (file === null) {
      return new Response("Not found", { status: 404 });
    }
    try {
      const body = await readFile(file);
      return new Response(body, {
        headers: {
          "Content-Type": CONTENT_TYPES.get(path.extname(file))
            || "application/octet-stream",
          "Content-Security-Policy": CSP,
          "X-Content-Type-Options": "nosniff",
          "Referrer-Policy": "no-referrer",
          "Cache-Control": "no-store",
        },
      });
    } catch {
      return new Response("Not found", { status: 404 });
    }
  });

  rpc = new WorkshopRPC(socketPath);
  api = createTaskAPI(rpc);

  win = new BrowserWindow({
    width: 1586,
    height: 992,
    useContentSize: true,
    minWidth: 980,
    minHeight: 680,
    title: "Workshop Preview",
    webPreferences: {
      preload: path.join(DESKTOP_DIR, "preload.cjs"),
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
    },
  });

  win.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  win.webContents.on("will-navigate", (event, url) => {
    if (!isOwnOrigin(url)) event.preventDefault();
  });
  win.webContents.on("will-frame-navigate", (event) => {
    if (!isOwnOrigin(event.url)) event.preventDefault();
  });
  win.webContents.session.setPermissionRequestHandler(
    (_wc, _permission, callback) => callback(false));
  win.webContents.session.setPermissionCheckHandler(() => false);

  const dropSubscription = () => {
    subscribed = false;
    if (stopSubscription) { stopSubscription(); stopSubscription = null; }
  };
  win.webContents.on("destroyed", dropSubscription);
  win.webContents.on("render-process-gone", dropSubscription);
  win.webContents.on("did-start-navigation",
    (_event, _url, _isInPlace, isMainFrame) => {
      if (isMainFrame) dropSubscription();
    });
  win.on("closed", () => { win = null; });

  wireIPC();
  buildMenu();

  if (SMOKE) {
    win.webContents.once("did-finish-load", () => {
      setTimeout(() => { void runSmoke(); }, 1500);
    });
  }

  win.loadURL(`${ORIGIN}/`);
});

app.on("before-quit", () => {
  if (stopSubscription) { stopSubscription(); stopSubscription = null; }
  subscribed = false;
  if (rpc) rpc.close();
});

app.on("window-all-closed", () => {
  if (rpc) rpc.close();
  app.quit();
});

app.on("second-instance", () => {
  if (win && !win.isDestroyed()) {
    if (win.isMinimized()) win.restore();
    win.focus();
  }
});
