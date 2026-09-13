# ADR 0002: System SQLite C API

## Status
Accepted

## Context
The spec allows "a maintained Swift wrapper such as GRDB … or SQLite's C API if already
available". GRDB would be the only third-party dependency.

## Decision
Use `import SQLite3` (system `libsqlite3`) behind a thin `Database` class: typed
bindings, `BEGIN IMMEDIATE` transactions, `sqlite3_changes()` for the CAS claim.
Zero third-party dependencies.

## Consequences
Direct control over durability (`journal_mode=WAL`, `synchronous=FULL`,
`foreign_keys=ON`, `busy_timeout=5000`) with no dependency pinning. The cost is a
hand-rolled repository layer, which Phase 1 accepts; GRDB can be reconsidered when the
schema grows.
