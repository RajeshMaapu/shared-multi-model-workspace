import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync }
  from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { validateInvocation } from "../ipc-policy.mjs";
import { assertWebValidated } from "../web-validation.mjs";

const DESKTOP_DIR = path.dirname(fileURLToPath(import.meta.url));
const ORIGIN = "workshop-preview://app";
const base = {
  senderURL: `${ORIGIN}/`,
  mainFrame: true,
  operation: "listTasks",
  args: [],
};

const ok = (over = {}) =>
  validateInvocation({ ...base, ...over });

test("validateInvocation accepts each allowed operation with exact arity", () => {
  for (const [op, args] of [
    ["listTasks", []],
    ["getEngineers", []],
    ["getCapacity", []],
    ["getTask", ["task_abc"]],
    ["getProposals", ["task_abc"]],
    ["getDecisions", ["task_abc"]],
    ["getFiles", ["task_abc"]],
    ["getMessages", ["task_abc"]],
    ["getMessages", ["task_abc", 5]],
    ["createTask", [{}]],
    ["postMessage", ["task_abc", "hi"]],
  ]) {
    const out = ok({ operation: op, args });
    assert.equal(out.operation, op);
    assert.deepEqual(out.args, args);
  }
});

test("validateInvocation rejects wrong origin, userinfo, port, subframe", () => {
  for (const senderURL of [
    "https://evil.example/",
    "workshop-preview://evil/",
    "workshop-preview://user@app/",
    "workshop-preview://app:443/",
    "workshop-preview://app.evil/",
    "not a url",
  ]) {
    assert.throws(() => ok({ senderURL }), /rejected/i,
      `expected rejection for ${senderURL}`);
  }
  assert.throws(() => ok({ mainFrame: false }), /main frame/i);
});

test("validateInvocation rejects unknown, prototype and subscribe operations", () => {
  for (const operation of [
    "subscribe", "invoke", "export", "constructor", "__proto__",
    "hasOwnProperty", "toString", "then", "call", "", 42, null,
  ]) {
    assert.throws(() => ok({ operation }), /not allowed/i,
      `expected rejection for ${String(operation)}`);
  }
});

test("validateInvocation enforces exact argument arity", () => {
  assert.throws(() => ok({ operation: "listTasks", args: [1] }), /argument/i);
  assert.throws(() => ok({ operation: "getTask", args: [] }), /argument/i);
  assert.throws(() => ok({ operation: "getTask", args: ["a", "b"] }),
    /argument/i);
  assert.throws(() => ok({ operation: "getMessages", args: [] }), /argument/i);
  assert.throws(() => ok({ operation: "postMessage", args: ["a"] }),
    /argument/i);
  assert.throws(() => ok({ operation: "createTask", args: [] }), /argument/i);
  assert.throws(() => ok({ operation: "createTask", args: [{}, {}] }),
    /argument/i);
  for (const args of ["task_abc", null, { taskID: "task_abc" }, 3]) {
    assert.throws(() => ok({ operation: "listTasks", args }),
      /argument/i, `expected rejection for args ${JSON.stringify(args)}`);
    assert.throws(() => ok({ operation: "getTask", args }),
      /argument/i, `expected rejection for args ${JSON.stringify(args)}`);
  }
});

function fixture({ checkResult = "pass", fresh = true } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), "webval-"));
  const renderer = path.join(root, "Web", "renderer");
  mkdirSync(renderer, { recursive: true });
  const contents = {
    "index.html": "<html></html>",
    "app.js": "app",
    "client.js": "client",
    "state.js": "state",
    "style.css": "css",
  };
  const hashes = {};
  for (const [name, body] of Object.entries(contents)) {
    writeFileSync(path.join(renderer, name), body);
    hashes[name] = createHash("sha256").update(body).digest("hex");
  }
  const evidenceDir = path.join(root, ".build", "web-qa");
  mkdirSync(evidenceDir, { recursive: true });
  writeFileSync(path.join(evidenceDir, "full.png"), "png");
  writeFileSync(path.join(evidenceDir, "compact.png"), "png");
  const checks = {};
  for (const name of [
    "full_layout_1586x992",
    "compact_980x680",
    "no_generation_suffix_in_system_messages",
    "options_reset_after_create",
    "requested_peers_honored",
  ]) {
    checks[name] = { result: checkResult, fresh };
  }
  writeFileSync(path.join(evidenceDir, "evidence.json"), JSON.stringify({
    renderer_file_sha256: hashes,
    checks,
  }));
  const refDir = path.join(root, "docs", "review");
  mkdirSync(refDir, { recursive: true });
  writeFileSync(path.join(refDir, "approved.png"), "png");
  writeFileSync(path.join(root, "Web", "web-validation.json"), JSON.stringify({
    result: "passed",
    reference: "docs/review/approved.png",
    evidence: ".build/web-qa/evidence.json",
    screenshots: [".build/web-qa/full.png", ".build/web-qa/compact.png"],
    renderer_file_sha256: hashes,
  }));
  return { root, hashes, contents };
}

const STALE = /Web validation missing or stale/;

test("web validation gate passes on a complete valid fixture", () => {
  const { root } = fixture();
  try {
    assert.doesNotThrow(() => assertWebValidated(root));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("web validation gate rejects stale renderer, extra file, stale checks", () => {
  const { root } = fixture();
  try {
    writeFileSync(path.join(root, "Web", "renderer", "app.js"), "changed");
    assert.throws(() => assertWebValidated(root), STALE);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
  const extra = fixture();
  try {
    writeFileSync(path.join(extra.root, "Web", "renderer", "extra.js"), "x");
    assert.throws(() => assertWebValidated(extra.root), STALE);
  } finally {
    rmSync(extra.root, { recursive: true, force: true });
  }
  const stale = fixture({ fresh: false });
  try {
    assert.throws(() => assertWebValidated(stale.root), STALE);
  } finally {
    rmSync(stale.root, { recursive: true, force: true });
  }
  const failed = fixture({ checkResult: "fail" });
  try {
    assert.throws(() => assertWebValidated(failed.root), STALE);
  } finally {
    rmSync(failed.root, { recursive: true, force: true });
  }
  const missing = fixture();
  try {
    rmSync(path.join(missing.root, ".build", "web-qa", "full.png"));
    assert.throws(() => assertWebValidated(missing.root), STALE);
    rmSync(path.join(missing.root, "Web", "web-validation.json"));
    assert.throws(() => assertWebValidated(missing.root), STALE);
  } finally {
    rmSync(missing.root, { recursive: true, force: true });
  }
});

test("web validation gate accepts the live repo manifest", () => {
  assert.doesNotThrow(() => assertWebValidated(
    path.dirname(path.dirname(DESKTOP_DIR))));
});

function loadPreload(respond) {
  const exposed = {};
  const calls = { invoke: [], send: [], on: [], remove: [] };
  const listeners = new Map();
  const ipcRenderer = {
    invoke: async (channel, operation, args) => {
      calls.invoke.push([channel, operation, args]);
      return respond
        ? respond(operation, args)
        : { ok: true, value: `result:${operation}` };
    },
    send: (channel, ...rest) => calls.send.push([channel, ...rest]),
    on: (channel, fn) => {
      calls.on.push(channel);
      listeners.set(channel, fn);
    },
    removeListener: (channel, fn) => {
      calls.remove.push(channel);
      if (listeners.get(channel) === fn) listeners.delete(channel);
    },
  };
  const sandbox = {
    require: (name) => {
      assert.equal(name, "electron");
      return {
        ipcRenderer,
        contextBridge: {
          exposeInMainWorld: (key, value) => {
            exposed[key] = value;
          },
        },
      };
    },
    module: { exports: {} },
  };
  vm.runInNewContext(
    readFileSync(path.join(DESKTOP_DIR, "..", "preload.cjs"), "utf8"),
    sandbox, { filename: "preload.cjs" });
  return { exposed, calls, listeners };
}

const EXPECTED_API = [
  "createTask", "getCapacity", "getDecisions", "getEngineers",
  "getFiles", "getMessages", "getProposals", "getTask", "listTasks",
  "postMessage", "subscribe",
];

test("preload exposes exactly the renderer API surface", async () => {
  const { exposed, calls } = loadPreload();
  assert.deepEqual(Object.keys(exposed), ["workshop"]);
  assert.deepEqual(Object.keys(exposed.workshop).sort(), EXPECTED_API);
  const value = await exposed.workshop.listTasks();
  assert.equal(value, "result:listTasks");
  assert.equal(JSON.stringify(calls.invoke),
    JSON.stringify([["workshop:invoke", "listTasks", []]]));
  await exposed.workshop.getMessages("task_1");
  assert.equal(JSON.stringify(calls.invoke.at(-1)),
    JSON.stringify(["workshop:invoke", "getMessages", ["task_1"]]));
  await exposed.workshop.getMessages("task_1", 7);
  assert.equal(JSON.stringify(calls.invoke.at(-1)),
    JSON.stringify(["workshop:invoke", "getMessages", ["task_1", 7]]));
});

test("preload surfaces daemon errors and removes subscribe listener", async () => {
  const { exposed, calls, listeners } = loadPreload();
  let listener = null;
  const unsub = exposed.workshop.subscribe((e) => { listener = e; });
  assert.equal(JSON.stringify(calls.send),
    JSON.stringify([["workshop:subscribe"]]));
  listeners.get("workshop:event")(null, { type: "refresh" });
  assert.equal(JSON.stringify(listener), JSON.stringify({ type: "refresh" }));
  assert.equal(typeof unsub, "function");
  unsub();
  assert.equal(listeners.has("workshop:event"), false);
  assert.equal(JSON.stringify(calls.send.at(-1)),
    JSON.stringify(["workshop:unsubscribe"]));
});

test("preload throws the safe error envelope", async () => {
  const { exposed } = loadPreload(() => ({ ok: false, error: "denied" }));
  await assert.rejects(() => exposed.workshop.getCapacity(), /denied/);
  const malformed = loadPreload(() => null);
  await assert.rejects(() => malformed.exposed.workshop.listTasks(),
    /unavailable|failed/i);
});

test("preload preserves status 400 for definite rejections, else 503", async () => {
  const bad = loadPreload(() => ({
    ok: false, error: "Invalid task_id", status: 400,
  }));
  await assert.rejects(() => bad.exposed.workshop.getTask("x"),
    (err) => err.status === 400 && /task_id/.test(err.message));
  const upstream = loadPreload(() => ({
    ok: false, error: "unavailable", status: 500,
  }));
  await assert.rejects(() => upstream.exposed.workshop.getTask("x"),
    (err) => err.status === 503);
  const noStatus = loadPreload(() => ({ ok: false, error: "oops" }));
  await assert.rejects(() => noStatus.exposed.workshop.getTask("x"),
    (err) => err.status === 503);
  const badStatus = loadPreload(() => ({
    ok: false, error: "oops", status: 418,
  }));
  await assert.rejects(() => badStatus.exposed.workshop.getTask("x"),
    (err) => err.status === 503);
});
