import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
GUARD_SOURCE = REPO_ROOT / '.devin' / 'security' / 'publication_guard.py'
POLICY_SOURCE = REPO_ROOT / '.devin' / 'security' / 'policy.json'
INSTALLER = REPO_ROOT / '.devin' / 'security' / 'install_hooks.py'

GIT_ENV = {
    'GIT_AUTHOR_NAME': 'Guard Test',
    'GIT_AUTHOR_EMAIL': 'guard-test@example.invalid',
    'GIT_COMMITTER_NAME': 'Guard Test',
    'GIT_COMMITTER_EMAIL': 'guard-test@example.invalid',
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_GLOBAL': '/dev/null',
    'HOME': os.environ.get('HOME', '/'),
}

ZERO = '0' * 40


def synthetic(prefix, body):
    return prefix + body


def run_git(repo, *args, input=None, check=True):
    env = dict(os.environ)
    env.update(GIT_ENV)
    result = subprocess.run(['git', '-C', str(repo), *args], input=input,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if check and result.returncode != 0:
        raise AssertionError('git %s failed: %s' % (args[0], result.stderr.decode('utf-8', 'replace')))
    return result


class GuardCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()
        run_git(self.repo, 'init', '-b', 'main')
        self.tool = Path(self.tmp.name) / 'tool'
        self.tool.mkdir()
        shutil.copy(GUARD_SOURCE, self.tool / 'publication_guard.py')
        self.write_policy()

    def write_policy(self, **overrides):
        policy = {
            'version': 1,
            'clean_base': ZERO,
            'blocked_commits': [],
            'max_blob_bytes': 8388608,
            'fixture_literals': {'Tests/ServiceTests/Phase4ServiceTests.swift': [
                'sk-' + 'abc123def456ghi789', 'sk-' + 'testSECRETvalue999']},
        }
        policy.update(overrides)
        (self.tool / 'policy.json').write_text(json.dumps(policy))
        return policy

    def guard(self, *args, input=None):
        return subprocess.run([sys.executable, str(self.tool / 'publication_guard.py'), *args],
                              input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              cwd=self.repo, env=dict(os.environ, **GIT_ENV))

    def write(self, relative, data):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(data, str):
            data = data.encode()
        path.write_bytes(data)
        return path

    def stage(self, *paths):
        run_git(self.repo, 'add', '-f', '--', *paths)

    def commit(self, message='fixture'):
        run_git(self.repo, 'commit', '-m', message)
        return run_git(self.repo, 'rev-parse', 'HEAD').stdout.decode().strip()

    def commit_file(self, relative, data, message='fixture'):
        self.write(relative, data)
        self.stage(relative)
        return self.commit(message)

    def assert_blocked(self, result):
        self.assertEqual(result.returncode, 1, result.stderr.decode())
        self.assertIn(b'Publication blocked', result.stderr)

    def assert_passed(self, result):
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertIn(b'passed', result.stderr)


class StagedScanTests(GuardCase):
    def test_forced_env_rejected_without_value_leak(self):
        secret = synthetic('ghp_', 'A' * 36)
        self.write('.env', 'TOKEN=' + secret)
        self.stage('.env')
        result = self.guard('staged')
        self.assert_blocked(result)
        self.assertIn(b'.env', result.stderr)
        self.assertIn(b'private file path', result.stderr)
        self.assertNotIn(secret.encode(), result.stderr)

    def test_staged_secret_rejected_after_worktree_cleaned(self):
        secret = synthetic('ghp_', 'B' * 36)
        self.write('Sources/app.swift', 'let t = "' + secret + '"')
        self.stage('Sources/app.swift')
        self.write('Sources/app.swift', 'let t = "clean"')
        result = self.guard('staged')
        self.assert_blocked(result)
        self.assertIn(b'GitHub token', result.stderr)

    def test_unstaged_secret_not_scanned(self):
        self.write('Sources/app.swift', 'let t = "clean"')
        self.stage('Sources/app.swift')
        self.write('Sources/app.swift', 'let t = "' + synthetic('ghp_', 'C' * 36) + '"')
        self.assert_passed(self.guard('staged'))

    def test_deleted_secret_file_passes(self):
        self.commit_file('.env', 'TOKEN=' + synthetic('ghp_', 'D' * 36))
        run_git(self.repo, 'rm', '-q', '.env')
        self.assert_passed(self.guard('staged'))

    def test_fixture_literals_only_in_declared_path(self):
        allowed_key = 'sk-' + 'abc123def456ghi789'
        fixture_path = 'Tests/ServiceTests/Phase4ServiceTests.swift'
        self.write(fixture_path, 'let k = "' + allowed_key + '"')
        self.stage(fixture_path)
        self.assert_passed(self.guard('staged'))
        run_git(self.repo, 'rm', '-q', '--cached', fixture_path)
        self.write('Sources/other.swift', 'let k = "' + allowed_key + '"')
        self.stage('Sources/other.swift')
        result = self.guard('staged')
        self.assert_blocked(result)
        self.assertIn(b'provider key', result.stderr)

    def test_new_key_in_fixture_path_rejected(self):
        fixture_path = 'Tests/ServiceTests/Phase4ServiceTests.swift'
        self.write(fixture_path, 'let k = "' + synthetic('sk-', 'E' * 20) + '"')
        self.stage(fixture_path)
        self.assert_blocked(self.guard('staged'))

    def test_env_example_placeholders_allowed(self):
        self.write('.env.example', 'API_KEY=your-api-key-here\nTOKEN=example-token-value\n')
        self.stage('.env.example')
        self.assert_passed(self.guard('staged'))

    def test_template_with_real_token_rejected(self):
        self.write('Configuration/engineers.template.json',
                   '{"key": "' + synthetic('ghp_', 'F' * 36) + '"}')
        self.stage('Configuration/engineers.template.json')
        self.assert_blocked(self.guard('staged'))

    def test_private_key_jwt_url_assignment_patterns(self):
        cases = [
            ('private key', '-----BEGIN RSA ' + 'PRIVATE KEY-----\nabc\n-----END RSA ' + 'PRIVATE KEY-----'),
            ('JWT', 'header ' + synthetic('eyJ', 'a' * 20) + '.' + 'b' * 15 + '.' + 'c' * 15),
            ('credential URL', 'fetch "https://user' + ':' + 'passw0rdvalue@example.com/x"'),
            ('credential assignment', 'config = "api_key": "' + 'g' * 20 + '"'),
            ('bearer credential', 'Authorization: Bearer ' + 'h' * 30),
        ]
        for index, (category, body) in enumerate(cases):
            with self.subTest(category=category):
                name = 'src/file%d.txt' % index
                self.write(name, body)
                self.stage(name)
                result = self.guard('staged')
                self.assert_blocked(result)
                self.assertIn(category.encode(), result.stderr)
                self.assertNotIn(body.splitlines()[0].encode()[:24], result.stderr)
                run_git(self.repo, 'rm', '-q', '--cached', '--', name)
                os.unlink(self.repo / name)

    def test_placeholder_assignment_passes(self):
        self.write('src/config.txt', 'api_key = "placeholder-value-12345"\npassword: "your-password-here"')
        self.stage('src/config.txt')
        self.assert_passed(self.guard('staged'))

    def test_private_task_identifier_in_docs_rejected(self):
        task_id = 'task_' + 'a1b2c3d4' + '-1234-4abc-9def-' + 'f' * 12
        self.write('docs/notes.md', 'See ' + task_id + ' for details.')
        self.stage('docs/notes.md')
        result = self.guard('staged')
        self.assert_blocked(result)
        self.assertIn(b'private task identifier', result.stderr)

    def test_private_paths_rejected(self):
        for path in ['docs/evidence/phase9/transcripts/turn.json',
                     'db/workshop.sqlite',
                     'runtime/user.token',
                     'nested/credentials.json',
                     'workshop.sqlite-wal',
                     'backup.dump',
                     'capture.har']:
            with self.subTest(path=path):
                self.write(path, 'data')
                self.stage(path)
                result = self.guard('staged')
                self.assert_blocked(result)
                self.assertIn(b'private file path', result.stderr)
                self.assertIn(path.encode(), result.stderr)
                run_git(self.repo, 'rm', '-q', '--cached', '--', path)
                os.unlink(self.repo / path)

    def test_submodule_mode_rejected(self):
        run_git(self.repo, 'update-index', '--add', '--cacheinfo', '160000,' + 'a' * 40 + ',vendor/sub')
        result = self.guard('staged')
        self.assert_blocked(result)
        self.assertIn(b'unsupported file mode', result.stderr)

    def test_oversize_blob_rejected(self):
        self.write_policy(max_blob_bytes=16)
        self.write('big.bin', 'x' * 64)
        self.stage('big.bin')
        result = self.guard('staged')
        self.assert_blocked(result)
        self.assertIn(b'exceeds scan limit', result.stderr)

    def test_policy_file_allows_only_declared_fixture_literals(self):
        policy_path = '.devin/security/policy.json'
        key1 = 'sk-' + 'abc123def456ghi789'
        key2 = 'sk-' + 'testSECRETvalue999'
        self.write(policy_path, json.dumps({'fixture_literals': {
            'Tests/ServiceTests/Phase4ServiceTests.swift': [key1, key2]}}))
        self.stage(policy_path)
        self.assert_passed(self.guard('staged'))
        self.write(policy_path, json.dumps({'fixture_literals': {
            'Tests/ServiceTests/Phase4ServiceTests.swift': [key1, key2],
            'other': [synthetic('sk-', 'W' * 20)]}}))
        self.stage(policy_path)
        result = self.guard('staged')
        self.assert_blocked(result)
        self.assertIn(b'provider key', result.stderr)

    def test_missing_policy_blocks(self):
        (self.tool / 'policy.json').unlink()
        self.write('ok.txt', 'fine')
        self.stage('ok.txt')
        result = self.guard('staged')
        self.assert_blocked(result)
        self.assertIn(b'could not complete', result.stderr)


class PrePushTests(GuardCase):
    def push_input(self, local_ref, local_sha, remote_ref='refs/heads/main', remote_sha=ZERO):
        return ('%s %s %s %s\n' % (local_ref, local_sha, remote_ref, remote_sha)).encode()

    def test_secret_in_earlier_commit_rejected(self):
        self.commit_file('src/app.txt', 'tok=' + synthetic('ghp_', 'G' * 36))
        self.commit_file('src/app.txt', 'clean')
        tip = run_git(self.repo, 'rev-parse', 'HEAD').stdout.decode().strip()
        result = self.guard('pre-push', input=self.push_input('refs/heads/main', tip))
        self.assert_blocked(result)

    def test_explicit_tip_checked_not_head(self):
        good = self.commit_file('src/good.txt', 'clean')
        self.commit_file('src/bad.txt', 'tok=' + synthetic('ghp_', 'H' * 36))
        result = self.guard('pre-push', input=self.push_input('refs/heads/side', good))
        self.assert_passed(result)

    def test_new_branch_remote_zero_supported(self):
        tip = self.commit_file('src/new.txt', 'clean')
        result = self.guard('pre-push', input=self.push_input('refs/heads/feature', tip, remote_sha=ZERO))
        self.assert_passed(result)

    def test_deleted_ref_skipped(self):
        self.commit_file('src/x.txt', 'clean')
        result = self.guard('pre-push', input=self.push_input('refs/heads/old', ZERO))
        self.assert_passed(result)

    def test_malformed_input_rejected(self):
        result = self.guard('pre-push', input=b'not-a-valid-line\n')
        self.assertEqual(result.returncode, 1)

    def test_blocked_ancestor_fails_regardless_of_base(self):
        first = self.commit_file('src/a.txt', 'clean')
        second = self.commit_file('src/b.txt', 'also clean')
        self.write_policy(clean_base=second, blocked_commits=[first])
        result = self.guard('pre-push', input=self.push_input('refs/heads/main', second))
        self.assert_blocked(result)
        self.assertIn(b'ancestry', result.stderr)

    def test_clean_push_passes(self):
        tip = self.commit_file('src/clean.txt', 'hello')
        result = self.guard('pre-push', input=self.push_input('refs/heads/main', tip))
        self.assert_passed(result)

    def test_annotated_tag_resolved(self):
        self.commit_file('src/tag.txt', 'clean')
        run_git(self.repo, 'tag', '-a', 'v9', '-m', 'release')
        tag = run_git(self.repo, 'rev-parse', 'v9').stdout.decode().strip()
        result = self.guard('pre-push', input=self.push_input('refs/tags/v9', tag, remote_ref='refs/tags/v9'))
        self.assert_passed(result)

    def test_annotated_tag_with_secret_commit_rejected(self):
        self.commit_file('src/secret.txt', 'tok=' + synthetic('ghp_', 'I' * 36))
        run_git(self.repo, 'tag', '-a', 'vbad', '-m', 'release')
        tag = run_git(self.repo, 'rev-parse', 'vbad').stdout.decode().strip()
        result = self.guard('pre-push', input=self.push_input('refs/tags/vbad', tag, remote_ref='refs/tags/vbad'))
        self.assert_blocked(result)

    def test_tag_annotation_secret_rejected(self):
        self.commit_file('src/tag2.txt', 'clean')
        secret = synthetic('ghp_', 'T' * 36)
        run_git(self.repo, 'tag', '-a', 'vsec', '-m', 'release ' + secret)
        tag = run_git(self.repo, 'rev-parse', 'vsec').stdout.decode().strip()
        result = self.guard('pre-push', input=self.push_input('refs/tags/vsec', tag, remote_ref='refs/tags/vsec'))
        self.assert_blocked(result)
        self.assertNotIn(secret.encode(), result.stderr)

    def test_nested_tag_annotation_scanned(self):
        self.commit_file('src/tag3.txt', 'clean')
        secret = synthetic('ghp_', 'U' * 36)
        run_git(self.repo, 'tag', '-a', 'vinner', '-m', 'inner ' + secret)
        inner = run_git(self.repo, 'rev-parse', 'vinner').stdout.decode().strip()
        run_git(self.repo, 'tag', '-a', 'vouter', '-m', 'outer clean', inner)
        outer = run_git(self.repo, 'rev-parse', 'vouter').stdout.decode().strip()
        result = self.guard('pre-push', input=self.push_input('refs/tags/vouter', outer, remote_ref='refs/tags/vouter'))
        self.assert_blocked(result)
        self.assertNotIn(secret.encode(), result.stderr)

    def test_commit_message_secret_rejected(self):
        secret = synthetic('ghp_', 'V' * 36)
        self.write('src/msg.txt', 'clean')
        self.stage('src/msg.txt')
        tip = self.commit('note ' + secret)
        result = self.guard('pre-push', input=self.push_input('refs/heads/main', tip))
        self.assert_blocked(result)
        self.assertNotIn(secret.encode(), result.stderr)

    def test_commit_message_task_id_rejected(self):
        task_id = 'task_' + 'b2c3d4e5' + '-1234-4abc-9def-' + 'e' * 12
        self.write('src/msg2.txt', 'clean')
        self.stage('src/msg2.txt')
        tip = self.commit('work on ' + task_id)
        result = self.guard('pre-push', input=self.push_input('refs/heads/main', tip))
        self.assert_blocked(result)
        self.assertIn(b'private task identifier', result.stderr)

    def test_shallow_clone_fails_closed(self):
        self.commit_file('src/s1.txt', 'one')
        self.commit_file('src/s2.txt', 'two')
        shallow = Path(self.tmp.name) / 'shallow'
        run_git(Path(self.tmp.name), 'clone', '--depth=1', 'file://' + str(self.repo), str(shallow))
        tip = run_git(shallow, 'rev-parse', 'HEAD').stdout.decode().strip()
        result = subprocess.run([sys.executable, str(self.tool / 'publication_guard.py'), 'pre-push'],
                                input=self.push_input('refs/heads/main', tip),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                cwd=shallow, env=dict(os.environ, **GIT_ENV))
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'Publication blocked', result.stderr)

    def test_replacement_ref_cannot_hide_blocked_commit(self):
        bad = self.commit_file('src/rep.txt', 'clean a')
        tree = run_git(self.repo, 'rev-parse', 'HEAD^{tree}').stdout.decode().strip()
        env = dict(os.environ, **GIT_ENV)
        safe = subprocess.run(['git', '-C', str(self.repo), 'commit-tree', tree, '-m', 'safe'],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, check=True).stdout.decode().strip()
        run_git(self.repo, 'replace', bad, safe)
        self.write_policy(blocked_commits=[bad])
        result = self.guard('pre-push', input=self.push_input('refs/heads/main', bad))
        self.assert_blocked(result)

    def test_git_unavailable_fails_closed_without_traceback(self):
        empty_bin = Path(self.tmp.name) / 'empty-bin'
        empty_bin.mkdir()
        env = dict(os.environ, **GIT_ENV)
        env['PATH'] = str(empty_bin)
        result = subprocess.run([sys.executable, str(self.tool / 'publication_guard.py'), 'staged'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                cwd=self.repo, env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'Publication blocked', result.stderr)
        self.assertNotIn(b'Traceback', result.stderr)


class InstallerTests(GuardCase):
    def hooks_dir(self, repo):
        return Path(run_git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir').stdout.decode().strip()) / 'hooks'

    def install(self, repo=None, env_extra=None):
        env = dict(os.environ)
        env.update(GIT_ENV)
        if env_extra:
            env.update(env_extra)
        return subprocess.run([sys.executable, str(INSTALLER), '--repo', str(repo or self.repo)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

    def test_install_then_idempotent(self):
        first = self.install()
        self.assertEqual(first.returncode, 0, first.stderr.decode())
        hooks = self.hooks_dir(self.repo)
        for name in ['pre-commit', 'pre-merge-commit', 'pre-push']:
            self.assertTrue(os.access(hooks / name, os.X_OK), name)
        self.assertTrue((hooks / 'workshop-publication' / 'publication_guard.py').is_file())
        self.assertTrue((hooks / 'workshop-publication' / 'policy.json').is_file())
        second = self.install()
        self.assertEqual(second.returncode, 0, second.stderr.decode())

    def test_hooks_path_config_refused(self):
        env = {
            'GIT_CONFIG_COUNT': '1',
            'GIT_CONFIG_KEY_0': 'core.hooksPath',
            'GIT_CONFIG_VALUE_0': '/tmp/somewhere',
        }
        result = self.install(env_extra=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'core.hooksPath', result.stderr)
        self.assertFalse((self.hooks_dir(self.repo) / 'pre-commit').exists())

    def test_conflicting_hook_installs_nothing(self):
        hooks = self.hooks_dir(self.repo)
        hooks.mkdir(parents=True, exist_ok=True)
        existing = hooks / 'pre-commit'
        existing.write_text('#!/bin/sh\necho user hook\n')
        before = existing.read_bytes()
        result = self.install()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'pre-commit', result.stderr)
        self.assertEqual(existing.read_bytes(), before)
        self.assertFalse((hooks / 'pre-push').exists())
        self.assertFalse((hooks / 'workshop-publication').exists())

    def test_symlink_destination_refused(self):
        hooks = self.hooks_dir(self.repo)
        hooks.mkdir(parents=True, exist_ok=True)
        target = Path(self.tmp.name) / 'elsewhere'
        target.mkdir()
        (target / 'pre-commit').write_text('#!/bin/sh\nexit 0\n')
        os.symlink(target / 'pre-commit', hooks / 'pre-commit')
        result = self.install()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b'symlink', result.stderr.lower())

    def test_installed_pre_commit_blocks_and_allows(self):
        self.assertEqual(self.install().returncode, 0)
        self.write('.env', 'TOKEN=' + synthetic('ghp_', 'J' * 36))
        self.stage('.env')
        bad = run_git(self.repo, 'commit', '-m', 'bad', check=False)
        self.assertNotEqual(bad.returncode, 0)
        run_git(self.repo, 'reset', '-q')
        os.unlink(self.repo / '.env')
        self.commit_file('src/ok.txt', 'clean')

    def test_installed_pre_push_wrapper_passes_stdin(self):
        tip = self.commit_file('src/x.txt', 'clean')
        secret = synthetic('ghp_', 'K' * 36)
        self.commit_file('.env', 'TOKEN=' + secret)
        tip2 = run_git(self.repo, 'rev-parse', 'HEAD').stdout.decode().strip()
        run_git(self.repo, 'branch', 'clean-tip', tip)
        self.assertEqual(self.install().returncode, 0)
        hooks = self.hooks_dir(self.repo)
        line = ('refs/heads/clean-tip %s refs/heads/clean-tip %s\n' % (tip, ZERO)).encode()
        result = subprocess.run([str(hooks / 'pre-push'), 'origin', 'https://example.invalid/x'],
                                input=line, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                cwd=self.repo, env=dict(os.environ, **GIT_ENV))
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        line2 = ('refs/heads/main %s refs/heads/main %s\n' % (tip2, ZERO)).encode()
        result2 = subprocess.run([str(hooks / 'pre-push'), 'origin', 'https://example.invalid/x'],
                                 input=line2, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 cwd=self.repo, env=dict(os.environ, **GIT_ENV))
        self.assertEqual(result2.returncode, 1)
        self.assertNotIn(secret.encode(), result2.stderr)

    def test_linked_worktree_uses_copied_runtime(self):
        self.assertEqual(self.install().returncode, 0)
        linked = Path(self.tmp.name) / 'linked'
        run_git(self.repo, 'worktree', 'add', str(linked), '-b', 'linked-work')
        hooks = self.hooks_dir(self.repo)
        self.assertTrue((hooks / 'workshop-publication' / 'publication_guard.py').is_file())
        self.write('.env', 'TOKEN=' + synthetic('ghp_', 'L' * 36))
        self.stage('.env')
        (linked / '.env').write_text('TOKEN=' + synthetic('ghp_', 'M' * 36))
        run_git(linked, 'add', '-f', '.env')
        bad = run_git(linked, 'commit', '-m', 'bad', check=False)
        self.assertNotEqual(bad.returncode, 0)


if __name__ == '__main__':
    unittest.main()
