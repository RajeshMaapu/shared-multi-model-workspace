# Workshop community: approved visual and interaction design

2026-09-15 · Design only. This document supersedes conflicting earlier topology and workflow wording. No production app, global skill, provider configuration or subscription is changed by this revision.

## Final decisions

1. Codex is the preferred task entry point. Explicit `$team` submits a scoped brief to Workshop. Ordinary Codex conversation does not dispatch work.
2. Devin Fusion owns delivery by default. Kimi and DeepSeek are peers who can discuss, investigate, propose, reject and adversarially review within the shared task conversation **when collaboration is requested**. A small owner task does not wake every engineer. The briefly proposed mandatory three-person initial review is superseded.
3. Astra is a fourth participant dedicated to computer interaction. Low reasoning for routine work; Medium for unfamiliar/difficult work or after two unsuccessful attempts. Permission/network failures are blockers, not reasoning escalation triggers. Astra is not automatically a general reviewer.
4. One retained engineer session per task, one shared worktree for that task, and one active writer. Separate tasks have separate worktrees. Fusion retains delivery accountability when a peer takes an implementation assignment.
5. Shared account capacity is operational input to assignment and reassignment, visible to every engineer and to the user. Unknown quotas stay unknown; shared pools are not counted twice.
6. Clean Workshop profiles exclude unrelated personal/repository custom instructions. Native capability instructions remain. The explicitly approved web-first UI rule below is an intentional Workshop-owned exception.
7. Final UI target is a macOS Electron app. The current implementation is SwiftUI; the migration is proposed, not performed.

## Visual target

Use `workshop-approved-reference.png`: purple top bar, narrow application rail, aubergine task-space/engineer sidebar, central message/task list with composer, and a right-hand task conversation. Preserve the five tabs: Conversation, Ownership, Proposals, Decisions, Files. Avoid exposing adapter, protocol or lease-generation details in the main conversation.

The new `community-standalone/` preview follows this layout. It adds Astra and a discreet Team capacity entry, shows Codex provenance on the task, and uses Ownership for writing/availability detail. A collaboration example and a small owner-only example are both selectable. All conversations, assignment states and capacity scenarios in the preview are fixtures, not live agent activity.

Source geometry: 1586×992, top bar 46px, app rail 88px, sidebar 241px, center approximately 464px, remaining width for conversation. Compact desktop: 980×680. The narrow web layout stacks content for inspection; a full mobile product is not in scope.

## Codex → team skill → persisted task → visible collaboration

### What was actually inspected

- Existing skill: `~/.codex/skills/team/SKILL.md`, name `team`.
- `$team` is its explicit invocation. `/team` and `/my-team` are textual aliases in the skill, **not verified registered slash commands**.
- Installed MCP config has server `workshop`, launching the installed `workshop-mcp` with `--principal codex` and a token-file reference. Token contents were not read or copied.
- Live read-only `workshop_list_tasks` succeeded. `workshop_read_messages` for `<redacted-task-id>` returned committed DeepSeek messages at seq 3 and 4 and a verification-pending event. This is evidence of persisted ingress/reply data, not a fresh three-model test or proof that the installed UI rendered it.
- `CollaborationService.createTask` atomically persists task, root message, participants, subtask, outbox and idempotent receipt. Research/proposal currently wakes each requested participant; execution dispatches through the existing execution path.
- `WorkshopApp/AppState.swift` loads selected task messages through `readMessagePage` and subscribes for refresh. `TaskPaneView` renders those messages. This is code evidence for the app display path; no live installed-app UI verification was performed.
- Earlier local Codex bridge tests were included in the passing 126-test clean-start suite. No new task or quota-consuming worker was launched for this design inspection.

### Required future flow

1. Codex prepares a concise brief, source references, acceptance criteria, requested phase and collaboration intent. Preserve existing authorization; do not forward raw conversation history or secrets.
2. Submit `workshop_create_task` through the existing MCP bridge. Add an explicit collaboration mode in a future schema (owner-only or requested peers) so research and collaboration are not conflated. Do not imply this field already exists.
3. Persist the accepted brief and request ID before dispatch. Return the real task ID, committed sequence, status and tested deep link. “Created” must not imply “all engineers running.”
4. Persist an origin binding: source Codex task ID, ingress request ID, Workshop task ID, last acknowledged sequence. This cross-application binding was **not established by the present inspection** and should be added/verified before promising automatic return messages.
5. Owner-only: Fusion investigates, implements and reports in the task. Peers remain available. If additional collaboration would help beyond the request, Fusion asks for that scope instead of silently spawning a debate. A capacity-based transfer is an implementation reassignment, not redundant joint research.
6. Requested collaboration: the service wakes only the requested existing peers. Each can post a concise proposal or question, then review another contribution. Every user-facing message, proposal, rebuttal, rejection, review, assignment, decision and final outcome appears under the same Workshop task ID.
7. Fusion consolidates the recommendation, evidence and disagreements. Design requests return a proposal for user approval. Already-authorized execution continues without inventing another approval gate. Proposed completion condition: requested peers have responded or are explicitly marked unavailable, material findings addressed or escalated, and one owner accepts delivery responsibility. Unanimity is not required.
8. If a requested peer is unavailable, record the blocker and ask whether to wait or proceed with reduced participation; never claim full review. A task-scoped timeout can trigger that decision, not silently waive requested collaboration.
9. Follow-ups append to the existing task by its ID. Notifications and cursor-based reads use durable event sequences. Native tool actions attach concise evidence; private reasoning does not belong in the conversation.

### Existing skill gaps to reconcile later

The global skill still describes research by all three for a new idea and lists three engineers without the dedicated operator. Do not edit it in this design-only scope. A future scoped update should record explicit collaboration intent and the owner-first policy. Its current hash recipe derives a key from title/objective/phase; identical intentional new tasks can collide. Prefer a persisted invocation identifier reused only for retries, with a payload hash for conflict detection. Do not blindly resubmit after timeout. Update the skill and service contract together and regression-test old clients. No automatic callback into Codex is claimed today.

## Community participation without perpetual chatter

Posting and inference wakeups are different operations. Engineers may post relevant work, ideas and reviews freely within an authorized collaboration task. A direct question, explicit review request, dependency-ready event or user message wakes its recipient. FYI posts, reactions and capacity refreshes update shared state without waking everyone. Coalesce pending events and include an unread-sequence cursor plus compact task state. Respect budget/turn limits; at a limit, checkpoint and surface “discussion paused,” preserving unresolved questions. Do not fabricate periodic messages to keep sessions or caches warm.

For a requested group review, all requested general peers receive the initial wakeup. The owner may bound review rounds and summarize disagreement rather than forcing consensus. Small owner tasks have no automatic initial group wakeup. Astra is called for browser/desktop evidence as needed.

## Shared worktree and writer ownership

The task's workspace record holds repository, branch, worktree path and current state. All participants receive the same task path. The service grants one exclusive mutation lease, coordinated by Fusion. Peers can inspect/discuss concurrently only if native tools can enforce read-only access; otherwise serialize entire turns for those harnesses.

Edits, formatters, installs, Git mutation, build/test outputs and computer actions that change source all require the writer role. A shared desktop requires its own exclusive operator lease. Acquire workspace then desktop consistently when both are needed. Pin reviews to the commit plus working-tree diff fingerprint. A commit alone does not identify dirty files.

Before transfer: save context/evidence, reconcile pending operations, ensure the old native process and descendants cannot still write, persist the transfer, and only then grant the next writer. Expired database fencing cannot stop an already-running shell. If uncertain, block recovery visibly; do not overwrite or reset dirty work. Writer enforcement remains planned.

## Quota-aware allocation and reassignment

Maintain account/window records, not fictitious independent per-agent allowances. Suggested fields: pool ID, provider, opaque account binding, participating model routes, limit/window kind, remaining value and unit when supplied, reset time, observed-at, source, confidence, current workloads and reservations. Keep secrets outside the shared record.

Fusion lead and Astra operator share a Codex account/window when configured to use the same account. Cognition's native sidekick uses its own provider pool. Kimi may expose a subscription allowance; DeepSeek may expose balance/rate limits rather than a comparable token percentage. Treat those dimensions separately. A free-priced model can still have throughput or account limits; do not assume unlimited availability.

Every engineer can query the same normalized snapshot and sees the relevant pool state in its next task packet. Publish meaningful changes to the board; wake active owners on material exhaustion or stale-to-known changes, not all idle peers on each refresh. A stale snapshot displays its timestamp and must not be treated as current. Missing telemetry is Unknown, never zero or unlimited.

Before assigning work, Fusion considers required tools/model capability, account headroom, in-flight workload, expected remaining work and handoff cost. Configure warning/headroom/stop rules by pool and task risk; no numerical threshold is user-approved yet. Reserve estimated headroom where practical and reconcile with measured use; estimates are not billing records. If all eligible pools are low/unknown, checkpoint and ask/wait rather than spin retries or spend/reset credits automatically.

When an engineer is low: stop granting new work, checkpoint at a safe boundary, choose a capable engineer with fresher sufficient capacity, and perform the writer transfer above. The implementation assignee changes; Fusion retains delivery accountability if it still has enough capacity to coordinate. If Fusion itself cannot run, surface an owner-unavailable decision rather than pretending it reviewed the replacement's work. Resume safely after reset; avoid assignment oscillation with a configurable cooldown and completion-cost comparison.

The preview exposes Unknown states plus an explicitly labeled low-capacity scenario. Its simulated transfer shows the checkpoint/reconciliation order. There is no live quota integration or scheduler change in this revision.

## Approved shared UI instruction (proposed policy text)

> For every UI design or change, first build the intended behavior as a web app. Use the computer-use skill to compare it against the approved visuals and exercise its intended interactions. Save the reference, rendered evidence, findings and retest result in the task. Carry the UI into the final macOS Electron app only after that web validation passes. If computer-use validation is blocked, report the blocker and do not claim UI validation or proceed with the carry-over.

This minimal instruction is user-approved and belongs in a versioned Workshop-owned shared instruction packet, not a personal global AGENTS.md. Preserve native capability instructions. The current design-only turn records the policy in `WORKSHOP_SHARED_UI_POLICY.md`; it does not modify runtime prompts.

Proposed enforcement: UI work cannot transition to Electron-ready without reference artifact, web revision, screenshot/interaction evidence and explicit passed result bound to that revision. Any subsequent UI change invalidates that result. An artifact's existence alone is not proof of verification. Preserve external computer-use qualification gates; this session's browser tooling does not prove the future Astra bridge works.

## Electron migration plan and tradeoffs

Current source is SwiftPM (`Package.swift`) with SwiftUI/AppKit `WorkshopApp`, a separate Swift daemon, SQLite store, MCP bridge and adapters. This is not Electron.

Proposed path: keep the daemon, store, task IDs, protocols and native adapters. Build the approved web UI separately against a typed client interface. After web QA, host the same renderer in Electron. Electron's main process owns the UDS client and lifecycle; a narrow preload bridge exposes task operations and event subscriptions. Do not expose generic shell execution, tokens or unrestricted filesystem APIs to the renderer. Package trusted local assets, use context isolation and renderer sandboxing, validate IPC senders and payloads, and constrain navigation/permissions. These choices follow Electron's [process model](https://www.electronjs.org/docs/latest/tutorial/process-model) and [security guidance](https://www.electronjs.org/docs/latest/tutorial/security).

Rebuild native shell features deliberately: deep links, notifications, menus, keyboard shortcuts, tray behavior, launch/background-helper integration, accessibility and signing/notarization. Preserve the distinction between quitting the UI and stopping work. Define one owner for URL registration and daemon startup when Swift and Electron bundles coexist. Test database/schema compatibility and rollback before swapping installed apps.

Tradeoff: renderer reuse improves visual consistency and browser-based QA, while Electron adds Chromium memory/bundle cost and a new IPC/security boundary. Existing SwiftUI views do not become Electron automatically. Native packaging, permissions, wake/reconnect and VoiceOver still require separate tests after browser QA. No full migration is authorized or performed here.

## Acceptance criteria for later implementation

- Explicit `$team` creates exactly one durable task; retry returns the same receipt; intentional identical new requests can create distinct tasks.
- Owner-only small task wakes no general peer unnecessarily. Explicit collaboration wakes requested peers and preserves their contributions and disagreements in the task.
- No mandatory initial three-engineer review. Astra only joins for computer work.
- UI displays committed replies after reconnect without duplication; Codex follow-up maps to the same task; no unverified return-channel promise.
- Shared-worktree path is identical for participants; separate tasks differ; concurrent/stale writers cannot mutate; dirty recovery is preserved.
- Capacity snapshot is visible to all, includes source/freshness/window, and shared pools are counted once. Unknown/stale values never masquerade as available quota.
- Quota-based transfer preserves checkpoint/evidence, reconciles active writes, changes assignee atomically and logs the decision.
- Web-first policy blocks Electron carry-over when validation is missing, stale or failed. Later native packaging tests remain required.

## Delivery status

Design/spec/icon and dependency-free browser prototype are deliverables. The earlier clean-start implementation remains separately committed at `94baa5c`; its 126 tests / 7 skipped live tests are not evidence for these newly proposed runtime behaviors. No production code changed after the design-only clarification. See `community-standalone/design-qa.md` for actual UI checks and limitations.
