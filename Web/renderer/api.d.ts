export interface WorkshopAPI {
  listTasks(): Promise<unknown[]>;
  getTask(taskID: string): Promise<unknown>;
  getMessages(taskID: string, beforeSeq?: number): Promise<unknown[]>;
  getEngineers(): Promise<unknown[]>;
  getCapacity(): Promise<unknown>;
  getProposals(taskID: string): Promise<unknown[]>;
  getDecisions(taskID: string): Promise<unknown[]>;
  getFiles(taskID: string): Promise<unknown[]>;
  createTask(request: NewTask): Promise<unknown>;
  postMessage(taskID: string, body: string): Promise<unknown>;
  subscribe(listener: (event: unknown) => void): () => void;
}

export interface NewTask {
  idempotency_key: string;
  title: string;
  objective: string;
  phase: 'execution' | 'research_proposal';
  collaboration_mode: 'owner_only' | 'requested_peers';
  participants: ('kimi' | 'deepseek')[];
  channel: string;
}
