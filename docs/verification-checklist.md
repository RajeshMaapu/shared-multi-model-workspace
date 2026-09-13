# Verification checklist — v0.1.0-rc1

Everything below runs locally on macOS 14+. Paths assume the repo at
`~/projects/Workshop`.

## Build + deterministic tests

```bash
cd ~/projects/Workshop
swift build                      # debug build, ~seconds
./scripts/test.sh                # full suite; expect exit 0, ~17 s,
                                 # 117 tests, 7 skipped (opt-in live)
swift test --filter CodexBridgeTests   # Phase 5 codex tests only
swift test --filter Phase4ServiceTests # resilience suite
swift test --filter LatencyBench       # writes latency numbers to stdout
```

## Packaged app

```bash
./scripts/package.sh 0.1.0-rc1   # builds release, assembles dist/Workshop.app,
                                 # signs, runs codesign --verify --deep --strict
                                 # and spctl --assess (rejected without a real
                                 # Developer ID + notarization — expected)
rm -rf ~/Applications/Workshop.app        # rm/move first — never overwrite a
cp -R dist/Workshop.app ~/Applications/   # running daemon's bundle (ADR 0016)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f ~/Applications/Workshop.app
swift /tmp/schemecheck.swift     # or any LSCopyDefaultHandlerForURLScheme call:
                                 # expect handler: ai.maapu.workshop
open ~/Applications/Workshop.app
```

Verify the runtime tree the app creates:

```bash
ls ~/Library/Application\ Support/Workshop          # db profiles bin artifacts …
ls -l ~/Library/Application\ Support/Workshop/profiles/codex/token   # -rw-------
readlink ~/Library/Application\ Support/Workshop/bin/workshop-mcp
pgrep -fl workshop-daemon
```

Lifecycle:

```bash
osascript -e 'tell application "Workshop" to quit'   # helper off → daemon exits
pgrep -fl workshop-daemon                            # expect: none (packaged)
```

Deep link (with the app running or not):

```bash
open "workshop://task/<task_id>"   # selects the task; unknown id → notice pill
```

## MCP bridge without the daemon (T35)

```bash
mkdir -p /tmp/ws-offline && echo tok > /tmp/ws-offline/token
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workshop_create_task","arguments":{"idempotency_key":"k","title":"t","objective":"o","phase":"execution"}}}' \
  | .build/debug/workshop-mcp --principal codex --token-file /tmp/ws-offline/token \
      --runtime-dir /tmp/ws-offline
# expect: tools/list returns the catalog; tools/call returns isError
# "Workshop service is not running. Open Workshop.app (or start the
#  background helper). Nothing was submitted."
```

## Codex run (uses ~/.codex/config.toml entry; requires daemon running)

```bash
codex exec --skip-git-repo-check -m gpt-5.6-luna -C /tmp/workshop-codex-smoke \
  '$team Create the Workshop task titled "Codex handoff smoke <nonce>" with
   objective "Call workshop_post_message once with body CODEX_SMOKE_<nonce>
   then say done" for participants deepseek only, phase approved execution.
   Report the receipt.'
```

## Database verification

```bash
DB=~/Library/Application\ Support/Workshop/db/workshop.sqlite
sqlite3 "$DB" "select id,title,state,phase from tasks"
sqlite3 "$DB" "select idempotency_key,principal from operations"   # codex-… keys
sqlite3 "$DB" "select seq,author_kind,structured from messages
               where task_id='<task_id>' order by seq"             # via=codex rows
sqlite3 "$DB" "select engineer_id,reason,state from wakeups
               where task_id='<task_id>'"                          # owner wakeup
```

## Live smoke (opt-in)

```bash
WORKSHOP_LIVE=1 swift test --filter LiveSmoke   # uses live adapters; costs API
```

## Stopping everything

```bash
# UI: Workshop menu → Stop Background Work… (pauses all Working tasks, exits
# the daemon; the LaunchAgent stays registered but idle)
# or from a shell:
sqlite3 "$DB" "select 1" >/dev/null   # sanity
pkill -f 'Workshop.app/Contents/MacOS/workshop-daemon'   # last resort
```
