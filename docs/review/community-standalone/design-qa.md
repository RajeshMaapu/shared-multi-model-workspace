# Workshop community preview — design QA

final result: passed

Scope: local design prototype, approved visual direction and primary task interactions. This is not production integration, Electron, accessibility certification or live model validation.

## Evidence

- Source visual truth: `../workshop-approved-reference.png` (1586×992).
- Browser: Codex in-app browser, controlled through computer-use tooling.
- Local URL: http://127.0.0.1:4175/
- Full-size implementation: `preview-1586.png`, viewport 1586×992, matching source dimensions.
- Compact implementation: `preview-980.png`, viewport 980×680.
- Capacity scenario capture: `capacity-scenario.png` (illustrative state, not live telemetry).
- Source and full-size implementation were opened together in the same comparison tool result. The original was inspected before building. The displayed comparison made sidebar, tab and message typography readable; no additional focused crop was needed for this scoped direction review.
- Screenshots used the browser's capture output; no screenshot was replaced with an ImageGen UI mock. Original app icon was generated separately and used as an actual asset.

## Findings and fixes

1. [P2, fixed] Initial right-pane spacing placed too much discussion below the first screen. Removed a redundant provenance badge, shortened repeated copy, and reduced message/header spacing. Recaptured `preview-1586.png`. Remaining scroll is intentional for long conversation, with composer and tabs fixed in their panes.
2. [P1, fixed] Pointer submission did not activate the task form reliably through the tested browser path, although keyboard activation succeeded. Added explicit form requestSubmit handling to the send buttons. Retested pointer task creation and reply submission; visible task/reply state updated, no console errors.
3. [P2, fixed] Sidebar account row clipped at 980×680. Added compact-height spacing rules. Recaptured `preview-980.png`; account visible, no horizontal overflow, images loaded.
4. [P2, fixed] Simulated writer ownership initially used a global field. Changed it to a per-task map. Retested: Kimi is writer on the reassigned task; switching to the small task shows Fusion as its writer.

## Required fidelity surfaces

- Typography: system sans-serif, 22px pane headers, compact 14–16px conversation text and 12–13px supporting labels. Line wrapping examined at both desktop widths; no hidden persistent controls in the final compact capture.
- Spacing/layout: reference's four columns and 46px top bar retained at source size. Narrow rail, purple sidebar, central task list/composer and right thread all remain recognizable. Exact source text is intentionally updated to reflect the approved four-participant topology and owner-only task.
- Colors: aubergine top/sidebar, pale lavender selected task, white conversation surface, dark green send controls and blue links. Source's subtle sidebar shading is simplified to a solid surface; minor polish only.
- Assets: generated woven-W icon is present in the rail and Files dialog. Standard macOS SF Symbols exported locally are used for controls; no new library install. Engineer initials intentionally identify participants instead of copying vendor marks. Symbol/license suitability should be rechecked before packaging for broader distribution; current target is a macOS design review.
- Copy: From Codex/$team provenance, explicit requested collaboration, small-task owner-only behavior, dedicated Astra computer review, shared writing and capacity details are shown. No claim that preview task creation invokes models.

## Browser interactions actually checked

- Conversation, Ownership, Proposals, Decisions and Files navigation.
- Proposal approval appears as a decision (preview only).
- App icon dialog opens and closes.
- Task creation by keyboard and corrected pointer action; new task appears.
- Reply submission; text appears under the selected task.
- Search empty result and keyboard clearing restores tasks.
- Small-task selection shows Fusion-only participation.
- Capacity initially Unknown with source/freshness/reset labels; demo toggle shows explicitly simulated low headroom.
- Simulated reassignment reports checkpoint/reconciliation then writer transfer; separate tasks do not inherit it.
- Final compact DOM measurements: no horizontal overflow, no broken images.
- Browser warning/error log checks returned no entries at the tested points.
- Viewport override reset; prototype left open as a deliverable.

## Remaining limits / P3 polish

- Secondary DMs/Activity/Later controls explicitly state they are outside this prototype; formatting/attachment toolbar is visual-only. There is no account authentication, durable browser storage or backend connection.
- Compact web responsive layout exists, but full mobile QA was not performed. VoiceOver, complete keyboard focus trapping in dialogs, contrast certification and native Electron packaging remain future checks.
- Preview conversation timestamps/reply counts and ownership are fixtures. Capacity defaults are Unknown; numerical allowance is never invented. The scenario selector is a design-review control, not a production assignment API.
- This approval is limited to the preview revision recorded in the design commit; subsequent UI changes require another visual/interaction pass.
