# Phase 0 — Connection probes

Date: 2026-09-27. Host: macOS (arm64). All probe workspaces under
`/private/tmp/workshop-probes-wk3567/`; raw logs under `.build/probes/`
relative to the repo root. Probe MCP server: `.build/probes/probe_mcp_server.py`
(Python 3.9 stdlib, Streamable HTTP, bearer-gated, SSE push of
`notifications/tools/list_changed` after each `probe_echo` call).

No production files were modified; no processes other than probe-spawned ones
were signalled.

---

## P0-1 — Devin CLI HTTP MCP config — PASS

- Client: `devin 3000.11.3 (9c803229faa4)`, launched via
  `~/projects/fusion-codex-relay/bin/devin-fusion --config <cfg> --permission-mode accept-edits acp`.
- Config: `W/.devin/mcp_config.local.json` with
  `{"mcpServers":{"probe":{"url":"http://127.0.0.1:PORT/mcp","transport":"http","headers":{"Authorization":"Bearer probe-token"}}}}`
  — **accepted**; CLI log: `Connecting to streamable HTTP MCP server 'probe'`
  followed by `MCP server 'probe' connected successfully`.
- MCP client: `rmcp` v3.1.0 (clientInfo in initialize).
- `protocolVersion` requested: **`2025-11-25`** (server echoed it back).
- `Accept` header on every POST: `text/event-stream, application/json`.
- `Authorization` header sent (lowercase `authorization:`) — present on all
  requests including GET.
- `Mcp-Session-Id` echoed back on every subsequent request; client also sends
  `mcp-protocol-version: 2025-11-25` on all post-initialize requests.
- GET SSE stream: **yes**, one `GET /mcp` with `Accept: text/event-stream`.
- After `tools/call probe_echo` and the pushed `notifications/tools/list_changed`:
  **no second `tools/list`** observed (server log holds exactly one).
- Raw logs: `.build/probes/devin-server.jsonl`, `.build/probes/devin-acp.jsonl`,
  `.build/probes/devin-cli.log`.

## P0-4a — Devin permission behaviour in ACP — PASS

- `session/request_permission`: **none** — zero occurrences in the ACP log.
  `permissions.allow` (`["exec","read","grep","glob","mcp__probe__*"]`) plus
  `--permission-mode accept-edits` produced `Permission decision for tool X:
  auto-decided Some(Allow) by cog` in the CLI log for `exec`,
  `mcp_list_servers`, `mcp_list_tools`, `mcp__probe__probe_echo`.
- `session/update` tool_call payloads **do** include `kind`: `"kind":"execute"`
  on the shell call. MCP tool calls show `title` like `"Called probe_echo from
  probe"` but no `kind` field was present on them. `_meta` carries
  `cognition.ai/inferenceToolName` (`exec`, `mcp__probe__probe_echo`, ...).
- Prompt completed: `stopReason: "end_turn"`. One inference turn total.

## P0-2 — Kimi ACP HTTP mcpServers — PASS

- Client: `kimi 2.1.1` (`kimi acp` over stdio, real HOME).
- `initialize` result advertises `mcpCapabilities: {"http":true,"sse":true}`.
- `session/new` accepted the first shape:
  `[{"type":"http","name":"probe","url":...,"headers":[{"name":"Authorization","value":"Bearer probe-token"}]}]`
  (the object-map header variant was never needed).
- `protocolVersion` requested: **`2025-11-25`** (clientInfo `kimi-code`,
  user-agent `node` — the MCP client is Node fetch).
- `Accept` on POSTs: `application/json, text/event-stream`; `Authorization`
  present; `Mcp-Session-Id` echoed on all subsequent requests;
  `mcp-protocol-version: 2025-11-25` sent.
- GET SSE stream: **yes** (`Accept: text/event-stream` only).
- `tools/list` once; `tools/call probe_echo` reached the server and returned
  `echo:done` to the model. After the pushed `list_changed`: **no second
  `tools/list`**.
- Prompt completed `stopReason:"end_turn"`. After our `session/cancel` the
  client sent `notifications/cancelled` for the (already-answered) tools/call.
- Raw logs: `.build/probes/kimi-server.jsonl`, `.build/probes/kimi-acp.jsonl`.

## P0-4b — Kimi permission behaviour in ACP — PASS

- `session/request_permission`: **yes, twice** — one for the shell call
  (title `"Bash"`) and one for `mcp__probe__probe_echo`. Default mode asks for
  every non-read tool.
- Permission payload: `options` carry `optionId`
  (`approve_once`/`approve_always`/`reject`) **and** `kind`
  (`allow_once`/`allow_always`/`reject_once`); the embedded `toolCall` echoes
  `toolCallId` and `title` only (no `kind` on the toolCall inside the request).
- `session/update` tool_call **does** include `kind`: `"execute"` for `Bash`,
  `"other"` for `mcp__probe__probe_echo`.
- Kimi tool names observed: `Bash` (shell). `kimi acp` exposes modes
  `default|plan|auto|yolo` via `configOptions`/modes in `session/new`; CLI flags
  `-y/--yolo` and `--auto` are global options that parse both before and after
  the `acp` subcommand (`kimi --auto acp --help` and `kimi acp --auto --help`
  both print acp help); whether `--auto` actually suppresses
  request_permission inside an ACP session was **not** exercised (would have
  needed a second inference turn).
- Raw logs: `.build/probes/kimi-server.jsonl`, `.build/probes/kimi-acp.jsonl`.

## P0-3 — Codex `codex exec` MCP streamable HTTP — PARTIAL/PASS

- Client: `codex-cli 0.147.0` (`/opt/homebrew/bin/codex`).
- Command: `codex exec --skip-git-repo-check -m <model>
  -c 'mcp_servers.probe.url="http://127.0.0.1:PORT/mcp"'
  -c 'mcp_servers.probe.http_headers={Authorization="Bearer probe-token"}'
  -c 'mcp_servers.probe.startup_timeout_sec=20' "<prompt>"`.
  The inline-table `-c` override syntax for `http_headers` **parsed fine**
  (no fallback needed).
- MCP client: `codex-mcp-client/0.147.0`; `protocolVersion` requested:
  **`2025-06-18`**. `Accept: text/event-stream, application/json`;
  `authorization` present; `Mcp-Session-Id` echoed; `traceparent` header sent.
- Session lifecycle: Codex opens **a fresh MCP session per phase** — a startup
  session (initialize → initialized → GET stream → `tools/list` → `DELETE
  /mcp`) and then an execution session (initialize → initialized → GET stream →
  `tools/list` → `tools/call` → `DELETE`). GET SSE stream: **yes**.
- After `tools/call` + pushed `list_changed`: **no second `tools/list`** —
  the client tears the session down (`DELETE /mcp`) instead of re-listing.
- Model/auth caveats: configured default `gpt-6-sol` and `gpt-5.3-codex` were
  rejected server-side (`invalid_request_error: model is not supported when
  using Codex with a ChatGPT account`, zero tokens consumed). `gpt-5.6-sol`
  was accepted as a model but returned "at capacity". `gpt-5.6-terra`
  succeeded — one inference turn, tool call returned `echo:hello`.
- Raw logs: `.build/probes/codex-server.jsonl`, `.build/probes/codex-exec.log`.

## P0-5 — Managed-lane model access — PASS

- **Kimi**: `~/.kimi-code/credentials/` holds OAuth JSON files
  (`kimi-code.json`, `kimi-code-env-*.json`; fields `access_token`,
  `refresh_token`, `expires_at`, `scope:"kimi-code"` — values never printed).
  `~/.kimi-code/config.toml` keys (not values) show provider `type="kimi"`,
  `base_url="https://api.kimi.ai/coding/v1"`,
  `oauth_host="https://auth.kimi.ai"`, models `kimi-for-coding`,
  `kimi-for-coding-highspeed`, `k3`, `k3-256k` under provider
  `managed:kimi-code`.
  `GET https://api.kimi.ai/coding/v1/models` with `Authorization: Bearer
  <oauth access_token>` → **HTTP 200**, OpenAI-style `{"data":[{"id":...}]}`
  model list (no token material in body). So **yes, a Workshop-owned client
  can call Kimi's coding API directly with the CLI's OAuth grant.**
- **Fusion relay** (`~/projects/fusion-codex-relay`): a Connect-protocol
  reverse proxy for the Devin CLI, not a general completions endpoint.
  `fusion_relay/relay.py` serves `application/connect+proto` frames; routing
  is `route_for_model` → `"codex"` (ChatGPT backend `codex/responses`),
  `"forward"` (Cognition native stream), `"reject"`. Control endpoints are
  `GET /identity` (nonce proof), `GET /healthz`, `GET /capabilities`,
  `POST /host/ack`, `/host/compaction`, `/shutdown` (relay.py:1102–1216,
  1434–1460). There is **no OpenAI-style chat/completions route** a Workshop
  tool loop could call for raw completions; the codex route expects a valid
  Devin-native Connect session packet for a `fusion-*` model.
- **DeepSeek**: `Sources/WorkshopAdapters/DeepSeekAdapter.swift` already uses
  a direct API (also `type="openai"`, `base_url=https://api.deepseek.com/v1`
  in Kimi's config).

## P0-6 — `sandbox-exec` cross-generation read grant — PASS

- Profile modelled on the installed
  `~/Library/Application Support/Workshop/profiles/clean-v2/kimi/isolation.sb`
  pattern: `(allow default)`, `(deny file-write*)` + write allowlist for the
  own-generation dir, `(deny file-read* (subpath <root>))` + allow
  `file-read*` on own dir and peer `genB/workspace`, plus
  `file-read-metadata` on the literal `genB` parent.
- `sandbox-exec -f prof.sb /bin/sh -c ...`: `cat B/b.txt` → OK; write to B →
  `Operation not permitted` (denied); write to A → OK; read of the denied
  probes-root file → denied.
- Same profile under `/usr/bin/python3`: `open(B/b.txt).read()` → OK.
- Conclusion: a read-only grant on another generation's workspace works for
  both a shell and a scripting runtime, exactly like the installed profile.
- Raw artifact: `/private/tmp/workshop-probes-wk3567/prof.sb` (test profile).

---

## Implications for Phase 1 (facts only)

1. All three engineers speak MCP Streamable HTTP with bearer headers and send
   `Accept: text/event-stream, application/json`; Devin and Kimi request
   protocol `2025-11-25`, Codex requests `2025-06-18`.
2. All three echo `Mcp-Session-Id` and open a GET SSE stream; none issued a
   second `tools/list` in response to `notifications/tools/list_changed`
   (Codex deletes the session immediately after the call).
3. Devin's `.devin/mcp_config.local.json` accepts `transport:"http"` +
   `headers`; Kimi's ACP `session/new` accepts the HTTP variant with a
   headers **array** `[{name,value}]`; Codex accepts `-c` overrides including
   an inline table for `mcp_servers.*.http_headers`.
4. Permission surfaces differ: Devin honors `permissions.allow` +
   `--permission-mode` (zero request_permission); Kimi always prompts via
   `session/request_permission` in default mode but carries
   `allow_once`/`allow_always` kinds on options; both emit
   `session/update` tool_call events with `kind` (`execute` for shell).
5. Codex reconnects per phase and DELETEs sessions — a Workshop MCP bridge
   cannot assume a long-lived Codex MCP session or rely on
   tools/list_changed round-trips within one.
6. Kimi's coding API is directly callable with the CLI OAuth grant
   (`api.kimi.ai/coding/v1`, OpenAI shape); the Fusion relay exposes only
   Devin-native Connect frames and host-control endpoints — no generic
   completions route.
7. `sandbox-exec` read-only grants across generation dirs work as the
   installed profile suggests, for shells and Python runtimes alike.
8. Codex model availability is account-gated: `gpt-6-sol`/`gpt-5.3-codex`
   rejected for ChatGPT-account auth; `gpt-5.6-terra` worked.
