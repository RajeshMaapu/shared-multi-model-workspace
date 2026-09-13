# ADR 0009: workshop-mcp closures must be nonisolated; ACP permission matching via option labels

## Status
Accepted (verified by live smoke run, 2026-09-13)

## Context

Two live-only defects surfaced in Phase 2b that deterministic tests could not
see:

1. `workshop-mcp` deadlocked on the first `tools/call`. Top-level `main.swift`
   code is `@MainActor`-isolated, so the `toolCaller` closure captured main-actor
   isolation. `await`ing it from a worker thread scheduled a hop to the main
   thread — which was blocked forever in `runStdio`'s stdin loop. The
   synchronous `output` closure never deadlocked because sync calls do not hop.
2. Devin's `session/request_permission` params carry only `toolCallId` — no
   `title`, no `_meta`. The tool name appears only inside option labels such as
   "allow calling workshop_post_message on the workshop MCP server". Matching on
   title/`_meta` alone silently rejected every real Devin MCP call.

## Decision

- Bridge closures are constructed inside a nonisolated factory function so they
  carry no actor isolation.
- The ACP permission policy treats option labels as an identity source: an
  `allow_*` option whose text mentions the workshop server is eligible.
- Diagnostic capture (`WORKSHOP_DIAG_DIR`) records raw permission params, ACP
  session updates, prompt results, and DeepSeek HTTP errors — these wire-shape
  facts are not discoverable from docs and were the only way to find both bugs.

## Consequences

Any future stdio/async bridge executable must build its async closures
nonisolated. Permission matching is looser for options that name the workshop
server (acceptable: the labels come from the local daemon's own tool list).
