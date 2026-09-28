# ADR 0018: Sandbox is the enforcement boundary; prompts decided by kind against a capability manifest

## Status

Accepted 2026-09-28 (amends ADR 0013 consequences)

## Context

Workshop answered ACP `session/request_permission` with title-prefix
heuristics and later a hardcoded command allowlist; 19 exec rejections in one
task forced the user to run tests by hand.

## Decision

Devin launches with config `permissions.allow` for read/grep/glob/exec/edit
and `mcp__workshop__*` under `--permission-mode accept-edits`; Kimi launches
`--auto`. The per-generation `sandbox-exec` profile is the hard boundary —
writes only inside the generation, reads of the Workshop home denied except
the generation and the profile. Residual prompts are decided by ACP
`toolCall.kind` against a per-turn `TurnCapabilityManifest`, and only sandbox
scope expansion (`request_scope`) is refused. No title, command or task-id
matching exists in policy code.

## Consequences

Engineers run tests and edit without prompts. A write outside the generation
fails at the OS level and is visible in the turn. The manifest exists so
later phases can tighten fetch/edit per task without touching the adapter.
