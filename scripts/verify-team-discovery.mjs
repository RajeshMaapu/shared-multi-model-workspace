import { spawn } from 'node:child_process';

const cwd = process.argv[2] ?? process.cwd();
const child = spawn('codex', ['app-server', '--stdio'], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
const pending = new Map();
let nextID = 1;
let buffer = '';
let diagnosticBytes = 0;
child.stderr.on('data', chunk => { diagnosticBytes += chunk.length; });
child.stdout.on('data', chunk => {
  buffer += chunk.toString();
  if (buffer.length > 4 * 1024 * 1024) { child.kill(); return; }
  let newline;
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    let message;
    try { message = JSON.parse(line); } catch { continue; }
    const handler = pending.get(message.id);
    if (handler) {
      pending.delete(message.id);
      if (message.error) handler.reject(new Error('Codex app-server request failed'));
      else handler.resolve(message.result);
    }
  }
});
const call = (method, params) => new Promise((resolve, reject) => {
  const id = nextID++;
  pending.set(id, { resolve, reject });
  child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
});
const timer = setTimeout(() => {
  for (const handler of pending.values()) handler.reject(new Error('Codex discovery timed out'));
  child.kill();
}, 20000);
child.on('error', error => { for (const handler of pending.values()) handler.reject(error); });
child.on('exit', () => { for (const handler of pending.values()) handler.reject(new Error('Codex app-server exited')); });
try {
  await call('initialize', { clientInfo: { name: 'workshop-skill-discovery', version: '0.2.0' } });
  child.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
  const result = await call('skills/list', { cwds: [cwd], forceReload: true });
  const matches = (result.data ?? []).flatMap(entry => (entry.skills ?? []).filter(skill => skill.name === 'team').map(skill => ({ name: skill.name, path: skill.path, enabled: skill.enabled, scope: skill.scope, description: skill.description })));
  const errors = (result.data ?? []).flatMap(entry => entry.errors ?? []).filter(error => JSON.stringify(error).includes('/team/')).length;
  console.log(JSON.stringify({ cwd, skills: matches, teamErrors: errors, diagnosticBytes }, null, 2));
  if (!matches.some(skill => skill.enabled && String(skill.path).includes('/.codex/skills/team/')) || errors) process.exitCode = 1;
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
} finally {
  clearTimeout(timer);
  child.stdin.end();
  child.kill();
}
