# Phase 4 report — resilience and resource policy

Scope: spec §4.3, §6.3, §8.5, §9.2, §9.4, §10, §14.1–14.5; tests T05, T06,
T13, T14, T15, T23, T24, T29, T30, T31, T32, T38; latency §10.3.

## Commands and results

| Command | Exit | Duration | Result |
|---|---|---|---|
| `./scripts/test.sh` | 0 | ~16.7 s | 109 tests, 102 passed, 7 skipped (opt-in LiveSmokeTests), 0 failures |
| `swift test --filter Phase4ServiceTests` | 0 | ~0.8 s | 21/21 passed |
| `WORKSHOP_EVIDENCE_DIR=docs/evidence/phase4 swift test --filter LatencyBench` | 0 | ~6.5 s | wrote `latency-full.json` |
| `WORKSHOP_BENCH_SYNC_NORMAL=1 … --filter LatencyBench` | 0 | ~7.0 s | wrote `latency-normal.json` (comparison only) |
| `WORKSHOP_LIVE=1 swift test --filter testL7DeepSeekBalance` | 0 | ~0.44 s | one bounded GET /user/balance |

Hardware/toolchain: macOS 15.6.1, arm64, Xcode 26.3, Swift 6.2.4, debug build.

## Latency (§10.3) — see latency.md

| Operation | FULL p50 / p95 (ms) | NORMAL p50 / p95 (ms) |
|---|---|---|
| create-task receipt | 5.74 / 7.82 | 5.97 / 21.85 |
| committed event → in-process subscriber | 0.48 / 1.15 | 0.37 / 2.87 |
| wakeup queued | 0.14 / 0.72 | 0.06 / 0.54 |
| open 5,000-message task (newest page) | 24.97 / 26.04 | 24.63 / 25.46 |

Machine-specific, not guarantees. Shipped configuration remains
`synchronous=FULL`; NORMAL measured for reporting only via
`WORKSHOP_BENCH_SYNC_NORMAL`.

## FTS5

`PRAGMA compile_options` on the system SQLite lists `ENABLE_FTS5` — search
uses FTS5 (`testDiagnosticsShape`/`testSearchFindsMessages` assert it); LIKE
is the fallback path.

## DeepSeek balance probe (the single approved live call)

`live/deepseek-balance.json`: availability **available**, currency **USD**.
No account identifiers or balance figures recorded.

## Coverage

T05 fencing + quarantine · T06 idempotent artifact/result + interrupted-turn
resume-or-block · checkpoint schema/64 KiB/secret validation + corrupt-skip ·
T13 critical-block + reservation bound · T14 unknown semantics (incl. nil
counters) · T15 durable task + single block event + 5-min probe throttle ·
T23 cancel ack/uncertain turn states · T24 lease CAS + takeover · T29 restart
+ wake reconcile · T30 storage guard · T31 5,000-message paging < 300 ms ·
T32 redaction surfaces · T38 backup-under-write verified at schema v4 · §8.5
service cursor + client dedupe · DeepSeek managed-history compaction.

## Deviations

- `checkpoints.valid` semantics: a malformed stored row is marked invalid at
  load and the earlier valid row is used (event records the skip) — as
  specified; loading is lazy so the mark happens on first read.
- Task-row capacity indicator: implemented for the selected task's owner via
  `workshop_get_capacity` snapshots; list rows have no per-task owner data
  without an extra IPC call per row — noted as a limitation.
- Lease release deletes the row, so a subsequent *fresh* acquire starts at
  generation 1; expiry *takeover* of an existing row bumps generation+1 as
  specified.
- `reconcileOnStart` leaves resource leases untouched on restart — TTL is the
  arbiter (ADR 0014).
- Screenshots of the engineer card and Diagnostics are captured at their
  natural window sizes (popover / 900×508); the main-window evidence shots
  are 1440×960.
