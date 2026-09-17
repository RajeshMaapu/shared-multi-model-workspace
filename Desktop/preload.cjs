"use strict";

const { contextBridge, ipcRenderer } = require("electron");

const invoke = async (operation, args) => {
  const envelope = await ipcRenderer.invoke("workshop:invoke", operation, args);
  if (envelope === null || typeof envelope !== "object"
      || typeof envelope.ok !== "boolean") {
    throw new Error("Workshop daemon unavailable or request failed");
  }
  if (!envelope.ok) {
    const err = new Error(typeof envelope.error === "string"
      ? envelope.error
      : "Workshop daemon unavailable or request failed");
    err.status = envelope.status === 400 ? 400 : 503;
    throw err;
  }
  return envelope.value;
};

const api = {
  listTasks: () => invoke("listTasks", []),
  getActivity: (taskID, afterSeq = 0) => invoke("getActivity", [taskID, afterSeq]),
  getTask: (taskID) => invoke("getTask", [taskID]),
  getMessages: (taskID, beforeSeq) => invoke("getMessages",
    beforeSeq === undefined ? [taskID] : [taskID, beforeSeq]),
  getEngineers: () => invoke("getEngineers", []),
  getCapacity: () => invoke("getCapacity", []),
  getProposals: (taskID) => invoke("getProposals", [taskID]),
  getDecisions: (taskID) => invoke("getDecisions", [taskID]),
  getFiles: (taskID) => invoke("getFiles", [taskID]),
  createTask: (request) => invoke("createTask", [request]),
  postMessage: (taskID, body) => invoke("postMessage", [taskID, body]),
  subscribe: (listener) => {
    const onEvent = (_event, payload) => {
      try { listener(payload); } catch {}
    };
    ipcRenderer.on("workshop:event", onEvent);
    ipcRenderer.send("workshop:subscribe");
    return () => {
      ipcRenderer.removeListener("workshop:event", onEvent);
      ipcRenderer.send("workshop:unsubscribe");
    };
  },
};

contextBridge.exposeInMainWorld("workshop", api);
