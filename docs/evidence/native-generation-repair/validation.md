# Measured validation

- Full Swift suite on repair source: 161 tests, 8 live tests skipped, zero failures (24.410 seconds).
- Separate explicit native Fusion sandbox probe: passed; exact file written/read (20.372 seconds).
- Separate native MCP v2 end-to-end probe: passed; see native-e2e.json.
- Web tests: 54 passed, 1 integration skipped, zero failures.
- Release build: passed.
- Fresh staged bundle codesign --verify --deep --strict: passed (ad-hoc local signature, not notarized).
- Installed-app migration, current Codex connection refresh, and real project handoff: pending approval/execution.
- No production service, user configuration, unrelated project runtime or existing development working files changed.

## Follow-up: Kimi writer-sandbox repair

After the first installed repair, live Kimi turns reached `session/new` and
failed with `ACP remote error -32603: Internal error`. Direct reproduction of
the exact spawn path (`sandbox-exec -f <writer-profile> kimi acp`) surfaced
`storage write failed: permission denied` plus `EPERM ... fs.watch` on
`KIMI_CODE_HOME`. Two defects, both verified by bisection:

1. The writer profile reused Devin's write allowlist for every engineer;
   Kimi writes session storage across its whole `KIMI_CODE_HOME` profile.
   `writerSandboxProfile` now takes an `engineer` parameter: Kimi gets
   `(subpath profile)` writes; other engineers keep the Devin-shaped list.
2. `fs.watch()`/vnode lookup stats every ancestor of the watched path; the
   blanket Workshop-home read deny broke watch even on allowed subdirs.
   The profile now grants `file-read-metadata` on the literal ancestors of
   the allowed subpaths — stat()-only, directory contents still denied.

Verified: `session/new` succeeds under the generated profile with clean
stderr (with and without MCP injection); `WriterSandboxTests` covers the
ancestor-metadata grant and the denied sibling control dir; full suite
174 tests, zero failures; installed-daemon live smoke ran a completed
Kimi discussion turn whose generations sealed `review_only`/`discussion`
(non-promotable). Originating-session MCP refresh remains unverified.
