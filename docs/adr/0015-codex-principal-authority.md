# ADR 0015 — Codex principal: limited authority, app-only approvals

## Status

Accepted (Phase 5)

## Context

Codex is the user's conversational entry point into Workshop (spec §2.1): it
prepares a brief and submits it through the `workshop` MCP server. It must be
able to create durable tasks and post follow-ups, but it is not a user and not
an engineer. Giving the bridge a `.user` principal would let any process holding
the Codex token approve architecture, accept tasks, and reassign work — exactly
the authority the spec keeps in the app (§9.3).

## Decision

- New `Principal.codex` encoded as `"codex"`; display name "You (via Codex)".
- The daemon generates `profiles/codex/token` (32 random bytes hex, mode 0600,
  preserved across restarts) alongside the engineer tokens.
- `CollaborationService.authenticate` resolves the Codex token to `.codex`.
- `callTool` enforces a Codex allowlist — `workshop_create_task`,
  `workshop_list_tasks`, `workshop_get_task`, `workshop_read_messages`,
  `workshop_post_message`, `workshop_select_review_seed`, and
  `workshop_read_review_file`. The two review-seed tools are limited to tasks
  whose recorded ingress source is `codex`. Selection requires the exact
  immutable owner snapshot generation and its verified digest; it only seeds
  fenced review and revision turns. Reading is limited to changed, regular
  UTF-8 files under 64 KiB. Neither operation promotes files or accepts work.
  Every other tool returns `-32005`
  (`userAuthorityRequired`).
- The user-authority RPC methods (`approveArchitecture`, `requestChanges`,
  `chooseAlternative`, `acceptTask`, `pauseTask`, `resumeTask`, `cancelTask`,
  `convertToResearch`, `reassignSubtask`) already call `requireUser`, so an
  injected "approve" through a Codex-authenticated connection is refused with
  `-32005` and changes nothing (T27 — tested at both layers).
- Codex-posted messages are stored as `author_kind = user` with
  `{"via": "codex"}` in `structured`; the app renders them "You (via Codex)".
  They wake the task owner exactly like a user message.
- The §8.4 receipt from `workshop_create_task` reports `task_id`,
  `committed_seq`, `state`, `status` (created|queued|running), and `deep_link`
  only when `LSCopyDefaultHandlerForURLScheme` verifies `workshop://` resolves
  to `ai.maapu.workshop`; otherwise `deep_link` is null and `deep_link_note`
  says why. `operations` rows record `principal = 'codex'`.

## Consequences

- The MCP bridge holds no authority of its own; enforcement lives in the
  service, so a hand-written JSON-RPC client with the Codex token is equally
  bounded.
- Token file theft grants task-creation and read access, not approvals —
  still reason to keep the file 0600 and the socket 0700.
- For Codex-origin tasks, token access can also choose which already sealed
  owner discussion snapshot peers review. The selection is recorded as a
  task-visible system event. User-only architecture approval, assignment,
  promotion, and acceptance remain unchanged.
- Prompt-level idempotency (`codex-<sha256[:32]>`) depends on the model
  following the skill; run 2 of the live smoke emitted the untruncated hash
  and created a second task. Service-side dedupe is exact-key only — callers
  that truncate inconsistently get distinct operations (documented in
  validation.md; not a service defect).

## Idempotency-key normalization

Codex occasionally emits the full 64-hex SHA-256 instead of the 32-hex recipe
in the team skill. `createTask` therefore normalizes, for principal `codex`
only, any key matching `codex-<33-64 hex>` to `codex-` + the first 32 hex
characters before hashing and storing it — both spellings of the same brief
dedupe to one task. Keys outside that shape are used verbatim; user-principal
keys are never rewritten. Covered by `CodexBridgeTests.testCreateTaskKeyNormalization`.

## Revision 2026-09-28

The allowlist now stands at, verbatim:

- `workshop_create_task` — task entry (§8.4); idempotent by invocation key.
- `workshop_list_tasks` — read-only task inventory.
- `workshop_get_task` — read-only task detail.
- `workshop_read_messages` — read-only committed history; advances the
  task's acknowledged cursor.
- `workshop_post_message` — follow-up appends as `user` with
  `{"via": "codex"}`; server-side `idempotency_key` dedupe since Phase 3.
- `workshop_select_review_seed` — added in the sealed-snapshot hot fixes;
  chooses a digest-verified owner discussion snapshot for fenced review on
  Codex-originated tasks only.
- `workshop_read_review_file` — added with it; bounded read of changed
  regular files inside that snapshot for adapters without a filesystem.
- `workshop_wait_for_events` — added in Phase 3 (G-A3): bounded read-only
  long-poll (≤120 s) so a Codex turn can wait for replies without a push
  channel; also advances the acknowledged cursor.

The allowlist is pinned by `CodexBridgeTests.testCodexAllowlistMatchesADR0015`;
any change requires a revision of this ADR.

## Revision 2026-09-29

The allowlist gains `workshop_resume_task`, origin-bound (a `task_ingress`
record with `principal=codex` is required; otherwise -32005). Resume-only:
it restarts a paused or recoverably-blocked execution task and re-wakes
the owner; it does not accept, promote, cancel or reassign — those remain
user-only. A call on a task that is not paused/blocked returns
`resumed:false` with a reason rather than an error, and an optional
`idempotency_key` replays the stored receipt through the `operations`
table. The resume system event is recorded as "Task resumed by You (via
Codex)". Rationale: the Codex monitor observes the task lifecycle and
should be able to restart a paused/blocked task it submitted without a
human relay; accepting results stays a human decision. Catalog version 4.
