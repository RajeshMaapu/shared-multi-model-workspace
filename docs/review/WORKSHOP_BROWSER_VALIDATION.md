# Workshop browser validation and recovery

Use the user's selected browser and its supported automation tool. Read the effective browser documentation and declared capabilities before deciding that a control is unavailable. A missing method on one page API does not establish that the browser lacks that capability.

## Deterministic procedure

1. Select the documented browser connection and inspect its current tabs. Confirm the exact preview URL with an actual screenshot and DOM state; do not infer success or failure from a tab title.
2. If navigation fails, preserve the exact error and distinguish a browser error from an explicit tool-policy denial. Use the bundled browser troubleshooting diagnostics for connection failures. Do not repeat unchanged checks or inspect a denied page through another surface.
3. Inspect declared browser capabilities before requesting manual resizing. The successful Chrome route on 2026-09-17 was `browser.capabilities.get('viewport')` with documented `set` and `reset` operations. Read the effective API signature before calling; do not guess arguments, use raw CDP, or substitute an unrelated controller.
4. Set each required viewport, 1586×992 then 980×680. Measure `innerWidth`/`innerHeight`, document client dimensions, and document scroll dimensions. Inspect the actual screenshot for layout, clipping and reference parity. A screenshot's existence alone is not a passing check.
5. Save actual screenshots and JSON measurements, record supported warning/error console observations, and reset the viewport after capture. Bind completed checks to the current renderer hashes and approved reference through the existing validation gate.
6. Keep browser validation, isolated fake-adapter interactions, live-model qualification, installed-app verification, and saved Team submission as separate results. Never submit an existing request twice to demonstrate UI behavior.

## Observed incident and limits

On 2026-09-17, the original local preview URL produced `ERR_BLOCKED_BY_CLIENT` in Chrome automation. Bundled checks reported Chrome running, its extension enabled, and a correct native-host manifest. A host request returned HTTP 200. The server had no access logging, so its log could not establish whether the failed browser request arrived.

Inspection of `chrome://policy` separately received an explicit Browser Use URL-policy denial. That denial did not establish the cause of the local preview error. No protection was disabled, no address or transport was substituted to evade a restriction, and no policy inspection fallback was used.

A later inspection of the existing Chrome tab at the exact original URL showed the working application. The cause of the earlier failure remains unknown; no root-cause repair is claimed. The documented viewport capability then produced both exact sizes without document overflow, with no reported console warnings/errors, and restored the prior viewport.

## Stop and recovery conditions

Stop the denied operation on an explicit policy refusal; do not retry it through another surface. Do not change healthy extension/native-host configuration without evidence of a defect. Follow the bundled supported repair instructions if diagnostics identify a connection defect. If required browser controls are unavailable, report the exact missing capability and keep the visual gate incomplete. Request manual evidence only after checking effective capabilities and respecting the user's preference for automation. Re-inspect current tab state when new evidence indicates a change; do not assume an old navigation error is permanent.

No renderer edits, dependency installations, production restarts, credentials changes, or browser-security changes are part of this diagnostic procedure. It requires no rollback beyond resetting the viewport; any separate repair must have its own validation and rollback plan.
