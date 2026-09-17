# Supported browser validation procedure

Use the user's chosen browser. Read the effective tool documentation and declared capabilities before asking for manual work. A missing method on one page API does not establish that the browser lacks a capability.

Inspect the actual current tab, screenshot and DOM at the exact preview URL. A previous ERR_BLOCKED_BY_CLIENT is an observation, not a diagnosed permanent or browser-wide restriction. A separate policy-page denial does not establish the original failure's cause. Follow the bundled connection diagnostics; do not disable protections, inspect denied pages indirectly or try another address/transport to evade a denial. Avoid repeated unchanged checks. Reinspect only after a real state change or supported user action.

For automatic sizes, the supported Chrome route is the declared viewport capability: `browser.capabilities.get('viewport')`, with its documented `set` and `reset` methods. Read the effective signatures before calling. Capture at 1586×992 and 980×680, measure inner/client/scroll dimensions, visually inspect the actual screenshots and intended interactions, save measurements and evidence, then reset. No raw CDP or unrelated automation substitute.

Compare against the approved reference with qualified findings, not a blanket pixel-parity claim. Bind passing evidence to final renderer hashes. If unavailable or blocked, leave the visual gate pending and do not carry the changed UI into an installed app. Browser validation, fake-adapter interaction tests, live-model qualification, native installation, configured-session connection and task submission are separate outcomes.

No new background service or automatic repair is authorized by this procedure.
