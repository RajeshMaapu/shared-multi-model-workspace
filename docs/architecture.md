# Workshop architecture

## Targets

| Target | Kind | Responsibility |
| --- | --- | --- |
| `WorkshopCore` | library | Typed IDs, task/message/subtask models, §8.2 state machine, §8.4 create-task contract, canonical JSON hash, JSON-RPC envelope, protocol constants |
| `WorkshopStore` | library | `Database` (system `libsqlite3` C API, WAL, `synchronous=FULL`, `foreign_keys=ON`, `busy_timeout=5000`), `Migrator`, typed repository functions |
| `WorkshopService` | library | `EngineerAdapter` protocol (§7.1), `FakeAdapter`, `UnconfiguredAdapter`, `CollaborationService` actor: single writer, dispatcher, recovery |
| `WorkshopIPC` | library | Newline-delimited JSON-RPC 2.0 over a Unix-domain socket (POSIX BSD sockets), peer-uid check, 4 MiB line bound |
| `workshop-daemon` | executable | Owns `WORKSHOP_HOME`, opens the DB, single-instance `flock`, serves IPC, bridges service events to subscribers |
| `WorkshopApp` (product `Workshop`) | executable | SwiftUI shell: rail, workspace sidebar, task list, task pane with tabs |

## Process topology

```text
Workshop.app ──JSON-RPC/UDS──> workshop-daemon ──> SQLite (WAL)
                                   │
                                   ├─ FakeAdapter ×3 (WORKSHOP_ADAPTERS=fake)
                                   └─ UnconfiguredAdapter ×3 (default off)
```

The app never writes SQLite. The daemon is the single logical writer; all mutations go
through `CollaborationService`, which commits state changes and outbox events in one
transaction (§8.5). Subscribers receive `workshop.event` notifications for committed
facts; streaming deltas are in-process `message.delta` notifications only — the outbox
stores committed facts, not keystrokes.

## Dispatch (Phase 1)

`createTask` commits task + root message + participants + root subtask +
`task.created` (+ `dispatch.requested` for execution/follow_up) in one transaction,
with idempotency via the `operations` table (same key + same payload hash → stored
receipt; same key + different hash → `-32009`).

The dispatcher processes pending `dispatch.requested` rows in seq order: probes the
task's participant adapters in devin → kimi → deepseek order (or `preferred_owner`
first), takes the first `available` engineer, and wins ownership with one CAS UPDATE
(`owner_id IS NULL AND generation=?` → `changes()==1`). The turn then runs outside the
claim transaction: a `streaming` message is committed first, deltas update its body,
and `turnCompleted` commits the body, moves the subtask to `review`, the task to
`verifying`, and records system events.

If no engineer is eligible the task goes `blocked` with a system event and the outbox
row is marked delivered — no retry storm (T15-lite). `research_proposal` tasks get no
dispatch and an honest system message that the Phase 3 policy is not yet implemented.

## Why the fake adapter

Phase 1's gate is the vertical slice, not provider integration. `FakeAdapter` exercises
the same `EngineerAdapter` contract (probe → openTaskSession → sendTurn stream →
cancel) with deterministic output and configurable `delayPerDelta` (0 in tests), so
dispatch, claiming, streaming, and recovery are all testable without network or
credentials. `WORKSHOP_ADAPTERS=fake` is the default daemon configuration this phase.
