import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import http from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import { createWebServer } from "../server.mjs";

function fakeDaemon(overrides = {}) {
  const dir = mkdtempSync(join(tmpdir(), "wweb-"));
  const socketPath = join(dir, "service.sock");
  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      let index;
      while ((index = buffer.indexOf(0x0a)) >= 0) {
        const line = buffer.subarray(0, index);
        buffer = buffer.subarray(index + 1);
        let req;
        try { req = JSON.parse(line.toString()); } catch { continue; }
        if (req.method === "workshop.subscribe") {
          socket.write(JSON.stringify({ jsonrpc: "2.0", id: req.id,
            result: { subscribed: true } }) + "\n");
          if (overrides.onSubscribe) overrides.onSubscribe(socket, req);
          continue;
        }
        const result = overrides.results?.[req.method] ?? defaultResult(req.method);
        if (result instanceof Error) {
          socket.write(JSON.stringify({ jsonrpc: "2.0", id: req.id,
            error: { code: -32603, message: result.message } }) + "\n");
        } else {
          socket.write(JSON.stringify({ jsonrpc: "2.0", id: req.id,
            result }) + "\n");
        }
      }
    });
  });
  return new Promise((resolve) => {
    server.listen(socketPath, () => resolve({ socketPath, server, sockets }));
  });
}

function defaultResult(method) {
  if (method === "workshop.listTasks") return [];
  if (method === "workshop.getTask") return { task: { id: "task_1" } };
  if (method === "workshop.readMessagePage") return [];
  if (method === "workshop.listEngineers") return [];
  if (method === "workshop_get_capacity") return { devin: {} };
  if (method === "workshop.listProposals") return [];
  if (method === "workshop.listDecisions") return [];
  if (method === "workshop.listArtifacts") return [];
  if (method === "workshop_create_task") return { task_id: "task_new" };
  if (method === "workshop.postMessage") return { ok: true };
  return new Error("unexpected method " + method);
}

async function startGateway(daemon) {
  const server = createWebServer({ socketPath: daemon.socketPath, port: 0 });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const root = await fetch(base + "/");
  const cookie = root.headers.get("set-cookie").split(";")[0];
  return { server, base, cookie };
}

function req(base, path, { cookie, ...init } = {}) {
  const headers = { ...(init.headers ?? {}) };
  if (cookie) headers.cookie = cookie;
  return fetch(base + path, { ...init, headers });
}

test("GET / serves index and mints HttpOnly SameSite=Strict cookie", async () => {
  const daemon = await fakeDaemon();
  const { server, base } = await startGateway(daemon);
  const res = await fetch(base + "/");
  assert.equal(res.status, 200);
  const cookie = res.headers.get("set-cookie");
  assert.match(cookie, /workshop_session=[a-f0-9]{64}/);
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Strict/);
  assert.match(res.headers.get("content-security-policy"), /default-src 'self'/);
  assert.equal(res.headers.get("x-content-type-options"), "nosniff");
  assert.equal(res.headers.get("cache-control"), "no-store");
  server.close();
  daemon.server.close();
});

test("Host mismatch rejected", async () => {
  const daemon = await fakeDaemon();
  const { server, cookie } = await startGateway(daemon);
  const port = server.address().port;
  const status = await new Promise((resolve, reject) => {
    const r = http.request({ host: "127.0.0.1", port, path: "/api/tasks",
      headers: { host: "evil.example.com", cookie } }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode));
    });
    r.on("error", reject);
    r.end();
  });
  assert.equal(status, 403);
  server.close();
  daemon.server.close();
});

test("missing cookie rejected on APIs", async () => {
  const daemon = await fakeDaemon();
  const { server, base } = await startGateway(daemon);
  const res = await fetch(base + "/api/tasks");
  assert.equal(res.status, 401);
  server.close();
  daemon.server.close();
});

test("foreign Origin rejected on GET and POST", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  const res = await req(base, "/api/tasks",
    { cookie, headers: { origin: "https://evil.example" } });
  assert.equal(res.status, 403);
  const res2 = await req(base, "/api/tasks", { cookie, method: "POST",
    headers: { origin: "https://evil.example",
      "content-type": "application/json" }, body: "{}" });
  assert.equal(res2.status, 403);
  server.close();
  daemon.server.close();
});

test("fetch-site cross-site and same-site rejected", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  for (const site of ["cross-site", "same-site"]) {
    const res = await req(base, "/api/tasks",
      { cookie, headers: { "sec-fetch-site": site } });
    assert.equal(res.status, 403, site);
  }
  const root = await fetch(base + "/",
    { headers: { "sec-fetch-site": "cross-site" } });
  assert.equal(root.status, 403);
  const ok = await req(base, "/api/tasks",
    { cookie, headers: { "sec-fetch-site": "same-origin" } });
  assert.equal(ok.status, 200);
  const none = await req(base, "/api/tasks",
    { cookie, headers: { "sec-fetch-site": "none" } });
  assert.equal(none.status, 200);
  server.close();
  daemon.server.close();
});

test("oversized JSON body rejected with 413", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  const origin = base;
  const res = await req(base, "/api/tasks", { cookie, method: "POST",
    headers: { origin, "content-type": "application/json" },
    body: JSON.stringify({ pad: "x".repeat(70 * 1024) }) });
  assert.equal(res.status, 413);
  server.close();
  daemon.server.close();
});

test("bad content-type rejected", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  const res = await req(base, "/api/tasks", { cookie, method: "POST",
    headers: { origin: base, "content-type": "text/plain" }, body: "{}" });
  assert.equal(res.status, 415);
  server.close();
  daemon.server.close();
});

test("path traversal rejected", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  const port = server.address().port;
  const rawGet = (path) => new Promise((resolve, reject) => {
    http.get({ host: "127.0.0.1", port, path }, (res) => {
      res.resume();
      res.on("end", () => resolve(res.statusCode));
    }).on("error", reject);
  });
  for (const path of ["/../etc/passwd", "/%2e%2e/%2e%2e/etc/passwd",
    "/%2E%2E/x", "/assets/..%2fapp.js", "/%5c%5cetc",
    "/app.js%00.png", "/%252e%252e/x"]) {
    const status = await rawGet(path);
    assert.ok([400, 404].includes(status), `${path}: ${status}`);
  }
  server.close();
  daemon.server.close();
});

test("unsupported methods rejected with 405", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  const put = await req(base, "/api/tasks", { cookie, method: "PUT",
    headers: { origin: base, "content-type": "application/json" },
    body: "{}" });
  assert.equal(put.status, 405);
  const del = await req(base, "/api/tasks/task_1",
    { cookie, method: "DELETE" });
  assert.equal(del.status, 405);
  const post = await fetch(base + "/style.css", { method: "POST" });
  assert.equal(post.status, 405);
  server.close();
  daemon.server.close();
});

test("unknown routes and arbitrary RPC endpoints 404", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  for (const path of ["/rpc", "/api/rpc", "/api/export", "/api/backup",
    "/api/shell", "/api/tasks/task_1/export", "/nope.txt"]) {
    const res = await req(base, path, { cookie });
    assert.equal(res.status, 404, path);
  }
  server.close();
  daemon.server.close();
});

test("static file headers and content", async () => {
  const daemon = await fakeDaemon();
  const { server, base } = await startGateway(daemon);
  const res = await fetch(base + "/style.css");
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /text\/css/);
  assert.match(res.headers.get("content-security-policy"), /object-src 'none'/);
  const client = await fetch(base + "/client.js");
  assert.match(client.headers.get("content-type"), /javascript/);
  const png = await fetch(base + "/assets/workshop-icon.png");
  assert.equal(png.headers.get("content-type"), "image/png");
  server.close();
  daemon.server.close();
});

test("task API routes proxy to daemon", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  const tasks = await (await req(base, "/api/tasks", { cookie })).json();
  assert.deepEqual(tasks, []);
  const detail = await (await req(base, "/api/tasks/task_1",
    { cookie })).json();
  assert.equal(detail.task.id, "task_1");
  const created = await (await req(base, "/api/tasks", { cookie,
    method: "POST",
    headers: { origin: base, "content-type": "application/json" },
    body: JSON.stringify({
      idempotency_key: "web-123e4567-e89b-42d3-a456-426614174000",
      title: "T", objective: "O", phase: "execution",
      collaboration_mode: "owner_only", participants: [],
      channel: "engineering",
    }) })).json();
  assert.equal(created.task_id, "task_new");
  server.close();
  daemon.server.close();
});

test("POST message requires exact {body:string}", async () => {
  const daemon = await fakeDaemon();
  const { server, base, cookie } = await startGateway(daemon);
  const post = (body) => req(base, "/api/tasks/task_1/messages", { cookie,
    method: "POST",
    headers: { origin: base, "content-type": "application/json" },
    body: JSON.stringify(body) });
  for (const body of [{}, { body: "x", extra: 1 }, { body: 5 }, [],
    null, { body: "" }]) {
    const res = await post(body);
    assert.equal(res.status, 400, JSON.stringify(body));
  }
  const ok = await post({ body: "hello" });
  assert.equal(ok.status, 200);
  server.close();
  daemon.server.close();
});

test("createWebServer requires absolute socket and loopback host", async () => {
  assert.throws(() => createWebServer({ socketPath: "relative.sock" }));
  assert.throws(() => createWebServer({ socketPath: "/x.sock",
    host: "0.0.0.0" }));
});

test("SSE stream sends connected only after ACK and dedupes seq", async () => {
  const daemon = await fakeDaemon({
    onSubscribe(socket) {
      daemon.subscribed = socket;
    },
  });
  const { server, base, cookie } = await startGateway(daemon);
  const events = [];
  let buffer = "";
  const response = await req(base, "/api/events", { cookie });
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  const pump = (async () => {
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const blocks = buffer.split("\n\n");
        buffer = blocks.pop();
        for (const block of blocks) {
          if (block.length > 0) events.push(block);
        }
      }
    } catch {}
  })();
  try {
    await new Promise((r) => setTimeout(r, 100));
    assert.ok(events.some((e) => e.includes('"connected":true')));
    const send = (params) => {
      daemon.subscribed.write(JSON.stringify({ jsonrpc: "2.0",
        method: "workshop.event", params }) + "\n");
    };
    send({ seq: 5, task_id: "task_1", type: "message.committed",
      payload: "{}" });
    send({ seq: 5, task_id: "task_1", type: "message.committed",
      payload: "{}" });
    send({ seq: 4, task_id: "task_1", type: "message.committed",
      payload: "{}" });
    send({ seq: 5, task_id: "task_1", type: "message.delta", payload: "{}" });
    await new Promise((r) => setTimeout(r, 100));
    const durable = events.filter((e) => e.includes("event: workshop.event"));
    const refresh = events.filter((e) => e.includes("event: refresh"));
    assert.equal(durable.length, 1);
    assert.ok(durable[0].includes("id: 5"));
    assert.equal(refresh.length, 1);
    assert.ok(refresh[0].includes('"seq":null'));
    daemon.subscribed.destroy();
    await new Promise((r) => setTimeout(r, 100));
    assert.ok(events.some((e) => e.includes('"connected":false')));
  } finally {
    reader.cancel();
    await pump;
    server.close();
    daemon.server.close();
  }
});

test("SSE does not send connected:true before subscribe ACK", async () => {
  const daemon = await fakeDaemon({
    onSubscribe() {},
  });
  const slow = net.createServer((socket) => {
    socket.on("data", () => {});
  });
  const dir = mkdtempSync(join(tmpdir(), "wweb-slow-"));
  const slowPath = join(dir, "service.sock");
  await new Promise((r) => slow.listen(slowPath, r));
  const server = createWebServer({ socketPath: slowPath, port: 0 });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const root = await fetch(base + "/");
  const cookie = root.headers.get("set-cookie").split(";")[0];
  const response = await req(base, "/api/events", { cookie });
  const reader = response.body.getReader();
  let buffer = "";
  const pump = (async () => {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += new TextDecoder().decode(value, { stream: true });
    }
  })();
  await new Promise((r) => setTimeout(r, 200));
  assert.ok(!buffer.includes('"connected":true'));
  reader.cancel();
  await pump.catch(() => {});
  server.close();
  slow.close();
  daemon.server.close();
});

test("client disconnect closes UDS subscription", async () => {
  const daemon = await fakeDaemon({});
  const { server, base, cookie } = await startGateway(daemon);
  const response = await req(base, "/api/events", { cookie });
  await new Promise((r) => setTimeout(r, 100));
  assert.ok(daemon.sockets.size >= 1);
  const count = daemon.sockets.size;
  response.body.cancel();
  await new Promise((r) => setTimeout(r, 150));
  assert.ok(daemon.sockets.size < count);
  server.close();
  daemon.server.close();
});
