# Workshop clean-start implementation and shared-worktree review

Date: 2026-09-15. Branch: `codex/workshop-clean-start-20260915`.
Base: `27eac6b`. Review-only implementation; no merge, installation, deployment, personal configuration edit, or running-service restart.

## Outcome

The branch implements stronger clean-profile boundaries and preserves explicit peer collaboration. The shared-worktree/single-writer decision is incorporated in the design and mockup only. This is not a claim that the complete owner/operator architecture is implemented or live-qualified.

## Approved design

- Devin Fusion is delivery owner by default. Requested future launch: `~/projects/fusion-codex-relay/bin/devin-fusion --model fusion-gpt-6-astra-high-sidekick-swe-2-medium`.
- Keep the current runtime model and native Fusion sidekick unchanged in this patch. The installed profile inspected earlier used Fable 5.1 Medium and native SWE-2 Medium; selecting the requested wrapper remains separate work.
- Kimi and DeepSeek are existing peers. Small tasks can stay with Fusion. Explicit user requests for joint research/review must consult existing requested peers and incorporate replies, preserving disagreements.
- One shared Git worktree per task, shared by its participating engineers; separate tasks get separate worktrees. One active writer, coordinated by Fusion and eventually enforced by the service. Concurrent read/discussion is allowed where a read-only boundary can be enforced.
- Proposed Astra computer operator: Low for routine tasks, Medium for unfamiliar/difficult tasks or after two unsuccessful attempts. Permission/network failures are blockers. A shared desktop has one active operator; this is distinct from the workspace writer lease.
- No additional Workshop-spawned subagents. Native Fusion's lead/sidekick remains unchanged pending clarification of that exception.

## Implemented on this branch

| File | Change |
|---|---|
| `Sources/WorkshopAdapters/Profiles.swift` | Versioned `profiles/clean-v2` namespace; owned deterministic minimal configurations; Devin custom instruction imports disabled; allowlisted subprocess environment; Kimi skills drift rejected without deletion; owned-profile symlink drift rejected before configuration writes. |
| Same file | Existing sandbox policy expanded to conventional custom instruction/discovery paths for Devin and Kimi; libc realpath canonicalization; ordinary source reads and synthetic native skill paths remain readable. Personal credential references retained. |
| `Sources/WorkshopAdapters/ACPHarness.swift` | Reject old profile bindings; close active native client when changing tasks; regenerate sandbox against actual task cwd. |
| `Sources/WorkshopService/Adapter.swift` | New bindings revision 2; minimal clean-start and existing-peer collaboration instructions. |
| `Sources/WorkshopService/CollaborationService.swift` | Known legacy bindings block execution with visible explanation, preserve history and require a fresh task brief. |
| `Sources/WorkshopAdapters/DeepSeekAdapter.swift` | Separate clean-v2 history namespace; reject legacy bindings; initial system instruction separated from task/peer content, which is supplied as user context. |
| `docs/review/WORKSHOP_OWNER_OPERATOR_REVIEW.md` | Updated design, writer-lease requirements, recovery constraints and acceptance criteria. |
| `docs/review/workshop-owner-operator-review.html` | Updated illustrative UI: shared task workspace, active writer, writer queue, clean instructions; pending runtime capabilities labeled. |

## Validation performed

Command: `swift test`, run in `<isolated-checkout>` with access to Swift compiler caches.

Result: **126 tests executed, 7 skipped, 0 failures**. The seven skipped tests are the opt-in live provider tests; they are not counted as demonstrated live compatibility. Existing Swift 6 concurrency warnings remain.

New regression coverage checks:
- Environment hooks and custom provider selectors are excluded.
- Nonempty Kimi custom skill directory fails closed without deleting its contents.
- A symlinked owned config fails before overwriting the personal target.
- Actual macOS sandbox denies synthetic instruction canaries, including task-local skills; permits ordinary source and a synthetic native skill path.
- Generated Devin configuration keeps model/native-sidekick settings while disabling custom instruction imports.
- A legacy binding is preserved and never dispatched.
- Explicit collaboration dispatches to existing peers with the collaboration instruction preserved (fake adapters).

The sandbox test initially failed because `/var` and `/private/var` did not match; realpath canonicalization corrected that failure. The final full suite includes that regression.

`git diff --check` passed. Mockup script syntax was checked with Node and a standalone HTML export generated. No visual browser QA or real model collaboration is claimed. The OneContext history search for Workshop clean profiles returned no matches; repository and session artifacts supplied the context.

## Remaining qualification and implementation

1. **Native compatibility:** run Devin/Kimi ACP startup, authentication, session new/load and end-to-end canary probes under the changed profiles. Synthetic file-access probes do not prove a harness's effective loaded instructions. `sandbox-exec` remains a deprecated macOS mechanism; this is a local boundary, not a newly established vendor-supported profile feature.
2. **Discovery coverage:** current deny rules cover known conventional paths, not arbitrary custom discovery mechanisms or remotely supplied instructions. Provider native capability instructions need live validation. Instructions in task data can still be adversarial; filesystem filtering is not a complete prompt-injection defense.
3. **No-child guarantee:** prompt instructions prohibit additional agents, but this patch does not mechanically disable all native subagent tools. Devin's existing `subagents_enabled` remains true to avoid silently breaking the native sidekick.
4. **Clean history:** known legacy bindings are blocked, not erased. The user supplies an explicit new brief. Arbitrary old task messages are not automatically sanitized. DeepSeek's pre-existing checkpoint compaction still deserves separate authority/tool-pairing review; this patch separates initial context, not every future compaction boundary.
5. **Writer lease:** not implemented here. Per-task ACP cwd is not proof of a real Git worktree, shared DeepSeek execution context, or single-writer enforcement. Implement a service-owned workspace record and mutation gate across all native tool, shell, MCP and computer routes. A database lease cannot fence an already-running shell by itself. See the design acceptance criteria.
6. **Computer operator:** Astra is not present in the current engineer enum/runtime. External-client Codex Computer Use, its permission path, retained operator sessions and desktop queue remain unqualified/planned.
7. **Collaboration correctness:** fake adapters verify routing/instructions, not actual model compliance or a high-quality synthesis. Run an explicit joint task and verify referenced peer responses before accepting this behavior live.
8. **Cache/token performance:** no provider cache-hit measurement or quota-cost claim was made in this run. Persistent sessions and stable prefixes are design intent; collect provider-supported usage evidence after live compatibility passes.
9. **Adoption:** installed Workshop profiles and processes are unchanged. Review branch first. Qualify a separate test instance before any installed-runtime migration. Keep old profiles/history for recovery; never delete them automatically.

## Review package

- `WORKSHOP_OWNER_OPERATOR_REVIEW.md`: updated design and writer acceptance criteria.
- `workshop-owner-operator-standalone.html`: openable Mac workspace mockup.
- `workshop-owner-operator-review.html`: editable inline source.
- `WORKSHOP_CLEAN_START_VALIDATION.md`: this report.

These documents supersede conflicting topology/clean-profile wording in the older September 13 build spec; they do not rewrite every historical specification. No live guarantee should be inferred from the mockup.
