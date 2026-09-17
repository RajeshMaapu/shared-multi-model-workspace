# Native generation repair — September 16, 2026

The approved change replaces a single writable directory shared by all engineers with one isolated proposal checkout per writer generation. The shared task retains its canonical accepted snapshot. No automatic model-completion-to-promotion path exists.

## Implemented

- ACP cancellation is a notification, with a bounded monotonic wait and client recovery. Post-spawn process-group setup is no longer claimed to contain detached descendants.
- SQLite schema 7 records writer generations, scoped token hashes, sealed candidates, digests and state. Actor-controlled promotion verifies the exact sealed digest and atomically updates the task workspace pointer. Crash recovery revokes incomplete generations; no proposal directories are deleted.
- Copying is descriptor-relative and rejects symlinks, hardlinks, special files, files changing while copied and oversized trees. Worker Git metadata is excluded; each writer starts with an independent Git baseline.
- The sandbox grants writes to the writer's own generation and necessary native CLI state, not the task's accepted snapshot, other generations, source repository or database. The relay gets only its existing launch-lock write exception; this is not permission to replace/restart the production relay.
- Generation tokens expire when superseded, sealed or interrupted. Requests are reauthenticated on existing sockets and scoped to the writer's task. Peer discussions cannot revoke the owner's generation.
- Desktop IPC requires authentication; engineers cannot invoke desktop-only commands. The desktop token is denied to the native sandbox. Swift and Electron transport clients support the new authentication handshake.
- Native v2 availability is confined to the specifically probed relay executable and Fusion Astra High + SWE-2 Medium selector. Kimi/other native routes remain unqualified; fake adapters are never counted as native proof.

## Measurements

- Real detached-child sandbox probe: own-directory write allowed; other-writer, database and accepted-snapshot writes denied.
- Real relay-backed Fusion ACP: created and read back the exact synthetic file inside its generation (20.372 seconds).
- Real isolated daemon + MCP v2 + Fusion: schema discovery, origin-bearing create, identical retry returning the same task, native MCP post, file capture in a sealed proposal, task state `verifying`. Raw fixture identifiers and local evidence paths are retained privately.
- Web transport suite: 54 passed, one socket-dependent integration skipped in this invocation. Full final Swift result is recorded in the final handoff after the run ends.
- The probe uses existing native authentication/relay routing; it does not independently prove every internal Fusion benchmark or subagent behavior.

## Limits and next operational step

The app/daemon/bridge are not installed by this source change. Existing sessions still advertise the legacy MCP schema until their connection is refreshed. Official Codex documentation exposes `config/mcpServer/reload`; it queues refreshes for loaded tasks. It must reach the actual desktop server, not a newly spawned server. The local direct control-socket probe has not yet succeeded; do not claim the originating task was refreshed.

Snapshot promotion is an authenticated user command (`workshop.promoteWriterSnapshot`, writer_id + verified_digest). The caller must independently verify the sealed candidate first; a model's completion message does not count. Proposal paths and digests appear in the task conversation. No UI approval button was added in this repair.

The build preserves the installed Swift app architecture while retaining Devin's separate community/Electron source. It does not claim the unfinished Electron lifecycle or computer-operator integration is production qualified. sandbox-exec remains the previously selected macOS baseline and carries its existing deprecation risk. Payload limits (256 MiB / 20,000 tree entries) fail visibly rather than silently drop data.

## Controlled upgrade requiring separate approval

The project AGENTS.md says: “Do not replace the installed app, change its MCP configuration, restart the production relay, migrate live Workshop data, merge, or deploy without separate user approval.”

Prepare a uniquely named local bundle with `scripts/package-upgrade.py`; verify signatures and manifest. After explicit approval: pause/stop only Workshop; preserve a consistent database backup and existing app/config; replace Workshop.app with the reviewed bundle; set only the Devin executable/model entries to the qualified route; register the intended project; start Workshop and migrate its copy-backed database to schema 7; refresh the existing Codex MCP connection without restarting Codex. Keep rollback copies and do not delete old data. Unrelated project services and the production relay must remain untouched. If live task data changes after migration, rollback requires a deliberate data decision, not restoring stale backups blindly.

## Submission acceptance

Do not submit a project brief until the actual originating desktop task's callable schema contains schema_version, collaboration_mode and origin. Persist one user-approved Team invocation with the actual source task and requested collaboration mode; submit once, then save and verify the receipt. The private project brief and originating task identifiers are omitted from this public snapshot. No project work was submitted during qualification.
