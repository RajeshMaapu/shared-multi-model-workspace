# ADR 0020: Workshop-owned task memory; native sessions disposable

## Status

Accepted 2026-09-28

## Context

`session/load` failed 12 times in one task; Kimi ran six cold native
sessions; the owner got eight read-only discussion turns while a revision was
open.

## Decision

A per-(task, engineer) ring of the last eight turn records plus the latest
checkpoint, own recent messages, latest result revision and peer dispositions
is rendered into every packet (bounded at 6 KiB). Results are revisioned and
reviews bind to the latest revision. Owner wakes while a revision is open run
as authoritative writer turns. The streamed native reply of a turn that
posted through tools is stored as `turn_summary` and excluded from packets,
cursors and default reads. `session/load` stays best-effort.

## Consequences

A fresh native session is a note, not a task event — cold starts no longer
lose context. Packets are bounded by count and bytes with inline images
stripped.
