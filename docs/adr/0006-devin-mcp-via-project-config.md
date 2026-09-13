# ADR 0006: Devin MCP tools via project config file, not ACP injection

## Status
Accepted (verified by live probes, 2026-09-13)

## Context
ACP `session/new` accepts an `mcpServers` param. Live probe D showed that for
Devin 3000.10.21 this is insufficient: the injected server connects
(`"MCP server 'workshop' connected successfully"`) but the agent's
`mcp_list_tools` fails with `"MCP server 'workshop' not found in configuration
for list_tools"` — Devin resolves MCP tools from its **config file**, not the
ACP-injected list. Kimi resolves injected servers correctly.

## Decision
- Devin: write `<worktree>/.devin/mcp_config.local.json` with
  `{"mcpServers":{"workshop":{"command":..., "args":[...], "transport":"stdio"}}}`
  and send an empty `mcpServers` array over ACP. Add `.devin/` to the
  worktree's `.git/info/exclude` when it is a git worktree.
- Kimi: send `mcpServers` in `session/new` (verified end-to-end: connect →
  tools/list → tools/call → canary returned).

## Consequences
- The Devin session store is hardcoded at `~/.local/share/devin/cli`
  (sessions.db + session_locks) regardless of XDG_DATA_HOME; the
  sandbox-exec profile must `allow file-write*` on that subpath or
  `session/new` fails with "readonly database".
- Two MCP code paths must be maintained; `MCPInjection` enum in
  `ACPHarness.swift` selects per harness.
