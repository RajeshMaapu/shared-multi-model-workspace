# Workshop community implementation milestone

Status: partial implementation, not production qualification. Recorded September 16, 2026.

This is a historical community milestone. See [native generation repair](NATIVE_GENERATION_REPAIR.md) for the later writer-isolation and authentication changes; the remaining limitations below are not a production-readiness claim.

## Source and runnable deliverables

- Historical development checkout: `<development-checkout>`.
- Branch: `devin/workshop-community`, based on `66c1d28` (preserves `94baa5c` clean-profile work).
- At this milestone the changes were uncommitted. This public snapshot includes that source; publication does not install, deploy, restart services, or migrate live data.
- Current Electron bundle: `dist/desktop-preview-1789572817370/Workshop Preview-darwin-arm64/Workshop Preview.app`.
- Electron runtime 42.9.1; packager 20.3.0. Separate preview bundle ID and user-data directory; installed Workshop URL registration unchanged.
- Current isolated development home/runtime: `<isolated-runtime>`; fake adapters only.
- Current web preview: `http://127.0.0.1:4177`.

To launch a separately built preview, set `WORKSHOP_PREVIEW_APP` to its bundle path and `WORKSHOP_RUNTIME_DIR` to the runtime directory of an isolated fake-adapter daemon:

```sh
"$WORKSHOP_PREVIEW_APP/Contents/MacOS/Workshop Preview" --workshop-socket "$WORKSHOP_RUNTIME_DIR/service.sock"
```

The preview requires an explicit socket. It does not automatically start the installed daemon or migrate its data. Quitting the UI does not stop the separately running daemon. The earlier test instance at port 4176 remains separate from the latest instance.

## Requirement status

| Requirement | Status | Demonstrated / remaining |
|---|---|---|
| Durable task creation and retries | Implemented; synthetic integration verified | Schema-v2 contract, atomic accepted brief/origin metadata, principal-aware key conflict, retries returning one task, distinct invocations with identical wording. Legacy hashes retained. |
| Codex origin and follow-ups | Partial | Origin tuple persisted and exposed; real MCP follow-up appends tested using fixture origin IDs. Fresh Codex `$team preview only` loaded installed skill. No actual live-model submission/automatic callback qualification; acknowledgment cursor has no public ACK integration. |
| Owner-only / requested peers | Initial routing implemented | Default Fusion-only; requested Kimi/DeepSeek membership and initial wakeups tested. No fallback pretending an unavailable Fusion accepted delivery. Existing research/publication, timeout, unavailable-peer decision and completion rules still need full final-design reconciliation. |
| Shared task worktree | Implemented and unit-tested | Registered repository reference reaches service-owned workspace record and adapter binding/context. Same-task participants share a path; tasks have distinct paths. Invalid refs, branch conflicts, symlinks and mismatched existing directories fail without deleting dirty work. |
| Enforced single writer / handover | Not implemented / not qualified | Existing native process-group setup and cancel acknowledgment are insufficient proof of process-tree quiescence. New v2 native turns and community-task reassignment are conservatively blocked. Synthetic adapters are the only currently qualified v2 test route. Do not enable the capability flag to bypass missing enforcement. |
| Shared account capacity | Not implemented | UI truthfully shows existing per-engineer snapshots and unknowns. Normalized shared provider/account pools, current telemetry, reservations, per-pool thresholds and safe transfer remain open. No new numeric thresholds approved. |
| Clean native profiles | Inherited implementation; live qualification pending | Clean-v2 isolation/sandbox tests pass. Native effective instruction loading, auth/session canaries and retained native capabilities not newly qualified. Existing Fusion runtime selector was not changed to the requested relay-backed model. |
| Astra computer operator | Not implemented | Sidebar explicitly says Not connected. Browser QA used Aside, not a production Astra bridge. Operator sessions, effort routing, permission handling and serialized desktop queue remain open. |
| Web-first renderer | Implemented and browser-tested | Approved layout/assets, actual persisted tasks/replies, all five tabs, search, forms, draft retention, dialog and keyboard checks at 1586x992 and 980x680. Fake output is visibly labeled. |
| Electron shell | Preview implemented; native smoke passed | Same renderer, sandboxed/context-isolated preload allowlist, sender checks, denied navigation/permissions, loopback-independent UDS main client, original icon, isolated packaging. Native menus exist but full shortcuts/deep-link/notifications/permissions/background-helper/reconnect/VoiceOver coverage remains open. |
| Codex team skill | Versioned and installed; discovery/dry-run verified | Existing skill extended; random persisted invocation journals, new policy, backup/rollback helper. Fresh app-server discovery and explicit `$team` preview invocation pass. Installed production bridge was not upgraded/repointed, so schema-v2 submissions must report incompatibility rather than dispatch via legacy behavior. |
| Release / signing / migration | Not delivered | Local preview only; no Developer ID signing/notarization, live migration or rollback qualification. No release-readiness claim. |

## Verification results

- `swift test`: 150 tests executed, 7 opt-in live tests skipped, 0 failures. Existing Swift 6 concurrency/deprecation warnings remain.
- `node --test Web/tests/*.test.mjs Desktop/tests/*.test.mjs`: 65 passed, 1 socket-dependent integration skipped in this invocation, 0 failures.
- Socket-dependent integration separately run against the latest schema-6 fake daemon: 1 passed, 0 failures.
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s Tests/SkillTests -v`: 9 passed.
- Actual MCP stdio bridge against isolated daemon: owner-only task, requested-Kimi task, retry deduplication, origin fixture and follow-up persistence passed.
- Fresh Codex app-server `skills/list`: exactly one enabled user `team` skill at `~/.codex/skills/team/SKILL.md`, zero skill errors.
- Fresh `codex exec --ignore-user-config --ephemeral --sandbox read-only` with explicit `$team preview only`: loaded that path, reported owner_only and Prepared—not submitted. Codex printed a models-cache warning but exited 0. No Workshop task dispatched in that check.
- Current packaged Electron smoke: pass, five persisted task cards, Connected with test-adapter label, `typeof process` and `typeof require` both undefined, exact 11-method preload API.
- `git diff --check`: passed before report creation.

Reproduction commands are in root `AGENTS.md`. Never run integration tests against installed/live state.

## Evidence

- Browser revision manifest: `Web/web-validation.json`.
- Browser screenshots: `.build/web-qa/full-final.png`, `.build/web-qa/compact-final.png`.
- Browser observations and hashes: `.build/web-qa/evidence.json` (changed-area checks fresh, unchanged checks explicitly regression-carried).
- Latest native screenshot/results: `.build/desktop-qa-final/smoke.png`, `.build/desktop-qa-final/smoke.json`.
- Evidence and bundles under `.build`/`dist` are local artifacts, not automatically included in a source-only checkout. Packaging intentionally refuses stale/missing web evidence.

The remaining cosmetic UI issue is task-state chip adjacency in accessibility text; screenshots show a separate visual chip. Engineer acknowledgments in screenshots are fake-adapter messages, not real provider output.

## Skill installation and rollback

Managed installed files:

- `~/.codex/skills/team/SKILL.md`
- `~/.codex/skills/team/scripts/invocation.py`
- `~/.codex/skills/team/agents/openai.yaml`

Backups:

1. `~/.codex/workshop-skill-backups/<first-backup>` — original skill before first installation, before metadata was added to the installer.
2. `~/.codex/workshop-skill-backups/<second-backup>` — immediately before the metadata-inclusive update; contains the old UI prompt plus the first installed skill/helper.

To undo both stages, run the installer with `--rollback` on backup 2, then backup 1, in that order. Add `--dry-run` to inspect first. The script refuses to overwrite later user edits and reports newly introduced files that remain rather than deleting them blindly. The backup directories are outside Codex skill discovery, avoiding duplicate skills. Existing Codex sessions may need a new session/reload; fresh-session discovery was verified.

No Codex MCP configuration was changed. It still points at the installed Workshop bridge and its existing token-file reference; credentials were not copied into the package.

## Dependency limitations

The Mac's npm policy remains unchanged: 30-day release-age guard and scripts disabled. User explicitly approved inspecting and executing only the pinned Electron installer's runtime download once. Its bundled checksums are validated. Upgrading packager to age-eligible 20.3.0 removed the vulnerable ZIP extractor dependency.

`npm audit --omit=dev`: zero findings. Full audit retains a high-severity dev-only `@xmldom/xmldom@0.9.11` advisory through packaging's `plist` dependency. Do not treat this as a clean full audit; resolve through a policy-compliant dependency update before release. Electron dependencies are not copied into the app's application-code staging tree.

## Next work

1. Implement mechanically enforced native workspace writing/process containment, durable writer and desktop queues, checkpointed handover, dirty-revision fingerprints and safe recovery. Then qualify native capability flags with adversarial process tests.
2. Finish final-design collaboration completion/unavailable-peer behavior and provider/profile live canaries.
3. Integrate actual shared capacity feeds without conflating local budgets with provider allowances; configure user-approved thresholds.
4. Qualify the actual Astra computer bridge and effort/permission routing.
5. Run owner-only and requested-collaboration examples from a fresh installed Codex session against actual engineers, including timeout/retry/reconnect/follow-up behavior and honest return-channel status.
6. Complete native lifecycle/accessibility/signing and compatible-data rollback tests before requesting installed-app replacement or live migration.
