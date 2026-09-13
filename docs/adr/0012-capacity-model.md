# ADR 0012: Capacity model — unknown ≠ zero ≠ unlimited; reservations

## Status
Accepted

## Context

§10 requires resource policy that can dispatch or refuse based on provider
budget. Two failure modes dominate naive designs: treating a missing
measurement as zero (blocks forever) or as unlimited (oversubscribes), and
letting N parallel turns each spend the full remaining budget.

## Decision

- `CapacityPolicy` per engineer bucket in `engineers.json`:
  `{daily_token_cap?, reserve_per_turn = 30000, low_pct = 20,
  critical_pct = 10, hysteresis_pct = 5}`.
- `remaining` is a **decimal string or the literal `"unknown"`** — never a
  number we didn't measure. Unknown when `daily_token_cap` is unset or when
  any of today's usage samples has nil counters (Kimi reports none). Unknown
  allows dispatch unless `require_known_capacity` is configured; it is never
  rendered as "unlimited" or a percentage.
- Every turn holds a `reservations` row (`held`) of `reserve_per_turn` before
  dispatch; the turn reconciles it to actual usage (`reconciled`) on
  completion or `released` on recovery — so the sum of held reservations can
  never exceed remaining.
- Availability: `available | low | critical | limited | unknown`. `limited`
  comes only from provider signals (402/429 → 15 min, DeepSeek balance probe
  `is_available == false`) with hysteresis on recovery so the bucket does not
  flap at the threshold.
- `critical` blocks new dispatch once per task+bucket (no retry storm), asks
  the owner to checkpoint at the end of its current turn, and proposes an
  eligible replacement. Automatic reassignment happens for small tasks only,
  after the turn ends and a checkpoint exists; substantial tasks require the
  user's `workshop.reassignSubtask`. Never auto top-up.

## Consequences

A fresh install with no caps behaves as unknown-allowed and dispatches
normally; operators opt into enforcement by setting `daily_token_cap`.
Usage is computed from `usage_samples` for the local day, so a day boundary
resets the bucket without an explicit reset timestamp.
