# ADR 0004: Qualified Devin isolation relies on deprecated sandbox-exec

## Status
Accepted (risk tracked)

## Context
The qualified Devin Fusion profile used a process-scoped macOS `sandbox-exec` profile
to deny personal instruction directories. `sandbox-exec` is deprecated and may be
removed or behavior-changed in a future macOS.

## Decision
Phase 2's real adapter launcher will reuse the qualified approach as the baseline
while tracking the deprecation risk, with configurable workspace grants — copying the
qualification sandbox verbatim would deny edits to normal repositories.

## Consequences
Instruction isolation for Devin workers depends on a deprecated mechanism. Mitigations
to evaluate in Phase 2: Endpoint Security / Seatbelt alternatives, or vendor-provided
isolation flags. If sandbox-exec disappears, engineer processes lose their file-scope
deny layer — must surface, not silently weaken.
