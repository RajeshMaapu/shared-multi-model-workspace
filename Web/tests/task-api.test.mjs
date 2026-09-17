import test from "node:test";
import assert from "node:assert/strict";
import { createTaskAPI, validateNewTask, normalize, normalizeID,
  ValidationError, UpstreamError } from "../task-api.mjs";
import { WorkshopRPCError } from "../rpc-client.mjs";

const UUID = "web-123e4567-e89b-42d3-a456-426614174000";

function mockRPC(result) {
  const calls = [];
  return {
    calls,
    async call(method, params) {
      calls.push({ method, params });
      if (result instanceof Error) throw result;
      return typeof result === "function" ? result(method, params) : result;
    },
  };
}

function validTask(extra = {}) {
  return {
    idempotency_key: UUID,
    title: "Test task",
    objective: "Do the thing",
    phase: "execution",
    collaboration_mode: "owner_only",
    participants: [],
    channel: "engineering",
    ...extra,
  };
}

test("method mappings", async () => {
  const rpc = mockRPC((method) => {
    if (method === "workshop.getTask") return { task: { id: "task_1" } };
    if (method === "workshop.postMessage") return { ok: true };
    if (method === "workshop_create_task") return { task_id: "task_9" };
    if (method === "workshop_get_capacity") return { devin: {} };
    return [];
  });
  const api = createTaskAPI(rpc);
  await api.listTasks();
  await api.getTask("task_1");
  await api.getMessages("task_1", 50);
  await api.getMessages("task_1");
  await api.postMessage("task_1", "hello");
  await api.getEngineers();
  await api.getCapacity();
  await api.getProposals("task_1");
  await api.getDecisions("task_1");
  await api.getFiles("task_1");
  await api.createTask(validTask());
  assert.deepEqual(rpc.calls.map((c) => c.method), [
    "workshop.listTasks", "workshop.getTask", "workshop.readMessagePage",
    "workshop.readMessagePage", "workshop.postMessage",
    "workshop.listEngineers", "workshop_get_capacity",
    "workshop.listProposals", "workshop.listDecisions",
    "workshop.listArtifacts", "workshop_create_task",
  ]);
  assert.deepEqual(rpc.calls[1].params, { task_id: "task_1" });
  assert.deepEqual(rpc.calls[2].params,
    { task_id: "task_1", limit: 100, before_seq: 50 });
  assert.deepEqual(rpc.calls[3].params, { task_id: "task_1", limit: 100 });
  assert.deepEqual(rpc.calls[4].params, { task_id: "task_1", body: "hello" });
  const created = rpc.calls[10].params;
  assert.equal(created.schema_version, 2);
  assert.equal(created.collaboration_mode, "owner_only");
  assert.equal(created.idempotency_key, UUID);
  assert.equal("origin" in created, false);
});

test("no arbitrary RPC surface", () => {
  const api = createTaskAPI(mockRPC([]));
  for (const key of ["call", "rpc", "method", "exportTask", "backup",
    "exec", "shell", "openPath", "authenticate"]) {
    assert.equal(api[key], undefined, key);
  }
});

test("task id validation", async () => {
  const api = createTaskAPI(mockRPC({ task: { id: "task_ok" } }));
  for (const bad of ["", "task", "x", "task_", "../etc", "task_ a",
    "task_" + "a".repeat(120), 12, { rawValue: "task_ok", extra: 1 }]) {
    await assert.rejects(api.getTask(bad), ValidationError);
  }
  await api.getTask("task_abc-DEF_123");
});

test("before_seq and body validation", async () => {
  const api = createTaskAPI(mockRPC([]));
  for (const bad of [0, -1, 1.5, "5", Number.MAX_SAFE_INTEGER + 1]) {
    await assert.rejects(api.getMessages("task_1", bad), ValidationError);
  }
  for (const bad of ["", "   ", null, 5, "x".repeat(32001)]) {
    await assert.rejects(api.postMessage("task_1", bad), ValidationError);
  }
});

test("new task validation", async () => {
  const api = createTaskAPI(mockRPC({ task_id: "t" }));
  const rejects = [
    null, [], "x", validTask({ extra: 1 }), validTask({ origin: {} }),
    validTask({ constraints: [] }), validTask({ sources: [] }),
    validTask({ workspace_ref: "x" }),
    validTask({ acceptance_criteria: "x" }),
    validTask({ budget_policy_ref: "x" }),
    validTask({ idempotency_key: "codex-invocation-x" }),
    validTask({ idempotency_key: "web-nope" }),
    validTask({ title: "" }), validTask({ title: "x".repeat(241) }),
    validTask({ objective: "" }), validTask({ phase: "other" }),
    validTask({ collaboration_mode: "shared" }),
    validTask({ participants: ["devin"] }),
    validTask({ participants: ["kimi", "kimi"] }),
    validTask({ participants: "kimi" }),
    validTask({ collaboration_mode: "requested_peers", participants: [] }),
    validTask({ participants: ["kimi"] }),
    validTask({ channel: "random" }),
  ];
  for (const input of rejects) {
    await assert.rejects(api.createTask(input), ValidationError,
      JSON.stringify(input));
  }
  await api.createTask(validTask());
  await api.createTask(validTask({
    collaboration_mode: "requested_peers", participants: ["kimi"],
  }));
  await api.createTask(validTask({
    collaboration_mode: "requested_peers",
    participants: ["kimi", "deepseek"],
  }));
});

test("id normalization", () => {
  assert.equal(normalizeID("task_1", "id"), "task_1");
  assert.equal(normalizeID({ rawValue: "task_1" }, "id"), "task_1");
  assert.throws(() => normalizeID(12, "id"), UpstreamError);
  assert.throws(() => normalizeID({ rawValue: "task_1", x: 1 }, "id"),
    UpstreamError);
  assert.throws(() => normalizeID({ nested: { rawValue: "x" } }, "id"),
    UpstreamError);
});

test("date normalization uses Apple reference epoch", () => {
  const out = normalize({ createdAt: 0, created_at: 1, other: 0 });
  assert.equal(out.createdAt, "2001-01-01T00:00:00.000Z");
  assert.equal(out.created_at, "2001-01-01T00:00:01.000Z");
  assert.equal(out.other, 0);
});

test("normalize unwraps sole rawValue objects", () => {
  const out = normalize({ task: { id: { rawValue: "task_5" } },
    participants: [{ engineerID: "kimi" }] });
  assert.equal(out.task.id, "task_5");
  assert.equal(out.participants[0].engineerID, "kimi");
});

test("unknown response shapes become upstream errors", async () => {
  const api = createTaskAPI(mockRPC({ not: "array" }));
  await assert.rejects(api.listTasks(), UpstreamError);
  await assert.rejects(api.getMessages("task_1"), UpstreamError);
  const badTask = createTaskAPI(mockRPC({ nope: true }));
  await assert.rejects(badTask.getTask("task_1"), UpstreamError);
});

test("daemon error mapping", async () => {
  const conflict = createTaskAPI(mockRPC(new WorkshopRPCError(-32009, "x")));
  await assert.rejects(conflict.listTasks(), (err) => {
    assert.equal(err.message, "This submission conflicts with an earlier request");
    assert.equal(err.statusCode, 503);
    return true;
  });
  const unknown = createTaskAPI(
    mockRPC(new WorkshopRPCError(-32603, "/secret/path leaked")));
  await assert.rejects(unknown.listTasks(), (err) => {
    assert.equal(err.message, "Workshop daemon unavailable or request failed");
    return true;
  });
  const generic = createTaskAPI(mockRPC(new Error("ECONNREFUSED /tmp/x.sock")));
  await assert.rejects(generic.listTasks(), (err) => {
    assert.ok(err instanceof UpstreamError);
    assert.ok(!err.message.includes("/tmp"));
    return true;
  });
});

test("event normalization via normalize()", () => {
  const event = normalize({ seq: 3, task_id: { rawValue: "task_2" },
    type: "message.committed", payload: "{}" });
  assert.equal(event.task_id, "task_2");
  assert.equal(event.seq, 3);
});

test('activity history requires bounded valid cursor and task scope', async () => {
  const rpc = mockRPC([]); const api = createTaskAPI(rpc);
  await api.getActivity('task_a', 15);
  assert.deepEqual(rpc.calls[0], { method: 'workshop.readActivity', params: { task_id: 'task_a', after_seq: 15, limit: 200 } });
  for (const bad of [-1, 1.5, Infinity, '12']) await assert.rejects(() => api.getActivity('task_a', bad), ValidationError);
  await assert.rejects(() => api.getActivity('../secret', 0), ValidationError);
});
