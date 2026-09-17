# Measured validation

- Full Swift suite on repair source: 161 tests, 8 live tests skipped, zero failures (24.410 seconds).
- Separate explicit native Fusion sandbox probe: passed; exact file written/read (20.372 seconds).
- Separate native MCP v2 end-to-end probe: passed; see native-e2e.json.
- Web tests: 54 passed, 1 integration skipped, zero failures.
- Release build: passed.
- Fresh staged bundle codesign --verify --deep --strict: passed (ad-hoc local signature, not notarized).
- Installed-app migration, current Codex connection refresh, and real project handoff: pending approval/execution.
- No production service, user configuration, unrelated project runtime or existing development working files changed.
