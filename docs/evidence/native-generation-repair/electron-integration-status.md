# New activity update staged — 2026-09-17

The installed Electron app described below remains the previously verified version. A new active-turn indicator and durable expandable activity feed is implemented in source but NOT browser-validated or installed. See [activity feed status](activity-feed-status.md) for test evidence, renderer hashes, limitations and blocked visual gate. The later submitted task reached verifying with no running engineer; no duplicate submission or proposal promotion occurred here.

# Submission handoff update — 2026-09-17

Fresh Codex task `01a0adea-ca03-7ee0-b8e8-bc821f729c5a` reports successful actual configured MCP list/get calls. After explicit user approval transferring submission to that task, it submitted the saved invocation once and verified `task_<id>`, titled “SPX RL input audit and shadow-entry attempt evidence”, working with Devin as the sole participant/running engineer and workspace ready. It reports the Team helper saved the receipt in the original invocation journal. This installation task did not submit or independently re-read the receipt.

This is a verified-by-submitting-task fresh-session handoff, not reconnection of the original stale voice task. Original-session MCP reconnection remains unverified. Installed-app visible-title verification is being coordinated separately; do not infer UI rendering from MCP list/get success. Earlier pending-submission statements below are historical and superseded by this update.

# Installed Electron update — 2026-09-17

The newest selected community Electron renderer is now packaged, installed at `~/Applications/Workshop.app`, and launched normally. Browser exact-size checks passed through Chrome's documented viewport capability; qualified reference differences remain recorded in `.build/web-qa/reference-comparison.md`. No renderer changes were made. Web/Desktop tests: 70 passed, zero failed/skipped, including isolated integration.

Packaged isolated smoke and installed live-data smoke both passed. The installed smoke displayed two existing task cards and Connected, with process/require undefined and the exact restricted preload API. Evidence: `/private/tmp/workshop-electron-installed-smoke/smoke.json`. The installed app started its bundled daemon against the existing schema-v7 Workshop home; stable bridge link now targets `Workshop.app/Contents/Resources/workshop-mcp`. The saved Team request was not submitted by this task.

App/database/config rollback backup: `~/Library/Application Support/Workshop-upgrade-backups/electron-20260916-223837`. SQLite backup integrity passed. Binary/resource hashes are in that directory's `electron-install.json`; signature verifies locally (ad-hoc, not notarized). CFBundleIconFile points to electron.icns, whose SHA-256 matches the generated newest Workshop icon (`20824f61249155d55704c0ebd76d363cf75100c06fc4ace2951c80230e53fdf3`). Actual Finder/Dock appearance is pending independent supported desktop observation; resource verification does not prove cached appearance.

Browser recovery procedure is durably committed as 815d37e and linked from AGENTS.md: `docs/review/WORKSHOP_BROWSER_VALIDATION.md`. The prior Chrome error cause remains unknown. The successful automated route is documented; no protection bypass or browser configuration repair occurred.

Remaining: root validates its actual MCP connection and alone submits the persisted Team invocation; supported desktop helper checks Dock/Finder icon appearance. Full native accessibility, notifications, and notarization are not qualified by these checks. Earlier checkpoints below are historical, superseded where noted above.

---

# Electron installation checkpoint — 2026-09-17

## Scope and current state

User selected the running community Electron preview as the installed product, superseding the Swift UI packaging choice. The repair worktree Web/renderer matches Workshop-community exactly. No renderer changes, dependencies installed, commits, merges, production Electron replacement, or Team submission occurred in this phase.

## Prepared code

- Sources/workshop-mcp/main.swift connects and authenticates on each tool call, recovering from startup-before-daemon and daemon restart. Never retries a dispatched request; uncertain mutations are not replayed.
- Desktop/lifecycle.mjs resolves bundled daemon and existing Workshop home/socket, preserves a responding daemon, starts a missing live daemon once, bounds readiness checks, detaches it from UI lifetime, and logs startup diagnostics. Explicit preview socket mode stays separate.
- Desktop/main.mjs supports installed mode and preview mode, using the same approved renderer, dimensions, restricted preload, protocol, and menus. Installed UI has its own userData path and product name.
- Desktop/package.mjs accepts --installed and WORKSHOP_PACKAGE_BIN_DIR, preserves custom icon generation, stages lifecycle module, and uses Workshop product/bundle identity. The visual-validation packaging gate remains intact.
- scripts/test-bridge-recovery.py tests one bridge process across absent daemon/start/stop/restart.

## Validation

- Swift MCP tests: 16 passed, zero failures.
- Debug and release bridge builds passed (existing Swift concurrency warnings remain).
- Same-bridge startup/restart regression passed for debug and release binaries, isolated fake-adapter runtimes.
- Four installed lifecycle unit tests passed.
- Web/Desktop suite: 68 passed, one skipped socket integration, one failure: missing current web evidence. This is expected gate behavior, not a passing suite.
- Separately ran socket integration against isolated daemon: one passed, verifies durable owner tasks, idempotent retry, requested peers, and persisted replies. Fake adapters do not prove live models.
- JavaScript syntax and git diff --check passed.
- Previous installed-release live synthetic Fusion workflow passed on Devin 3000.10.31; evidence in dedicated task artifact fusion-qualification/result.json. It predates the bridge recovery source change and is not evidence for a new Electron bundle.

## Mandatory browser-validation blocker

Aside opened but aside guide reports signed-out account and openai-codex authentication failure. This task inventory has no cua_repl/browser-control tool. Origin provided a browser helper; navigation to http://127.0.0.1:4187 returned ERR_BLOCKED_BY_CLIENT. No screenshot/interaction or viewport checks passed. Helper report: /private/tmp/workshop-ui-validation-20260917/browser-validation.md. Do not bypass either browser restriction or claim visual validation. Restore Aside sign-in, or make the local preview accessible through the supported browser. Project policy forbids Electron carry-over while this validation is blocked.

## Lifecycle observation

Installed daemon log records two explicit 'stop background work requested; exiting' events. Last production UI API read failed ECONNREFUSED because service was stopped again; no third restart during validation pause. Preview UI and installed Swift UI are different apps. Do not close user's preview windows blindly.

## Next steps after browser access

Run full/compact comparison and interactions against selected preview, bind real evidence to final renderer hashes, rerun full Web/Desktop suite, package using existing pinned dependencies and reviewed daemon plus rebuilt bridge, verify Electron security/lifecycle/icon and actual real data connection, back up and replace installed Workshop, relaunch only Workshop. Verify actual origin connection; origin alone submits exact persisted Team invocation. No Codex/relay/Thenali restart or policy changes. No fake UI/demo counted as live creation/message proof.


## Updated browser checkpoint

Aside CLI update to1.26.916.1741 completed under explicit user approval. aside guide and guide repl read successfully. Actual supported Aside browser accessed http://127.0.0.1:4187 and passed owner creation, requested Kimi participation, options reset, no legacy generation suffix in system messages, reply persistence after reload/reselect, search, five tabs, capacity display, icon dialog, and draft retention. Screenshots/notes are preserved in .build/web-qa/interaction-evidence.json and associated PNG files. The observed viewport was1440x900 with no horizontal overflow; evidence deliberately remains partial.

The guide's Page API has no setViewportSize. Origin's computer-use helper found only Chrome and could not select Aside; it timed out without changing any window. No raw CDP or alternate UI bypass was attempted. Mandatory full_layout_1586x992 and compact_980x680 checks in Desktop/web-validation.mjs remain unperformed. Packaging gate unchanged. User can make the required viewport available manually through supported browser window/responsive-view controls, then let Codex capture/measure it. No Electron replacement has been packaged or installed.
