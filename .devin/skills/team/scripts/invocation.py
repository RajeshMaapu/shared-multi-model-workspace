import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import uuid

BRIEF_KEYS = {
    'title', 'objective', 'phase', 'collaboration_mode', 'participants',
    'constraints', 'sources', 'workspace_ref', 'acceptance_criteria',
    'budget_policy_ref', 'channel',
}


def safe_path(value):
    path = Path(os.path.abspath(os.path.expanduser(str(value))))
    for item in [path] + list(path.parents):
        if item.is_symlink():
            raise ValueError('Symlink paths are not permitted')
    return path


def load_json(path):
    path = safe_path(path)
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r', encoding='utf-8') as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise ValueError('Expected a regular file')
        text = handle.read(262145)
        if len(text) > 262144:
            raise ValueError('JSON input exceeds 256 KiB')
        return json.loads(text), text.encode('utf-8')


def validate_brief(brief):
    if not isinstance(brief, dict) or set(brief) - BRIEF_KEYS:
        raise ValueError('Unsupported brief fields')
    for key, limit in [('title', 240), ('objective', 32000)]:
        value = brief.get(key)
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            raise ValueError('Invalid ' + key)
    if brief.get('phase') not in ('execution', 'research_proposal'):
        raise ValueError('Invalid phase')
    mode = brief.get('collaboration_mode')
    if mode not in ('owner_only', 'requested_peers'):
        raise ValueError('Invalid collaboration_mode')
    peers = brief.get('participants', [])
    if not isinstance(peers, list) or any(p not in ('kimi', 'deepseek') for p in peers):
        raise ValueError('Invalid participants')
    if len(set(peers)) != len(peers):
        raise ValueError('Duplicate participants')
    if (mode == 'owner_only' and peers) or (mode == 'requested_peers' and not peers):
        raise ValueError('Participants do not match collaboration mode')
    for key in ('constraints', 'sources', 'acceptance_criteria'):
        if key in brief and (not isinstance(brief[key], list)
                             or not all(isinstance(v, str) for v in brief[key])):
            raise ValueError('Invalid ' + key)
    for key in ('workspace_ref', 'budget_policy_ref', 'channel'):
        if key in brief and (not isinstance(brief[key], str) or not brief[key].strip()):
            raise ValueError('Invalid ' + key)
    return dict(brief, participants=peers)


def validate_request(request):
    if not isinstance(request, dict) or request.get('schema_version') != 2:
        raise ValueError('Invalid persisted request')
    if set(request) - BRIEF_KEYS - {'schema_version', 'idempotency_key', 'origin'}:
        raise ValueError('Unsupported persisted request fields')
    validate_brief({k: v for k, v in request.items() if k in BRIEF_KEYS})
    key = request.get('idempotency_key', '')
    prefix = 'codex-invocation-'
    if not isinstance(key, str) or not key.startswith(prefix):
        raise ValueError('Invalid invocation key')
    identity = key[len(prefix):]
    if str(uuid.UUID(identity)) != identity:
        raise ValueError('Invalid invocation identifier')
    origin = request.get('origin')
    if origin is not None:
        if not isinstance(origin, dict) or set(origin) != {'source_task_id', 'invocation_id'}:
            raise ValueError('Invalid origin binding')
        if origin['invocation_id'] != identity or not isinstance(origin['source_task_id'], str) or not origin['source_task_id'].strip():
            raise ValueError('Invalid origin binding')


# Cursor spaces: the receipt's `committed_seq` is an ingress/outbox sequence.
# `workshop_read_messages`/`workshop_wait_for_events` `after_seq` are task
# MESSAGE seqs (start at 0, or the last message seq observed) — never pass a
# receipt committed_seq as a message cursor.
def validate_receipt(receipt):
    if not isinstance(receipt, dict):
        raise ValueError('Invalid receipt')
    task_id = receipt.get('task_id')
    if not isinstance(task_id, str) or not re.fullmatch(r'task_[A-Za-z0-9_-]{1,120}', task_id):
        raise ValueError('Invalid receipt task ID')
    if type(receipt.get('committed_seq')) is not int or receipt['committed_seq'] < 0:
        raise ValueError('Invalid receipt sequence')
    for field in ('state', 'status'):
        if not isinstance(receipt.get(field), str) or not receipt[field]:
            raise ValueError('Invalid receipt ' + field)


def load_text(path):
    path = safe_path(path)
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r', encoding='utf-8') as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise ValueError('Expected a regular file')
        text = handle.read(32769)
    if not isinstance(text, str) or not text.strip() or len(text) > 32768:
        raise ValueError('Invalid follow-up body')
    return text


def validate_append(entry):
    if not isinstance(entry, dict) or set(entry) != {'idempotency_key', 'request'}:
        raise ValueError('Invalid append entry')
    key = entry['idempotency_key']
    prefix = 'codex-append-'
    if not isinstance(key, str) or not key.startswith(prefix) or str(uuid.UUID(key[len(prefix):])) != key[len(prefix):]:
        raise ValueError('Invalid append key')
    request = entry['request']
    if not isinstance(request, dict) or set(request) != {'task_id', 'body', 'idempotency_key'}:
        raise ValueError('Invalid append request')
    if request['idempotency_key'] != key:
        raise ValueError('Append request key mismatch')
    if not isinstance(request['body'], str) or not request['body'].strip() or len(request['body']) > 32768:
        raise ValueError('Invalid append body')
    if not isinstance(request['task_id'], str) or not re.fullmatch(r'task_[A-Za-z0-9_-]{1,120}', request['task_id']):
        raise ValueError('Invalid append task ID')


def load_journal(path):
    value, raw = load_json(path)
    if not isinstance(value, dict) or value.get('version') != 1:
        raise ValueError('Unsupported journal version')
    validate_request(value.get('request'))
    if value.get('receipt') is not None:
        validate_receipt(value['receipt'])
    appends = value.get('appends', [])
    if not isinstance(appends, list):
        raise ValueError('Invalid appends')
    for entry in appends:
        validate_append(entry)
    return value, raw


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode('utf-8')


def sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def new_invocation(args):
    brief, _ = load_json(args.brief)
    request = validate_brief(brief)
    identity = str(uuid.uuid4())
    request.update(schema_version=2, idempotency_key='codex-invocation-' + identity)
    if args.source_task_id is not None:
        if not args.source_task_id.strip():
            raise ValueError('source-task-id must be an actual nonempty runtime ID')
        request['origin'] = {'source_task_id': args.source_task_id, 'invocation_id': identity}
    root = safe_path(args.state_root or (Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'workshop-invocations'))
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not root.is_dir():
        raise ValueError('Journal root must be a directory')
    path = root / (identity + '.json')
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(encoded({'version': 1, 'request': request, 'receipt': None}))
        handle.flush()
        os.fsync(handle.fileno())
    sync_directory(root)
    return {'journal': str(path), 'request': request}


def rewrite_journal(journal_path, update):
    """Locked, hash-checked atomic journal rewrite. update(journal) returns
    the payload this command reports."""
    path = safe_path(journal_path)
    lock_path = path.with_name(path.name + '.lock')
    lock_fd = os.open(str(lock_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    temp = None
    try:
        journal, original = load_journal(path)
        result = update(journal)
        fd, temp = tempfile.mkstemp(prefix='.journal-', dir=str(path.parent))
        with os.fdopen(fd, 'wb') as handle:
            handle.write(encoded(journal))
            handle.flush()
            os.fsync(handle.fileno())
        _, current = load_journal(path)
        if hashlib.sha256(current).digest() != hashlib.sha256(original).digest():
            raise ValueError('Journal changed; refusing overwrite')
        os.replace(temp, path)
        temp = None
        sync_directory(path.parent)
        return result
    finally:
        os.close(lock_fd)
        lock_path.unlink()
        if temp is not None:
            Path(temp).unlink()


def save_receipt(args):
    receipt, _ = load_json(args.receipt)
    validate_receipt(receipt)

    def update(journal):
        previous = journal.get('receipt')
        if previous and previous['task_id'] != receipt['task_id']:
            raise ValueError('Receipt conflicts with the recorded task')
        journal['receipt'] = receipt
        return {'journal': args.journal, 'task_id': receipt['task_id'], 'saved': True}

    return rewrite_journal(args.journal, update)


def append_followup(args):
    """Persist a follow-up request with a fresh codex-append-<uuid> key so an
    uncertain workshop_post_message can be retried verbatim."""
    body = load_text(args.body)

    def update(journal):
        receipt = journal.get('receipt')
        if not receipt:
            raise ValueError('Journal has no receipt; resolve the task first')
        key = 'codex-append-' + str(uuid.uuid4())
        request = {'task_id': receipt['task_id'], 'body': body,
                   'idempotency_key': key}
        journal.setdefault('appends', [])
        journal['appends'].append({'idempotency_key': key, 'request': request})
        return {'journal': args.journal, 'request': request}

    return rewrite_journal(args.journal, update)


def main():
    parser = argparse.ArgumentParser(description='Persist scoped Workshop invocations without dispatching work')
    commands = parser.add_subparsers(dest='command', required=True)
    new = commands.add_parser('new')
    new.add_argument('--brief', required=True)
    new.add_argument('--source-task-id')
    new.add_argument('--state-root')
    show = commands.add_parser('show')
    show.add_argument('--journal', required=True)
    receipt = commands.add_parser('receipt')
    receipt.add_argument('--journal', required=True)
    receipt.add_argument('--receipt', required=True)
    append = commands.add_parser('append')
    append.add_argument('--journal', required=True)
    append.add_argument('--body', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'new':
            result = new_invocation(args)
        elif args.command == 'show':
            result, _ = load_journal(args.journal)
        elif args.command == 'append':
            result = append_followup(args)
        else:
            result = save_receipt(args)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, TypeError) as error:
        print('Workshop invocation error: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
