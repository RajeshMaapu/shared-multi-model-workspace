import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, openSync, closeSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export function installedPaths(resourcesPath, tempDir, userHome = os.homedir()) {
  if (!path.isAbsolute(resourcesPath) || !path.isAbsolute(tempDir)) {
    throw new Error('Workshop requires absolute runtime paths');
  }
  const home = path.join(userHome, 'Library', 'Application Support', 'Workshop');
  const runtime = path.join(tempDir.trim(), 'workshop');
  return { home, runtime, socket: path.join(runtime, 'service.sock'),
    daemon: path.join(resourcesPath, 'workshop-daemon') };
}

export async function ensureDaemon(paths, probe, launch, { attempts = 50, wait = () => new Promise(r => setTimeout(r, 100)) } = {}) {
  try { await probe(); return { started: false }; } catch {}
  // Only startup is retried. Never send or replay a user mutation here.
  await launch(paths);
  for (let i = 0; i < attempts; i++) {
    await wait();
    try { await probe(); return { started: true }; } catch {}
  }
  throw new Error('Workshop background service did not become available. See diagnostics/desktop-daemon.log.');
}

export function defaultInstalledPaths(resourcesPath) {
  return installedPaths(resourcesPath,
    execFileSync('/usr/bin/getconf', ['DARWIN_USER_TEMP_DIR'], { encoding: 'utf8' }).trim());
}

export function launchInstalledDaemon(paths) {
  mkdirSync(paths.runtime, { recursive: true, mode: 0o700 });
  const diagnostics = path.join(paths.home, 'diagnostics');
  mkdirSync(diagnostics, { recursive: true, mode: 0o700 });
  const fd = openSync(path.join(diagnostics, 'desktop-daemon.log'), 'a', 0o600);
  return new Promise((resolve, reject) => {
    const child = spawn(paths.daemon, [], { detached: true,
      env: { ...process.env, PATH: [path.join(os.homedir(), '.local', 'bin'), '/usr/bin', '/bin', '/usr/sbin', '/sbin', '/opt/homebrew/bin', '/usr/local/bin'].join(':'), WORKSHOP_HOME: paths.home,
        WORKSHOP_RUNTIME_DIR: paths.runtime, WORKSHOP_ADAPTERS: 'live' },
      stdio: ['ignore', fd, fd] });
    closeSync(fd);
    child.once('error', reject);
    child.once('spawn', () => { child.unref(); resolve(); });
  });
}
