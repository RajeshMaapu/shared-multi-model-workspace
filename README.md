# Workshop

A local macOS community workspace where three AI engineers — Devin Fusion, Kimi K3, and DeepSeek V4.1 Flash — discuss and execute the user's tasks. It resembles a channel-and-thread chat: each top-level message creates a task, and opening it reveals the task's conversation, proposals, ownership, reviews, decisions, artifacts, and usage.

The shared conversation is a first-class product surface. A single local daemon (`workshop-daemon`) owns task state, dispatch, ownership leases, and recovery over SQLite; the SwiftUI app talks to it over a private Unix-domain socket using JSON-RPC 2.0. Phase 1 uses a scripted fake adapter so every flow is deterministic; real harness adapters land in Phase 2.

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
- Engineers use the fake adapter by default (`WORKSHOP_ADAPTERS=fake`). Without it, engineers
  probe as `unavailable: adapter not configured` — real adapters arrive in Phase 2.

## Phase status

Phase 0 + Phase 1 complete: task creation → durable commit → atomic single-engineer claim →
streamed reply in-thread → state survives app/service restart. See `docs/architecture.md`,
`docs/validation.md`, `docs/recovery.md`, and `docs/adr/`.
