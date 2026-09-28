# Activity feed update — staged, not installed

## Implementation

The selected task now has a truthful active-turn indicator and expandable work activity history. A fresh connected `getTask` result must report task state working and nonempty runningEngineers before dots animate. The label is “Worker turn active”; it explicitly does not establish output or forward progress. Five-second polling, fifteen-second freshness expiry, request-start timestamps, and reduced-motion CSS prevent cached or delayed state from masquerading as current activity. Non-working, waiting, disconnected and unknown states do not animate.

The daemon records bounded, redacted, allowlisted user-visible activity into the existing durable outbox, with ordered sequence, task/turn/engineer identity and timestamp. Tool call IDs are hashed for stable opaque correlation, including updates without a preceding start. Tool status, permission denial, authentication/quota status, provider uncertainty, message arrival, and turn lifecycle are distinct. Legacy tool start/finish events are preserved. Synthetic lifecycle is labeled separately; lease heartbeats are not progress.

The task-scoped authenticated desktop API `workshop.readActivity` reads pages of up to 200 events after a validated cursor. Web and restricted Electron preload expose only `getActivity(taskID, afterSeq)`. The collapsible history preserves ordering, deduplicates sequence IDs, isolates tasks, supports incremental loading/reconnect, and explicitly shows unavailable or empty pre-instrumentation history. Turn-end events qualify unfinished tool status without inventing completion.

No raw provider payloads, tool arguments/results, private prompt bodies, hidden reasoning or native log files are added to the feed. Titles use the existing registered-secret redactor plus credential-field patterns and a 240-character bound; correlation IDs are hashed. Provider message chunks continue through the existing message store; the activity feed records arrival, while full committed text remains in the conversation. This is not a complete CLI transcript or proof of provider health.

## Evidence

- Full Swift regression after event preservation: 163 tests, eight opt-in tests skipped. One new fixture count assertion initially expected two rather than four preserved tool events; corrected. The final targeted WorkActivityTests rerun passed both tests. All other tests in that full run passed.
- Earlier full Swift run before legacy event preservation: 163 tests, eight skipped, zero failures.
- Final web/desktop suite: 74 tests, 73 passed, zero skipped, one expected failure: current repository visual-validation gate.
- Actual separate fake-daemon integration validates activity API persistence, task isolation, cursor/replay alongside owner/peer creation and replies.
- Adapter contract tests verify tool-call ID mapping and exclusion of agent_thought_chunk. Service tests verify durable reopen, pagination, task isolation, redaction, legacy and correlated events, and terminal worker state.
- JavaScript syntax and diff hygiene checks passed.

## Browser and installation boundary

Fresh Chrome navigation to the new isolated preview was blocked with ERR_BLOCKED_BY_CLIENT. The browser helper was explicitly denied trying the separately planned synthetic fixture as an alternate-port workaround. No further navigation or alternate transport is authorized to evade that restriction. No fresh screenshot/interaction evidence exists for this renderer revision. `Web/web-validation.json` is explicitly pending; previous screenshots do not validate it. Do not package or install this change until supported fresh web validation passes.

The previously validated installed Electron app remains running unchanged. No active worker was interrupted, no task duplicated, no Thenali proposal promoted, and no native database modified by this work. After an eventual authorized installed runtime update, follow the standing actual-session Codex reconnect checklist.

## Native persistence observation

The task worker returned a substantive report and reached verifying with no running engineer. Earlier no-output observations are superseded. The isolated native sessions.db is still absent; task-specific logs reported SQLiteCannotOpen14 despite a writable-parent probe. The profile source already grants its data/devin/cli path. Neither a precise filesystem cause nor a safe repair is established. This log condition is not represented by the current adapter event contract and is not invented as an automatic UI health status. Any further reproduction should use the same binary in a separate narrow profile/sandbox, without inference or writes to the installed worker database; do not weaken protections.

## Next checks

Use an allowed existing exact-preview Chrome tab once available; verify both exact viewport sizes, active/quiet/terminal/disconnected scenarios, reduced-motion behavior, expandable history and replay, and required create/options/peer/message regression. Bind evidence to the final hashes. Then rerun the gate, build the final release, confirm no running task would be interrupted, and coordinate the supported backend handover and actual-session MCP refresh. Do not treat the staged release from an earlier intermediate build as final.
