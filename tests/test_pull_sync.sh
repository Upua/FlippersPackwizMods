#!/usr/bin/env bash
# gsr-backup-pull pull: the downloaded snapshot's files and directories, and
# the directory entries that publish it, are flushed to disk BEFORE older
# local snapshots are deleted (round 3, Astra #4). A fake `ssh` serves a
# snapshot; a fake `sync` records its arguments and whether the snapshot that
# rotation will delete still existed at that moment.
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup-pull scripts/backup-transfer-progress.py
pull="$REPO/scripts/bin/gsr-backup-pull"
root="$WORK/backups"
mkdir -p "$XDG_CONFIG_HOME/gsr-backup-pull" "$WORK/src"
cat > "$XDG_CONFIG_HOME/gsr-backup-pull/config.json" <<EOF
{"ssh_host": "h", "ssh_port": 22, "ssh_user": "u", "service_user": "s",
 "local_root": "$root", "retention": 2, "environments": ["test"]}
EOF

# The server's current snapshot, with a shared/ directory.
echo props > "$WORK/src/server.properties"
server_snapshot="$WORK/server-snapshot"
make_snapshot_archive "$server_snapshot" "$WORK/src"
mkdir -p "$server_snapshot/shared"
echo '[]' > "$server_snapshot/shared/whitelist.json"

# Two older local snapshots; with retention 2 the oldest is deleted.
oldest="$root/test/snapshots/20200101T000000Z-1"
newer="$root/test/snapshots/20200102T000000Z-2"
make_snapshot_archive "$oldest" "$WORK/src"
make_snapshot_archive "$newer" "$WORK/src"
ln -s snapshots/20200102T000000Z-2 "$root/test/current"

cat > "$FAKE_BIN/ssh" <<EOF
#!/usr/bin/env bash
snapshot="$server_snapshot"
EOF
cat >> "$FAKE_BIN/ssh" <<'EOF'
remote="${*: -1}"
case " $* " in
    *" -M "*|*" -O "*) exit 0 ;;
esac
cat > /dev/null
case "$remote" in
    *" share-info "*) cat "$snapshot/manifest.json" ;;
    *" share-bundle "*) tar -C "$snapshot" -cf - manifest.json volume.tar.zst volume.tar.zst.sha256 shared ;;
    *) echo "fake ssh: unsupported: $remote" >&2; exit 1 ;;
esac
EOF
cat > "$FAKE_BIN/sync" <<EOF
#!/usr/bin/env bash
if [[ -d "$oldest" ]]; then state=old-present; else state=old-gone; fi
printf '%s\t%s\n' "\$state" "\$*" >> "$WORK/sync.log"
EOF
chmod +x "$FAKE_BIN/ssh" "$FAKE_BIN/sync"

echo password | "$pull" pull test > "$WORK/pull.log" 2>&1; rc=$?
current="$(readlink -e "$root/test/current")"
if ((rc == 0)) && [[ -n "$current" && "$current" != "$newer" ]] && "$pull" verify test current >/dev/null 2>&1 \
    && [[ ! -e "$oldest" && "$(readlink -e "$root/test/previous")" == "$newer" ]]; then
    ok "pull stores the new snapshot as current, keeps previous, rotates the oldest"
else
    ko "pull (rc=$rc): $(cat "$WORK/pull.log")"
fi

# synced_before_delete <description> <pattern>: some sync call whose
# arguments match <pattern> ran while the oldest snapshot still existed.
synced_before_delete() {
    if grep -qE "^old-present"$'\t'".*$2" "$WORK/sync.log" 2>/dev/null; then ok "$1"
    else ko "$1: sync log: $(cat "$WORK/sync.log" 2>/dev/null || echo none)"; fi
}
synced_before_delete "the archive is synced before older snapshots are deleted" '/volume\.tar\.zst( |$)'
synced_before_delete "the checksum file is synced before deletion" 'volume\.tar\.zst\.sha256'
synced_before_delete "the manifest is synced before deletion" '/manifest\.json( |$)'
synced_before_delete "shared/ files are synced before deletion" 'shared/whitelist\.json'
synced_before_delete "the snapshot directory itself is synced before deletion" '/snapshot( |$)'
synced_before_delete "the snapshots/ and environment directories (new entry, links) are synced before deletion" \
    "$root/test/snapshots $root/test( |$)"

finish
