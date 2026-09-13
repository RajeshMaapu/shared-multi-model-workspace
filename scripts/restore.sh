#!/bin/bash
# Restore a workshop.backup directory into a NEW WORKSHOP_HOME (§14.3, T38).
#
#   scripts/restore.sh <backup_dir> <new_workshop_home>
#
# IMPORTANT: this script stops nothing itself. Quit the Workshop app and the
# workshop-daemon first (the daemon holds the live DB open). It restores into
# the NEW home path given as arg 2 — never overwrite the live WORKSHOP_HOME
# directly. Then restart the daemon/app with WORKSHOP_HOME=<new_workshop_home>.
set -euo pipefail

backup_dir="${1:?usage: restore.sh <backup_dir> <new_workshop_home>}"
new_home="${2:?usage: restore.sh <backup_dir> <new_workshop_home>}"

if [ ! -f "$backup_dir/workshop.sqlite" ]; then
    echo "error: $backup_dir/workshop.sqlite not found — not a backup dir" >&2
    exit 1
fi
if [ -e "$new_home/db/workshop.sqlite" ]; then
    echo "error: $new_home already contains a live database — refusing" >&2
    echo "restore must target a new, empty home path" >&2
    exit 1
fi

mkdir -p "$new_home/db"
cp "$backup_dir/workshop.sqlite" "$new_home/db/workshop.sqlite"
# A backup taken mid-write can carry a hot WAL sidecar.
for sidecar in wal shm; do
    if [ -f "$backup_dir/workshop.sqlite-$sidecar" ]; then
        cp "$backup_dir/workshop.sqlite-$sidecar" \
           "$new_home/db/workshop.sqlite-$sidecar"
    fi
done
if [ -d "$backup_dir/artifacts" ]; then
    mkdir -p "$new_home/artifacts"
    cp -R "$backup_dir/artifacts/." "$new_home/artifacts/"
fi
cp "$backup_dir/manifest.json" "$new_home/backup-manifest.json" 2>/dev/null || true

echo "Restored backup into $new_home"
echo "Start the daemon with WORKSHOP_HOME=$new_home — never point this at the"
echo "live home while the app/daemon is running."
