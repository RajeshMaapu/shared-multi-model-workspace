import http from "node:http";
import { randomBytes } from "node:crypto";
import { readdirSync, readFileSync, lstatSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { WorkshopRPC } from "./rpc-client.mjs";
import { createTaskAPI, ValidationError } from "./task-api.mjs";

const RENDERER_DIR = fileURLToPath(new URL("./renderer", import.meta.url));
const MAX_BODY = 64 * 1024;
const STATIC_NAMES = ["index.html", "style.css", "app.js", "client.js",
  "state.js", "api.d.ts"];

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".png": "image/png",
  ".ts": "text/plain; charset=utf-8",
};

function staticAllowlist() {
  const files = new Map();
  for (const name of STATIC_NAMES) {
    const path = join(RENDERER_DIR, name);
    try {
      const st = lstatSync(path);
      if (st.isFile() && !st.isSymbolicLink()) files.set("/" + name, path);
    } catch {}
  }
  const assetsDir = join(RENDERER_DIR, "assets");
  try {
    for (const name of readdirSync(assetsDir)) {
      if (!name.endsWith(".png")) continue;
      const path = join(assetsDir, name);
      const st = lstatSync(path);
      if (st.isFile() && !st.isSymbolicLink()) {
        files.set("/assets/" + name, path);
      }
    }
  } catch {}
  return files;
}

function securityHeaders(res) {
  res.setHeader("Content-Security-Policy",
    "default-src 'self'; script-src 'self'; style-src 'self'; "
    + "img-src 'self'; connect-src 'self'; object-src 'none'; "
    + "base-uri 'none'; frame-ancestors 'none'");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("Cache-Control", "no-store");
}

function sendJSON(res, status, body) {
  const data = JSON.stringify(body);
  securityHeaders(res);
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(data);
}

function sendError(res, status, message) {
  sendJSON(res, status, { error: message });
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function createWebServer({ socketPath, port = 4176,
  host = "127.0.0.1" } = {}) {
  if (typeof socketPath !== "string" || !socketPath.startsWith("/")) {
    throw new Error("--socket <absolute path> is required");
  }
  if (host !== "127.0.0.1") {
    throw new Error("The web gateway binds to 127.0.0.1 only");
  }
  const rpc = new WorkshopRPC(socketPath);
  const api = createTaskAPI(rpc);
  const session = randomBytes(32).toString("hex");
  const staticFiles = staticAllowlist();
  const eventStreams = new Set();

  const server = http.createServer((req, res) => {
    handle(req, res).catch(() => {
      if (!res.headersSent) sendError(res, 500, "Internal error");
      else res.end();
    });
  });
  server.requestTimeout = 15000;
  server.on("close", () => {
    for (const stream of eventStreams) stream.cleanup();
    eventStreams.clear();
    rpc.close();
  });

  function ownHost() {
    return "127.0.0.1:" + server.address().port;
  }

  function hasSession(req) {
    const cookie = req.headers.cookie ?? "";
    for (const part of cookie.split(";")) {
      const [name, ...rest] = part.trim().split("=");
      if (name === "workshop_session") {
        return rest.join("=") === session;
      }
    }
    return false;
  }

  function fetchSiteAllowed(value, { strict }) {
    if (value === undefined) return true;
    if (value === "none" || value === "same-origin") return true;
    if (!strict && value === "same-site") return true;
    return false;
  }

  function rawPathUnsafe(rawURL) {
    const raw = String(rawURL).split("?")[0].split("#")[0];
    if (raw.includes("..") || raw.includes("\\") || raw.includes("\0")) {
      return true;
    }
    let decoded = raw;
    for (let i = 0; i < 3; i++) {
      try {
        const next = decodeURIComponent(decoded);
        if (next === decoded) break;
        decoded = next;
      } catch {
        return true;
      }
      if (decoded.includes("..") || decoded.includes("\\")
          || decoded.includes("\0")) {
        return true;
      }
    }
    return false;
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      let settled = false;
      req.on("data", (chunk) => {
        if (settled) return;
        size += chunk.length;
        if (size > MAX_BODY) {
          settled = true;
          chunks.length = 0;
          const err = new ValidationError("Request body too large");
          err.statusCode = 413;
          reject(err);
          req.resume();
          return;
        }
        chunks.push(chunk);
      });
      req.on("end", () => {
        if (settled) return;
        settled = true;
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
        } catch {
          reject(new ValidationError("Invalid JSON body"));
        }
      });
      req.on("error", () => {
        if (settled) return;
        settled = true;
        reject(new ValidationError("Request failed"));
      });
      req.on("close", () => {
        if (settled) return;
        settled = true;
        reject(new ValidationError("Request aborted"));
      });
    });
  }

  async function handle(req, res) {
    if (req.headers.host !== ownHost()) {
      sendError(res, 403, "Host not allowed");
      return;
    }
    const fetchSite = req.headers["sec-fetch-site"];
    const url = new URL(req.url, "http://" + ownHost());
    if (rawPathUnsafe(req.url)) {
      sendError(res, 400, "Invalid path");
      return;
    }

    if (url.pathname === "/" && req.method === "GET") {
      if (!fetchSiteAllowed(fetchSite, { strict: true })) {
        sendError(res, 403, "Fetch metadata not permitted");
        return;
      }
      const file = staticFiles.get("/index.html");
      securityHeaders(res);
      res.setHeader("Set-Cookie",
        `workshop_session=${session}; HttpOnly; SameSite=Strict; Path=/`);
      res.writeHead(200, { "Content-Type": MIME[".html"] });
      res.end(readFileSync(file));
      return;
    }

    if (url.pathname.startsWith("/api/")) {
      if (!fetchSiteAllowed(fetchSite, { strict: true })) {
        sendError(res, 403, "Fetch metadata not permitted");
        return;
      }
      const origin = req.headers.origin;
      if (origin !== undefined && origin !== "http://" + ownHost()) {
        sendError(res, 403, "Origin not allowed");
        return;
      }
      if (!hasSession(req)) {
        sendError(res, 401, "Session required");
        return;
      }
      await handleAPI(req, res, url);
      return;
    }

    if (req.method !== "GET") {
      sendError(res, 405, "Method not allowed");
      return;
    }
    const file = staticFiles.get(url.pathname);
    if (!file) {
      sendError(res, 404, "Not found");
      return;
    }
    const ext = file.slice(file.lastIndexOf("."));
    securityHeaders(res);
    res.writeHead(200,
      { "Content-Type": MIME[ext] ?? "application/octet-stream" });
    res.end(readFileSync(file));
  }

  async function handleAPI(req, res, url) {
    if (url.pathname === "/api/events" && req.method === "GET") {
      handleEvents(req, res);
      return;
    }
    if (req.method === "POST") {
      const origin = req.headers.origin;
      if (origin !== "http://" + ownHost()) {
        sendError(res, 403, "Origin not allowed");
        return;
      }
      const contentType = (req.headers["content-type"] ?? "")
        .split(";")[0].trim().toLowerCase();
      if (contentType !== "application/json") {
        sendError(res, 415, "Content-Type must be application/json");
        return;
      }
    }
    const segments = url.pathname.split("/").filter(Boolean);
    const knownRoute =
      (segments.length === 2 && segments[0] === "api"
        && ["tasks", "engineers", "capacity", "events"]
          .includes(segments[1]))
      || (segments.length === 3 && segments[0] === "api"
        && segments[1] === "tasks")
      || (segments.length === 4 && segments[0] === "api"
        && segments[1] === "tasks"
        && ["messages", "proposals", "decisions", "files"]
          .includes(segments[3]));
    try {
      if (req.method === "GET" && url.pathname === "/api/tasks") {
        sendJSON(res, 200, await api.listTasks());
      } else if (req.method === "POST" && url.pathname === "/api/tasks") {
        sendJSON(res, 200, await api.createTask(await readBody(req)));
      } else if (req.method === "GET" && url.pathname === "/api/engineers") {
        sendJSON(res, 200, await api.getEngineers());
      } else if (req.method === "GET" && url.pathname === "/api/capacity") {
        sendJSON(res, 200, await api.getCapacity());
      } else if (segments.length === 3 && segments[0] === "api"
          && segments[1] === "tasks" && req.method === "GET") {
        sendJSON(res, 200, await api.getTask(segments[2]));
      } else if (segments.length === 4 && segments[0] === "api"
          && segments[1] === "tasks" && segments[3] === "messages"
          && req.method === "GET") {
        const raw = url.searchParams.get("before_seq");
        const before = raw === null ? undefined : Number(raw);
        sendJSON(res, 200, await api.getMessages(segments[2], before));
      } else if (segments.length === 4 && segments[0] === "api"
          && segments[1] === "tasks" && segments[3] === "messages"
          && req.method === "POST") {
        const body = await readBody(req);
        if (!isPlainObject(body) || Object.keys(body).length !== 1
            || typeof body.body !== "string") {
          throw new ValidationError("Expected {\"body\": string}");
        }
        sendJSON(res, 200, await api.postMessage(segments[2], body.body));
      } else if (segments.length === 4 && segments[0] === "api"
          && segments[1] === "tasks" && req.method === "GET"
          && ["proposals", "decisions", "files"].includes(segments[3])) {
        const fn = { proposals: "getProposals", decisions: "getDecisions",
          files: "getFiles" }[segments[3]];
        sendJSON(res, 200, await api[fn](segments[2]));
      } else if (knownRoute) {
        sendError(res, 405, "Method not allowed");
      } else {
        sendError(res, 404, "Not found");
      }
    } catch (err) {
      if (res.headersSent) {
        res.end();
        return;
      }
      const status = err && err.statusCode ? err.statusCode : 503;
      sendError(res, status,
        status < 500 ? err.message : "Workshop daemon error");
    }
  }

  function handleEvents(req, res) {
    const lastEventID = req.headers["last-event-id"];
    let cursor = 0;
    if (lastEventID !== undefined) {
      const parsed = Number(lastEventID);
      if (!Number.isSafeInteger(parsed) || parsed < 0) {
        sendError(res, 400, "Invalid Last-Event-ID");
        return;
      }
      cursor = parsed;
    }
    securityHeaders(res);
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-store",
      "Connection": "keep-alive",
    });
    res.write("retry: 2000\n\n");
    const stream = {
      cleanup: null,
    };
    let alive = true;
    let unsubscribe = null;
    let timer = null;
    let delay = 1000;
    let attempt = null;
    const heartbeat = setInterval(() => {
      write(":ok\n\n");
    }, 30000);

    const write = (block) => {
      if (!alive) return;
      try { res.write(block); } catch {}
    };

    const cleanup = () => {
      if (!alive) return;
      alive = false;
      clearInterval(heartbeat);
      if (timer) { clearTimeout(timer); timer = null; }
      if (attempt) { attempt.abort(); attempt = null; }
      if (unsubscribe) { unsubscribe(); unsubscribe = null; }
      eventStreams.delete(stream);
    };
    stream.cleanup = cleanup;
    eventStreams.add(stream);

    const connect = () => {
      if (!alive) return;
      attempt = new AbortController();
      rpc.subscribe(cursor, (event) => {
        if (!alive) return;
        if (event.type === "message.delta") {
          write("event: refresh\ndata: "
            + JSON.stringify({ seq: null, task_id: event.task_id })
            + "\n\n");
          return;
        }
        if (event.seq <= cursor) return;
        cursor = event.seq;
        write(`id: ${event.seq}\nevent: workshop.event\ndata: `
          + JSON.stringify(event) + "\n\n");
      }, () => {
        unsubscribe = null;
        attempt = null;
        if (!alive) return;
        write('event: connection\ndata: {"connected":false}\n\n');
        timer = setTimeout(() => {
          timer = null;
          connect();
        }, delay);
        delay = Math.min(delay * 2, 5000);
      }, { signal: attempt.signal }).then((unsub) => {
        unsubscribe = unsub;
        if (!alive) { unsub(); return; }
        delay = 1000;
        write('event: connection\ndata: {"connected":true}\n\n');
      }).catch(() => {
        if (!alive) return;
        write('event: connection\ndata: {"connected":false}\n\n');
        timer = setTimeout(() => {
          timer = null;
          connect();
        }, delay);
        delay = Math.min(delay * 2, 5000);
      });
    };
    connect();

    res.on("close", cleanup);
  }

  return server;
}

function parseCLI(argv) {
  let socket = null;
  let port = 4176;
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--socket") {
      socket = argv[++i];
    } else if (argv[i] === "--port") {
      port = Number(argv[++i]);
      if (!Number.isInteger(port) || port <= 0 || port > 65535) {
        console.error("Invalid --port");
        process.exit(2);
      }
    } else if (argv[i] === "--host") {
      console.error("--host is not supported; the gateway binds to 127.0.0.1");
      process.exit(2);
    } else {
      console.error(`Unknown argument: ${argv[i]}`);
      process.exit(2);
    }
  }
  if (!socket || !socket.startsWith("/")) {
    console.error("Usage: node server.mjs --socket <absolute path> [--port N]");
    process.exit(2);
  }
  return { socket, port };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { socket, port } = parseCLI(process.argv);
  const server = createWebServer({ socketPath: socket, port });
  server.listen(port, "127.0.0.1", () => {
    console.log(
      `Workshop web gateway on http://127.0.0.1:${server.address().port}`);
    console.log(`socket: ${socket}`);
  });
  server.on("error", (err) => {
    console.error(`Failed to start: ${err.message}`);
    process.exit(1);
  });
}
