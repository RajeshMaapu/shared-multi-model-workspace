# Recovery runbook

Operational guide for every Workshop recovery path. All state lives under
`$WORKSHOP_HOME` (default `~/Library/Application Support/Workshop`): the DB at
`db/workshop.sqlite`, artifacts under `artifacts/<task_id>/`, capability tokens
under `profiles/<engineer>/token`, DeepSeek managed sessions under
`sessions/deepseek/`.

## Durability baseline

- SQLite in WAL mode, `synchronous=FULL`, `foreign_keys=ON`,
  `busy_timeout=5000`. Schema version 4.
- Every commit path uses short `BEGIN IMMEDIATE` transactions owned by the
  single-writer `CollaborationService` actor.
- Artifacts publish via temp-file + fsync + rename; the DB row is written after
  the rename, so a torn publish leaves a `.tmp-*` file, never a partial row.
- The WAL is checkpointed passively when it exceeds 64 MiB (checked every 60 s).

## Restart (service or daemon relaunch)

`reconcileOnStart()` runs before any dispatch:

- `turns` left `running` → `interrupted`.
- `reservations` left `held` → `released` (capacity accounting never leaks).
- `wakeups` left `running` → `pending` (re-delivered by the coalescer).
- Messages left `streaming` are committed with
  `[stream interrupted by service restart; marked uncertain]` appended.
- For each interrupted turn: if the owner has a valid checkpoint, a
  `resume_from_checkpoint` wakeup is queued (the packet carries the checkpoint
  JSON and instructs re-reading artifacts before editing). If not, the subtask
  is `blocked` with a system event and requires user reconciliation.
- The task pane shows "Recovered: N interrupted turns, M unresolved
  operations" while unresolved rows remain.

## Sleep / wake

The daemon subscribes to `NSWorkspace.willSleepNotification` /
`didWakeNotification`. On wake, every `running` turn is checked against the
registered harness liveness probe: alive → continues; dead → treated exactly
like a restart interruption (checkpoint resume or block).

## Session bindings (§6.2)

`session_bindings` persists each (task, engineer, role, worker) native session
id + recovery state. ACP adapters try `session/load` on reopen and fall back
to `session/new`, updating the binding in place. DeepSeek managed-history
files under `sessions/deepseek/` are advisory: a missing/corrupt file starts a
fresh visible history; the SQLite transcript is the source of truth. When the
stored history exceeds 60 messages or ~200k characters it is compacted to a
checkpoint-derived summary plus the newest 20 entries (no model call) with a
"DeepSeek session compacted" system event.

## Subtask leases and fencing (T05)

- A running turn renews `subtasks.lease_expires_at` every 60 s; leases are
  5 minutes.
- The sweeper (every 30 s) blocks a subtask whose lease expired with no
  running turn in this process, posts "Lease for <engineer> expired
  (generation N); reconciliation required before reassignment", and suppresses
  its wakeups.
- Reassignment bumps `generation`. Every execution packet states the
  `ownership_generation`; `workshop_report_result` requires it and
  `workshop_publish_artifact` accepts it. A stale generation is refused with
  `-32004`; a stale artifact is quarantined to
  `artifacts/<task>/fenced/<hash>-<name>` and never merged into Files.
- Result reporting is idempotent on `(subtask, generation)`; artifact
  publication is idempotent on `(task, content_hash)`.

## Checkpoints (§6.3)

`workshop_save_checkpoint` validates `schema_version == 1`, the required keys
(`objective`, `completed`, `decisions`, `artifacts`, `validation`,
`unresolved`, `next_action`, `last_read_message_seq`), a 64 KiB size cap, and
rejects bodies containing registered secrets. A malformed stored row is marked
`valid=0` with "Corrupt checkpoint skipped; using earlier valid checkpoint".
Before pause/cancel/quota-stop the running turn's packet requests a checkpoint;
no extra turn is spent just to checkpoint.

## Quota stops (§10)

- `capacityBlockedNotified` ensures one "Dispatch to <engineer> blocked:
  bucket <reason>" system event per task+bucket — no retry storm.
- Provider 402/429 → snapshot `limited` for 15 min (hysteresis). A bucket at
  `critical` blocks new dispatch and proposes an eligible replacement via
  `workshop.reassignSubtask`; small tasks auto-reassign after the turn ends
  when a valid checkpoint exists. Never auto top-up.
- `remaining` is the string `"unknown"` when the cap is unset or any usage
  sample lacks counters — unknown is never treated as zero or unlimited.
- When all providers are unavailable the task stays durable, dispatch is
  blocked once with "No eligible engineer available", and re-probe is bounded
  to once per 5 minutes.

## Cancellation outcomes (T23)

Pause/cancel marks the durable turn `cancel_requested` before calling
`adapter.cancelTurn`. Acknowledged → `cancelled`; not acknowledged within the
bound → `uncertain` (ACP: `session/cancel` then ≤10 s wait, then
process-group kill; DeepSeek: URLSession cancellation). System events record
"turn cancellation requested" and "Turn cancellation acknowledged/uncertain".

## Disk low (T30)

`StorageGuard` refuses `createTask`, `workshop_publish_artifact`, and
`workshop_save_checkpoint` with `-32010 storageLow` when free space drops
below 200 MiB, posting one "Storage critically low" event per task. Reads keep
working.

## Resource leases (T24)

`workshop_acquire_lease`/`renew`/`release` coordinate external
browser/computer-use runtimes by named resource with generation CAS: acquire
if absent or expired (takeover bumps generation), renew/release only for the
current owner+generation. Workshop exposes no browser tool itself — the
registry coordinates whichever engineer's runtime has one (ADR 0014).

## Backup and restore (T38)

`workshop.backup {dest_dir}` writes `workshop.sqlite` via the SQLite online
backup API (safe while a writer is active), copies `artifacts/`, and writes
`manifest.json` with artifact SHA-256 hashes and the schema version.

Restore procedure:

1. Quit the Workshop app and `workshop-daemon`. The restore script stops
   nothing itself.
2. `scripts/restore.sh <backup_dir> <new_workshop_home>` — restores into a
   **new** home path. It refuses if `<new_home>/db/workshop.sqlite` already
   exists. Never overwrite the live home directly.
3. Restart the daemon/app with `WORKSHOP_HOME=<new_workshop_home>`.

## Outbox consumers (§8.5)

`publishCommitted()` yields committed rows to in-process subscribers, advances
`outbox_cursors('service')`, and marks broadcast rows delivered.
`dispatch.requested` rows are owned by the dispatcher and are never marked
delivered by subscriber publication. App clients dedupe by `seq`.
