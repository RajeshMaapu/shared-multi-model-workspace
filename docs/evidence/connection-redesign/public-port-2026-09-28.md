# Public port CI — 2026-09-28

Tree-level port of the private connection-redesign line onto the clean
public history. Four port commits on `public/connection-redesign`:

1. `35f2aa2` — workspace-ref recovery and native generation repair
   hot-fixes (private range 34b9dda..f268327, 46 commits)
2. `3358d6b` — Phase 1: loopback HTTP MCP endpoint, sandbox permission
   boundary, result revisions, wakeup policy (f268327..3551937)
3. `3a0447b` — Phase 2: task memory, owner writer coalescing, turn
   summaries, activity pruning (3551937..7dfa1a3, 9 commits)
4. `a262051` — Phase 3: managed runtime lane, event long-poll,
   qualification records, review-seed rule, live-run fixes
   (7dfa1a3..fdd60cd, 51 commits)

Each commit's tree is the exact source-tree state at the named commit,
plus the retained public-only files (publication guard, git hooks,
publication-safety rule, SecurityTests, WORKSHOP_DESKTOP_UPDATES.md,
discussion GIF) and a union `.gitignore`.

## Per-commit gates

| Commit | swift build | swift test |
|---|---|---|
| 35f2aa2 | ok | 209 executed, 8 skipped, 0 failures |
| 3358d6b | ok | (not run — mid-sequence tree) |
| 3a0447b | ok | (not run — mid-sequence tree) |
| a262051 | ok | see totals below |

## Local CI at the final tree (a262051)

- `swift test`: **331 executed, 9 skipped, 0 failures** (85 s).
- `node --test Web/tests/*.test.mjs Desktop/tests/*.test.mjs`:
  **74 tests, 72 pass, 1 fail** — the failure is
  `web validation gate accepts the live repo manifest`
  (Desktop/tests/policy.test.mjs), which requires the ignored artifacts
  `Web/web-validation.json` evidence `.build/web-qa/evidence.json` and
  screenshots. The manifest itself was kept from `origin/main`
  (`result: passed`, renderer sha256s verified identical to this tree);
  only the local evidence files are absent in a fresh clone —
  environmental, not a code regression.
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s
  Tests/SkillTests -v`: 10 tests, OK.
- `python3 -m unittest discover -s Tests/SecurityTests -v`: 39 tests, OK.
- `git diff --check origin/main...HEAD`: clean.

## Dropped public-line files

- `Sources/WorkshopAdapters/ACPPermissionPolicy.swift` and
  `Tests/AdapterContractTests/ACPPermissionPolicyTests.swift` — do not
  exist in the ported tree; the ported `ACPClient.swift` carries the
  permission-decision logic.
- `Tests/AdapterContractTests/NativeRemediationProbeTests.swift` — does
  not exist in the ported tree.
