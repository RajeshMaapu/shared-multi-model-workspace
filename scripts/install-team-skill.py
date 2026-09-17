import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / '.devin' / 'skills' / 'team'
MANAGED = ('SKILL.md', 'scripts/invocation.py', 'agents/openai.yaml')


def safe_path(value):
    path = Path(os.path.abspath(os.path.expanduser(str(value))))
    for part in [path] + list(path.parents):
        if part.is_symlink():
            raise ValueError('Symlink paths are not permitted')
    return path


def digest(path):
    path = safe_path(path)
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def atomic_copy(source, destination, mode):
    source, destination = safe_path(source), safe_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.team-install-', dir=str(destination.parent))
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(source.read_bytes())
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        safe_path(destination)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(destination, dry_run):
    destination = safe_path(destination)
    before, installed = {}, {}
    for relative in MANAGED:
        source = safe_path(SOURCE / relative)
        if not source.is_file():
            raise ValueError('Missing skill source: ' + relative)
        before[relative] = digest(destination / relative)
        installed[relative] = digest(source)
    result = {'destination': str(destination), 'files': list(MANAGED), 'dry_run': dry_run}
    if dry_run:
        return result
    destination.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    backup_root = safe_path(destination.parent.parent / 'workshop-skill-backups')
    backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = backup_root / (destination.name + '.' + stamp)
    backup.mkdir(mode=0o700)
    for relative in MANAGED:
        old = destination / relative
        if old.exists():
            atomic_copy(old, backup / relative, old.stat().st_mode & 0o777)
    manifest = {'version': 1, 'destination': str(destination), 'before': before, 'installed': installed}
    (backup / 'install-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    for relative in MANAGED:
        if digest(destination / relative) != before[relative]:
            raise ValueError('Destination changed during backup; refusing overwrite')
    try:
        for relative in MANAGED:
            atomic_copy(SOURCE / relative, destination / relative, 0o755 if relative.endswith('.py') else 0o644)
    except OSError:
        for relative in MANAGED:
            if before[relative] is not None and digest(destination / relative) == installed[relative]:
                atomic_copy(backup / relative, destination / relative, (backup / relative).stat().st_mode & 0o777)
        raise
    result.update(backup=str(backup), installed_hashes=installed)
    return result


def rollback(backup, dry_run):
    backup = safe_path(backup)
    manifest = json.loads((safe_path(backup / 'install-manifest.json')).read_text(encoding='utf-8'))
    managed = tuple(manifest.get('installed', {}))
    if manifest.get('version') != 1 or not managed or set(managed) - set(MANAGED):
        raise ValueError('Invalid install manifest')
    destination = safe_path(manifest['destination'])
    for relative in managed:
        if digest(destination / relative) != manifest['installed'][relative]:
            raise ValueError('Installed skill changed; refusing rollback over user edits')
        if manifest['before'].get(relative) is not None and digest(backup / relative) != manifest['before'][relative]:
            raise ValueError('Backup changed; refusing rollback')
    result = {'destination': str(destination), 'backup': str(backup), 'dry_run': dry_run, 'restored': [], 'leftover_new_files': []}
    for relative in managed:
        if manifest['before'].get(relative) is None:
            result['leftover_new_files'].append(str(destination / relative))
        else:
            if not dry_run:
                atomic_copy(backup / relative, destination / relative, (backup / relative).stat().st_mode & 0o777)
            result['restored'].append(relative)
    return result


def main():
    parser = argparse.ArgumentParser(description='Install only the Workshop team skill, with backup and drift-safe rollback')
    parser.add_argument('--destination', default=str(Path.home() / '.codex' / 'skills' / 'team'))
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--rollback')
    args = parser.parse_args()
    try:
        result = rollback(args.rollback, args.dry_run) if args.rollback else install(args.destination, args.dry_run)
        print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('Team skill installation error: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
