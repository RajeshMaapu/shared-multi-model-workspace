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
- Real isolated daemon + MCP v2 + Fusion: schema discovery, origin-bearing create, identical retry returning the same task, native MCP post, file capture in a sealed proposal, task state `verifying`. Fixture task `task_<id>`; original evidence `/private/tmp/wn-a31_m601/result.json`.
- Web transport suite: 54 passed, one socket-dependent integration skipped in this invocation. Full final Swift result is recorded in the final handoff after the run ends.
- The probe uses existing native authentication/relay routing; it does not independently prove every internal Fusion benchmark or subagent behavior.

## Limits and next operational step

The app/daemon/bridge are not installed by this source change. Existing sessions still advertise the legacy MCP schema until their connection is refreshed. Official Codex documentation exposes `config/mcpServer/reload`; it queues refreshes for loaded tasks. It must reach the actual desktop server, not a newly spawned server. The local direct control-socket probe has not yet succeeded; do not claim the originating task was refreshed.

Snapshot promotion is an authenticated user command (`workshop.promoteWriterSnapshot`, writer_id + verified_digest). The caller must independently verify the sealed candidate first; a model's completion message does not count. Proposal paths and digests appear in the task conversation. No UI approval button was added in this repair.

The build preserves the installed Swift app architecture while retaining Devin's separate community/Electron source. It does not claim the unfinished Electron lifecycle or computer-operator integration is production qualified. sandbox-exec remains the previously selected macOS baseline and carries its existing deprecation risk. Payload limits (256 MiB / 20,000 tree entries) fail visibly rather than silently drop data.

## Controlled upgrade requiring separate approval

The project AGENTS.md says: “Do not replace the installed app, change its MCP configuration, restart the production relay, migrate live Workshop data, merge, or deploy without separate user approval.”

Prepare a uniquely named local bundle with `scripts/package-upgrade.py`; verify signatures and manifest. After explicit approval: pause/stop only Workshop; preserve a consistent database backup and existing app/config; replace Workshop.app with the reviewed bundle; set only the Devin executable/model entries to the qualified route; register Thenali as a project; start Workshop and migrate its copy-backed database to schema 7; refresh the existing Codex MCP connection without restarting Codex. Keep rollback copies and do not delete old data. No Thenali services/trades or relay restart belong to this operation. If live task data changes after migration, rollback requires a deliberate data decision, not restoring stale backups blindly.

## Post-install connection checklist

Apply after every installed Workshop app/backend/MCP bridge replacement or deployment, including rollback to another installed runtime. A source-only change or push does not trigger reconnection.

1. Complete the authorized bundle/data backup, installation and Workshop health checks; preserve rollback evidence.
2. Refresh/reconnect the existing configured Workshop MCP connection using a supported Codex control. A documented `config/mcpServer/reload` must reach the actual desktop server; it queues refreshes for loaded tasks and is not scoped to Workshop alone. Consider other active tasks, do not interrupt them, and verify completion rather than treating request acceptance as success. Do not restart Codex or unrelated services as a shortcut.
3. From the actual originating Codex session, verify a fresh read-only Workshop tool call succeeds and inspect its current callable schema, including required v2 fields. Process age, a new file on disk, advertised schema without a successful call, or a separate freshly spawned CLI cannot establish that this session reconnected.
4. Record the connection verification result with the installed revision and evidence. Only then claim the end-to-end upgrade complete or submit the saved request. Preserve its existing invocation identifier, payload and receipt journal; a reconnect is not a new task or permission to replay an uncertain mutation.
5. If the supported refresh is unavailable, denied, or fails unchanged, stop that route, mark **installed; Codex connection unverified**, and state the specific supported user reconnect action required. Do not repeatedly retry the same failed proxy, inspect a denied surface indirectly, kill processes, alter unrelated configuration, or submit via another connection to hide the missing check. Recheck once a real state change or user refresh is reported.

This standing checklist does not install an automatic hook or background service. Browser validation, native live qualification, installed UI health, Codex connection health and task submission remain separately reported outcomes.

## Submission acceptance

Do not submit the Thenali brief until the actual originating desktop task's callable schema contains schema_version, collaboration_mode and origin. Persist one Team invocation with source task `01a0ad3f-8cc9-7b51-9ea8-4f5bd8014cf7`, owner_only execution; send both the complete current SPX RL-data/learning report and every-shadow-entry-attempt evidence/notification implementation as the previously approved single brief. Save and verify the receipt. No Thenali work was submitted during qualification.


## September 27 trading-task recovery checkpoint (16:24 MST)

The existing trading task retains its original identity.

- Installed permission repair `65c5165`: ACP permission requests may carry only
  `toolCallId`; correlate the preceding native tool update, including Devin's
  `cognition.ai/inferenceToolName`. Exact approved validation commands remain
  scoped to this task's current fenced workspace. Arbitrary shell execution and
  commands outside that workspace remain declined.
- Live measurement: task message seq 156 records the exact approved Python
  command returning exit 0 and 21 passing tests. Both the native execution and
  native Workshop MCP post succeeded. The originating Codex `workshop_get_task`
  call also succeeded after replacement; SQLite quick_check returned `ok`.
- Native Devin session continuity is preserved. The stable copied MCP executable
  avoids the installed bundle's nested executable startup stall; the writer
  sandbox grants read access only to that executable.
- DeepSeek's complete-turn compaction preserves tool-call/result adjacency;
  task seq 142/143 contains a substantive re-review after the former HTTP 400.
- Source `4a62736` permits a new result after changes_requested, retains exact
  retry idempotency, checks owner/generation before deduplication, and rejects
  stale approval of a superseded result. Full Swift suite: 206 tests, 8 live
  tests skipped, zero failures. Installation/live revision verification remain
  pending at this checkpoint.
- Independent full Thenali CI is running in the attached Git worktree
  attached `workshop-shadow-validation` checkout with the
  four files copied from sealed digest `3d7f17629bf5aceac944403a5e2e6a6699fb0d5ff435056d3d28414d86d94ff9`.
  A prior plain-copy run lacked Git metadata and is not CI qualification.
- New correctness finding in task seq 158: aligned positions currently emit
  EXIT_OPEN without an exit trigger; request substantive peer re-review before
  acceptance. No held-out SPY spread performance evidence or PR exists yet.

Rollback copies are under Workshop/backups, including the prior daemon and
consistent database backup. Never restore an older database over new task work
without an explicit reconciliation decision. No Thenali runtime or production
relay restart was performed.
