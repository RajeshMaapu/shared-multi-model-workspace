export const NEEDS_INPUT_STATES = new Set([
  "blocked", "paused", "awaiting_architecture_approval",
]);

export function messageID(message) {
  if (message === null || typeof message !== "object") return null;
  const id = message.id;
  if (typeof id === "string") return id;
  if (id && typeof id === "object" && typeof id.rawValue === "string") {
    return id.rawValue;
  }
  return null;
}

export function isCommitted(message) {
  const state = message?.deliveryState ?? message?.delivery_state;
  return state === "committed";
}

export function mergeMessages(existing, page) {
  const byKey = new Map();
  for (const message of [...existing, ...page]) {
    if (!isCommitted(message)) continue;
    const id = messageID(message);
    const key = id ?? `seq:${message.seq}`;
    byKey.set(key, message);
  }
  return [...byKey.values()].sort((a, b) => a.seq - b.seq);
}

export function isFresh(requestGen, taskID, currentGen, currentTaskID) {
  return requestGen === currentGen && taskID === currentTaskID;
}

export function taskNeedsInput(task) {
  return NEEDS_INPUT_STATES.has(task?.state);
}

export function filterTasks(tasks, { view, space, search }) {
  const needle = String(search ?? "").toLowerCase();
  return tasks.filter((task) => {
    if (view === "needs" && !taskNeedsInput(task)) return false;
    if (view === "space" && task.channel !== space) return false;
    if (needle.length > 0) {
      const hay = `${task.title ?? ""} ${task.brief ?? ""}`.toLowerCase();
      if (!hay.includes(needle)) return false;
    }
    return true;
  });
}

export function buildTaskPayload({ draft, phase, mode, peers, channel, uuid }) {
  const objective = String(draft ?? "").trim();
  if (objective.length === 0) {
    throw new Error("Task draft is empty");
  }
  const title = objective.split("\n")[0].trim().slice(0, 240);
  const participants = mode === "requested_peers" ? [...peers] : [];
  return {
    idempotency_key: `web-${uuid}`,
    title,
    objective,
    phase,
    collaboration_mode: mode,
    participants,
    channel,
  };
}

export function viaCodex(structured) {
  if (typeof structured !== "string" || structured.length === 0) return false;
  try {
    const parsed = JSON.parse(structured);
    return parsed && parsed.via === "codex";
  } catch {
    return false;
  }
}

export function authorName(author, structured) {
  if (typeof author !== "string") return "Unknown";
  if (author === "user") {
    return viaCodex(structured) ? "You (via Codex)" : "You";
  }
  if (author === "codex") return "You (via Codex)";
  if (author === "system") return "Workshop";
  if (author.startsWith("engineer:")) {
    const id = author.slice(9);
    return { devin: "Devin Fusion", kimi: "Kimi K3",
      deepseek: "DeepSeek" }[id] ?? id;
  }
  return author;
}

export function authorColor(author) {
  if (typeof author === "string" && author.startsWith("engineer:")) {
    const id = author.slice(9);
    if (id === "kimi") return "kimi";
    if (id === "deepseek") return "deepseek";
    return "fusion";
  }
  return "user";
}

export function displayMessageBody(message) {
  const body = String(message.body ?? '');
  return message.author === 'system'
    ? body.replace(/ \(generation \d+\)(?=\s|$)/g, '')
    : body;
}

export function parseProposal(content) {
  if (typeof content !== "string") return null;
  try {
    const parsed = JSON.parse(content);
    if (parsed === null || typeof parsed !== "object") return null;
    return parsed;
  } catch {
    return null;
  }
}
