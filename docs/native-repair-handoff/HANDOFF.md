# Workshop native recovery repair — 2026-09-16

## Scope and evidence

Original Devin WIP preserved at `~/projects/Workshop-community`. Independent source snapshot and applied repair: `/private/tmp/workshop-native-repair-20260916`, branch `codex/native-cancellation-recovery`.

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
6. Persist the exact Team invocation for source task `01a0ad3f-8cc9-7b51-9ea8-4f5bd8014cf7`; submit once and save/verify receipt.

## Preserved Thenali brief

Fusion owner_only, execution phase; no peer wakeups. Deliver both:

1. Evidence-backed table of ALL data RL actually sees for SPX shadow entry decisions: runtime versus intended config, freshness/missing/defaults, inference versus learning targets, actions/gates, cash-session cadence and whether shadow outcomes update the serving policy. Revalidate the prior findings rather than treating them as current proof.
2. Alert Evidence and notification for EVERY attempted RL shadow-entry initiation regardless outcome, titled “Reinforcement Learning Trade Entry — Long/Short”. Include actual spread legs/entry details/status; distinguish pending/blocked/failed from corroborated opened shadow FIRE; never invent values. One durable notification per attempt with status updates and regression coverage. WITHHOLD alone is not an entry attempt.

Reference evidence task: `01a0ad41-0486-7a41-a849-962d47870336`. No live Thenali runtime/trades, deletion or merge authorized. Use isolated worktree and existing branch/PR rules; preserve pinned policy semantics. No Workshop submission has been made by this repair task.
