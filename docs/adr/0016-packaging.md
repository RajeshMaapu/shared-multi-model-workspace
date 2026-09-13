# ADR 0016 — Packaging: Developer ID intent, no sandbox, no notarization yet

## Status

Accepted (Phase 5)

## Context

Workshop must ship as a user-installable `.app` containing the UI, the daemon
helper, and the MCP bridge (spec §4.1). The daemon spawns engineer CLIs
(devin/kimi CLIs, ACP harnesses), writes under
`~/Library/Application Support/Workshop`, and binds a Unix socket — behaviour
that cannot run under App Sandbox.

## Decision

- `scripts/package.sh` builds all three products in release, assembles
  `dist/Workshop.app` (MacOS/{Workshop,workshop-daemon,workshop-mcp},
  Info.plist with `CFBundleURLTypes` for `workshop://`, LaunchAgents plist at
  `Contents/Library/LaunchAgents/ai.maapu.workshop.daemon.plist` with
  `BundleProgram`, `RunAtLoad`, `KeepAlive=false`, `WORKSHOP_ADAPTERS=live`),
  then codesigns each binary and the bundle with `--options runtime
  --timestamp`.
- Signing identity is discovered via `security find-identity -v -p
  codesigning` preferring `Developer ID Application:`. On this machine the
  only identity is the local self-signed "Maapu LLC" (no TeamID), so builds
  are signed locally with hardened runtime but are NOT Apple Developer ID
  signatures.
- No App Sandbox — the daemon must spawn CLIs and manage sockets/worktrees.
- No notarization — requires Apple ID credentials; out of scope.
- User-level install at `~/Applications/Workshop.app`; `/Applications` is
  never touched.
- `spctl --assess --type execute` rejects the app (expected for a
  non-notarized, non-Developer-ID signature). Locally built copies run fine —
  they are never quarantined; a downloaded copy would be blocked and needs
  right-click → Open or notarization.
- The LaunchAgent helper is registered only through the Settings toggle
  (`SMAppService.agent(plistName:)`, status surfaced, "Open Login Items
  settings" button). Stop background work leaves the registration in place
  but idle (`KeepAlive=false`).

## Consequences / operational note

- Replacing the bundle in place (`cp -R` over `~/Applications/Workshop.app`)
  while the daemon runs gets the running image SIGKILLed (CODESIGNING Invalid
  Page — observed 2026-09-13). Installers must `rm -rf` the old bundle first
  (or move it aside), then copy. `scripts/package.sh` builds into `dist/` and
  does not install; the install step is a `rm -rf && cp -R`.
- Build identity is the bundle `CFBundleVersion`; the daemon reports it via
  `workshop.health.build` and the app warns "Service is running an older
  build — Stop background work and relaunch" on mismatch. Dev (unbundled)
  builds carry `bin:<mtime>-<size>` and never compare against bundle ids.
