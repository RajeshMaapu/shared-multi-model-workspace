# ADR 0013: Fencing at the tool boundary; fenced artifact quarantine

## Status
Accepted

## Context

Subtask ownership uses compare-and-swap with a `generation` that bumps on
reassignment (T05). After a takeover, the previous owner's runtime may still
be executing with stale credentials — its late results must not silently
merge into the task.

## Decision

- The context packet tells each engineer its `ownership_generation`;
  `workshop_report_result` requires it and `workshop_publish_artifact`
  accepts it. A stale generation is refused with `-32004`.
- A refused artifact's bytes are still copied to
  `artifacts/<task>/fenced/<hash>-<name>` — quarantined, listed in a system
  event ("Fenced stale result from <engineer> (generation N, current M)"),
  and never entered in the task's artifact table.
- Fencing lives at the tool boundary because that is the boundary the
  service controls. **Native harness tools cannot be fenced by the
  service** — an engineer's own shell/file tools inside its worktree run
  outside our tool dispatch. The worktree write grant remains the boundary
  there: reassignment plus process termination removes the stale owner's
  ability to write, and the CAS on result/artifact rows removes the ability
  to publish.
- `workshop_report_result` is idempotent on `(subtask, generation)` —
  a retried report returns the original message (T06).

## Consequences

Stale work is never lost (it is quarantined for inspection) and never merged.
The acknowledged gap — in-worktree writes by a not-yet-dead stale process —
is bounded by the 10 s cancellation bound plus process-group kill on
reassignment.
