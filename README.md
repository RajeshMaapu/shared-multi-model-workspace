# Workshop

A local macOS community workspace where three AI engineers — Devin Fusion, Kimi K3, and DeepSeek V4.1 Flash — discuss and execute the user's tasks. It resembles a channel-and-thread chat: each top-level message creates a task, and opening it reveals the task's conversation, proposals, ownership, reviews, decisions, artifacts, and usage.

The shared conversation is a first-class product surface. A single local daemon (`workshop-daemon`) owns task state, dispatch, ownership leases, and recovery over SQLite; the SwiftUI app talks to it over a private Unix-domain socket using JSON-RPC 2.0. Phase 1 uses a scripted fake adapter so every flow is deterministic; the real Devin/Kimi/DeepSeek harness adapters landed in Phase 2.

## Prerequisites

- macOS 14+ (developed on macOS 15.6.1, Apple Silicon)
- Xcode 26.3 toolchain / Swift 6.2.4 (`swift` on PATH)
- No third-party dependencies. SQLite via the system `libsqlite3`.

## Commands

```sh
make build         # swift build
make test          # deterministic test suite, tees to docs/evidence/phase1/test-output.txt
make dev           # build, assemble .build/Workshop.app, ad-hoc sign, open
make screenshots   # capture the four evidence PNGs into docs/evidence/phase1/
```

## Storage

- Durable state: `~/Library/Application Support/Workshop/` (override: `WORKSHOP_HOME`)
  — `db/workshop.sqlite`, plus `profiles/`, `sessions/`, `worktrees/`, `artifacts/`, `diagnostics/`.
- Runtime socket/lock: `${DARWIN_USER_TEMP_DIR}/workshop/service.sock` (override: `WORKSHOP_RUNTIME_DIR`).
- Engineers use the fake adapter by default (`WORKSHOP_ADAPTERS=fake`).
  `WORKSHOP_ADAPTERS=live` registers the real Devin (ACP, project-config MCP),
  Kimi (ACP, `mcpServers` injection), and DeepSeek (direct tool loop) adapters;
  `mixed:<engineer>=fake,…` is available for tests.

## Phase status

Phase 0–2 complete: task creation → durable commit → atomic claim → streamed
replies → restart recovery, plus real Devin/Kimi/DeepSeek adapters, the
`workshop-mcp` tool bridge, wakeup policy, artifacts, usage samples, and the
engineer-card/tabbed task UI. Live smoke suite (L1–L5) passes against the real
accounts — `WORKSHOP_LIVE=1 swift test --filter LiveSmokeTests`, evidence in
`docs/evidence/phase2/`. See `docs/architecture.md`, `docs/validation.md`,
`docs/recovery.md`, `docs/credential-ownership.md`, and `docs/adr/`.

Phase 3 adds the collaboration policy for substantial tasks: private
independent proposals (published together), cross-review with preserved
disagreement, Devin-only consolidation, user-only architecture approval with
stale-revision protection, arbiter allocation with dependency gating and
disputes, proportional verification, and pause/resume/cancel/escalate/convert
task actions — plus Proposals/Decisions tabs, a six-column board, and task
actions in the UI. Live evidence: `docs/evidence/phase3/` (L6).

Phase 4 adds resilience and resource policy: schema v4 (turns, leases,
reservations, outbox cursors, checkpoints), tool-boundary fencing with a
fenced-artifact quarantine, capacity model (unknown ≠ 0 ≠ unlimited),
cancellation states, storage guard, redaction, DeepSeek managed-history
compaction, diagnostics, FTS5 search, task export, online backup +
`scripts/restore.sh`, and 500-message paging. Runbook: `docs/recovery.md`.

Phase 5 (release candidate `v0.1.0-rc1`) adds the Codex handoff and packaging:
a `codex` principal with five allowed tools (approvals stay in the app),
`workshop-mcp --principal codex` that keeps serving tools while the daemon is
down, `~/Library/Application Support/Workshop/bin/workshop-mcp` stable symlink,
`~/Applications/Workshop.app` (`ai.maapu.workshop`, `workshop://task/<id>` deep
links, `workshop.stopBackground`, menu-bar extra, SMAppService helper,
notifications, build-mismatch banner). Package with `./scripts/package.sh`
and install per `docs/verification-checklist.md`. Final status:
`docs/final-report.md`, `docs/validation.md` Phase 5, ADRs 0015–0016.
