# Recovery

## Phase 1 behaviour

- **Service restart (T03):** `dispatch.requested` outbox rows survive in SQLite. On
  `start()` the service replays pending rows exactly once — each is claimed under the
  CAS and marked delivered in the same transaction as the claim, so a crash between
  commit and dispatch cannot drop or duplicate the effective turn.
- **Interrupted streams:** any message still `streaming` when a process dies is
  committed on next `start()` with `\n\n[stream interrupted by service restart; marked
  uncertain]` appended and a system event recorded. The UI shows the flag truthfully.
- **No eligible engineer:** the dispatch row is marked delivered, the task is
  `blocked`, and a system event is recorded. Nothing is retried automatically.
- **Durability:** `synchronous=FULL` + WAL; create/claim/commit use short
  `BEGIN IMMEDIATE` transactions. `busy_timeout=5000`.

## Phase 4 items (TODO)

- Lease expiry fencing at the execution boundary and reassignment (T05).
- Reconciliation of uncertain external effects after adapter mid-turn exits (T06).
- Sleep/wake reconciliation of in-flight requests and leases before redispatch (T29).
- Artifact publication reconciliation (temp file → rename → DB reference) (T38).
- Session binding resume across adapter restarts (§6.2).

## Phase 2a additions

- **Session bindings** are persisted (`session_bindings` table, schema v1) with
  `native_session_id` + `recovery_state`; ACP adapters try `session/load` on
  reopen and fall back to `session/new` (binding updated in place).
- **Wakeups** left `pending`/`running` at crash are re-scanned by the
  coalescer on the next committed message; rows never silently vanish because
  they live in SQLite.
- **Artifacts** copy via temp-file + fsync + rename; a torn publish leaves a
  `.tmp-*` file, never a partial artifact row (row insert follows the rename).
- **DeepSeek history** files are advisory state only — a missing/corrupt file
  simply starts a fresh visible-message history; the SQLite transcript is the
  source of truth.
