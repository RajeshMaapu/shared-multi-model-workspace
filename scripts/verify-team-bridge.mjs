import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

const [binary, runtimeDir, tokenFile] = process.argv.slice(2);
if (!binary || !runtimeDir || !tokenFile) throw new Error('Usage: node verify-team-bridge.mjs <bridge> <isolated-runtime> <token-file>');
const child = spawn(binary, ['--principal', 'codex', '--runtime-dir', runtimeDir, '--token-file', tokenFile], { stdio: ['pipe', 'pipe', 'pipe'] });
const pending = new Map();
let nextID = 1;
let buffer = '';
child.stderr.on('data', () => {});
child.stdout.on('data', chunk => {
  buffer += chunk.toString();
  let newline;
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    let message;
    try { message = JSON.parse(line); } catch { continue; }
    const waiter = pending.get(message.id);
    if (waiter) {
      pending.delete(message.id);
      if (message.error) waiter.reject(new Error('MCP protocol error'));
      else waiter.resolve(message.result);
    }
  }
});
const call = (method, params) => new Promise((resolve, reject) => {
  const id = nextID++;
  pending.set(id, { resolve, reject });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
});
const tool = async (name, args = {}) => {
  const result = await call('tools/call', { name, arguments: args });
  if (result.isError) throw new Error('Workshop tool rejected the isolated test');
  return JSON.parse(result.content.find(item => item.type === 'text').text);
};
const timer = setTimeout(() => {
  for (const waiter of pending.values()) waiter.reject(new Error('MCP verification timeout'));
  child.kill();
}, 25000);
child.on('error', error => { for (const waiter of pending.values()) waiter.reject(error); });
try {
  await call('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'workshop-team-verification', version: '0.2.0' } });
  const tools = await call('tools/list', {});
  const properties = tools.tools.find(item => item.name === 'workshop_create_task').inputSchema.properties;
  assert.ok(properties.schema_version && properties.collaboration_mode && properties.origin);
  const before = await tool('workshop_list_tasks');
  const invocationID = randomUUID();
  const request = { schema_version: 2, idempotency_key: 'codex-invocation-' + invocationID, title: 'MCP Codex owner verification', objective: 'Isolated bridge verification with fake adapters', phase: 'execution', collaboration_mode: 'owner_only', participants: [], origin: { source_task_id: 'verification-fixture-not-real-codex-thread', invocation_id: invocationID } };
  const first = await tool('workshop_create_task', request);
  const retry = await tool('workshop_create_task', request);
  assert.equal(first.task_id, retry.task_id);
  assert.equal((await tool('workshop_list_tasks')).length, before.length + 1);
  const detail = await tool('workshop_get_task', { task_id: first.task_id });
  assert.deepEqual(detail.participants.map(item => item.engineerID), ['devin']);
  assert.deepEqual(detail.ingress.request.origin, request.origin);
  const reply = await tool('workshop_post_message', { task_id: first.task_id, body: 'Bridge follow-up verification' });
  const messages = await tool('workshop_read_messages', { task_id: first.task_id, after_seq: 0 });
  assert.ok(messages.some(item => JSON.stringify(item.id) === JSON.stringify(reply.id)));
  const peerInvocation = randomUUID();
  const peers = await tool('workshop_create_task', { ...request, idempotency_key: 'codex-invocation-' + peerInvocation, title: 'MCP Codex requested peers verification', collaboration_mode: 'requested_peers', participants: ['kimi'], origin: { ...request.origin, invocation_id: peerInvocation } });
  const peerDetail = await tool('workshop_get_task', { task_id: peers.task_id });
  assert.deepEqual(new Set(peerDetail.participants.map(item => item.engineerID)), new Set(['devin', 'kimi']));
  assert.equal((await tool('workshop_list_tasks')).length, before.length + 2);
  console.log(JSON.stringify({ pass: true, ownerTaskID: first.task_id, collaborationTaskID: peers.task_id, retryDeduplicated: true, followUpPersisted: true, originBinding: 'synthetic fixture only', adapters: 'isolated fake adapters; no live engineer claim' }, null, 2));
} finally {
  clearTimeout(timer);
  child.stdin.end();
  child.kill();
}
