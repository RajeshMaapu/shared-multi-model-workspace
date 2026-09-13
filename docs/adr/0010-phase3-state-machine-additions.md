# ADR 0010: Phase 3 state-machine additions (Paused → Researching, AwaitingArchitectureApproval → ReviewingProposal)

## Status
Accepted

## Context

Spec §8.2's state machine did not cover two flows Phase 3 needs:

1. After an engineer escalation pauses a task, the user may decide the work
   was actually substantial and convert it to the research path. §8.2 has no
   transition out of `Paused` into the proposal states.
2. When the user requests changes on a consolidated report, work must return
   to cross-review/consolidation. §8.2 has no transition out of
   `AwaitingArchitectureApproval` except approval.

## Decision

Two transitions are added and recorded here as deliberate deviations from
§8.2:

- `Paused → Researching` — triggered only by the user's
  `workshop.convertToResearch`; sets `phase = researchProposal` and wakes all
  participants with reason `research_proposal`.
- `AwaitingArchitectureApproval → ReviewingProposal` — triggered only by the
  user's `workshop.requestChanges`; Devin is woken with reason
  `revise_report` and the comment.

No other edges were added; every other transition follows §8.2 exactly.
