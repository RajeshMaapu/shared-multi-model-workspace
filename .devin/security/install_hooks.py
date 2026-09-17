import argparse
import os
from pathlib import Path
import subprocess
import sys

SOURCE_ROOT = Path(__file__).resolve().parent.parent.parent
SECURITY_DIR = SOURCE_ROOT / '.devin' / 'security'
HOOK_TEMPLATES = SOURCE_ROOT / '.devin' / 'git-hooks'
RUNTIME_FILES = [
    ('workshop-publication/publication_guard.py', SECURITY_DIR / 'publication_guard.py', 0o644),
    ('workshop-publication/policy.json', SECURITY_DIR / 'policy.json', 0o644),
    ('pre-commit', HOOK_TEMPLATES / 'pre-commit', 0o755),
    ('pre-merge-commit', HOOK_TEMPLATES / 'pre-merge-commit', 0o755),
    ('pre-push', HOOK_TEMPLATES / 'pre-push', 0o755),
]


def git(repo, *args, ok=(0,)):
    result = subprocess.run(['git', '-C', str(repo), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in ok:
        raise RuntimeError('Git operation failed: ' + args[0])
    return result


def reject_symlink_path(path, stop):
    current = Path(stop)
    try:
        relative = path.relative_to(stop)
    except ValueError:
        raise ValueError('Destination outside hooks directory')
    for part in relative.parts[:-1]:
        current = current / part
        if os.path.islink(current):
            raise ValueError('Refusing symlinked directory: ' + str(current))
    if os.path.islink(path):
        raise ValueError('Refusing symlink destination: ' + str(path))


def install(repo):
    repo = Path(repo).resolve()
    git(repo, 'rev-parse', '--git-dir')
    hooks_path = git(repo, 'config', '--get', 'core.hooksPath', ok=(0, 1))
    if hooks_path.returncode == 0 and hooks_path.stdout.strip():
        raise ValueError('core.hooksPath is configured; refusing to install')
    common = Path(git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir').stdout.decode().strip()).resolve()
    hooks_dir = common / 'hooks'

    plan = []
    conflicts = []
    for relative, source, mode in RUNTIME_FILES:
        if os.path.islink(source) or not source.is_file():
            raise ValueError('Missing or invalid source: ' + str(source))
        expected = source.read_bytes()
        destination = hooks_dir / relative
        reject_symlink_path(destination, common)
        if destination.exists():
            if not destination.is_file() or destination.read_bytes() != expected:
                conflicts.append(destination)
                continue
            if mode == 0o755 and not os.access(destination, os.X_OK):
                conflicts.append(destination)
                continue
            plan.append((destination, expected, mode, False))
        else:
            plan.append((destination, expected, mode, True))
    if conflicts:
        for path in conflicts:
            print('Conflicting existing file (not modified): ' + str(path), file=sys.stderr)
        raise ValueError('Refusing to overwrite existing hooks; remove them manually after review')

    for destination, expected, mode, create in plan:
        if not create:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, mode)
        try:
            with os.fdopen(fd, 'wb') as handle:
                handle.write(expected)
        except BaseException:
            destination.unlink(missing_ok=True)
            raise
    print('Publication guards installed under ' + str(hooks_dir))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', default=os.getcwd())
    args = parser.parse_args()
    try:
        install(args.repo)
        return 0
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print('Hook installation blocked: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
