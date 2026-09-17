import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / '.devin/skills/team/scripts/invocation.py'
INSTALLER = ROOT / 'scripts/install-team-skill.py'


class TeamSkillTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.brief = self.root / 'brief.json'
        self.payload = {'title': 'Test brief', 'objective': 'Test brief', 'phase': 'execution', 'collaboration_mode': 'owner_only', 'participants': []}
        self.brief.write_text(json.dumps(self.payload))

    def run_script(self, script, *args, success=True):
        result = subprocess.run([sys.executable, str(script), *map(str, args)], text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        return result

    def new(self, *args):
        return self.run_script(HELPER, 'new', '--brief', self.brief, '--state-root', self.root / 'journals', *args)

    def test_new_identity_is_random_and_journal_durable(self):
        first, second = self.new(), self.new()
        self.assertNotEqual(first['request']['idempotency_key'], second['request']['idempotency_key'])
        self.assertNotIn('origin', first['request'])
        journal = self.run_script(HELPER, 'show', '--journal', first['journal'])
        self.assertEqual(journal['request'], first['request'])
        self.assertIsNone(journal['receipt'])
        self.assertEqual(os.stat(first['journal']).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(self.root / 'journals').st_mode & 0o777, 0o700)

    def test_origin_uses_supplied_runtime_id(self):
        first = self.new('--source-task-id', 'test-codex-thread')
        origin = first['request']['origin']
        self.assertEqual(origin['source_task_id'], 'test-codex-thread')
        self.assertEqual(first['request']['idempotency_key'], 'codex-invocation-' + origin['invocation_id'])

    def test_receipt_persists_without_changing_request(self):
        created = self.new()
        receipt_file = self.root / 'receipt.json'
        receipt = {'task_id': 'task_test', 'committed_seq': 1, 'state': 'queued', 'status': 'created'}
        receipt_file.write_text(json.dumps(receipt))
        self.run_script(HELPER, 'receipt', '--journal', created['journal'], '--receipt', receipt_file)
        journal = self.run_script(HELPER, 'show', '--journal', created['journal'])
        self.assertEqual(journal['request'], created['request'])
        self.assertEqual(journal['receipt'], receipt)
        receipt_file.write_text(json.dumps(dict(receipt, task_id='task_other')))
        self.run_script(HELPER, 'receipt', '--journal', created['journal'], '--receipt', receipt_file, success=False)
        self.assertEqual(self.run_script(HELPER, 'show', '--journal', created['journal'])['receipt'], receipt)

    def test_invalid_brief_has_no_side_effects(self):
        self.brief.write_text(json.dumps(dict(self.payload, participants=['kimi'])))
        self.run_script(HELPER, 'new', '--brief', self.brief, '--state-root', self.root / 'journals', success=False)
        self.assertFalse((self.root / 'journals').exists())

    def test_symlink_journal_root_and_journal_rejected(self):
        target = self.root / 'target'
        target.mkdir()
        link = self.root / 'link'
        link.symlink_to(target)
        self.run_script(HELPER, 'new', '--brief', self.brief, '--state-root', link, success=False)
        self.assertEqual(list(target.iterdir()), [])
        created = self.new()
        linked_journal = self.root / 'linked.json'
        linked_journal.symlink_to(created['journal'])
        self.run_script(HELPER, 'show', '--journal', linked_journal, success=False)

    def test_installer_dry_run_backup_preservation_and_rollback(self):
        destination = self.root / 'team'
        self.run_script(INSTALLER, '--destination', destination, '--dry-run')
        self.assertFalse(destination.exists())
        destination.mkdir()
        old = b'original skill\n'
        (destination / 'SKILL.md').write_bytes(old)
        (destination / 'agents').mkdir()
        (destination / 'agents/openai.yaml').write_text('old metadata')
        (destination / 'unrelated.txt').write_text('preserve')
        result = self.run_script(INSTALLER, '--destination', destination)
        backup = Path(result['backup'])
        self.assertEqual((backup / 'SKILL.md').read_bytes(), old)
        self.assertEqual((destination / 'SKILL.md').read_bytes(), (ROOT / '.devin/skills/team/SKILL.md').read_bytes())
        self.assertEqual((destination / 'unrelated.txt').read_text(), 'preserve')
        rolled = self.run_script(INSTALLER, '--rollback', backup)
        self.assertEqual((destination / 'SKILL.md').read_bytes(), old)
        self.assertEqual((destination / 'agents/openai.yaml').read_text(), 'old metadata')
        self.assertEqual(rolled['leftover_new_files'], [str(destination / 'scripts/invocation.py')])

    def test_rollback_supports_earlier_managed_file_set(self):
        destination = self.root / 'team'
        destination.mkdir()
        (destination / 'SKILL.md').write_text('original')
        result = self.run_script(INSTALLER, '--destination', destination)
        manifest_path = Path(result['backup']) / 'install-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['before'].pop('agents/openai.yaml')
        manifest['installed'].pop('agents/openai.yaml')
        manifest_path.write_text(json.dumps(manifest))
        self.run_script(INSTALLER, '--rollback', result['backup'])
        self.assertEqual((destination / 'SKILL.md').read_text(), 'original')

    def test_rollback_refuses_user_edits(self):
        destination = self.root / 'team'
        result = self.run_script(INSTALLER, '--destination', destination)
        (destination / 'SKILL.md').write_text('User changed')
        self.run_script(INSTALLER, '--rollback', result['backup'], success=False)
        self.assertEqual((destination / 'SKILL.md').read_text(), 'User changed')

    def test_installer_rejects_symlink_target(self):
        target = self.root / 'target'
        target.mkdir()
        destination = self.root / 'team'
        destination.symlink_to(target)
        self.run_script(INSTALLER, '--destination', destination, success=False)
        self.assertEqual(list(target.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
