# ADR 0007: Kimi runs as a single process (credential owner)

## Status
Accepted (verified by live probes, 2026-09-13)

## Context
Workshop's isolated Kimi profile links `profiles/kimi/credentials` (a
**directory** symlink) to `~/.kimi-code/credentials`. Kimi refreshes its OAuth
grant through that link — probe B observed `kimi-code.json` mtime change during
a turn. Concurrent Kimi processes could race the refresh and corrupt or
re-roll the grant.

## Decision
At most one Kimi harness process runs at a time in Workshop. The service
serializes turns per (task, engineer) via the `runningTurns` in-flight guard,
and `ACPHarnessAdapter` holds a single warm client per adapter instance. The
dispatch path claims subtasks before opening sessions, so concurrent Kimi
spawns cannot occur.

## Consequences
- Kimi throughput is one turn at a time; acceptable for a 3-engineer local
  workspace.
- Credential refresh writes flow through the directory symlink to the user's
  canonical `~/.kimi-code/credentials` — expected and required for token
  validity.
