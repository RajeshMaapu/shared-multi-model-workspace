# Workshop development

## Checkout and scope

This public snapshot includes the community implementation and native-generation repair. Original development branches and private handoff notes are maintained separately. Preserve the original main checkout and the clean-start review worktree. Do not replace the installed app, change its MCP configuration, restart the production relay, migrate live Workshop data, merge, or deploy without separate user approval.

The approved behavior is `docs/review/WORKSHOP_COMMUNITY_DESIGN.md`; it supersedes mandatory all-engineer research. Fusion's native SWE-2 sidekick is an approved exception to prohibiting additional Workshop-spawned agents.

## Verification

- Swift: `swift test`. Live tests opt in via `WORKSHOP_LIVE=1`; do not treat skipped tests as qualification.
- Web and desktop unit tests: `node --test Web/tests/*.test.mjs Desktop/tests/*.test.mjs`.
- Real-daemon integration with fake adapters: `WORKSHOP_TEST_SOCKET=<isolated-runtime>/service.sock node --test Web/tests/integration.test.mjs`.
- Skill tooling: `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s Tests/SkillTests -v`.
- Codex discovery: `node scripts/verify-team-discovery.mjs "$PWD"`.
- Diff hygiene: `git diff --check`.
- Packaging: `npm run package:desktop`. Requires built Swift daemon/MCP binaries and current web-validation evidence. Creates a unique preview bundle, never replaces an installed app.

## Isolation and evidence

Always supply both `WORKSHOP_HOME` and `WORKSHOP_RUNTIME_DIR` when launching a development daemon, with `WORKSHOP_ADAPTERS=fake` unless an explicit live qualification is being conducted. Never default tests to installed runtime paths. Node gateway requires `--socket <absolute-path>` and listens on loopback only.

New v2 tasks deliberately block native adapter turns until `supportsIsolatedWorkspaceTurns` is qualified. Do not set this capability merely to make a test or demonstration pass. Shared workspace identity is implemented; native single-writer process isolation and safe transfer are not.

Do not change `Web/renderer` without new computer-use validation. `Web/web-validation.json` binds the approved renderer file hashes; packaging checks that manifest against `.build/web-qa/evidence.json`. Existing evidence used Aside on an isolated fake-adapter daemon, not Astra or live engineers. Launch `/Applications/Aside.app` before `aside repl` if the CLI returns `fetch failed` because the app is not running.

This Mac has a 30-day npm release-age guard and `ignore-scripts=true`. Keep those safeguards. Electron 42.9.1 and packager 20.3.0 are pinned. The user approved a one-time execution of the inspected Electron installer for this checkout; that does not authorize enabling scripts globally. The dev-only XML parser advisory remains recorded in the status report.

## Codex skill

Versioned source: `.devin/skills/team/`. The user explicitly requested installation into the existing `~/.codex/skills/team`, not a competing skill. `scripts/install-team-skill.py` installs only managed skill files and saves drift-safe rollback backups outside the skills discovery tree. Do not edit prompt policy through delegated authoring or put the entry-point skill into engineer runtime profiles.

## Public commits and pushes

Follow `.devin/rules/publication-safety.md` for every commit and push. Install local guards with `python3 .devin/security/install_hooks.py`; review staged content and outgoing history, never bypass findings, and never reintroduce pre-cleanup/private ancestry. Guard tests: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/SecurityTests -v`.

## Clean-history transfers and installed-runtime connection checks

This is the canonical target for approved Workshop changes. Keep old development checkouts as source evidence only. Transfer reviewed code with scoped patches or fresh commits on a feature branch based on this repository's cleaned history; never merge old branches or import their ancestry. Preserve other authors' work. A transfer does not authorize publication beyond the user's stated scope.

After every installed app/backend/MCP bridge replacement, use a supported refresh of the actual configured Codex connection and verify a fresh read-only tool call plus its current callable schema from the originating session before claiming end-to-end completion or submitting a saved task. Source-only pushes do not trigger this step. Installed binary versions, process age, advertised schemas alone and separate fresh CLI sessions are insufficient evidence. If refresh is unavailable, record installed/connection unverified and the required supported user action; preserve idempotency records. Do not kill Codex or unrelated processes, repeat unchanged failed proxies, or bypass restrictions. See [desktop update status](docs/WORKSHOP_DESKTOP_UPDATES.md) and [browser validation procedure](docs/review/WORKSHOP_BROWSER_VALIDATION.md).
