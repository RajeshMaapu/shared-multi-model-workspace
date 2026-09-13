# Validation report — Phase 1

```text
Commit / build ID:            (see git log; phase-1 rework commit)
macOS / hardware / toolchain: macOS 15.6.1 / arm64 / Xcode 26.3 / Swift 6.2.4
Harness versions:             devin 3000.10.21 / kimi 0.42.0 / codex 0.147.0 (not exercised this phase)
Effective model selectors:    none live — fake adapter only (effectiveModel "fake-model")
Tests run:                    ./scripts/test.sh (swift test) — exit 0 — ~9 s
                              Evidence: docs/evidence/phase1/test-output.txt
                              26 tests executed, 25 passed, 1 skipped, 0 failures
Tests skipped:                LiveSmokeTests.testLiveSmokeOptIn — XCTSkip; opt-in
                              (WORKSHOP_LIVE=1), no live adapters exist in Phase 1
Live provider calls:          none
UI screenshots:               docs/evidence/phase1/main-1440x960-{light,dark}.png,
                              docs/evidence/phase1/main-980x680-{light,dark}.png
                              (captured 2026-09-13 04:23 local)
                              Scenario: seeded execution task after fake reply committed.
                              Both composer placeholders visible; engineer rows show
                              health kind + probe detail ("Available · Fake adapter ready").
Failure injections:           T03 — task committed with dispatcher disabled, service
                              "restarted" on the same DB; outbox replayed, exactly one
                              turn ran. T21-lite — invalid JSON line and >4 MiB line on a
                              raw socket; -32700 returned, connection stayed usable.
                              Interrupted-stream recovery blocks the owning subtask and
                              task and marks the stream uncertain (Phase 4 reconciliation).
                              FakeAdapter.failAfterDeltas injects a mid-turn failure:
                              task/subtask blocked, "Turn failed: ... awaiting
                              reconciliation", no false completion. Poisoned
                              dispatch.requested row is marked failed (error appended to
                              payload), the dispatch loop exits, and later tasks still
                              dispatch.
Deterministic coverage:       T01 idempotent create, T02 conflict, T03 outbox recovery,
                              T04 single-winner CAS claim, T09 one-engineer execution,
                              T28 reopen persistence, T15-lite no-eligible block,
                              T21-lite malformed input, research_proposal truthfulness,
                              failed-turn handling, poisoned-outbox recovery,
                              usage telemetry nulls preserved.
Known limitations:            Research/proposal phase is preserved-but-queued (Phase 3
                              policy not implemented). No proposals/decisions/files data
                              model yet; Usage tab shows the latest fake usage sample
                              with "unknown" for unmeasured counters. deepLink always
                              nil (URL scheme not registered). No MCP bridge, no real
                              adapters, no artifacts. User replies (workshop.postMessage)
                              commit but do not yet wake the owning engineer (Phase 2
                              wakeup policy). Informational outbox rows (task.created,
                              message.committed) remain delivery_state 'pending' — there
                              is no persistent consumer/ack cursor yet (Phase 4). Pane
                              widths are fixed defaults; no draggable splitters.
                              Transient message.delta notifications are in-process
                              semantics broadcast over IPC; committed facts remain the
                              outbox.
Independent reviewer:         none (builder self-check only)
```
