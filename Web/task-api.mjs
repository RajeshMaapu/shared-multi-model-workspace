import { WorkshopRPCError } from "./rpc-client.mjs";

export class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "ValidationError";
    this.statusCode = 400;
  }
}

export class UpstreamError extends Error {
  constructor(message) {
    super(message);
    this.name = "UpstreamError";
    this.statusCode = 503;
  }
}

const TASK_ID_PATTERN = /^task_[a-zA-Z0-9_-]{1,100}$/;
const IDEMPOTENCY_PATTERN = /^web-[a-f0-9-]{36}$/;
const PHASES = new Set(["execution", "research_proposal"]);
const MODES = new Set(["owner_only", "requested_peers"]);
const PEERS = new Set(["kimi", "deepseek"]);
const CHANNELS = new Set(["engineering", "research", "product", "projects"]);

const DATE_KEYS = new Set([
  "created_at", "updated_at", "observed_at", "reset_at", "committed_at",
  "completed_at", "started_at", "deadline",
  "createdAt", "updatedAt", "observedAt", "resetAt", "committedAt",
  "completedAt", "startedAt", "endedAt", "firstEventAt", "expiresAt",
  "leaseExpiresAt", "cancelRequestedAt", "deliveredAt",
]);
const ID_KEYS = new Set([
  "id", "task_id", "message_id", "subtask_id", "parent_id", "artifact_id",
  "taskID", "messageID", "subtaskID", "parentID", "artifactID", "replyTo",
]);

const APPLE_EPOCH_OFFSET_SECONDS = 978307200;

const SAFE_ERROR_MESSAGES = new Map([
  [-32009, "This submission conflicts with an earlier request"],
  [-32602, "The daemon rejected the request as invalid"],
  [-32601, "The daemon does not support this operation"],
]);

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function normalizeID(value, field) {
  if (typeof value === "string") return value;
  if (isPlainObject(value) && Object.keys(value).length === 1
      && typeof value.rawValue === "string") {
    return value.rawValue;
  }
  throw new UpstreamError(`Unexpected ${field} shape`);
}

function normalizeDate(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return new Date(Math.round((value + APPLE_EPOCH_OFFSET_SECONDS) * 1000))
      .toISOString();
  }
  return value;
}

export function normalize(value, key = null) {
  if (Array.isArray(value)) {
    return value.map((item) => normalize(item));
  }
  if (isPlainObject(value)) {
    const keys = Object.keys(value);
    if (keys.length === 1 && typeof value.rawValue === "string") {
      return value.rawValue;
    }
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (v === null || v === undefined) {
        out[k] = v ?? null;
      } else if (ID_KEYS.has(k)) {
        out[k] = normalizeID(v, k);
      } else if (DATE_KEYS.has(k) && typeof v === "number") {
        out[k] = normalizeDate(v);
      } else {
        out[k] = normalize(v, k);
      }
    }
    return out;
  }
  return value;
}

function requireTaskID(taskID) {
  let id;
  try {
    id = normalizeID(taskID, "task_id");
  } catch {
    throw new ValidationError("Invalid task_id");
  }
  if (typeof id !== "string" || !TASK_ID_PATTERN.test(id)) {
    throw new ValidationError("Invalid task_id");
  }
  return id;
}

function optionalBeforeSeq(beforeSeq) {
  if (beforeSeq === undefined || beforeSeq === null) return undefined;
  if (!Number.isSafeInteger(beforeSeq) || beforeSeq <= 0) {
    throw new ValidationError("before_seq must be a positive integer");
  }
  return beforeSeq;
}

function requireBody(body) {
  if (typeof body !== "string" || body.trim().length === 0) {
    throw new ValidationError("body must be a non-empty string");
  }
  if (body.length > 32000) {
    throw new ValidationError("body exceeds 32000 characters");
  }
  return body;
}

const NEW_TASK_KEYS = new Set([
  "idempotency_key", "title", "objective", "phase", "collaboration_mode",
  "participants", "channel",
]);

export function validateNewTask(input) {
  if (!isPlainObject(input)) {
    throw new ValidationError("Task request must be an object");
  }
  for (const key of Object.keys(input)) {
    if (!NEW_TASK_KEYS.has(key)) {
      throw new ValidationError(`Unsupported field: ${key}`);
    }
  }
  const { idempotency_key, title, objective, phase, collaboration_mode,
    participants, channel } = input;
  if (typeof idempotency_key !== "string"
      || !IDEMPOTENCY_PATTERN.test(idempotency_key)) {
    throw new ValidationError("idempotency_key must be web-<uuid>");
  }
  if (typeof title !== "string" || title.trim().length === 0
      || title.length > 240) {
    throw new ValidationError("title must be 1-240 characters");
  }
  if (typeof objective !== "string" || objective.trim().length === 0
      || objective.length > 32000) {
    throw new ValidationError("objective must be 1-32000 characters");
  }
  if (!PHASES.has(phase)) {
    throw new ValidationError("phase must be execution or research_proposal");
  }
  if (!MODES.has(collaboration_mode)) {
    throw new ValidationError(
      "collaboration_mode must be owner_only or requested_peers");
  }
  if (!Array.isArray(participants)) {
    throw new ValidationError("participants must be an array");
  }
  const peers = new Set();
  for (const p of participants) {
    if (!PEERS.has(p)) {
      throw new ValidationError("participants may only include kimi/deepseek");
    }
    if (peers.has(p)) {
      throw new ValidationError("Duplicate participant");
    }
    peers.add(p);
  }
  if (collaboration_mode === "owner_only" && peers.size > 0) {
    throw new ValidationError("owner_only tasks may not select peers");
  }
  if (collaboration_mode === "requested_peers" && peers.size === 0) {
    throw new ValidationError("requested_peers requires at least one peer");
  }
  if (!CHANNELS.has(channel)) {
    throw new ValidationError("Unknown channel");
  }
  return {
    schema_version: 2,
    idempotency_key,
    title: title.trim(),
    objective,
    phase,
    collaboration_mode,
    participants: [...peers],
    channel,
  };
}

function wrapError(err) {
  if (err instanceof ValidationError || err instanceof UpstreamError) {
    return err;
  }
  if (err instanceof WorkshopRPCError) {
    const safe = SAFE_ERROR_MESSAGES.get(err.rpcCode);
    return new UpstreamError(
      safe ?? "Workshop daemon unavailable or request failed");
  }
  return new UpstreamError("Workshop daemon unavailable or request failed");
}

export function createTaskAPI(rpc) {
  if (rpc === null || typeof rpc.call !== "function") {
    throw new ValidationError("rpc client required");
  }
  const call = async (method, params) => {
    try {
      return normalize(await rpc.call(method, params));
    } catch (err) {
      throw wrapError(err);
    }
  };
  return {
    async listTasks() {
      const result = await call("workshop.listTasks", {});
      if (!Array.isArray(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async getTask(taskID) {
      const result = await call("workshop.getTask",
        { task_id: requireTaskID(taskID) });
      if (!isPlainObject(result) || !isPlainObject(result.task)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async getMessages(taskID, beforeSeq) {
      const params = { task_id: requireTaskID(taskID), limit: 100 };
      const before = optionalBeforeSeq(beforeSeq);
      if (before !== undefined) params.before_seq = before;
      const result = await call("workshop.readMessagePage", params);
      if (!Array.isArray(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async postMessage(taskID, body) {
      const result = await call("workshop.postMessage", {
        task_id: requireTaskID(taskID),
        body: requireBody(body),
      });
      if (!isPlainObject(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async getEngineers() {
      const result = await call("workshop.listEngineers", {});
      if (!Array.isArray(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async getCapacity() {
      const result = await call("workshop_get_capacity", {});
      if (!isPlainObject(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async getProposals(taskID) {
      const result = await call("workshop.listProposals",
        { task_id: requireTaskID(taskID) });
      if (!Array.isArray(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async getDecisions(taskID) {
      const result = await call("workshop.listDecisions",
        { task_id: requireTaskID(taskID) });
      if (!Array.isArray(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async getFiles(taskID) {
      const result = await call("workshop.listArtifacts",
        { task_id: requireTaskID(taskID) });
      if (!Array.isArray(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
    async createTask(input) {
      const request = validateNewTask(input);
      const result = await call("workshop_create_task", request);
      if (!isPlainObject(result)) {
        throw new UpstreamError("Unexpected daemon response");
      }
      return result;
    },
  };
}
