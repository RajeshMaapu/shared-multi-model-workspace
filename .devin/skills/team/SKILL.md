---
name: team
description: Explicitly submit a user-approved brief from Codex to Workshop when the user invokes $team or asks to send work to Workshop. Fusion owns delivery by default; involve Kimi and DeepSeek only when collaboration is requested, and Astra only for computer interaction. Ordinary conversation, quoted examples, and skill editing do not dispatch work.
---

# Team

Use Codex as the entry point to one durable Workshop conversation. This skill prepares a scoped brief and submits it through a verified Workshop MCP connection. It does not replace the daemon or native engineer harnesses.

## Invocation and authority

- Run only for an actual `$team` invocation or explicit request to send work to Workshop. Treat `/team` and `/my-team` as textual aliases only; do not claim registered slash commands.
- Treat `preview`, `draft`, and `do not send` as preparation only. Do not create a task or launch a worker.
- A submission request authorizes that handoff and its requested phase; do not ask for redundant confirmation. Ask one focused question when the objective or requested peers cannot be determined.
- Preserve existing execution approval. Do not send already-authorized implementation back through mandatory research or a three-engineer approval gate.
- Leave approvals, cancellation, subscriptions, credit purchases, installed-app replacement, and live-data migration subject to their existing authority boundaries.

## Team policy

- Make Devin Fusion the delivery owner. Default to `owner_only`; small tasks do not wake general peers.
- Use `requested_peers` only for explicitly requested collaboration. Select the requested existing Kimi and/or DeepSeek peers. If the user asks the general team to collaborate without narrowing peers, select both. Do not interpret research phase alone as a collaboration request.
- Keep proposals, questions, rebuttals, reviews, disagreements, assignments and outcomes in the same Workshop task. Do not demand unanimity. If a requested peer is unavailable, report it and ask whether to wait or proceed with reduced participation; do not claim full review.
- Keep Fusion's existing native SWE-2 sidekick. Do not launch additional Workshop subagents or turn Codex into a competing engineer.
- Route browser/desktop interaction to Astra only through a verified operator integration. Use Low effort routinely and Medium for unfamiliar/difficult work or after two unsuccessful attempts. Permission/connectivity errors are blockers, not reasons to escalate effort. Do not fabricate an Astra participant or callable tool when the connector lacks one.
- Consider the shared capacity snapshot when the service exposes it. Preserve source, freshness, reset window, account-pool sharing and unknown values. Do not infer provider quota from local usage budgets, count a shared pool twice, invent numeric thresholds, or reset credits automatically.
- Require a checkpoint, reconciliation of old processes, and a verified single-writer handover before changing implementation assignee. A shared path or expired database lease alone does not prove that old processes stopped writing. Keep delivery ownership separate from implementation assignment.

## Prepare a concise brief

Include title/objective, phase, explicit collaboration intent, requested peers, context/constraints, source references, registered workspace reference when known, acceptance criteria, approvals, budget limits and unresolved decisions. Preserve relevant corrections and rejected approaches without forwarding raw conversation history, credentials, unrelated personal instructions, or hidden reasoning.

For UI work include this approved Workshop constraint:

> First build the intended behavior as a web app. Use computer-use tooling to compare it against approved visuals and exercise interactions. Record the reference, exact web revision, screenshots, findings and passed retest. Only then carry the same renderer into Electron. Subsequent UI changes invalidate that validation. If computer use is blocked, report it and do not claim validation or proceed with carry-over. Native packaging and lifecycle need separate checks.

Keep this entry-point skill out of clean engineer profiles. Do not inject personal skills or repository agent instructions into launched engineer context.

## Verify the connection before submission

Discover the actual tools and schemas on the configured Workshop MCP server. The expected capabilities are `workshop_create_task`, `workshop_get_task`, `workshop_list_tasks`, `workshop_read_messages`, and `workshop_post_message`; names here are not proof they are callable.

For new submissions require a connector whose create schema supports `schema_version`, `collaboration_mode`, and `origin`. Use `schema_version: 2`. Do not silently send the new contract to a legacy connector or rely on unknown fields being ignored. If the installed connector is older, prepare the brief and report that the matching bridge/daemon upgrade is required. Do not upgrade, restart, reconfigure, or install services as part of invoking this skill.

If no usable connection is available, show **Prepared — not submitted**, the brief, and the specific missing connection/capability. Do not claim a task or engineer notification exists.

## New task identity and retries

Generate one random invocation identifier for each intentional new task, even if its wording is identical to an earlier task. Never derive identity from title/objective/phase content.

Use the bundled `scripts/invocation.py` helper to persist the complete request before dispatch:

1. Write the scoped non-secret brief as JSON with `title`, `objective`, `phase` (`execution` or `research_proposal`), `collaboration_mode` (`owner_only` or `requested_peers`), `participants` (empty for owner-only, otherwise the selected `kimi`/`deepseek` IDs), and optional `constraints`, `sources`, `workspace_ref`, `acceptance_criteria`, `budget_policy_ref`, `channel`.
2. Run `python3 <skill-directory>/scripts/invocation.py new --brief <brief.json>`. Supply `--source-task-id <actual-Codex-thread-id>` only if that identifier is provided by the runtime; never invent one. The helper returns the journal path and exact request, including `idempotency_key: codex-invocation-<random-id>`. With a real source ID it also includes the origin binding. Without it, explicitly report that automatic origin resolution is unavailable.
3. Submit the returned `request` unchanged via the verified `workshop_create_task` tool. Do not submit the journal envelope.
4. On a confirmed receipt, save its JSON and run `python3 <skill-directory>/scripts/invocation.py receipt --journal <journal.json> --receipt <receipt.json>` to retain the task ID for retries and follow-ups.
5. After a timeout or uncertain result, retain the journal. Read it with `python3 <skill-directory>/scripts/invocation.py show --journal <journal.json>`. If a receipt is present, inspect that task. Otherwise retry only the identical persisted request/key through the idempotent create tool. Never generate a fresh invocation to resolve an uncertain submission. Treat a payload conflict as a blocker, not permission to create a duplicate.

These journals contain only the deliberately scoped brief/receipt. Do not place credentials or entire transcripts in them. Their persistence is not an automatic Codex callback.

## Follow-ups and results

- Resolve the known Workshop task ID from the saved receipt or an explicit verified user reference. A Codex thread can create multiple Workshop tasks; do not guess which one a follow-up targets. Ask when ambiguous.
- Read committed messages using `after_seq` and preserve the observed cursor. Acknowledge only messages actually read. The current create receipt sequence is an event cursor, not necessarily a message cursor; do not interchange them.
- Append the follow-up with `workshop_post_message` on the existing task ID. Never create a `follow_up` task. Do not blindly retry an uncertain message append: inspect recent messages and resolve delivery first because legacy append calls are not idempotent.
- Report actual title, task ID, returned verified link when available, phase, collaboration mode and selected peers. Distinguish created, queued, running, blocked, verifying and completed using current tool evidence. Task creation or a model saying it finished is not proof of verified completion.
- Report fake adapters, unavailable peers, unqualified computer use, unknown telemetry and missing writer enforcement explicitly. A design mock or a synthetic test is not live integration evidence.
- Monitor only as requested using durable reads and bounded waits. Do not fabricate unsolicited replies into the originating Codex conversation; the durable Workshop conversation is the return surface until a supported callback channel is qualified.

If the bridge reports "Workshop service is not running. Open Workshop.app (or start the background helper). Nothing was submitted.", show **Prepared — not submitted**, preserve the journal for a future explicit retry, and stop without claiming that any engineer was notified.
