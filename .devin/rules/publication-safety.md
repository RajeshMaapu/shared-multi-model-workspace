---
description: Protect public commits and pushes from credentials and private history
trigger: always_on
---

# Public repository safety

- Apply these checks before EVERY commit and push, including tags and new branches. Never commit credentials, private keys, provider/session tokens, personal paths, raw transcripts, private task briefs, database/runtime state, or unrelated project details. Keep credentials outside the repository and use reviewed placeholders in templates.
- Run `python3 .devin/security/install_hooks.py` in a fresh clone before any commit or push. Do not replace unrelated hooks or change Git configuration. If installation reports a conflict, stop for review. Run `python3 .devin/security/publication_guard.py staged` before committing; installed hooks enforce staged and outgoing-history checks.
- Review the exact staged diff and every outgoing commit, not just the working tree or final tip. Check screenshots, binary artifacts, configuration examples, logs, commit messages, and author metadata manually. Automated patterns and `.gitignore` are safeguards, not proof that all sensitive data is absent.
- Use the cleaned public history. Never merge or push pre-cleanup history, private development branches, backup bundles, or mirror refs into the public repository. Port approved changes onto the clean branch without importing old ancestry; sanitize and re-test them.
- Never use `--no-verify`, disable these hooks, force-add private artifacts, or weaken the guard/allowlist to get a commit or push through. Resolve findings; changes to security policy require explicit user approval.
- `.gitignore` does not remove already-tracked files or historical secrets. Stop publication on suspected exposure, report only paths/categories (never credential values), and require credential revocation/rotation if real credentials were exposed. Any history rewrite or force-push needs explicit approval for the exact refs and action.
- These hooks are local, not GitHub-enforced. Each clone must install them. Keep existing private worktrees and backups private; do not reset, delete, or overwrite them automatically.
