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

# Validation report — Phase 3

```text
Commit / build ID:            78e0e8b + Phase 3 UI/docs commits (main)
macOS / hardware / toolchain: macOS 15.6.1 / arm64 / Xcode 26.3 / Swift 6.2.4

Deterministic tests:          ./scripts/test.sh — exit 0 — ~8.8 s
                              85 tests, 79 passed, 6 skipped (LiveSmokeTests
                              opt-in), 0 failures
Live tests:                   WORKSHOP_LIVE=1 swift test --filter
                              testL6ResearchApprovalAllocation — exit 0 —
                              231.5 s — passed
                              Evidence: docs/evidence/phase3/live/l6.json,
                              docs/evidence/phase3/live/live-l6.md

Phase 3 coverage:             T12 draft privacy (peers see published + own
                              draft only; get_task exposes counts), publish-
                              together with missing participant recorded,
                              exactly one cross_review wakeup per participant,
                              Devin-only consolidation, unavailable-arbiter
                              wait (no promotion), T07 approval gate on all
                              implementation tools with no pre-approval turn,
                              approval → subtasks + Devin allocate wakeup,
                              stale revision -32008, engineer approval -32005,
                              T27-lite engineer "approved" message inert,
                              T08 revision invalidates approval, assign CAS +
                              generation + dependency gating -32007, dispute
                              wakes Devin, proportional review picks verifier
                              ≠ owner and agree→done/passed, needs_changes→
                              rework, small-task path unchanged, pause cancel
                              with requested/acknowledged events, cancel while
                              running requested→completed, escalate→pause→
                              convert→researching, v2→v3 migration preserving
                              data, F1 tool-message-before-reply ordering,
                              F2 honest recovery wording (both cases).

Live coverage (L6):           Research task with all three participants:
                              3 drafts at t+87 s, publish, 3 cross-reviews at
                              t+173 s, Devin report r1 at t+216 s, user
                              approval, Devin allocation at t+231 s, owner
                              result at t+231 s. 24 messages, 10 wakeup rows
                              (7 done, 1 suppressed — a coalesced mention),
                              usage rows for all three engineers.

UI screenshots:               docs/evidence/phase3/proposals-1440x960-
                              {light,dark}.png — L6 published proposal cards
                              with peer reviews and the approved report card.
                              approval-card-before-1440x960-light.png — the
                              same task's report card before approval
                              (rendered on a copy of the L6 home with
                              approval_revision reset; noted here per spec).
                              decisions-1440x960-light.png — decision log.
                              board-1440x960-light.png — owner/verification
                              columns.

Known limitations:            L6 asserts stage rows exist; it does not grade
                              proposal content quality. Kimi ACP reports no
                              token usage (rows recorded with nil counters).
                              Keyboard approval: Approve/Choose/Request-
                              changes are standard focusable controls (Tab
                              traversal) with .defaultAction on Approve;
                              verified by build, not a scripted UI test.
Independent reviewer:         none (builder self-check only)
```
