# ADR 0003: Daemon over a Unix-domain socket

## Status
Accepted — Revision 2026-09-28: the UDS remains the UI transport; MCP moved
to a loopback TCP listener per ADR 0017.

## Context
UI clients must never write SQLite; the service is the single writer. IPC needs a
private, versioned channel between app and service.

## Decision
`workshop-daemon` owns the database and serves newline-delimited JSON-RPC 2.0 on
`${DARWIN_USER_TEMP_DIR}/workshop/service.sock` (POSIX BSD sockets; no
Network.framework, no TCP port). Directory mode 0700, socket mode 0600, and a peer-uid
check (`getpeereid`, the macOS `LOCAL_PEERCRED` equivalent) that closes non-same-uid
connections. Single instance enforced by `flock` on `service.lock`.

## Consequences
Single writer with a durable outbox; peers are identified by uid only — per §9.3 this
is a local trust boundary, not protection against a malicious same-uid process; that
limitation is documented, not solved. `workshop-mcp` (Codex bridge) is deferred.
