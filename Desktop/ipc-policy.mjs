const ARITY = new Map([
  ["listTasks", [0]],
  ["getEngineers", [0]],
  ["getCapacity", [0]],
  ["getTask", [1]],
  ["getActivity", [1, 2]],
  ["getProposals", [1]],
  ["getDecisions", [1]],
  ["getFiles", [1]],
  ["getMessages", [1, 2]],
  ["createTask", [1]],
  ["postMessage", [2]],
]);

const FORBIDDEN_NAMES = new Set([
  "__proto__", "prototype", "constructor", "hasOwnProperty",
  "isPrototypeOf", "propertyIsEnumerable", "toLocaleString", "toString",
  "valueOf", "__defineGetter__", "__defineSetter__", "__lookupGetter__",
  "__lookupSetter__", "subscribe", "then", "call", "apply", "bind",
]);

export function validateInvocation({ senderURL, mainFrame, operation, args }) {
  if (mainFrame !== true) {
    throw new Error("Invocation must come from the main frame");
  }
  let parsed;
  try {
    parsed = new URL(senderURL);
  } catch {
    throw new Error("Invocation sender rejected");
  }
  if (parsed.protocol !== "workshop-preview:" || parsed.hostname !== "app"
      || parsed.port !== "" || parsed.username !== ""
      || parsed.password !== "") {
    throw new Error("Invocation sender rejected");
  }
  if (typeof operation !== "string" || FORBIDDEN_NAMES.has(operation)
      || !ARITY.has(operation)) {
    throw new Error("Operation not allowed");
  }
  if (!Array.isArray(args)) {
    throw new Error("Invalid arguments");
  }
  const list = args;
  if (!ARITY.get(operation).includes(list.length)) {
    throw new Error("Invalid argument count");
  }
  return { operation, args: list };
}
