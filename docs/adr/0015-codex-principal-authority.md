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
  `workshop_post_message`. Every other tool returns `-32005`
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
- Prompt-level idempotency (`codex-<sha256[:32]>`) depends on the model
  following the skill; run 2 of the live smoke emitted the untruncated hash
  and created a second task. Service-side dedupe is exact-key only — callers
  that truncate inconsistently get distinct operations (documented in
  validation.md; not a service defect).
