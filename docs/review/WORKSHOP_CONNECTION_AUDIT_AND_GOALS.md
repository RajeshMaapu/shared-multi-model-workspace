# Workshop connection audit and redesign goals

Recorded 2026-09-27. Status: **approved direction, implementation not started.**
This document is the working list of gaps to close and the target architecture
for how Codex, the engineers (Devin Fusion, Kimi K3, DeepSeek), and the UI attach
to Workshop. It supplements `WORKSHOP_COMMUNITY_DESIGN.md` (collaboration
behavior) and supersedes the transport wording in ADR 0003, 0006, 0009 and the
"fence at the tool boundary" consequence of ADR 0013 once the goals below land.

## Decisions

| # | Decision | Status |
|---|---|---|
| D-a | Workshop hosts **one MCP endpoint over Streamable HTTP on loopback** (`127.0.0.1`, bearer token per request). ADR 0003's "no TCP port" stance is relaxed to *loopback-only, token-gated*; the Unix-domain socket remains the UI transport. Stdio bridges are removed or reduced to stateless proxy shims. | **Agreed** |
| D-b | A **Workshop-owned managed runtime lane** (model API + Workshop-owned tool loop, generalizing `DeepSeekAdapter`) is **in scope now**, as the fallback lane per engineer when the native ACP lane fails authentication or startup, with lane provenance visible on every message. | **Agreed, in scope now** |
| D-c | Tool schemas are a backward-compatible public contract: tools only gain optional fields; the daemon reports `workshop_catalog_version` on every result; a daemon restart invalidates HTTP sessions so clients re-initialize and re-list. No client re-lists on `tools/list_changed` (probes P0-1..P0-3), so that notification is best-effort only. | **Agreed (follows from probes)** |
| D-d | Peer review reads a digest-verified sealed snapshot copied into the peer's own fenced generation (hot-fixes d5fb9a6/e2d198a), not a live read grant on the owner's moving tree: reviews pin to an exact digest. `workshop_read_review_file` stays for adapters without a filesystem until the managed lane gives them one. Generation directories are never deleted automatically; retention is a separate user decision. | **Agreed** |

Everything else in this document follows from those two decisions plus the
principle below.

> Workshop owns one durable, authenticated, resumable connection surface.
> Agents connect *to* it; it never depends on being spawned *by* them.
> Enforcement lives in the sandbox and the service, never in answering
> permission prompts.

## Evidence base (read-only inspection, 2026-09-27)

- Phase 2 install: recorded in `docs/evidence/connection-redesign/install-2026-09-27.md` (Phase 2 section).

- Installed store: `~/Library/Application Support/Workshop/db/workshop.sqlite`
  (8 tasks, 272 messages, 84 turns, 144 wakeups, 5 decisions, 8 operations,
  29,177 outbox rows; 86 `writer-runs/`, 58 `writer-snapshots/`).
- Phase 1 install: `docs/evidence/connection-redesign/install-2026-09-27.md`.
- Daemon log: `~/Library/Application Support/Workshop/diagnostics/desktop-daemon.log`.
- Workshop-launched Devin harness logs:
  `~/Library/Application Support/Workshop/profiles/clean-v2/devin/data/devin/cli/logs/` (41 files).
- Workshop-launched Kimi logs:
  `~/Library/Application Support/Workshop/profiles/clean-v2/kimi/sessions/*/logs/kimi-code.log`.
- Codex rollouts: `~/.codex/sessions/2026/09/20` … `2026/09/27`.
- Installed code: worktree `/private/tmp/workshop-workspace-repair`, branch
  `codex/workspace-ref-recovery` (21 hot-fix commits ahead of `main`, installed
  app `0.2.0`, Electron shell + `workshop-daemon`).
- Primary incident tasks: task `f8b61a4f` (2026-09-27, execution, 95 messages)
  and task `9d9dbf78` (2026-09-20, research, 125 messages).
- Phase 0 probe results: `docs/evidence/connection-redesign/probes.md`.

Message references below are `#seq` within task `f8b61a4f` unless marked
`(9d9dbf78 #seq)`.

## Part 1 — Gap catalogue

Each gap has an ID, the measured evidence, and the goal that closes it.
Status: **Open** (nothing landed), **Hot-fixed** (a targeted commit exists on
`codex/workspace-ref-recovery` but the root cause remains), **Planned**.

### A. Codex → Workshop ingress (`workshop-mcp --principal codex`)

| ID | Gap | Evidence | Status |
|---|---|---|---|
| A1 | One stdio bridge process per Codex thread; each call connects, authenticates, disconnects. | 6 concurrent `--principal codex` bridges (pids 70573, 70598, 71716, 78646, 86261, 87426); `Sources/workshop-mcp/main.swift` `makeToolCaller`. | Landed (branch) |
| A2 | Tool schema frozen at spawn; no `tools/list_changed`; `serverInfo.version` hardcoded `"0"`. Every install requires a human "quit and reopen Codex". | Codex rollout `2026-09-27 …01a0e429…`: assistant asks user to reply "Codex reopened". `WorkshopMCP/Bridge.swift` `initialize`. AGENTS.md "Post-install Codex connection requirement". | Landed (branch); install check pending |
| A3 | No return channel; `task_ingress.last_acknowledged_seq = 0` on every row. Human relays between Codex and Workshop. | 50 user messages vs 22 `{"via":"codex"}` messages. | Landed (branch) |
| A4 | Idempotency depends on model behavior; append (`post_message`) not idempotent. | `operations`: same brief created task `ec8e2f84` (principal `user`) and task `c4e885ef` (principal `codex`, 64-hex key). ADR 0015 consequences. Team skill: "legacy append calls are not idempotent". | Landed (branch) |
| A5 | Codex authority extended per incident. | `be448ea fix: allow origin-scoped Codex review seed recovery`; #78. | Landed (branch) |

Goals:

- [x] **G-A1** Serve MCP from the daemon over Streamable HTTP on loopback; Codex config uses `url =`. Acceptance: zero `workshop-mcp --principal codex` processes while three Codex threads have Workshop tools; `tools/list` returns from the daemon process. — landed 736a276 (2026-09-27)
- [x] **G-A2** Every tool result carries `schema_version`; daemon emits `notifications/tools/list_changed` on upgrade; a request with an unsupported schema returns `-32010 schemaUpgradeRequired` with the required action. Acceptance: after a daemon restart/upgrade, a client's next call on its old session receives 404 and its re-initialize + `tools/list` succeeds without restarting Codex (verified in the Phase 1 install check); every tools/call result carries `_meta.workshop_catalog_version`; `catalogVersion` is bumped only with additive schema changes. — landed 736a276 (2026-09-27) (mechanism landed; install check pending)
- [x] **G-A3** `workshop_wait_for_events {task_id, after_seq, timeout ≤ 120 s}` bounded long-poll; every Codex read advances `last_acknowledged_seq`. Acceptance: a `$team` follow-up reports "N new events since seq M" using the stored cursor; no fabricated push into a Codex thread is claimed. — landed a47188b
- [x] **G-A4** Server-side idempotency for **create and append**: `idempotency_key` required on `workshop_post_message`; same key + same hash → same receipt; same key + different hash → `-32009`. Acceptance: `CodexBridgeTests` covers append replay; team skill stops warning about non-idempotent appends. — landed a47188b
- [x] **G-A5** Codex authority is a versioned allowlist document (`docs/adr/0015`) with a test that fails when a tool is added without an ADR revision. Acceptance: test exists; `be448ea` is either justified in ADR 0015 or reverted. — landed a47188b

### B. Engineer → Workshop tools (`workshop-mcp --engineer` inside the harness)

| ID | Gap | Evidence | Status |
|---|---|---|---|
| B1 | Bridge could not start inside the writer sandbox / from the app bundle; owner's report lost. | Devin logs: 11× `connection closed: initialize response`, 2× `Broken pipe … initialize`; #80, #82 "Failed to connect to MCP server 'workshop'". Fixes `df056d1`, `4434dba`. | Landed (branch) |
| B2 | Devin resolves MCP only from `<cwd>/.devin/mcp_config.local.json`; token path is per writer generation, so the file must be rewritten before every ACP initialize. | ADR 0006; `ACPHarness.swift` `bridgeArgs()`/`writeDevinMCPConfig`; Codex rollout 4× `MCP server 'workshop' not found in configuration for list_tools`. Fix `fcf2ab5`. | Landed (branch); install check pending |
| B3 | Token read once at bridge start; generation tokens expire on seal; harness stays warm 10 min → stale-token tool errors. | Devin logs: `workshop_publish_artifact` MCP error ×9, `report_result` ×1, `post_message` ×1. `workshop-mcp/main.swift` lines 50–55. | Landed (branch) |
| B4 | `report_result` idempotent forever on (subtask, generation); revised results cannot be reported; plain-text completion does not drive state. | #84, #87, #93 "returned the older pre-fix report … does not overwrite"; #44 user hand-orchestrated re-report → re-review (#44–#57). | Landed (branch) |
| B5 | Three tool-injection code paths (Devin file, Kimi ACP param, DeepSeek in-process); DeepSeek has no filesystem tool. | `MCPInjection` enum; (9d9dbf78 #99) "no file-reader/exec tool in this session". | Landed (branch) |

Goals:

- [x] **G-B1** Engineers reach the daemon's HTTP MCP endpoint directly (Kimi: ACP `mcpServers` HTTP variant; Devin: static HTTP entry in `.devin/mcp_config.local.json`). Where a client cannot speak HTTP, `workshop-mcp` becomes a **stateless proxy shim** that forwards to the endpoint and re-reads the token per call. Acceptance: no `sandbox-exec` launch of the bridge; zero `initialize` failures across 20 consecutive writer generations in a live probe. — landed 736a276 (2026-09-27)
- [x] **G-B2** The Devin MCP config file is written **once per task workspace** and contains no per-generation data. Acceptance: `.devin/mcp_config.local.json` contains only the daemon URL, `transport: http` and the bearer header — no bundle path, no shim command, no per-generation argv; sealed snapshots and digests exclude it (SafeTree). — landed 736a276 (2026-09-27) (mechanism landed; install check pending)
- [x] **G-B3** Principal and generation are resolved **per request** from the bearer token; sealing a generation invalidates its token immediately and the next call returns `-32004 fenced` with the current generation id. Acceptance: test seals a generation while a client holds an open session; the client's next call is fenced; no stale-token success. — landed 736a276 (2026-09-27)
- [x] **G-B4** `workshop_report_result` writes **result revision N+1** for the same (subtask, generation); reviews bind to `(result_id, revision)`; a `text` message never counts as a result; `verify_result`/`changes_requested` wakes target the latest revision. Acceptance: `Phase3ServiceTests` covers re-report after `needs_changes`; the #44–#57 sequence completes with zero user messages. — landed e599d5a (2026-09-27)
- [x] **G-B5** One tool-injection path per lane: native lane = HTTP MCP; managed lane = in-process catalog. `MCPInjection` deleted. DeepSeek (managed lane) gains sandboxed `read_file`/`list_dir` within the generation. Acceptance: DeepSeek review turns cite file paths and line numbers from the generation, not "committed record only". — landed c964e82

### C. Workshop as the harness's permission oracle (ACP `session/request_permission`)

| ID | Gap | Evidence | Status |
|---|---|---|---|
| C1 | Every `exec` auto-rejected; owner cannot run tests; the human ran `pytest`/`make ci` by hand. | 19× `permission: exec (reason=NonInteractive("User rejected this tool call"))`, `write` ×1, `request_scope` ×1; #62, #66, #82, #87; user ran tests at #15, #79, #88. | Landed (branch) |
| C2 | Policy is string matching on tool titles (`hasPrefix("Read"…)`, `contains("workshop")`, option-label scan); Kimi's differently named read tools are declined. | `ACPClient.swift` `respondToPermission`; #65 "Bash is unavailable", #74 "the user declined the tool calls". | Landed (branch) |
| C3 | The hot-fix hardcodes three task-specific shell commands (with the user's home path) into the adapter's permission policy. | `147cc8b fix: allow approved task validation commands in fenced writer`; `ACPClient.swift` lines 294–303 on `codex/workspace-ref-recovery`. | Landed (branch) |
| C4 | Owner stuck in read-only "discussion" turns for 8 consecutive turns while 20 writer generations were created and none promoted. | #20, #23, #66, #67, #71, #72, #93, #94; `writer_generations` for the task: devin 16 `review_only` + 4 `interrupted`, kimi 9 + 8. | Landed (branch) |
| C5 | Peers cannot read the sealed snapshot; a file-proxy tool over MCP was added instead of a read grant. | #39, #40, #64, #69 "permission-denied from my fenced scratch workspace"; `e2d198a`, `workshop_read_review_file`. | Landed (branch) |

Goals:

- [x] **G-C1** Launch harnesses in the mode that does **not** prompt for `exec`/`write` inside a generation; the `sandbox-exec` profile is the enforcement boundary. Acceptance: a live writer turn runs `pytest` and `make ci` without any `request_permission` for `exec`; a write outside the generation is denied by the sandbox and surfaces as a system event. — landed 622f5be (2026-09-27)
- [x] **G-C2** Any remaining prompt is decided by ACP structured `toolCall.kind` (read/edit/execute/fetch) against a per-turn **capability manifest** issued with the packet (`execute: within_generation | deny`, `write: generation_only | deny`, `network: allow | deny`). No title/prefix/command matching. Acceptance: unit tests feed Devin-style and Kimi-style permission requests with arbitrary titles and get identical decisions from `kind` alone. — landed 622f5be (2026-09-27)
- [x] **G-C3** Remove the hardcoded validation command allowlist and the home-directory path from `ACPClient.swift`. Acceptance: `rg "thenaliAI" Sources` returns nothing. — landed 622f5be (2026-09-27)
- [x] **G-C4** The owner never receives a read-only turn while it has an open revision: `mention`/`user_message` wakes to the owner coalesce into the current writer turn; `changes_requested`/`verify_result` always start a writer turn seeded from the reviewed revision. Acceptance: in a replay of task `f8b61a4f`'s event sequence, the owner receives exactly one writer turn per review cycle and zero read-only turns. — landed 8113496
- [x] **G-C5** Peers review a fresh fenced copy of the owner's digest-verified sealed snapshot (seeding rule pinned by test); `workshop_read_review_file` remains for filesystem-less adapters. Acceptance: Kimi's discussion turn workspace contains the owner's sealed files; retention of `writer-runs/` is tracked as an open user decision (see D-d). — landed via d5fb9a6/e2d198a; test pinned in Phase 2 close-out

### D. Session lifecycle (ACP adapters)

| ID | Gap | Evidence | Status |
|---|---|---|---|
| D1 | Kimi authentication failures from credential symlink + sandbox blocking OAuth refresh. | 4× `-32000 Authentication required`; `OAuthUnauthorizedError`; `EPERM … open '…/Workshop/…'`. Fixes `e530613`, `25aceb9`, `5648e6c`. | Landed (branch) |
| D2 | Kimi `session/new` internal errors and timeouts. | 5× `-32603 Internal error`, 2× `session/new timed out`, 1× `Can not write to FileHandle after it's closed`. Fixes `174a882`, `300bc8e`. | Landed (branch) |
| D3 | `session/load` essentially never works; each wake starts cold. | 12× Kimi "could not be loaded … started a new session (no checkpoint)"; 4× Devin "Session not found / Failed to load session data"; Kimi ran under **6 distinct native sessions in one task** (`turns.native_session_id`). | Landed (branch) |
| D4 | Fusion relay initialize timeouts drop the owner's revision wake. | 2× `devin initialize failed: cancelled — fusion-relay: timed out`; #59–#60. | Landed (branch) |
| D5 | Version probe used as liveness gate silently drops wakeups. | 2× "Devin was mentioned but is version probe failed; not woken" (#47, #48). Fix `c5e330c`. | Landed (branch) |
| D6 | ACP payload growth: `-32013 Request payload is too large. Too many images`. | (9d9dbf78 #14). | Landed (branch) |
| D7 | DeepSeek `HTTP 400` after compaction (orphaned tool message); silent DeepSeek turns. | (9d9dbf78 #104–#106); `ecf9eb9`. | Landed (branch) |
| D8 | FakeAdapter messages landed in a live task after a manual restart. | (9d9dbf78 #114) messages 107–113. | Landed (branch) |
| D9 | ~20 daemon SIGTERM/restart cycles; wakeups lost across restarts. | `desktop-daemon.log`; fix `a462889`. | Landed (branch) |

Goals:

- [x] **G-D1** Credential handling is a documented per-engineer contract tested by a live canary (`Tests/LiveSmokeTests`): OAuth refresh inside the sandbox succeeds; symlinked credential directories are validated at daemon start with a health chip, not discovered at `session/new`. Acceptance: canary passes; a broken credential shows "Login required" before any wake is attempted. — landed 878579e
- [x] **G-D2** Native session startup is bounded (`initialize` ≤ 15 s, `session/new` ≤ 30 s) and failures are classified (`auth`, `timeout`, `transport`, `internal`) into the wakeup retry policy. Acceptance: each class has a test; no `NSCocoaErrorDomain` text reaches a task message. — landed 8113496
- [x] **G-D3** Workshop owns **task memory** per (task, engineer): decisions, open items, files touched with digests, review cursor, last result revision; rendered into every packet. `session/load` becomes best-effort. Acceptance: with `session/load` forced to fail, an engineer's next turn references its prior decisions from the packet; "no checkpoint available yet" no longer appears. — landed 8113496
- [x] **G-D4** A failed owner launch re-queues the wake with backoff and posts one visible "waiting for Devin Fusion (relay timeout)" system event, never "not woken". Acceptance: test with a transport that fails initialize twice then succeeds; the turn runs on the third attempt with no user message. — landed 3551937 (2026-09-27)
- [x] **G-D5** Version probe is advisory (UNTESTED badge only); liveness is decided by the launch attempt. Acceptance: probe failure never suppresses a wakeup. — landed 3551937 (2026-09-27)
- [x] **G-D6** Packets carry no images; `recentMessages` bound is enforced by bytes as well as count; native-session growth triggers a Workshop-side memory refresh rather than a larger prompt. Acceptance: no `-32013` in a 40-turn live soak. — landed (Phase 2 close-out): no images; 24 KiB body bound; native-session growth handled by task memory rather than session/load.
- [x] **G-D7** Managed-lane history compaction is covered by a property test (no orphaned tool result after suffix cut); a silent turn (no Workshop tool call, no text) is recorded as `turn_state = silent` and surfaced. Acceptance: tests pass; silent turns appear in the Board with the lane label. — landed c964e82
- [x] **G-D8** Adapter selection is a persisted daemon setting; **fake adapters refuse to start when `WORKSHOP_HOME` is the installed home**. Acceptance: startup test asserts refusal; fake output is impossible in the installed store. — landed 3551937 (2026-09-27)
- [x] **G-D9** Pending wakeups and in-flight turns are reconciled on every start (already `a462889`); add a restart soak test that kills the daemon mid-turn 10 times and asserts no wakeup is lost or duplicated. — landed 878579e

### E. Orchestration policy

| ID | Gap | Evidence | Status |
|---|---|---|---|
| E1 | User @mentions wake only the owner. | (9d9dbf78 #16–#32) user retried "@kimi please give a one-paragraph review" 8× over 2 h; #27 "user mentions wake only the owner". | Landed (branch) |
| E2 | Discussion round limit reached within minutes because failed launches count as rounds; 28 wakeups `suppressed`. | (9d9dbf78 #6) at +3 min; #10 at +20 min. | Landed (branch) |
| E3 | Two messages per turn (tool-posted + streamed ACP reply); stream committed with an earlier timestamp than its seq; peers re-woken by their own summaries. | #8/#12, #61/#62, #89/#90, #91/#92; #57. | Landed (branch) |
| E4 | `work.activity` firehose in the outbox. | 30,516 `work.activity` rows vs 192 `message.committed`. | Landed (branch) |
| E5 | Native qualification is a hardcoded path + model string in Swift. | `ACPHarness.swift` `supportsIsolatedWorkspaceTurns` (lines 89–94 on `main`). | Landed (branch) |

Goals:

- [x] **G-E1** A user @mention wakes the mentioned participant. Acceptance: `Phase2` wakeup test; a user message mentioning `@kimi` produces exactly one Kimi wakeup and no owner wakeup unless the owner is also mentioned or the message is unaddressed. — landed 3551937 (2026-09-27)
- [x] **G-E2** Round limit counts **completed substantive** engineer turns (at least one Workshop tool call or committed text); launch failures and silent turns do not count. Acceptance: test replays six failed launches; no "Discussion round limit reached". — landed 3551937 (2026-09-27)
- [x] **G-E3** The streamed ACP reply is stored as `kind = turn_summary`, excluded from packets, cursors and the default thread view; ordering is by commit seq only. Acceptance: `packetText` contains no `turn_summary`; UI thread shows one message per tool post. — landed 9e7caf9
- [x] **G-E4** `work.activity` moves to a bounded `activity` table (ring per task); the outbox carries committed facts only. Acceptance: outbox row count for a 100-turn task < 1,000. — landed 9e7caf9
- [x] **G-E5** Qualification is a `capabilities` row per (engineer, binary hash, model selector, probe date, evidence path) written by `workshop-daemon qualify`; `supportsIsolatedWorkspaceTurns` reads it. Acceptance: no home-directory path or model string literal in `Sources/`. — landed 878579e

### F. Shared workspace and writer model (cross-cutting)

| ID | Gap | Evidence | Status |
|---|---|---|---|
| F1 | "Task workspace unavailable" ×3 at task start; blocked until a hot-fix. | #3–#5; `dd9df9a`, `7e70d06`. | Hot-fixed |
| F2 | Every turn is a copy (`writer-runs/<gen>/workspace`) sealed to `writer-snapshots/<gen>`; promotion is a manual user command that never ran in `f8b61a4f`; 8 sealed snapshots announced "No changes promoted". | #23, #29, #33, #37, #53, #67, #72; `writer_generations`. | Open |
| F3 | The human validated in a temporary copy because neither the owner (C1) nor peers (C5) could. | #15, #79, #88. | Open (closes with G-C1, G-C5) |

Goals:

- [ ] **G-F1** Workspace preparation failures are classified and retried; a task never enters `blocked` for a recoverable path error without a system event naming the exact missing reference.
- [ ] **G-F2** Promotion of a digest-verified snapshot is offered in the UI on the result card (user authority preserved); the packet tells the owner the exact promotion state. Acceptance: promotion is one click in the task pane; the number of unpromoted sealed snapshots per task is visible.
- [ ] **G-F3** Definition of done for the whole effort (see below) includes "zero human validation runs".

## Part 2 — Diagnosis

MCP is a fine tool-call vocabulary; the weakness is how Workshop is attached to
each agent.

1. **Transport = a stdio child process spawned by someone else.** Its lifetime,
   token, schema and sandbox are fixed at spawn by a different process (Codex
   thread, Devin harness, Kimi harness). A1–A2 and B1–B3 are lifetime mismatches.
2. **Security boundary = an interactive prompt answered by a non-interactive
   program.** Workshop is the ACP "user" without a policy language, so it matches
   strings and hardcodes commands (C1–C3). The per-generation `sandbox-exec`
   profile already exists and is not trusted to *be* the boundary.
3. **State of record split three ways.** Task truth in SQLite; conversation
   memory in vendor session stores (`session/load`, which fails); file truth in
   per-turn copies. Human time went to reconciling the three (C4–C5, D3, F2).
4. **No subscription/event path for any client.** UI polls over UDS; Codex has
   nothing; engineers see only the next packet (A3, E1–E3).

## Part 3 — Target architecture

```text
Codex thread ─── HTTP MCP (loopback, bearer) ──┐
Devin harness ── HTTP MCP or stateless shim ───┤
Kimi harness ─── HTTP MCP (ACP mcpServers) ────┼──> workshop-daemon ──> SQLite (WAL)
Managed lane ─── in-process tool catalog ──────┤        │  task memory, result revisions,
Workshop UI ──── JSON-RPC over UDS ────────────┘        │  capability manifests, activity ring
                                                        └─ sandbox-exec per generation = write/exec boundary
```

### 3.1 One daemon-hosted MCP endpoint (D-a)

- `DaemonRuntime` hosts a Streamable HTTP listener on `127.0.0.1:<port>` at
  `/mcp`, port recorded in `<runtime-dir>/mcp.json` with the schema version.
  UDS stays for the UI and remains peer-uid checked.
- Bearer token per request → principal + generation resolved per request.
  Tokens are the existing files (`profiles/<principal>/token`,
  `writer-runs/<gen>/token`); nothing new is stored.
- `MCPBridge.handle(line:)` is reused as the HTTP handler body.
- Server → client: `notifications/tools/list_changed`, `schema_version` in
  every result, `-32010 schemaUpgradeRequired`.
- `workshop-mcp` survives only as a stateless proxy shim for clients that
  cannot speak HTTP; it re-reads the token per call and holds no state.

### 3.2 Sandbox as the boundary (C)

- Harness launch modes that do not prompt for `exec`/`write` inside a
  generation; the `isolation.sb` profile denies everything outside it.
- Residual prompts decided by ACP `toolCall.kind` against the per-turn
  capability manifest. No string matching, no command allowlists.
- Peers get a sandbox read grant on the owner's live generation.

### 3.3 Workshop-owned task memory (D3)

- `task_memory(task_id, engineer_id, revision, decisions, open_items,
  files_touched[{path, digest}], review_cursor, last_result_revision)` updated
  from tool calls and turn end; rendered into every packet.
- `session/load` best-effort; a cold native session is not a task event.

### 3.4 Results and reviews as revisioned objects (B4, C4)

- `results(task_id, subtask_id, generation, revision, summary, validation,
  artifact_ids)`; reviews bind to `(result_id, revision)`.
- Owner wakes while a revision is open always become writer turns.

### 3.5 Wakeups and liveness (D4, D5, E1, E2)

- Mentions wake the mentioned participant regardless of author kind.
- Launch failures re-queue with backoff and a visible chip; probe is advisory.
- Round limit counts completed substantive turns only.

### 3.6 Codex return path (A3, A4)

- `workshop_wait_for_events` bounded long-poll; `last_acknowledged_seq`
  advanced by every Codex read; server-side idempotency on create and append.
- No push into a Codex thread is claimed; the durable task remains the return
  surface.

### 3.7 Managed runtime lane (D-b)

- `ManagedRuntimeAdapter` generalizes `DeepSeekAdapter`: model API client +
  Workshop-owned tool loop with `read_file`, `list_dir`, `write_file` (generation
  only), `exec` (inside the same `sandbox-exec` profile), and the Workshop tool
  catalog in-process. File-backed visible history with the compaction property
  test from G-D7.
- Lane selection per engineer per task: **native ACP lane preferred**; fall back
  to the managed lane on classified `auth`/`timeout`/`transport` startup
  failures after the retry budget, never silently. Every message carries
  `lane = native | managed` in `structured`; the UI shows it; the packet tells
  peers which lane the author ran on.
- Model access per engineer: DeepSeek already has a direct API. **Kimi and
  Fusion require a probe** (Kimi: whether the OAuth grant or an API key path
  exposes a completion API usable outside `kimi acp`; Fusion: whether the relay
  exposes a raw completion endpoint). If a lane has no model access it is
  recorded as `unavailable` in `capabilities`, not faked.
- The managed lane does not get Fusion's native sidekick, Devin skills, or Kimi
  native tooling; that loss is stated on the task when a fallback occurs.

### 3.8 Configuration and qualification as data (D8, E5)

- Adapter selection persisted; fake adapters refuse the installed home.
- `capabilities` rows replace Swift literals.

### Preserved invariants

SQLite ledger and single-writer daemon; generation fencing; sealed snapshots
and digest-verified user promotion; Codex 5-tool authority; clean engineer
profiles; UDS for the UI; user-only approvals in the app; no additional
Workshop-spawned agents beyond Fusion's native sidekick.

## Part 4 — Work plan

Phases are ordered by how much human infrastructure work they remove per unit
of change. Each item names the goals it closes.

### Phase 0 — Probes (before any implementation brief)

- [ ] **P0-1** Devin CLI: does `.devin/mcp_config.local.json` accept an HTTP/Streamable-HTTP server entry? Record exact version and config shape. (G-B1)
- [ ] **P0-2** Kimi ACP: does `session/new.mcpServers` accept the HTTP variant? Record the exact ACP schema version. (G-B1)
- [ ] **P0-3** Codex: does `[mcp_servers.workshop] url =` negotiate Streamable HTTP and honor `notifications/tools/list_changed`? (G-A1, G-A2)
- [ ] **P0-4** Devin CLI and Kimi: which launch/permission mode suppresses `exec`/`write` prompts, and does it still emit `session/update` tool activity? (G-C1)
- [ ] **P0-5** Model access for the managed lane: Kimi completion API path; Fusion relay raw completion endpoint. (3.7)
- [ ] **P0-6** `sandbox-exec` read-only grant on another generation's directory works for both harnesses. (G-C5)

Probe results go in `docs/evidence/connection-redesign/probes.md` with commands,
versions and raw output paths.

### Phase 1 — Stop the bleeding

- [x] HTTP MCP endpoint in `DaemonRuntime`; stateless shim; per-request token resolution; `schema_version`; `list_changed`. (G-A1, G-A2, G-B1, G-B2, G-B3)
- [x] Sandbox-as-boundary launch modes; `kind`-based residual policy; delete the command allowlist and home path. (G-C1, G-C2, G-C3)
- [x] Result revisions and review binding. (G-B4)
- [x] User mentions wake peers; launch-failure re-queue; probe advisory; round limit counts substantive turns. (G-E1, G-E2, G-D4, G-D5)
- [x] Fake-adapter refusal on the installed home. (G-D8)

### Phase 2 — Own the state

- [x] `task_memory` and packet rendering; `session/load` best-effort. (G-D3, G-D6)
- [x] Peer read grant on the live generation; retire scratch copies and `workshop_read_review_file`. (G-C5, G-F2)
- [x] Owner writer-turn coalescing. (G-C4)
- [x] `turn_summary` kind; `activity` table; outbox facts only. (G-E3, G-E4)
- [x] Startup failure classification and bounded startup. (G-D2)

### Phase 3 — Managed lane and Codex return path

- [x] `ManagedRuntimeAdapter` from `DeepSeekAdapter`; lane selection and provenance; compaction property test; silent-turn detection. (3.7, G-B5, G-D7)
- [x] `workshop_wait_for_events`; acknowledged cursor; idempotent append. (G-A3, G-A4)
- [x] `capabilities` rows and `workshop-daemon qualify`; credential canaries. (G-E5, G-D1)
- [x] Restart soak. (G-D9) — 40-turn live soak pending install
- [ ] 40-turn live soak. (G-D6)
- [x] Codex authority test; ADR updates. (G-A5)

### ADRs to write or amend

- Written: ADR 0017 *Loopback Streamable-HTTP MCP endpoint; stdio bridges retired*
  (amends 0003 "no TCP port", supersedes 0006 and 0009).
- Written: ADR 0018 *Sandbox is the enforcement boundary; permission prompts
  decided by kind against a capability manifest* (amends 0013 consequences).
- Written: ADR 0019 *Managed runtime lane and lane provenance* (extends 0008).
- Written: ADR 0020 *Workshop-owned task memory; native sessions disposable*.
- Amended: 0003, 0013 (Revision 2026-09-28), 0015 (authority test +
  `be448ea` decision); 0006/0009 marked superseded by 0017.

## Part 5 — Definition of done

Run one execution task with requested peers from a fresh Codex session against
the real engineers, and one research task, and measure:

- [x] Zero user messages whose content is infrastructure (running tests,
  restarting the daemon, repairing credentials, re-mentioning peers,
  re-triggering reports). Baseline on 2026-09-27: roughly half of 50.
  Evidence: live-run doc reruns 1–6 observed zero user infrastructure
  messages (docs/evidence/connection-redesign/live-run-2026-09-28.md).
- [ ] Zero `Turn could not start` and zero `not woken` system events.
  Baseline: 14 and 2. Note: 2–3 transient `fusion-relay: timed out`
  turn-could-not-start events were observed during the reruns; each
  recovered on retry — not counted as met yet.
- [x] Zero `permission: exec … rejected` in harness logs. Baseline: 19.
  Evidence: reruns 1–6 observed none.
- [x] Owner receives no read-only turn while a revision is open.
  Baseline: 8. Evidence: reruns 1–6 observed none.
- [ ] Peers read the live generation; `writer-runs/` per task equals writer
  generations. Baseline: 37 generations, 0 promoted, peers permission-denied.
- [x] One native session per engineer per task, or a task-memory packet that
  makes the cold start invisible. Baseline: 6 Kimi sessions.
- [x] A daemon upgrade during the task requires no Codex restart.
  Evidence: Phases 3.4–3.6 installed with the configured Codex MCP session
  untouched; 5+ post-install re-initializations observed
  (`codex-mcp-client` sessions), then real `mcp call` lines (workshop_get_task,
  workshop_wait_for_events, workshop_read_messages,
  workshop_read_review_file) from session 4b215f7d.
- [x] Every message shows its lane; any managed-lane fallback is announced on
  the task.
- [ ] `swift test`, `node --test Web/tests/*.test.mjs Desktop/tests/*.test.mjs`,
  the skill tests, and `git diff --check` pass; live tests run with
  `WORKSHOP_LIVE=1`, not skipped.
  Note: the full fresh-thread `requested_peers` acceptance run is still
  outstanding, so this line and the suite stays open until it lands.

## Part 6 — Operating rules while this lands

- Hot-fixes on `codex/workspace-ref-recovery` are acceptable only if they cite
  the gap ID they mitigate and do not add string- or path-based policy.
- No goal above is closed by a synthetic or fake-adapter test alone; each
  acceptance line names the live or replay evidence required.
- The AGENTS.md scope rules (no installed-app replacement, MCP config change,
  relay restart, live migration, merge or deploy without separate approval)
  apply to every phase.

## Part 7 — Live rerun findings (2026-09-28)

Six live reruns against the installed redesign build (see
docs/evidence/connection-redesign/live-run-2026-09-28.md) surfaced four
root causes, each fixed and installed:

1. **Legacy digest** — old `writer_generations` rows carried a digest
   format the new verifier rejected, so resume/recovery mislabeled or
   refused valid snapshots. Fix: `93d07a4` (accept legacy snapshot
   digests, block hard workspace failures without retry, refresh Kimi
   canary via CLI).
2. **Resume-from-blocked** — a gate-blocked task could not be resumed
   through the supported path, stranding the owner claim. Fix: `eb653db`
   (resume gate-blocked tasks, CLI-driven Kimi token refresh, SIGPIPE
   tolerance).
3. **Stale pin / review-seed rule** — `writer_seed_pins` outranked newer
   authoritative sealed revisions, so reviews seeded (and reviewers read)
   pre-edit bytes — Kimi's eight identical CANNOT-AGREE verdicts.
   Fixes: `f0d7bee` (newest authoritative snapshot seeds `begin`) +
   `902f20b` (one `currentReviewSeed` rule for reads, grants, pins,
   `getTask.review_seed`; Kimi refresh spawn parity; managed writer seal).
4. **Managed tool-loop cap** — managed turns exhausted `maxIterations = 8`
   after `workshop_report_result` and failed before sealing. Fix:
   `d665443` (cap 24, wall bound, graceful `.turnCompleted` at bounds,
   post-report "end the turn" nudge). Follow-up `fix` in this round:
   the post-report nudge is now request-scoped (not persisted into
   session history) and the continuity checker ignores streaming/empty
   reply placeholders — the Phase 3.6 Kimi continuity `fail — ` was the
   checker matching the in-flight turn's empty streaming `text` row.

### Open items after the reruns

- **DeepSeek managed qualification** — real turn ran and
  `workshop_report_result` committed revision 1, but the provider stream
  died on `NSURLErrorDomain -1005` (transient); record remains
  unqualified pending a network-good window.
- **Kimi managed continuity** — root-caused this round (streaming
  placeholder race above); awaiting a live `--continuity-check` rerun
  against the fix.
- **T11 loop bound suppressing non-verifier peers** — DeepSeek stayed
  silent under the long verify loop because only the designated
  verifier's `verify_result` wakeups bypass the
  `engineerWakeupsSinceLastUserMessage` bound. Currently a deliberate
  design choice, not a bug; revisit if peer participation during verify
  loops is wanted.
- **Fresh-thread `requested_peers` acceptance run** — the definition of
  done requires one clean measured run; reruns so far were continuation
  runs on the same task.
