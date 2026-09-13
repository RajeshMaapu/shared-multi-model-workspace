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

# Validation report — Phase 2

```text
Commit / build ID:            7c0dafa (main)
macOS / hardware / toolchain: macOS 15.6.1 / arm64 / Xcode 26.3 / Swift 6.2.4
Harness versions:             devin 3000.10.21 (qualified) / kimi 0.42.0 (qualified)
                              / DeepSeek api.deepseek.com (no binary)
Effective model selectors:    devin: fusion-claude-fable-5-1-medium-sidekick-swe-2-medium
                              kimi: kimi-code/k3 (high)   deepseek: deepseek-flash (max)

Deterministic tests:          ./scripts/test.sh — exit 0 — ~7.7 s
                              68 tests, 63 passed, 5 skipped (LiveSmokeTests
                              opt-in), 0 failures
Live tests:                   WORKSHOP_LIVE=1 swift test --filter LiveSmokeTests
                              — exit 0 — ~70 s — 5/5 passed
                              Evidence: docs/evidence/phase2/live/*.json,
                              docs/evidence/phase2/live-matrix.md

Live coverage:                L1 Devin ACP: session/new, project-file MCP,
                              permission allow_once, tool-posted marker in DB,
                              usage row (input 23179/out 3/cache r 22829/w 348).
                              L2 Kimi ACP: mcpServers injection, tool-posted
                              marker, usage row (counters nil — Kimi reports
                              none over ACP). L3 DeepSeek: tool loop,
                              tool-posted marker, managed session file,
                              usage row (in 1164/out 139/cache r 0).
                              L4 peer roundtrip: devin @kimi → kimi KIMI_ACK +
                              @deepseek → deepseek DEEPSEEK_ACK; 2 wakeups done,
                              0 suppressed, ≤5 turns. L5 restart recall: reopened
                              on same home, packet omitted prior messages
                              (last_read_seq), both Devin and Kimi native
                              sessions recalled their nonces.

Notable live defects fixed:   workshop-mcp toolCaller was @MainActor-isolated
                              (top-level main.swift) and deadlocked against the
                              blocking stdio loop — built nonisolated. Devin
                              permission requests carry only toolCallId — policy
                              now scans option labels for the workshop marker.
                              Turn packet lacked a literal task_id — DeepSeek
                              guessed the subtask UUID; packet now states it.
                              dispatchMain() trapped in async main — daemon
                              parks on Task.sleep.

Failure injections:           session/load failure → session/new + visible
                              uncertain system event; unavailable wakeup target
                              → suppressed rows + one system event; workspace
                              traversal/symlink/absolute-outside rejected (T26);
                              malformed MCP/JSON-RPC lines bounded and
                              recovered.

Secret scan:                  docs/evidence/phase2/live grepped for "Bearer",
                              "api_key", "sk-", and the DeepSeek key prefix —
                              no matches.

UI screenshots:               docs/evidence/phase2/ui-1440x960-{light,dark}.png,
                              ui-980x680-{light,dark}.png — the L4 peer
                              roundtrip task with real engineer messages;
                              ui-usage-tab-light.png (Usage tab); 
                              ui-engineer-card-dark.png (engineer popover).
                              Rendered via the in-window view path (no
                              screen-recording permission needed).

Known limitations:            Kimi ACP surfaces no token usage (row recorded
                              with nil counters). DeepSeek exposes no
                              cache-write counter. Quota remains "unknown".
                              L4 relies on model compliance with mention
                              instructions — one earlier run had Kimi omit
                              @deepseek; the brief now instructs each engineer
                              explicitly. No PR/open items remain for 2b.
Independent reviewer:         none (builder self-check only)
```
