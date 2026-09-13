# ADR 0001: SwiftPM without an .xcodeproj

## Status
Accepted

## Context
Workshop is a new standalone project. The spec recommends a proposed layout, not a
specific build system. An .xcodeproj adds merge-prone generated state and complicates
`swift test` on CI.

## Decision
Pure SwiftPM (`// swift-tools-version: 5.10`, `.macOS(.v14)`, Swift 5 language mode).
Four libraries (`WorkshopCore`, `WorkshopStore`, `WorkshopService`, `WorkshopIPC`) and
two executable targets (`workshop-daemon`, `WorkshopApp` → product `Workshop`).
`scripts/dev.sh` assembles a minimal `.app` bundle around the built binaries and signs
it ad-hoc so LaunchServices/`open` work during development.

## Consequences
`swift build` / `swift test` are the only build commands; no Xcode project to maintain.
The .app is a dev convenience — a signed Developer ID bundle with SMAppService helper
registration is deferred to packaging work (ADR 0005).
