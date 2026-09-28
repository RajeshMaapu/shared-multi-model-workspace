# Measured validation

- Full Swift suite on repair source: 161 tests, 8 live tests skipped, zero failures (24.410 seconds).
- Separate explicit native Fusion sandbox probe: passed; exact file written/read (20.372 seconds).
- Separate native MCP v2 end-to-end probe: passed; see native-e2e.json.
- Web tests: 54 passed, 1 integration skipped, zero failures.
- Release build: passed.
- Fresh staged bundle codesign --verify --deep --strict: passed (ad-hoc local signature, not notarized).
- Installed-app migration, current Codex connection refresh, and real Thenali handoff: pending approval/execution.
- No production service, user configuration, Thenali runtime or existing Devin working files changed.

## 2026-09-19 audit-blocker repair round

Three audit blockers addressed in source; installed app untouched.

- Fusion error preservation: `ACPClient.ACPError` is `LocalizedError`
  (`"ACP remote error <code>: <message>"`); `ACPTransport.stderrText` /
  `transportStderrText` expose the redacted child stderr tail;
  `HarnessSessionError` carries engineer + operation + underlying + stderr
  tail; `workshopErrorDescription(_:)` is used at every system-event/log
  boundary instead of `localizedDescription` (which collapsed typed errors to
  "The operation couldn't be completed"); `WorkshopClient.RemoteError` gains
  `errorDescription`. `session/load` fallback notes now include the cause.
- Fusion session/new verified live: the exact Workshop spawn path
  (`/usr/bin/sandbox-exec -f devin/isolation-diag.sb devin-fusion … acp`)
  returned `sessionId: scythe-tungsten` in ~2.2 s; `team_settings_refresh`
  completed in ~843 ms via the relay. The audit's 10 s timeout was upstream
  relay latency (relay forwards with 120 s timeout vs. native 10 s
  client-side cap), not a Workshop defect; the preserved error now surfaces
  it if it recurs.
- Isolation gate scoped to authoritative turns: `executionReason` is
  nil/assigned/resumed/changes_requested; `authoritative` requires an owned
  subtask (or the devin task-level owner turn). Only authoritative turns on
  unqualified adapters are blocked ("…execution turn was not started.
  Discussion turns remain available."). Discussion wakeups
  (mention/review_request/cross_review/collaboration_requested/
  research_proposal/user_message/…) run on fenced non-authoritative
  generations that seal to `review_only` — never promotable (`promote`
  requires `sealed`). New `usesWorkspaceFilesystem` capability: the pure-API
  DeepSeek adapter reports false and skips the per-turn workspace copy while
  still getting a `state:"discussion"` read-only context.
- DeepSeek explicit model: `DeepSeekAdapter(model:)` +
  `defaultModel = "deepseek-flash"`; `DaemonRuntime` wires
  `engineers.json model_selection` at both construction sites.
  `openTaskSession` runs a bounded one-token `verifyModel` ping; HTTP 400 for
  unsupported identifiers surfaces the provider's own message; per-turn
  echoed `model` mismatches emit `.uncertain` and update the effective
  selection. `modelSelection` feeds `AdapterProbe.effectiveModel`, session
  bindings, and usage rows. Provider truth: `GET /models` serves
  `deepseek-flash` and `deepseek-v4-pro` only; `deepseek-v4.1` /
  `deepseek-v4.1-flash` are rejected; `deepseek-chat` aliases to
  `deepseek-flash`.
- Tests: `swift test` — 173 tests, 0 failures, 8 opt-in skips. New coverage:
  remote `session/new` error preserves native message; missing `sessionId`
  is descriptive; failed `initialize` respawns the transport; session/load
  fallback note includes the cause; DeepSeek configured model verified at
  open + on the wire; default model; unsupported model rejected pre-turn;
  alias echo reported via `.uncertain`; v2 discussion wakeups run
  unqualified peers on `review_only` generations; authoritative execution
  stays gated; owner user-message replies stay read-only; legacy v1 routing
  unchanged.
- `git diff --check`: clean.
- Not done (unchanged constraints): no install/deploy, no MCP config change,
  no production relay restart, no live-data migration, no `WORKSHOP_LIVE=1`
  run this round — the live `session/new` evidence above came from a direct
  sandboxed harness reproduction, not the packaged daemon.

## 2026-09-19 installed-app upgrade (user-approved, daemon/bridge only)

User approved install. The pending `Web/renderer` changes lack current
computer-use validation, so the Electron shell was NOT repackaged; instead
the two Swift binaries carrying all three audit fixes were swapped into the
installed bundle (`Contents/Resources/workshop-daemon`, `workshop-mcp`).

- Backup: `Workshop-upgrade-backups/audit-fix-20260919T233618Z/` — old
  binaries (matching the 20260917 cutover hashes), consistent sqlite backup,
  config copies, manifest with rollback instructions.
- Stopped only Workshop app (16632) + detached daemon (16535). Preserved:
  fusion-relay (38746), Codex bridge process (16874), unrelated validation
  daemon (54752). No relay restart, no MCP config change, no data migration
  (schema already v7).
- New daemon 18026 spawned by relaunched app; `workshop.health` ok,
  `listEngineers` reports `effectiveModel` for all three adapters.
- Fresh bridge spawn (new binary) → initialize/tools/list/tools/call
  verified; `workshop_create_task` advertises `schema_version`,
  `collaboration_mode`, `origin`.
- **Live smoke** `task_<id>` (v2,
  research_proposal, peers kimi+deepseek): DeepSeek ran two committed
  discussion turns — no pre-execution rejection; usage rows record
  `model: "deepseek-flash"` (configured model verified at open against the
  real provider). Devin created native session `brass-fuchsia` and sealed a
  reviewable writer proposal. Kimi's turn was attempted (gate did not
  block) and the native `session/new` failure surfaced verbatim in the task
  feed: `kimi session/new failed: ACP remote error -32603: Internal error`
  — exactly the error preservation the audit demanded. Kimi's native-side
  failure is an operational issue now visible for diagnosis.
- **Codex connection: unverified.** `config/mcpServer/reload` via
  `~/.codex/app-server-control/app-server-control.sock` is owned by the
  launchd remote-control daemon (pid 19619), not the desktop session
  (pid 16731) that holds the workshop-mcp child; the socket does not answer
  plain JSON-RPC and the CLI exposes no reload command. Supported user
  action required: reconnect the Workshop MCP server from the Codex desktop
  app (e.g. start a new thread, which spawns a fresh `workshop-mcp` through
  the existing `bin/` symlink), then make a real tool call. The running
  bridge (16874) is the old binary but forwards to the new daemon, so all
  three fixes already apply to it; only the bridge binary itself is stale
  until respawn.

## Follow-up: Kimi writer-sandbox repair (2026-09-19 evening)

After the first install, live Kimi turns reached `session/new` and failed with
`ACP remote error -32603: Internal error`. Direct reproduction of the exact
spawn path (`sandbox-exec -f <writer-profile> kimi acp`) surfaced the real
cause: `storage write failed: permission denied` plus `EPERM ... fs.watch` on
`KIMI_CODE_HOME`.

Two sandbox defects, both verified by bisection:

1. The writer profile reused Devin's write allowlist for every engineer.
   Kimi writes session storage across its whole `KIMI_CODE_HOME` profile dir.
   Fix: `writerSandboxProfile(engineer:)` — kimi gets `(subpath profile)`
   writes; other engineers keep the Devin-shaped allowlist.
2. `fs.watch()`/`vnode` lookup stats every ancestor of the watched path; the
   blanket `(deny file-read* (subpath workshopHome))` broke watch even on
   fully-allowed subdirs. Fix: `(allow file-read-metadata (literal ancestor…))`
   for the ancestors of the run dir and profile under the Workshop root —
   stat()-only, directory contents still denied.

Verified:
- Reproduced failure under the old profile; `session/new` returns
  `session_1078e11e` / `session_c0050914` (with MCP injection) under the
  fixed profile, zero stderr.
- `WriterSandboxTests` extended: kimi profile-write grant + ancestor-metadata
  literals emitted; sandboxed `os.stat` allowed on ancestors, denied on a
  sibling control dir. Full suite: 174 tests, 0 failures.
- Installed: `workshop-daemon` swapped to sha256 `255a41af…` (backup in
  `Workshop-upgrade-backups/kimi-sandbox-20260920T0145Z/`); workshop-mcp
  byte-identical after re-sign.
- **Live smoke** `task_<id>` on the installed
  daemon: kimi `session/new` → `session_623bd7d0-…`, turn `completed`,
  generations sealed `review_only`/`discussion` — non-promotable, isolation
  preserved. No `-32603`, no `EPERM`.
- Codex connection refresh remains **unverified** (same supported user action
  as above).
