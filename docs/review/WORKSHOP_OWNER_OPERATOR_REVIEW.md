# Workshop: owner and computer operator review

Design review, September 15, 2026. Proposed behavior, not implementation evidence.

**Latest design:** see WORKSHOP_COMMUNITY_DESIGN.md and community-standalone/index.html. They supersede the simplified mock and any wording implying unsolicited peer collaboration. Collaboration is explicitly requested; there is no mandatory initial three-peer review. The target is now Electron, with web-first UI validation and quota-aware allocation.

## Agreed topology

- Devin Fusion owns delivery by default. The specified profile is Astra High plus native SWE-2 Medium.
- Kimi and DeepSeek are persistent peer engineers consulted for questions, reviews, or bounded work. They are not invoked for every task.
- A fourth participant, Astra, performs computer interaction only. Use Low for routine work and Medium for unfamiliar/difficult workflows; escalate after two unsuccessful attempts. Permission and connectivity failures are blockers, not reasons to increase reasoning.
- One retained session per engineer per task; resume it for follow-ups. Do not combine unrelated tasks into a single ever-growing conversation.
- No additional Workshop subagent spawning. Existing peers may inspect and discuss concurrently. All participants in a task share ONE worktree; only one participant may mutate it at a time. Separate tasks get separate worktrees.
- Fusion keeps responsibility for integration and verified completion. A small task can finish with Fusion alone.

## Material distinction requiring a decision

Native Fusion itself uses a lead and sidekick. One Fusion engineer/session in Workshop does not eliminate that internal workflow. The current mockup keeps the explicitly requested Fusion profile and discloses both models.

Question: Does “no subagents” allow Fusion's built-in SWE-2 sidekick, while prohibiting additional Workshop-spawned agents?

## Interaction rules

- One task thread holds conversation, ownership, evidence, and linked execution events.
- Direct help requests wake only their recipient. FYI posts and quota snapshots do not wake every engineer.
- Consultations block only dependent work. Requests and responses identify the relevant code revision and evidence.
- Astra receives outcome-level requests and reports observations, actions, evidence, uncertainty, and blockers. It does not become the delivery owner.
- Serialize computer actions on a shared desktop. Preserve task-specific operator context, but re-observe the actual screen when switching tasks or recovering.
- File reads, APIs, and command-line tests remain with engineers; actual browser/desktop interaction routes to Astra.
- Capacity snapshots have source and freshness. Quota-driven ownership transfer happens explicitly at a checkpoint; avoid unnecessary reassignment near completion.
- Use clean Workshop profiles without personal or repository custom instruction files or custom skills. Preserve native provider defaults and required capability instructions. Explicit collaboration requests still engage the existing peers.
- Track worktree ownership and lifecycle. Never clean up unrelated or uncommitted work automatically.

## Validation before calling this working

- Verify external Codex Computer Use access and its normal permission flow; general App Server support does not establish this capability.
- Test retained sessions, isolation, owner fencing, retry idempotency, operator serialization, and restart reconciliation.
- Compare Fusion-only execution with selective peer help using completed-task correctness, total usage, elapsed time, repeated investigation, and handoff failures.
- Measure Low versus Medium computer effort including retries and screenshots. Do not translate API costs directly into subscription-quota estimates.

## Polylane interpretation

The article advocates one agent per investigation and reports improvements after removing a staged multi-agent pipeline. It does not establish that parallel agents on independent tasks are harmful or beneficial; that is a separate design choice to measure. It does not discuss git worktrees or skill cleanup. Those recommendations here are Workshop-specific.

Source: https://polylane.com/blog/sub-agents-are-just-wrong/

## Review mockup

workshop-owner-operator-review.html depicts the native Mac workspace with four participants, task threads, conversation, ownership/evidence, and the shared computer queue. Switch between the navigation-bug example and a small label fix to see selective participation. All states are illustrative.

The September 13 WORKSHOP_BUILD_SPEC.md and bridge handoff predate these refinements and must be reconciled before implementation. This review does not change installed application configuration. The clean-start branch and its validation are described in WORKSHOP_CLEAN_START_VALIDATION.md.

## Shared task worktree: approved design refinement

Status: approved design; writer-lease enforcement is NOT implemented by the clean-start change.

Each task owns one Git worktree and branch. Fusion, Kimi, DeepSeek and the proposed computer operator refer to the same task workspace. Do not provision an engineer-specific worktree inside a task. Sessions remain separate per engineer; filesystem context is shared. Separate tasks use separate worktrees.

Fusion coordinates an exclusive writer lease. The service must enforce it, rather than relying on chat instructions. The lease identifies task, workspace, holder, request, epoch and operation. Acquire atomically; queue competing writers. Ownership of delivery and ownership of the writer lease are separate concepts: Kimi can hold the writer lease while Fusion remains delivery owner.

Mutating operations include edits, formatters, code generation, package installs, Git index/branch operations, and tests/builds that write outputs into the shared workspace. Classify arbitrary shell commands as potentially mutating unless an enforced read-only execution surface is available. A UI action which edits source must also hold the writer lease in addition to the desktop lease. Use a consistent acquisition order (workspace then desktop) to avoid deadlocks.

Read-only peers may inspect concurrently, but a review must name the observed revision and working-tree snapshot. A commit hash alone is insufficient when there are uncommitted changes. After writes, publish a checkpoint containing the changed paths, diff fingerprint and test evidence. Invalidate reviews based on stale content. Pause the writer if a reviewer needs a stable snapshot.

A crashed or timed-out writer does not automatically make reassignment safe. First stop or reconcile the process and its descendants and ensure the old writer can no longer mutate files. A database fencing epoch rejects stale tool requests but cannot stop an already-running native shell process. On uncertain process state, mark the workspace blocked. Never transfer a lease on expiry alone or reset dirty work to make recovery easier.

Native harness tools must pass an enforceable permission boundary. If a harness cannot deny writes to non-holders, serialize its entire execution turn as the conservative first implementation; interactive concurrent read-only participation then remains unavailable for that harness. Instructions alone are not sufficient.

The UI shows task worktree, delivery owner, active writer, queued writers and recovery status. Show planned/demo status until enforcement passes live validation. The mockup illustrates Fusion writing while Kimi reviews the same workspace.

Acceptance criteria:
1. All engineer cwd values resolve to the same task worktree; a second task resolves to a different worktree.
2. Two simultaneous writer requests yield exactly one grant; denied/queued requests cannot mutate through file tools, shell, MCP or desktop routes.
3. An expired/stale lease cannot write; restart retains dirty files and blocks until the prior writer is reconciled.
4. Read-only review remains available where enforceable; revision changes invalidate stale review evidence.
5. Formatters and write-producing tests hold the lease; shared-desktop work follows the fixed lock order.
6. Quota exhaustion releases ownership only after a saved checkpoint and process reconciliation; pending writes are not replayed blindly.
7. Every transfer is visible in the task thread; no automatic cleanup or per-engineer worktree creation occurs.
