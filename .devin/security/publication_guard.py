import argparse
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
PRIVATE_NAMES = {
    'credentials', 'secrets', 'token', 'api-key', 'api_key', '.envrc', '.netrc', '.pypirc',
    'auth.json', 'auth.toml', 'auth.yaml', 'auth.yml', 'tokens.json', 'tokens.toml',
    'credential.json', 'credential.toml', 'credential.yaml', 'credential.yml',
    'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'AGENTS.local.md',
}
PRIVATE_DIRS = {'.aws', '.azure', '.gcloud', '.ssh', '.gnupg', '.secrets', '.oauth', '.direnv', 'credentials', 'secrets'}
ROOT_DIRS = {'.workshop', 'workshop-home', 'workshop-runtime', 'runtime', 'db', 'profiles', 'sessions', 'worktrees', 'writer-runs', 'writer-snapshots', 'artifacts', 'diagnostics', 'backups', 'exports', 'private', 'tmp', 'config'}
PRIVATE_GLOBS = ['credentials.*', 'secrets.*', 'api-key.*', 'api_key.*', '*.token', '*.pem', '*.key', '*.p8', '*.p12', '*.pfx', '*.jks', '*.keystore', '*.keychain', '*.keychain-db', '*.mobileprovision', '*.provisionprofile', '*.sqlite*', '*.db', '*.db-shm', '*.db-wal', '*.db-journal', '*.dump', '*.sql.gz', '*.sql.zip', '*.bak', '*.backup', '*.log', '*.log.*', '*.har', '*.sock', '*.lock', '*.local.json', '*.local.toml', '*.local.yaml', '*.local.yml', '*.local.ini', '*.local.conf', '*.local.env', '*.local.sh', 'id_rsa_*', 'id_dsa_*', 'id_ecdsa_*', 'id_ed25519_*']
PATTERNS = [
    ('private key', re.compile(rb'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----')),
    ('GitHub token', re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b')),
    ('provider key', re.compile(rb'\bsk-[A-Za-z0-9_-]{16,}\b')),
    ('AWS access key', re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('Slack token', re.compile(rb'\bxox[baprs]-[A-Za-z0-9-]{12,}\b')),
    ('JWT', re.compile(rb'\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}')),
    ('bearer credential', re.compile(rb'(?i)\bBearer[ \t]+[A-Za-z0-9_.+/=-]{20,}')),
    ('credential URL', re.compile(rb'https?://[^\s/:"\x27]+:[^\s/@"\x27]+@')),
    ('credential assignment', re.compile(rb'''(?i)["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|secret|token)["']?\s*[:=]\s*["']([A-Za-z0-9_./+=-]{16,})["']''')),
    ('personal filesystem path', re.compile(rb'/Users/[A-Za-z0-9_.-]+/')),
]
DOC_ID = re.compile(rb'\btask_[0-9a-f]{8}(?:[0-9a-f-]*)(?:\xe2\x80\xa6)?\b')
PLACEHOLDERS = re.compile(rb'(?i)^(?:your[_-]|example[_-]|placeholder|replace[_-]|changeme|test[_-]|dummy[_-])')


def git(*args, input=None, ok=(0,)):
    result = subprocess.run(['git', *args], input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=dict(os.environ, GIT_NO_REPLACE_OBJECTS='1'))
    if result.returncode not in ok:
        raise RuntimeError('Git operation failed: ' + args[0])
    return result


def private_path(path):
    parts = path.split('/')
    name = parts[-1]
    if name.startswith('.env') and (name == '.env' or name.startswith('.env.')):
        return not name.endswith(('.example', '.sample', '.template'))
    if name in PRIVATE_NAMES or any(part in PRIVATE_DIRS for part in parts[:-1]):
        return True
    if parts[0] in ROOT_DIRS or path == 'bin/workshop-mcp' or path.endswith('/.docker/config.json') or path == '.docker/config.json':
        return True
    if any(fnmatch.fnmatchcase(name, pattern) for pattern in PRIVATE_GLOBS):
        return True
    if path.startswith('Configuration/') and name.endswith('.json'):
        return not name.endswith(('.template.json', '.example.json'))
    if path.startswith('docs/evidence/') and set(parts[2:-1]) & {'live', 'raw', 'private', 'transcripts', 'tmp'}:
        return True
    if '.devin' in parts and (name.startswith('mcp_config') or name.startswith('config.')):
        return True
    return False


class Guard:
    def __init__(self):
        self.policy = json.loads((ROOT / 'policy.json').read_text())
        if self.policy['version'] != 1:
            raise ValueError('Unsupported policy')
        self.seen = set()
        self.issues = set()

    def issue(self, path, category, line=0):
        self.issues.add((path, line, category))

    def content(self, path, data):
        allowed = set(value.encode() for value in self.policy['fixture_literals'].get(path, []))
        if path == '.devin/security/policy.json':
            for values in self.policy['fixture_literals'].values():
                allowed.update(value.encode() for value in values)
        for category, pattern in PATTERNS:
            for match in pattern.finditer(data):
                literal = match.group(1) if category == 'credential assignment' else match.group()
                if literal in allowed or (category == 'credential assignment' and PLACEHOLDERS.match(literal)):
                    continue
                self.issue(path, category, data[:match.start()].count(b'\n') + 1)
        if path.startswith('docs/') or path in ('<commit message>', '<tag annotation>'):
            for match in DOC_ID.finditer(data):
                self.issue(path, 'private task identifier', data[:match.start()].count(b'\n') + 1)

    def blob(self, path, mode, oid):
        if private_path(path):
            self.issue(path, 'private file path')
        key = (path, mode, oid)
        if key in self.seen:
            return
        self.seen.add(key)
        if mode not in ('100644', '100755', '120000'):
            self.issue(path, 'unsupported file mode; manual review required')
            return
        if int(git('cat-file', '-s', oid).stdout) > self.policy['max_blob_bytes']:
            self.issue(path, 'file exceeds scan limit; manual review required')
            return
        data = git('cat-file', 'blob', oid).stdout
        if mode == '120000' and (data.startswith(b'/') or b'..' in data.split(b'/')):
            self.issue(path, 'external symlink')
        self.content(path, data)

    def staged(self):
        for entry in git('ls-files', '--stage', '-z').stdout.split(b'\0'):
            if not entry:
                continue
            header, path = entry.split(b'\t', 1)
            mode, oid, stage = header.decode().split()
            if stage != '0':
                raise ValueError('Unmerged index')
            self.blob(path.decode('utf-8', 'surrogateescape'), mode, oid)

    def push(self, updates):
        tips = set()
        for line in updates.splitlines():
            fields = line.split()
            if len(fields) != 4 or not all(re.fullmatch(r'[0-9a-f]{40,64}', fields[i]) for i in (1, 3)):
                raise ValueError('Invalid pre-push input')
            if set(fields[1]) != {'0'}:
                oid = fields[1]
                while git('cat-file', '-t', oid).stdout.strip() == b'tag':
                    annotation = git('cat-file', 'tag', oid).stdout
                    self.content('<tag annotation>', annotation)
                    oid = annotation.split(b'\n', 1)[0].split()[1].decode('ascii')
                tips.add(git('rev-parse', '--verify', fields[1] + '^{commit}').stdout.decode().strip())
        if not tips:
            return
        if git('rev-parse', '--is-shallow-repository').stdout.strip() != b'false':
            raise ValueError('Complete history is required for publication checks')
        ancestors = set(git('rev-list', *sorted(tips)).stdout.decode().splitlines())
        if ancestors & set(self.policy['blocked_commits']):
            self.issue('<outgoing history>', 'pre-cleanup or private development ancestry; port changes onto clean history')
            return
        args = sorted(tips)
        base = self.policy['clean_base']
        if git('cat-file', '-e', base + '^{commit}', ok=(0, 1, 128)).returncode == 0:
            args.append('^' + base)
        for commit in git('rev-list', *args).stdout.decode().splitlines():
            self.content('<commit message>', git('show', '-s', '--format=%B', commit).stdout)
            entries = git('diff-tree', '--root', '--no-commit-id', '--raw', '-r', '-z', '--no-renames', '-m', commit).stdout.split(b'\0')
            index = 0
            while index < len(entries) and entries[index]:
                header = entries[index].decode().split()
                path = entries[index + 1].decode('utf-8', 'surrogateescape')
                index += 2
                if header[4] != 'D':
                    self.blob(path, header[1], header[3])

    def finish(self):
        if self.issues:
            print('Publication blocked. Resolve these findings; do not bypass the guard:', file=sys.stderr)
            for path, line, category in sorted(self.issues):
                print(f'  {path!r}:{line}: {category}', file=sys.stderr)
            return 1
        print('Publication guard passed (manual artifact review still required).', file=sys.stderr)
        return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['staged', 'pre-push'])
    parser.add_argument('hook_args', nargs='*')
    args = parser.parse_args()
    try:
        guard = Guard()
        if args.mode == 'staged':
            guard.staged()
        else:
            guard.push(sys.stdin.read())
        return guard.finish()
    except (OSError, ValueError, KeyError, RuntimeError, IndexError, TypeError):
        print('Publication blocked: the guard could not complete. Repair the check; do not bypass it.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
