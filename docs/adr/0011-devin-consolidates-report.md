# ADR 0011: Devin Fusion consolidates the report; user override via proposal approval

## Status
Accepted

## Context

§5.3 names Devin Fusion the allocation arbiter. The same authority is needed
one step earlier: after cross-review, someone must merge the published
proposals — preserving disagreements rather than silently resolving them —
into a single report the user approves.

## Decision

- Only Devin is woken with reason `consolidate` and only Devin's principal may
  call `workshop_submit_report`; other engineers get
  `-32005 userAuthorityRequired` with the message "the consolidated report is
  Devin Fusion's responsibility".
- If Devin's probe is unavailable, the task waits: a system event records
  "Consolidated report waits for Devin Fusion (unavailable: <detail>) or a
  user override". No other engineer is promoted to arbiter — substituting one
  would quietly move allocation authority, which §5.3 reserves.
- The user override is `workshop.approveArchitecture` with
  `scope = "proposal:<id>"`, which treats a published proposal as the report.
- The same arbiter rule applies at allocation time: only Devin or the user may
  call `workshop_assign_subtask`; Kimi/DeepSeek get `-32005`.

## Consequences

Consolidation is a single-writer step, so report revisions are totally ordered
(`UNIQUE(task_id, revision)`); a later revision invalidates prior approval
(T08). Disagreements survive as data — the report's `disagreements` field and
the review messages under each proposal remain visible in the UI.
