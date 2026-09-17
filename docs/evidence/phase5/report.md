# Phase 5 evidence index

- Codex transcripts (raw evidence retained privately, see
  `docs/evidence/README.md`): run 1 created `<redacted-task-id>`
  via workshop_create_task (committed_seq 2, queued, deep
  link present; model gpt-5.6-luna — configured gpt-6-astra needed a newer
  CLI); run 2 re-sent the same brief but the model used the untruncated
  64-char sha → distinct key → second task (fixed by key normalization,
  ADR 0015); run 3 posted the follow-up (seq 6, author user + via=codex,
  owner wakeup dispatched).
- `deeplink-task.png` — `open workshop://task/<redacted-task-id>` selected the
  Codex-created task in the packaged app. Re-captured on the rc1 rebuild:
  the tool-only DeepSeek turn no longer leaves an empty row and via=codex
  messages no longer show a "via codex" structured card.
- `update-banner.png` — installed app (0.1.0-rc1) against a daemon running
  from a 0.1.0-test99 bundle: build-mismatch banner.
- `update-banner-1440x960.png` — same banner rendered deterministically via
  the WORKSHOP_FAKE_UPDATE_BANNER dev hook.
- `menubar-item.png` — status item (35×24, natural size).
- `menubar-menu.png` — menu-bar extra popup (~500×500).
- `settings.png` — Settings window with helper toggle/status + mute (~500×500,
  natural size).
- Notifications: banner delivery not capturable headlessly; posted content is
  `Workshop / <task title> / <reason>` for awaiting_architecture_approval,
  blocked, and verifying states — see NotificationPoster.swift. The
  packaged daemon's follow-up wakeup turn is exactly such a transition
  (verifying).
