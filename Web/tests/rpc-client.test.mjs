import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WorkshopRPC, WorkshopRPCError } from "../rpc-client.mjs";

function fakeSocket() {
  const dir = mkdtempSync(join(tmpdir(), "wrpc-"));
  return join(dir, "s.sock");
}

function serve(socketPath, onConnection) {
  const server = net.createServer(onConnection);
  return new Promise((resolve) => {
    server.listen(socketPath, () => resolve(server));
  });
}

function respond(socket, id, result) {
  socket.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

test("call resolves result for matching id", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      respond(socket, req.id, { ok: true, echo: req.method });
    });
  });
  const rpc = new WorkshopRPC(path);
  const result = await rpc.call("workshop.health", {});
  assert.equal(result.ok, true);
  assert.equal(result.echo, "workshop.health");
  server.close();
});

test("call handles fragmented response", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      const line = JSON.stringify({ jsonrpc: "2.0", id: req.id,
        result: { v: 7 } }) + "\n";
      socket.write(line.slice(0, 5));
      setTimeout(() => socket.write(line.slice(5)), 20);
    });
  });
  const rpc = new WorkshopRPC(path);
  const result = await rpc.call("m");
  assert.equal(result.v, 7);
  server.close();
});

test("call ignores interleaved notifications", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      const out = JSON.stringify({ jsonrpc: "2.0", method: "workshop.event",
        params: { seq: 1, type: "x" } }) + "\n"
        + JSON.stringify({ jsonrpc: "2.0", id: req.id,
          result: { good: true } }) + "\n";
      socket.write(out);
    });
  });
  const rpc = new WorkshopRPC(path);
  const result = await rpc.call("m");
  assert.equal(result.good, true);
  server.close();
});

test("call rejects response with mismatched correlation id", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      socket.write(JSON.stringify({ jsonrpc: "2.0", id: req.id + 100,
        result: { bad: true } }) + "\n");
    });
  });
  const rpc = new WorkshopRPC(path);
  await assert.rejects(rpc.call("m"), /Malformed/);
  server.close();
});

test("remote error becomes WorkshopRPCError with code", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      socket.write(JSON.stringify({ jsonrpc: "2.0", id: req.id,
        error: { code: -32009, message: "conflict" } }) + "\n");
    });
  });
  const rpc = new WorkshopRPC(path);
  await assert.rejects(rpc.call("m"), (err) => {
    assert.ok(err instanceof WorkshopRPCError);
    assert.equal(err.rpcCode, -32009);
    assert.equal(err.message, "conflict");
    return true;
  });
  server.close();
});

test("call times out", async () => {
  const path = fakeSocket();
  const server = await serve(path, () => {});
  const rpc = new WorkshopRPC(path, { timeoutMs: 50 });
  await assert.rejects(rpc.call("m"), /timeout/i);
  server.close();
});

test("call rejects oversized buffer", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", () => {
      socket.write(Buffer.alloc(4 * 1024 * 1024 + 10, 0x41));
    });
  });
  const rpc = new WorkshopRPC(path);
  await assert.rejects(rpc.call("m"), /4 MiB/);
  server.close();
});

test("call rejects on disconnect", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", () => socket.end());
  });
  const rpc = new WorkshopRPC(path);
  await assert.rejects(rpc.call("m"), /disconnect/i);
  server.close();
});

test("call rejects malformed JSON line", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", () => socket.write("{bad\n"));
  });
  const rpc = new WorkshopRPC(path);
  await assert.rejects(rpc.call("m"), /Malformed/);
  server.close();
});

test("call rejects response with both result and error", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      socket.write(JSON.stringify({ jsonrpc: "2.0", id: req.id,
        result: {}, error: { code: -1, message: "x" } }) + "\n");
    });
  });
  const rpc = new WorkshopRPC(path);
  await assert.rejects(rpc.call("m"), /Malformed/);
  server.close();
});

test("call rejects response without jsonrpc 2.0", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      socket.write(JSON.stringify({ id: req.id, result: {} }) + "\n");
    });
  });
  const rpc = new WorkshopRPC(path);
  await assert.rejects(rpc.call("m"), /Malformed/);
  server.close();
});

test("subscribe resolves unsubscribe after ACK and delivers events", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      socket.write(JSON.stringify({ jsonrpc: "2.0", method: "workshop.event",
        params: { seq: 3, task_id: { rawValue: "task_1" },
          type: "message.committed", payload: "{}" } }) + "\n");
      respond(socket, req.id, { subscribed: true });
      socket.write(JSON.stringify({ jsonrpc: "2.0", method: "workshop.event",
        params: { seq: 4, taskID: "task_2", eventType: "task.state_changed" } })
        + "\n");
    });
  });
  const rpc = new WorkshopRPC(path);
  const events = [];
  const unsub = await rpc.subscribe(0, (e) => events.push(e));
  assert.equal(typeof unsub, "function");
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(events.length, 2);
  assert.deepEqual(events[0], { seq: 3, task_id: "task_1",
    type: "message.committed", payload: "{}" });
  assert.deepEqual(events[1], { seq: 4, task_id: "task_2",
    type: "task.state_changed", payload: null });
  unsub();
  server.close();
});

test("subscribe rejects on error response without onDisconnect", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      socket.write(JSON.stringify({ jsonrpc: "2.0", id: req.id,
        error: { code: -32603, message: "nope" } }) + "\n");
    });
  });
  const rpc = new WorkshopRPC(path);
  let disconnected = false;
  await assert.rejects(
    rpc.subscribe(0, () => {}, () => { disconnected = true; }),
    /nope/);
  assert.equal(disconnected, false);
  server.close();
});

test("subscribe rejects on missing subscribed flag", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      respond(socket, req.id, { subscribed: false });
    });
  });
  const rpc = new WorkshopRPC(path);
  await assert.rejects(rpc.subscribe(0, () => {}), /rejected/);
  server.close();
});

test("subscribe onDisconnect on socket close after ACK", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      respond(socket, req.id, { subscribed: true });
      setTimeout(() => socket.end(), 20);
    });
  });
  const rpc = new WorkshopRPC(path);
  const closed = new Promise((resolve) => {
    rpc.subscribe(0, () => {}, resolve);
  });
  await closed;
  server.close();
});

test("subscribe disconnects on invalid event seq", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      respond(socket, req.id, { subscribed: true });
      socket.write(JSON.stringify({ jsonrpc: "2.0", method: "workshop.event",
        params: { seq: "five", type: "x" } }) + "\n");
    });
  });
  const rpc = new WorkshopRPC(path);
  const events = [];
  const closed = new Promise((resolve) => {
    rpc.subscribe(0, (e) => events.push(e), resolve);
  });
  await closed;
  assert.equal(events.length, 0);
  server.close();
});

test("subscribe allows transient message.delta events", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", (chunk) => {
      const req = JSON.parse(chunk.toString());
      respond(socket, req.id, { subscribed: true });
      socket.write(JSON.stringify({ jsonrpc: "2.0", method: "workshop.event",
        params: { seq: 0, task_id: "task_1", type: "message.delta",
          payload: "{}" } }) + "\n");
    });
  });
  const rpc = new WorkshopRPC(path);
  const events = [];
  let disconnected = false;
  const unsub = await rpc.subscribe(0, (e) => events.push(e),
    () => { disconnected = true; });
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "message.delta");
  assert.equal(disconnected, false);
  unsub();
  rpc.close();
  server.close();
});

test("subscribe abort signal rejects pending ACK quickly", async () => {
  const path = fakeSocket();
  let serverSocket = null;
  const server = await serve(path, (socket) => {
    serverSocket = socket;
    socket.on("data", () => {});
  });
  const rpc = new WorkshopRPC(path, { timeoutMs: 10000 });
  const controller = new AbortController();
  const pending = rpc.subscribe(0, () => {}, () => {}, {
    signal: controller.signal,
  });
  await new Promise((r) => setTimeout(r, 20));
  controller.abort();
  await assert.rejects(pending, /closed/i);
  await new Promise((r) => setTimeout(r, 30));
  assert.ok(serverSocket.destroyed);
  rpc.close();
  server.close();
});

test("rpc.close cancels pending subscribe ACK", async () => {
  const path = fakeSocket();
  const server = await serve(path, (socket) => {
    socket.on("data", () => {});
  });
  const rpc = new WorkshopRPC(path, { timeoutMs: 10000 });
  const pending = rpc.subscribe(0, () => {});
  await new Promise((r) => setTimeout(r, 20));
  rpc.close();
  await assert.rejects(pending, /closed/i);
  server.close();
});

test("subscribe rejects when socket unavailable", async () => {
  const rpc = new WorkshopRPC(fakeSocket(), { timeoutMs: 200 });
  await assert.rejects(rpc.subscribe(0, () => {}));
});
