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

## Phase 2a: principals, bridge, real adapters, wakeups

**Principals.** The daemon generates a per-engineer capability token at
`<WORKSHOP_HOME>/profiles/<engineer>/token` (32 random bytes, mode 0600) on
first start. `workshop.authenticate {token}` binds a connection to
`.engineer(id)`; unauthenticated connections stay `.user` (same-uid socket —
ADR 0003). Author identity always comes from the connection principal, never
params. Engineer principals may only read/post on tasks where they are
participants → `-32003 notAParticipant`; `workshop_report_result` additionally
requires current ownership → `-32004 notOwner`.

**workshop-mcp bridge.** A stdio MCP server (pinned protocolVersion
2025-06-18) that forwards `tools/call` to the daemon over the UDS with the
engineer's token. Devin finds it via `<worktree>/.devin/mcp_config.local.json`
(ADR 0006); Kimi via ACP `session/new.mcpServers`.

**Adapters** (`WorkshopAdapters`): `ACPClient` + `ACPHarnessAdapter` shared by
Devin and Kimi (per-harness `HarnessLaunchSpec`, `MCPInjection` mode, warm
process kept between turns, 10 min idle bound, process-group kill on cancel).
`probe()` runs `<bin> --version` (10 s bound): equal to the qualified version →
`available`/`tested`; different → `available` + "UNTESTED" + `tested:false`;
missing binary → `unavailable`. `DeepSeekAdapter` owns a direct tool loop with
in-process tool execution and file-backed visible-message history (ADR 0008).
Adapter registration is `WORKSHOP_ADAPTERS=fake|live|mixed:<eng>=fake,…`;
`live` reads `config/engineers.json` (seeded from
`Configuration/engineers.template.json` — paths and model selectors only).

**Wakeups (§5.4).** A committed message inserts pending `wakeups` rows for:
@mentions of other participants, `request_review` targets, and — for user
messages — the current owner. A coalescer (500 ms, 0 in tests) batches pending
rows per (task, engineer) into one turn carrying a "you were mentioned"
context. Engineer↔engineer messages with no mention wake nobody; system
events never wake. Loop bound: 6 consecutive engineer wakeups without a user
message → further rows `suppressed` + one "Discussion round limit reached"
system event.

**Consumed cursor.** `participants.last_read_seq` bounds the turn context to
unseen messages (≤60, oldest truncated with a note) and advances only when a
turn completes — never on send.
