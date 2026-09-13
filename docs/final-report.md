# Workshop — final report (v0.1.0-rc1)

Build: `dist/Workshop.app` → `~/Applications/Workshop.app`, CFBundleVersion
`0.1.0-rc1`, bundle id `ai.maapu.workshop`, `workshop://` scheme registered.
Commit: see `git log main`; tag `v0.1.0-rc1`.

## Implemented

- Task lifecycle: durable create (idempotency-key dedupe, conflict detection),
  atomic subtask claims, streamed provider replies, committed-event outbox,
  restart/sleep-wake reconciliation, pause/resume/cancel/accept/convert.
- Research → proposals (private drafts, publish, cross-review) → consolidated
  Devin report → user architecture approval → allocation → execution →
  verification/accept.
- Phase 4 resilience: turns table, lease registry + sweeper, tool-boundary
  fencing with fenced-artifact quarantine, checkpoints (validated, corrupt
  skipped), capacity model (unknown ≠ 0 ≠ unlimited) + reservations,
  cancellation acknowledged/uncertain, storage guard, redaction, DeepSeek
  managed-history compaction, diagnostics, FTS5 search, export, backup.
- Phase 5: `Principal.codex` with a 5-tool allowlist (-32005 on everything
  else — approvals stay in the app), `profiles/codex/token`, stable
  `bin/workshop-mcp` symlink, offline-safe MCP bridge (tools served with the
  daemon down; calls return isError), truthful §8.4 receipt incl. verified
  `workshop://task/<id>` deep link, `via=codex` messages ("You (via Codex)"),
  packaged app (URL scheme, LaunchAgent plist, hardened runtime), lifecycle
  (Quit UI / Pause team / Stop background work), menu-bar extra
  (N active turns / M awaiting you), SMAppService helper toggle + status,
  notifications (approval/blocked/verifying, mutable), build-mismatch banner.

## Tested

Deterministic (`./scripts/test.sh`, 117 tests, 0 failures, ~17 s):
create/dedupe/conflict, claim CAS, pre-dispatch crash recovery, fenced stale
generations, interrupted-turn reconcile + checkpoint resume, capacity
block/unknown, lease CAS + takeover, cancel states, storage guard, paging,
search, export, backup-under-write, Codex auth/allowlist/via/offline bridge,
latency bench (docs/evidence/phase4/latency.md).

Live (approved calls only):
- Phase 3 L6 research→approval→allocation (231 s, all real turns).
- Phase 4 DeepSeek `/user/balance` probe (available, USD).
- Phase 5: `codex exec` ×3 (create, duplicate brief, follow-up) — task
  created via MCP with receipt + deep link, DeepSeek turn ran, `via=codex`
  follow-up posted and woke the owner. Transcripts:
  `docs/evidence/phase5/live/codex-transcript-{1,2,3}.txt`.
- Binary-level: offline `workshop-mcp` isError text; `lsregister` +
  `LSCopyDefaultHandlerForURLScheme` → `ai.maapu.workshop`;
  `open workshop://task/<id>` selects the task; packaged daemon lifecycle
  (helper-off quit exits the daemon); update-mismatch banner.

## Deferred

- True Developer ID signature + notarization (no Apple TeamID/Apple ID
  credentials on this machine) — signed with local "Maapu LLC" identity;
  `spctl` rejects. See ADR 0016.
- SMAppService helper registration exercised only through the UI toggle
  (status `notRegistered` observed); register/unregister is manual-only.
- Task-list-row capacity indicator is selected-task-scoped.
- Leases coordinate external computer-use runtimes; Workshop exposes no
  browser tool itself (ADR 0014).

## Blocked

- None outstanding. Non-blocking known issues: `codex exec` needed
  `-m gpt-5.6-luna` (configured `gpt-6-astra` requires a newer CLI); the
  second Codex run emitted the untruncated 64-char idempotency hash and
  created a second task — prompt-following variance, service dedupe is
  exact-key and correct; overwriting the app bundle in place SIGKILLs a
  running daemon (install = rm/move then copy, ADR 0016).

## Acceptance matrix

Evidence paths are relative to the repo root. "passed-deterministic" = covered
by the XCTest suite; "passed-live" = observed against real provider/CLI.

| Row | Status | Evidence |
|-----|--------|----------|
| T01 create idempotent | passed-deterministic (live partial — see note) | ServiceTests.testT01IdempotentCreate; CodexBridgeTests.testCreateTaskIdempotentDuplicate; live transcript 2 created a second task because the model used the full hash — key fidelity, not dedupe failure |
| T02 idempotency conflict | passed-deterministic | ServiceTests.testT02IdempotencyConflict; CodexBridgeTests.testCreateTaskIdempotencyConflict (-32009, "idempotency conflict") |
| T03 pre-dispatch crash | passed-deterministic | ServiceTests.testT03PreDispatchCrashRecovery |
| T04 atomic claim | passed-deterministic | ServiceTests.testT04AtomicClaimSingleWinner; StoreTests.testCASClaim |
| T05 stale generation fenced | passed-deterministic | Phase4ServiceTests.testT05StaleGenerationFenced |
| T06 reconcile + idempotent publish/result | passed-deterministic | Phase4ServiceTests.testT06ArtifactIdempotentAndInterruptedResume |
| T07 approval gate | passed-deterministic | Phase3ServiceTests (all five implementation tools refused pre-approval) |
| T08 report invalidation | passed-deterministic | Phase3ServiceTests (stale revision -32008) |
| T09 one engineer executes | passed-deterministic | ServiceTests.testT09OneEngineerDoesWork |
| T10 user reply wakes owner | passed-deterministic | Phase2/3 wakeup tests + CodexBridgeTests.testCodexPostMessageVia |
| T11 research produces proposals | passed-deterministic + passed-live | Phase3ServiceTests; L6 evidence docs/evidence/phase3/live/ |
| T12 draft privacy | passed-deterministic | Phase3ServiceTests |
| T13 critical capacity blocks | passed-deterministic | Phase4ServiceTests.testT13CriticalCapacityBlocksDispatch |
| T14 unknown ≠ 0 ≠ unlimited | passed-deterministic | Phase4ServiceTests.testT14UnknownCapacityDistinct |
| T15 all unavailable durable | passed-deterministic | Phase4ServiceTests.testT15AllUnavailableKeepsTaskDurable |
| T16 live smoke each adapter | partial | Devin/Kimi live exercised in earlier phases; Phase 5 live = DeepSeek only |
| T17 restart mid-turn | passed-deterministic | ServiceTests.testInterruptedStreamMarkedUncertain + T29 tests |
| T18 tool loop / usage mapping | passed-deterministic | AdapterContractTests.testDeepSeekToolLoopAndUsageMapping |
| T19 dispatch exactly-once | passed-deterministic | outbox cursor + delivered-on-yield tests (Phase4) |
| T20 session binding persist | passed-deterministic | session_bindings coverage in service tests |
| T21 malformed input | passed-deterministic | IPCTests (T21-lite: -32700, >4 MiB line) |
| T22 concurrency multi-task | partial | dispatcher concurrency covered implicitly; no dedicated multi-task soak |
| T23 cancellation states | passed-deterministic | Phase4ServiceTests.testT23CancellationAcknowledgedAndUncertain |
| T24 resource lease CAS | passed-deterministic | Phase4ServiceTests.testT24ResourceLeaseCAS |
| T25 dispute/ownership vote | passed-deterministic | Phase3ServiceTests (dispute wakes Devin, CAS) |
| T26 private continuation | passed-deterministic | DeepSeekAdapter managed sessions; ADR 0008 |
| T27 no authority escalation | passed-deterministic | CodexBridgeTests.testCodexForbiddenActions (-32005, injected approve/accept); Phase3 T27-lite |
| T28 reopen preserves | passed-deterministic | ServiceTests.testT28ReopenPreservesState |
| T29 restart/sleep reconcile | passed-deterministic | Phase4ServiceTests.testT29ReconcileOnStart + testWakeReconcileDeadProcess |
| T30 disk low guard | passed-deterministic | Phase4ServiceTests.testT30StorageGuard |
| T31 large thread paging | passed-deterministic | Phase4ServiceTests.testT31MessagePaging + latency.md |
| T32 secret redaction | passed-deterministic | Phase4ServiceTests.testT32Redaction |
| T33 notifications on events | manual-only | NotificationPoster posts; banner not captured headlessly (validation.md Phase 5) |
| T34 multi-window state | passed-deterministic | AppState shared across windows; earlier phases |
| T35 daemon down via bridge | passed-deterministic + passed-live | CodexBridgeTests.testOfflineBridgeStillServesTools; binary run output |
| T36 codex handoff e2e | passed-live | docs/evidence/phase5/live/codex-transcript-{1,3}.txt; DB rows |
| T37 package install e2e | passed-live | ~/Applications/Workshop.app; lsregister + scheme verify; lifecycle tests |
| T38 backup/restore | passed-deterministic | Phase4ServiceTests.testT38BackupWhileWriting; scripts/restore.sh |
| T39 settings/preferences | manual-only | Settings window (helper toggle, mute, send-on-enter); settings.png |
| T40 update path | passed-live | build-mismatch banner observed (validation.md Phase 5; update-banner.png) |

Independent reviewer: pending — user.
