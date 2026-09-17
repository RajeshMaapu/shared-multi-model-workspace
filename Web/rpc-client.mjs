import net from "node:net";
import fs from "node:fs";
import path from "node:path";

function desktopToken(socketPath) {
  const tokenPath = path.join(path.dirname(socketPath), "user.token");
  let fd;
  try {
    fd = fs.openSync(tokenPath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const token = fs.readFileSync(fd, "utf8").trim();
    if (!/^[a-f0-9]{64}$/.test(token)) throw new Error("Invalid desktop token file");
    return token;
  } catch (error) {
    if (error.code === "ENOENT") return null; // Legacy/test server only.
    throw error;
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}


const MAX_BUFFER = 4 * 1024 * 1024;

export class WorkshopRPCError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "WorkshopRPCError";
    this.rpcCode = code;
  }
}

function malformed() {
  return new Error("Malformed JSON-RPC response");
}

function isValidResponse(message, id) {
  if (message === null || typeof message !== "object" || Array.isArray(message)) {
    return false;
  }
  if (message.jsonrpc !== "2.0") return false;
  if (message.id !== id) return false;
  const hasResult = "result" in message;
  const hasError = "error" in message;
  if (hasResult === hasError) return false;
  if (hasError) {
    const e = message.error;
    if (e === null || typeof e !== "object" || Array.isArray(e)) return false;
    if (!Number.isInteger(e.code) || typeof e.message !== "string") return false;
  }
  return true;
}

function normalizeTaskID(value) {
  if (typeof value === "string") return value;
  if (value !== null && typeof value === "object" && !Array.isArray(value)
      && Object.keys(value).length === 1
      && typeof value.rawValue === "string") {
    return value.rawValue;
  }
  return null;
}

function normalizeEvent(params) {
  if (params === null || typeof params !== "object" || Array.isArray(params)) {
    return null;
  }
  const seq = params.seq;
  if (!Number.isSafeInteger(seq) || seq < 0) return null;
  const type = params.type ?? params.eventType ?? params.event_type ?? null;
  if (typeof type !== "string") return null;
  const taskID = normalizeTaskID(params.task_id ?? params.taskID ?? null);
  const payload = params.payload;
  return {
    seq,
    task_id: taskID,
    type,
    payload: typeof payload === "string" ? payload : null,
  };
}

export class WorkshopRPC {
  constructor(socketPath, { timeoutMs = 10000 } = {}) {
    if (typeof socketPath !== "string" || socketPath.length === 0) {
      throw new Error("socketPath required");
    }
    this.socketPath = socketPath;
    this.timeoutMs = timeoutMs;
    this.nextID = 1;
    this.subscriptions = new Set();
  }

  call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.nextID++;
      const request = { jsonrpc: "2.0", id, method, params };
      const token = desktopToken(this.socketPath);
      let authenticating = token !== null;
      const auth = { jsonrpc: "2.0", id: -id, method: "workshop.authenticate", params: { token } };
      let buffer = Buffer.alloc(0);
      let settled = false;
      let socket;
      const finish = (err, result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (socket) socket.destroy();
        if (err) reject(err);
        else resolve(result);
      };
      const timer = setTimeout(() => {
        finish(new Error("Workshop RPC timeout"));
      }, this.timeoutMs);
      try {
        socket = net.createConnection(this.socketPath);
      } catch (err) {
        finish(err);
        return;
      }
      socket.once("connect", () => {
        socket.write(JSON.stringify(authenticating ? auth : request) + "\n");
      });
      socket.once("error", (err) => {
        finish(err instanceof Error ? err : new Error(String(err)));
      });
      socket.once("close", () => {
        finish(new Error("Workshop RPC disconnected"));
      });
      socket.on("data", (chunk) => {
        if (settled) return;
        buffer = Buffer.concat([buffer, chunk]);
        if (buffer.length > MAX_BUFFER) {
          finish(new Error("Workshop RPC response exceeds 4 MiB limit"));
          return;
        }
        let index;
        while ((index = buffer.indexOf(0x0a)) >= 0) {
          const line = buffer.subarray(0, index);
          buffer = buffer.subarray(index + 1);
          if (line.length === 0) continue;
          let message;
          try {
            message = JSON.parse(line.toString("utf8"));
          } catch {
            finish(malformed());
            return;
          }
          if (message !== null && typeof message === "object"
              && typeof message.method === "string"
              && !("id" in message)) {
            continue;
          }
          if (authenticating) {
            if (!isValidResponse(message, -id) || "error" in message) {
              finish(new Error("Workshop desktop authentication failed")); return;
            }
            authenticating = false;
            socket.write(JSON.stringify(request) + "\n");
            continue;
          }
          if (!isValidResponse(message, id)) {
            finish(malformed());
            return;
          }
          if ("error" in message) {
            finish(new WorkshopRPCError(message.error.code,
              message.error.message));
            return;
          }
          finish(null, message.result);
          return;
        }
      });
    });
  }

  subscribe(afterSeq, onEvent, onDisconnect, { signal } = {}) {
    const startSeq = Number.isSafeInteger(afterSeq) && afterSeq >= 0
      ? afterSeq
      : 0;
    return new Promise((resolve, reject) => {
      const sub = {
        socket: null,
        buffer: Buffer.alloc(0),
        closed: false,
        established: false,
        cancel: null,
      };
      this.subscriptions.add(sub);
      const id = this.nextID++;
      const token = desktopToken(this.socketPath);
      let authenticating = token !== null;
      const subscribeRequest = { jsonrpc: "2.0", id, method: "workshop.subscribe", params: { after_seq: startSeq } };
      const onAbort = () => fail(new Error("Subscription closed"));
      const fail = (err) => {
        if (sub.closed) return;
        sub.closed = true;
        this.subscriptions.delete(sub);
        clearTimeout(timer);
        if (signal) signal.removeEventListener("abort", onAbort);
        socket.destroy();
        if (sub.established) {
          if (typeof onDisconnect === "function") {
            try { onDisconnect(); } catch {}
          }
        } else {
          reject(err);
        }
      };
      sub.cancel = () => fail(new Error("Workshop RPC closed"));
      const timer = setTimeout(() => {
        fail(new Error("Workshop subscribe timeout"));
      }, this.timeoutMs);
      const socket = net.createConnection(this.socketPath);
      sub.socket = socket;
      if (signal) {
        if (signal.aborted) {
          fail(new Error("Subscription closed"));
          return;
        }
        signal.addEventListener("abort", onAbort, { once: true });
      }
      socket.on("data", (chunk) => {
        if (sub.closed) return;
        sub.buffer = Buffer.concat([sub.buffer, chunk]);
        if (sub.buffer.length > MAX_BUFFER) {
          fail(new Error("Workshop RPC stream exceeds 4 MiB limit"));
          return;
        }
        let index;
        while ((index = sub.buffer.indexOf(0x0a)) >= 0) {
          const line = sub.buffer.subarray(0, index);
          sub.buffer = sub.buffer.subarray(index + 1);
          if (line.length === 0) continue;
          let message;
          try {
            message = JSON.parse(line.toString("utf8"));
          } catch {
            fail(malformed());
            return;
          }
          if (message !== null && typeof message === "object"
              && !Array.isArray(message)
              && message.method === "workshop.event") {
            const event = normalizeEvent(message.params);
            if (event === null) {
              fail(new Error("Invalid workshop.event notification"));
              return;
            }
            try { onEvent(event); } catch {}
            continue;
          }
          if (authenticating) {
            if (!isValidResponse(message, -id) || "error" in message) {
              fail(new Error("Workshop desktop authentication failed")); return;
            }
            authenticating = false;
            socket.write(JSON.stringify(subscribeRequest) + "\n");
            continue;
          }
          if (!sub.established) {
            if (!isValidResponse(message, id)) {
              fail(malformed());
              return;
            }
            if ("error" in message) {
              fail(new WorkshopRPCError(message.error.code,
                message.error.message));
              return;
            }
            const result = message.result;
            if (result === null || typeof result !== "object"
                || result.subscribed !== true) {
              fail(new Error("Subscribe rejected by daemon"));
              return;
            }
            sub.established = true;
            clearTimeout(timer);
            resolve(() => {
              if (sub.closed) return;
              sub.closed = true;
              this.subscriptions.delete(sub);
              if (signal) signal.removeEventListener("abort", onAbort);
              socket.destroy();
            });
            continue;
          }
        }
      });
      socket.once("error", () => {});
      socket.once("close", () => {
        fail(new Error("Workshop RPC disconnected"));
      });
      socket.write(JSON.stringify(authenticating ? {
        jsonrpc: "2.0", id: -id, method: "workshop.authenticate", params: { token },
      } : subscribeRequest) + "\n");
    });
  }

  close() {
    for (const sub of [...this.subscriptions]) {
      if (!sub.closed) {
        if (sub.cancel) sub.cancel();
        else {
          sub.closed = true;
          if (sub.socket) sub.socket.destroy();
        }
      }
    }
    this.subscriptions.clear();
  }
}
