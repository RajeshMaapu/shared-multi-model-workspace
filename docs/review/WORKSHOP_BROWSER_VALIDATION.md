# Supported browser validation procedure

Use the user's chosen browser. Read the effective tool documentation and declared capabilities before asking for manual work. A missing method on one page API does not establish that the browser lacks a capability.

Inspect the actual current tab, screenshot and DOM at the exact preview URL. A previous ERR_BLOCKED_BY_CLIENT is an observation, not a diagnosed permanent or browser-wide restriction. A separate policy-page denial does not establish the original failure's cause. Follow the bundled connection diagnostics; do not disable protections, inspect denied pages indirectly or try another address/transport to evade a denial. Avoid repeated unchanged checks. Reinspect only after a real state change or supported user action.

The user approved acquiring Chrome tooling for this checkout. The verified route is pinned Playwright Core 1.62.1 with `chromium.launch({ channel: 'chrome', headless: true, chromiumSandbox: true })`, a fresh context, and `page.setViewportSize`. Use the installed Google Chrome, not Aside or a personal browser profile. Capture at 1586×992 and 980×680, measure inner/client/scroll dimensions, visually inspect the actual screenshots and intended interactions, capture console warnings/errors before navigation, save measurements and evidence, then restore the initial viewport. No raw CDP, disabling browser protections, or changing targets to evade a denial. Other hosts may expose the declared `browser.capabilities.get('viewport')` API instead; follow that host's documented set/reset signatures.

Compare against the approved reference with qualified findings, not a blanket pixel-parity claim. Bind passing evidence to final renderer hashes. If unavailable or blocked, leave the visual gate pending and do not carry the changed UI into an installed app. Browser validation, fake-adapter interaction tests, live-model qualification, native installation, configured-session connection and task submission are separate outcomes.

No new background service or automatic repair is authorized by this procedure.
