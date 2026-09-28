# ADR 0019: Managed runtime lane with lane provenance

## Status

Accepted 2026-09-28 (extends ADR 0008)

## Context

Native harness startup failures — auth errors, relay timeouts, session
errors — left peers absent from tasks; DeepSeek could not read files.

## Decision

`ManagedRuntimeAdapter` generalizes the DeepSeek tool loop with
Workshop-owned `read_file`/`list_dir`/`write_file`/`exec` tools confined to
the fenced generation via `sandbox-exec`. Kimi falls back to it on its coding
API using the CLI's OAuth grant after classified native failures — auth
immediately, timeout/transport after two failures. DeepSeek runs on it
exclusively; Devin has none because the Fusion relay exposes no completions
route. Every message posted on the managed lane carries `lane: managed` and
packets label such authors. Managed lanes are unqualified for authoritative
writer turns until a capability record says otherwise (ADR-locked gate, see
capabilities.json / ADR 0013 revision 2026-09-28).

## Consequences

Peers stay present under native outages without pretending native tooling —
the fallback posts an `uncertain` note naming the failure class. Token
material stays in the CLI's credential files, read at request time and never
persisted. The managed lane has no native sidekick or skills; that is stated
on the task when a fallback occurs.
