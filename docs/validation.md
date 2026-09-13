# Validation report — Phase 1

```text
Commit / build ID:            (see git log; phase-1 branch of initial build)
macOS / hardware / toolchain: macOS 15.6.1 / arm64 / Xcode 26.3 / Swift 6.2.4
Harness versions:             devin 3000.10.21 / kimi 0.42.0 / codex 0.147.0 (not exercised this phase)
Effective model selectors:    none live — fake adapter only (effectiveModel "fake-model")
Tests run:                    ./scripts/test.sh (swift test) — exit 0 — ~9 s
                              Evidence: docs/evidence/phase1/test-output.txt
                              23 tests executed, 22 passed, 1 skipped, 0 failures
Tests skipped:                LiveSmokeTests.testLiveSmokeOptIn — XCTSkip; opt-in
                              (WORKSHOP_LIVE=1), no live adapters exist in Phase 1
Live provider calls:          none
UI screenshots:               docs/evidence/phase1/main-1440x960-{light,dark}.png,
                              docs/evidence/phase1/main-980x680-{light,dark}.png
                              Scenario: seeded execution task after fake reply committed
Failure injections:           T03 — task committed with dispatcher disabled, service
                              "restarted" on the same DB; outbox replayed, exactly one
                              turn ran. T21-lite — invalid JSON line and >4 MiB line on a
                              raw socket; -32700 returned, connection stayed usable.
                              Interrupted-stream recovery test marks messages uncertain.
Deterministic coverage:       T01 idempotent create, T02 conflict, T03 outbox recovery,
                              T04 single-winner CAS claim, T09 one-engineer execution,
                              T28 reopen persistence, T15-lite no-eligible block,
                              T21-lite malformed input, research_proposal truthfulness.
Known limitations:            Research/proposal phase is preserved-but-queued (Phase 3
                              policy not implemented). No proposals/decisions/files/usage
                              data model yet. deepLink always nil (URL scheme not
                              registered). No MCP bridge, no real adapters, no artifacts.
                              Transient message.delta notifications are in-process
                              semantics broadcast over IPC; committed facts remain the
                              outbox. Pane widths use fixed defaults (persisted via
                              @AppStorage but not user-resizable this phase).
Independent reviewer:         none (builder self-check only)
```
