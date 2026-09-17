# Workshop native recovery repair — 2026-09-16

## Scope and evidence

Original development work and the independent repair snapshot are retained privately. This document describes the cancellation repair without local checkout paths.

`acp-cancellation.patch` contains only this repair relative to the copied Devin source; do not copy the entire snapshot over ongoing Devin work. Apply only after `git apply --check` against the destination and inspect any concurrent changes.

## Implemented

- Add `ACPClient.notify` with no JSON-RPC request id or pending continuation.
- Send `session/cancel` as the ACP v1 notification it is, rather than awaiting a nonexistent cancellation response.
- Replace task-group/uncancellable-continuation race with a monotonic deadline and cancellable polling of the original prompt completion.
- Close/reset the client when the deadline expires or cancellation delivery fails, allowing subsequent session reopening.
- Add tests for notification wire shape, unresponsive cancellation bounded return, and session reopening.

Official contract: https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/protocol/v1/overview.mdx

## Verified

Independent original-source ingress/bridge run: 24 tests, zero failures. Patched adapter/profile run: 24 tests, zero failures. These are local synthetic protocol/profile tests, not live Fusion containment qualification. Full patched Swift suite: 152 tests executed, 7 live tests skipped, zero failures, exit 0 (22.318 seconds). `git diff --check` passed.

## Remaining containment decision

The existing transport calls `setpgid` after Foundation launches the process, ignores its result, and claims group termination kills the whole tree. This is not sufficient for descendants that detach. The sandbox also grants writes across Workshop home, including other workspaces. No native v2 capability flag was enabled.

Recommended design for approval: each writer generation gets an isolated checkout and narrow write grants. The daemon alone promotes a validated change into the canonical task workspace after checking current generation, base revision, ownership and conflicts. Retired generations cannot publish changes. Durable journals govern crash recovery and prevent duplicate promotions. Native harnesses remain intact; task conversation remains shared. This changes the earlier exact-same-writable-path constraint and still requires proving filesystem containment, including links, Git common directories, descendant processes and control-plane credentials.

Alternative: retain one exact writable path behind a separately managed OS/VM boundary, qualify teardown before transfer, and separately qualify native CLI authentication/relay compatibility. Do not claim that process groups or advisory lock files supply that boundary.

## Required qualification before dispatch

1. Resolve the workspace design choice.
2. Implement/verify narrowed grants, generation fencing, crash recovery, stale writer rejection, symlink and detached-descendant cases. Verify native Fusion launch/model, editing, tests and recovery with scoped live evidence.
3. Keep `supportsIsolatedWorkspaceTurns` false until evidence covers its contract.
4. Prepare and review bridge/daemon upgrade plus migration/rollback; obtain separate installed-app approval required by Workshop-community/AGENTS.md.
5. Refresh the actual callable MCP schema and require schema_version, collaboration_mode and origin.
6. Persist the user-approved Team invocation for its actual originating task; submit once and save/verify the receipt. Private task identifiers are omitted from this public report.

## Project-specific handoff

The unrelated project brief and originating task identifiers are retained privately and omitted from this public source snapshot. No project work was submitted during qualification.
