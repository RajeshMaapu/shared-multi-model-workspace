# ADR 0005: Deep links and notifications deferred to packaged bundle

## Status
Accepted

## Context
§8.4 wants a `workshop://task/<id>` deep link in create-task receipts, and §3.8 wants
macOS notifications. Both require a registered bundle (`CFBundleURLTypes`) and signing
beyond the Phase 1 ad-hoc dev bundle.

## Decision
`CreateTaskReceipt.deepLink` is always nil this phase — a truthful absence rather than
an unregistered scheme. The dev `.app` Info.plist deliberately omits
`CFBundleURLTypes`. Notifications and URL scheme registration land with the signed
packaging work.

## Consequences
Receipts cannot deep-link into the app yet; the task id is the stable reference. When
the scheme is registered and tested, the service will start emitting it.
