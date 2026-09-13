# ADR 0008: DeepSeek adapter manages its own runtime; reasoning stays private

## Status
Accepted (verified by live probe, 2026-09-13)

## Context
DeepSeek has no ACP harness. Probe C verified the direct API shape:
`POST /v1/chat/completions` with `model:"deepseek-flash"`,
`thinking:{type:"enabled"}`, `reasoning_effort:"max"` returns
`reasoning_content` + `tool_calls`; continuation requires echoing the
assistant message **including** `reasoning_content` back, followed by
`{role:"tool"}` results.

## Decision
- The adapter owns the tool loop (max 8 iterations, `max_tokens` 4000/turn) and
  executes the §8.3 Workshop tools in-process via `service.callTool` with
  principal `.engineer(.deepseek)`.
- Conversation history is persisted per (task, worker) at
  `<WORKSHOP_HOME>/sessions/deepseek/<task>/<worker>.json` — **visible
  messages only**. `reasoning_content` is echoed in-memory inside a tool
  sequence but stripped before persistence (reasoning is provider-private
  continuation state, not workspace content).
- The API key is a credential reference read at request time from
  `~/.kimi-code/config.toml` `[providers.deepseek] api_key` via a targeted
  section/key scanner — never persisted, logged, or committed.

## Consequences
- Error mapping: 401 → `authRequired`, 402/429 → `quotaLimited`,
  5xx → `uncertain`.
- Usage `cache_read` maps `prompt_cache_hit_tokens`; `cache_write` is nil
  (DeepSeek reports no write counter).
