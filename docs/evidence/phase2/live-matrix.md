# Phase 2 live integration matrix

Date: 2026-09-13. Command: `WORKSHOP_LIVE=1 swift test --filter LiveSmokeTests`
(exit 0, 5 tests, ~70 s). Raw evidence JSONs retained privately (see
`docs/evidence/README.md`).

| Engineer | Binary / CLI | Model selector | Reasoning | Capabilities verified live | Usage / cache | Wall |
|---|---|---|---|---|---|---|
| Devin | devin 3000.10.21 (qualified) | `fusion-claude-fable-5-1-medium-sidekick-swe-2-medium` | Fusion pairing | ACP `session/new`, MCP via project `.devin/mcp_config.local.json`, `workshop_post_message` tool call after `session/request_permission` (auto allow_once), session binding persisted, restart `session/load` recall | input 23 179, output 3, cache read 22 829, cache write 348 (`acp:devin`) | ~12 s |
| Kimi | kimi 0.42.0 (qualified) | `kimi-code/k3` | high | ACP `session/new` with `mcpServers` injection, permission `allow_once`, `workshop_post_message`, `session/load` recall after restart | usage row present; counters nil (Kimi ACP does not report usage on `session/prompt` result) | ~21 s |
| DeepSeek | api.deepseek.com chat/completions | `deepseek-flash` (response `model` field) | max (`reasoning_effort`) | direct tool loop, `workshop_post_message` executed in-process, managed session file under `sessions/deepseek/` | input 1 164, output 139, cache read 0, cache write n/a (`deepseek:usage`) | ~2 s |

## L4 peer roundtrip (~24 s)

Devin posted `@kimi` via `workshop_post_message` → wakeup → Kimi posted
`KIMI_ACK_<nonce>` mentioning `@deepseek` → wakeup → DeepSeek posted
`DEEPSEEK_ACK_<nonce>`. Wakeup rows: 2 done, 0 suppressed; engineer turns ≤ 5.

## L5 restart recall (~11 s)

Service closed and reopened on the same `WORKSHOP_HOME`; participant
`last_read_seq` set so the packet contained only the new user reply. Verified:
the captured packet omitted the earlier posted message line, and each
engineer's native session reply contained the earlier nonce — native session
memory proven for Devin and Kimi.

## Unknowns / limitations

- Kimi ACP reports no token usage on `session/prompt`; a usage row is recorded
  with nil counters (distinguishes "unmeasured" from "no turn").
- DeepSeek reports no cache-write counter; `cache_write` is always nil.
- Quota buckets remain `unknown` (never measured) by design this phase.

## Secret scan

The raw live evidence (retained privately) was grepped for `Bearer`,
`api_key`, `sk-`, and the first six characters of the DeepSeek key: no matches.
