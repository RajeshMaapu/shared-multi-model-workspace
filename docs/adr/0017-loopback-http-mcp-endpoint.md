# ADR 0017: Loopback Streamable-HTTP MCP endpoint; stdio bridges retired

## Status

Accepted 2026-09-28 (amends ADR 0003 "no TCP port"; supersedes ADR 0006 and
ADR 0009)

## Context

The stdio bridge processes were spawned by Codex threads and by each harness,
freezing tool schema, token and sandbox at spawn. Live evidence (2026-09-27):
six concurrent Codex bridges, 11 `initialize` failures from inside the writer
sandbox, stale-generation token errors, and a manual "quit and reopen Codex"
after every install.

## Decision

The daemon hosts one MCP Streamable HTTP endpoint on 127.0.0.1 — port 47831
for the installed home, ephemeral otherwise, advertised in
`<runtime>/mcp.json`. Every request is bearer-token authenticated and
writer-scope authorized; sessions live in memory bound to the token hash, so
a daemon restart invalidates them and clients re-initialize per spec on 404.
The `Origin` header is allowlisted to loopback and sessions/calls are logged
without tokens. Devin receives a `url`-based `.devin/mcp_config.local.json`,
Kimi the ACP HTTP `mcpServers` variant, Codex `url` + `http_headers`.
`workshop-mcp` remains only as a stateless stdio shim that re-reads its token
on every call. Tool schemas are a backward-compatible contract carrying
`workshop_catalog_version` on every result — probes showed no client re-lists
on `tools/list_changed`. UDS stays for the desktop UI.

## Consequences

One loopback TCP listener now exists: token-gated, same-uid trust boundary as
before — a same-uid process holding a token has that token's authority,
unchanged. Sealed snapshots exclude `.devin/mcp_config.local.json` so tokens
never enter a digest. Daemon upgrades no longer require a Codex restart for
new threads; existing threads keep their cached tool inventory until Codex
reloads.
