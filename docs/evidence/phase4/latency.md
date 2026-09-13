# Phase 4 latency evidence (§10.3)

Measured by `ServiceTests.LatencyBench` — deterministic, fake adapters, real
temporary SQLite databases with `synchronous=FULL` + WAL (the shipped
configuration). 200 iterations per measurement; p50/p95 reported in
milliseconds.

**Hardware / toolchain:** macOS 15.6.1, Apple Silicon (arm64), Xcode 26.3,
Swift 6.2.4, debug build.

> These are numbers measured on this Mac on this day — evidence that the
> operations are cheap, **not** guarantees or SLAs. Absolute values will
> differ on other hardware and under load.

## synchronous=FULL (shipped)

| Operation | p50 (ms) | p95 (ms) |
|---|---|---|
| Local create-task receipt | 5.74 | 7.82 |
| Committed event visible to in-process subscriber | 0.48 | 1.15 |
| Wakeup queued | 0.14 | 0.72 |
| Open task with 5,000-message history (newest page, limit 500) | 24.97 | 26.04 |

Raw: `latency-full.json`.

## synchronous=NORMAL (comparison only — NOT shipped)

| Operation | p50 (ms) | p95 (ms) |
|---|---|---|
| Local create-task receipt | 5.97 | 21.85 |
| Committed event visible to in-process subscriber | 0.37 | 2.87 |
| Wakeup queued | 0.06 | 0.54 |
| Open task with 5,000-message history | 24.63 | 25.46 |

Raw: `latency-normal.json`.

FULL costs meaningfully at the p95 tail for write bursts (fsync per commit)
and roughly doubles wakeup-queue p50. The durability guarantee — every commit
survives a power loss — is the point of the design, so the shipped setting
remains `synchronous=FULL`.

The 5,000-message open is dominated by decode+mapping of the newest 500-row
page, not by the scan: it stays flat in both modes and meets the §10.3
expectation of an interactive open.
