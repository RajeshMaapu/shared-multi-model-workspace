# ADR 0014: Lease registry, not a browser tool

## Status
Accepted

## Context

§9.2 requires coordinating access to scarce external resources — a browser
or computer-use runtime owned by whichever engineer's harness provides one.
Workshop must not grow a browser tool of its own; it coordinates.

## Decision

- `leases(resource PK, owner, task_id, generation, expires_at, url)` is a
  durable registry. `workshop_acquire_lease {resource, ttl_seconds ≤ 900,
  url?}`, `workshop_renew_lease`, `workshop_release_lease` use generation CAS:
  acquire succeeds when absent or expired (takeover bumps generation),
  renew/release succeed only for the current owner at the current
  generation.
- Leases are advisory records for the engineers' own runtimes to honor;
  they are not enforced inside harnesses. On restart, leases are left
  untouched — the sweeper/TTL decides, because a lease may legitimately
  outlive the service process that granted it.
- A lease `url` lets the holder advertise where its browser/computer-use
  endpoint lives without Workshop proxying it.

## Consequences

Contention resolution is deterministic (generation fencing) and survives
restarts via TTL rather than liveness tracking. Workshop stays free of a
browser automation surface — that belongs to the runtime that already has
one (§9.2).
