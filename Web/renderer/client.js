async function request(path, options = {}) {
  const init = { method: options.method ?? "GET" };
  if (options.body !== undefined) {
    init.headers = { "Content-Type": "application/json" };
    init.body = JSON.stringify(options.body);
  }
  const res = await fetch(path, init);
  const text = await res.text();
  let data = null;
  if (text.length > 0) {
    try {
      data = JSON.parse(text);
    } catch {
      const err = new Error("Invalid response from gateway");
      err.status = res.status;
      throw err;
    }
  }
  if (!res.ok) {
    const message = data && typeof data.error === "string"
      ? data.error
      : `Request failed (${res.status})`;
    const err = new Error(message);
    err.status = res.status;
    throw err;
  }
  return data;
}

export function createHTTPClient() {
  return {
    listTasks() {
      return request("/api/tasks");
    },
    getTask(taskID) {
      return request("/api/tasks/" + encodeURIComponent(taskID));
    },
    getActivity(taskID, afterSeq = 0) {
      return request("/api/tasks/" + encodeURIComponent(taskID) + "/activity?after_seq=" + afterSeq);
    },
    getMessages(taskID, beforeSeq) {
      const query = beforeSeq !== undefined ? "?before_seq=" + beforeSeq : "";
      return request("/api/tasks/" + encodeURIComponent(taskID)
        + "/messages" + query);
    },
    getEngineers() {
      return request("/api/engineers");
    },
    getCapacity() {
      return request("/api/capacity");
    },
    getProposals(taskID) {
      return request("/api/tasks/" + encodeURIComponent(taskID) + "/proposals");
    },
    getDecisions(taskID) {
      return request("/api/tasks/" + encodeURIComponent(taskID) + "/decisions");
    },
    getFiles(taskID) {
      return request("/api/tasks/" + encodeURIComponent(taskID) + "/files");
    },
    createTask(task) {
      return request("/api/tasks", { method: "POST", body: task });
    },
    postMessage(taskID, body) {
      return request("/api/tasks/" + encodeURIComponent(taskID) + "/messages",
        { method: "POST", body: { body } });
    },
    subscribe(listener) {
      const source = new EventSource("/api/events");
      const onEvent = (e) => {
        try { listener(JSON.parse(e.data)); } catch {}
      };
      const onConnection = (e) => {
        try {
          const data = JSON.parse(e.data);
          listener({ type: "connection", connected: data.connected });
        } catch {}
      };
      const onRefresh = () => listener({ type: "refresh" });
      source.addEventListener("workshop.event", onEvent);
      source.addEventListener("connection", onConnection);
      source.addEventListener("refresh", onRefresh);
      source.onerror = () => listener({ type: "connection", connected: false });
      return () => source.close();
    },
  };
}
