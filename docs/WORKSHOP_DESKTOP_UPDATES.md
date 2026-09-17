# Desktop connection and work activity update

## Scope

This branch ports reviewed source changes onto the cleaned public history without importing prior development ancestry. It includes installed Electron lifecycle/package support, a per-call reconnecting MCP bridge, and an active-turn indicator with expandable durable activity history. Private task briefs, runtime data, credentials, logs, screenshots and unrelated project proposals are excluded.

The MCP bridge reconnects and authenticates for each new call; it never automatically replays a dispatched mutation. Installed Electron mode uses the bundled daemon and existing Workshop home, preserves a responding daemon, starts a missing daemon once with bounded readiness checks, and keeps UI exit separate from background work. Preview mode remains isolated.

## Activity semantics and data handling

The indicator requires a connected, fresh task read that reports working and nonempty runningEngineers. The label is Worker turn active; it does not prove token output, productive work or healthy native persistence. Polling is bounded to five seconds, freshness expires after fifteen seconds, request-start timestamps reject delayed state, and reduced-motion CSS stops animation. Waiting, blocked, terminal, disconnected or unknown states do not animate.

The existing outbox stores ordered task/turn/engineer activity records without a new database migration. Tool call/update correlation uses hashed opaque IDs; updates without starts remain valid observed events. Tool status, permission/auth/quota/uncertainty, message arrival and separately labeled lifecycle are preserved. Raw arguments/results, provider payloads, private prompts and reasoning are not added. Titles are bounded and redacted. Full committed messages remain in the conversation; the feed is not a full CLI transcript.

A task-scoped authenticated read API pages up to 200 records by sequence. The restricted preload exposes getActivity only. The collapsible feed deduplicates replay, isolates tasks, supports incremental history, and marks unavailable or pre-instrumentation history honestly. Lifecycle completion does not claim verification or infer missing tool results.

## Validation and release boundary

The source activity changes are staged for review, not qualified for installation. Fresh browser validation is blocked and the manifest is explicitly pending. Previous screenshots cannot validate this renderer. Tests cover bridge recovery, lifecycle, adapter event mapping, reasoning exclusion, content redaction, durable activity reopen/pagination, isolation/replay and terminal activity. Target-repository checks: Swift 163 tests with 8 opt-in skips and zero failures; publication-guard suite 39 passed; Web/Desktop 74 tests with 73 passed and one intentional failure at the pending fresh visual gate. Do not count opt-in skipped live tests as qualification.

Before an installed runtime update: finish supported web validation, bind final hashes, pass required tests, verify the bundle/icon and rollback backup, and ensure no active worker is interrupted. After installation, refresh the actual configured Codex MCP session and verify a fresh tool call plus current schema before end-to-end completion or task submission. Preserve the invocation/receipt journal. If no supported refresh works, record connection unverified and request the supported user action; do not kill Codex, retry unchanged failed probes or submit via another connection to conceal the missing check.

No automatic runtime-persistence repair, proposal promotion, new service, main-branch merge or history rewrite is part of this change.
