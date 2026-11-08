#!/usr/bin/env bash
# gsr-backup restore-server: a failed import must keep the protected restore
# source (round 1, fix 626c1f5); a successful one replaces the live volume,
# starts the service and removes the protected copy.
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup
write_test_environment
install_fake_podman
install_fake_systemctl
gsr_backup="$REPO/scripts/bin/gsr-backup"
bk="$XDG_DATA_HOME/gsr/backups/test"
live="$VOLUMES/testdata"

# --- failing import: the first import (the restore) fails, the rollback works.
mkdir -p "$live"
echo props > "$live/server.properties"
"$gsr_backup" create test > "$WORK/setup.log" 2>&1 || ko "setup create failed: $(cat "$WORK/setup.log")"
echo 1 > "$WORK/import-failures"
echo RESTORE-test | "$gsr_backup" restore-server test > "$WORK/fail.log" 2>&1; rc=$?
kept=( "$bk"/.restore-source.* )
if ((rc != 0)) && [[ -f "${kept[0]}/volume.tar.zst" ]] && grep -q 'source backup was kept' "$WORK/fail.log"; then
    ok "failed restore keeps its source and says where"
else
    ko "failed restore (rc=$rc): $(cat "$WORK/fail.log")"
fi
if [[ "$(cat "$live/server.properties" 2>/dev/null)" == props ]]; then ok "failed restore recovers the pre-restore volume"
else ko "failed restore: live volume not recovered"; fi
rm -rf "$bk"/.restore-source.*

# --- successful restore.
rm -rf "$bk" "$live" "$WORK/import-failures" "$WORK/systemctl.log"
mkdir -p "$live"
echo backed-up > "$live/server.properties"
"$gsr_backup" create test > "$WORK/setup.log" 2>&1 || ko "setup create failed: $(cat "$WORK/setup.log")"
echo changed-later > "$live/server.properties"
echo RESTORE-test | "$gsr_backup" restore-server test > "$WORK/ok.log" 2>&1; rc=$?
if ((rc == 0)) && [[ "$(cat "$live/server.properties")" == backed-up ]]; then ok "restore-server replaces the live volume"
else ko "restore-server (rc=$rc): $(cat "$WORK/ok.log")"; fi
leftover=( "$bk"/.restore-source.* )
check "successful restore removes the protected source" [ ! -e "${leftover[0]}" ]
check "successful restore starts the service" grep -q 'start test.service' "$WORK/systemctl.log"
# The new current is the rollback point: it holds the pre-restore content.
rollback="$(readlink -e "$bk/current")"
if zstd -dcq "$rollback/volume.tar.zst" | tar -xOf - ./server.properties | grep -qx changed-later; then
    ok "the current backup after a restore is the pre-restore rollback point"
else
    ko "rollback point does not hold the pre-restore content"
fi

# --- a wrong confirmation changes nothing.
echo changed-again > "$live/server.properties"
echo nope | "$gsr_backup" restore-server test > "$WORK/cancel.log" 2>&1; rc=$?
if ((rc == 0)) && grep -q 'restore cancelled' "$WORK/cancel.log" && [[ "$(cat "$live/server.properties")" == changed-again ]]; then
    ok "a wrong confirmation cancels without changes"
else
    ko "cancel (rc=$rc): $(cat "$WORK/cancel.log")"
fi

# --- keep=3: the restore works and the earlier backups survive it.
mkdir -p "$XDG_CONFIG_HOME/gsr"
printf 'GSR_SERVER_BACKUP_KEEP=3\n' > "$XDG_CONFIG_HOME/gsr/backup.conf"
count_before="$(find "$bk/snapshots" -mindepth 1 -maxdepth 1 | wc -l)"
echo RESTORE-test | "$gsr_backup" restore-server test > "$WORK/keep3.log" 2>&1; rc=$?
count_after="$(find "$bk/snapshots" -mindepth 1 -maxdepth 1 | wc -l)"
if ((rc == 0)) && [[ "$(cat "$live/server.properties")" == changed-later ]] && ((count_after == count_before + 1)); then
    ok "keep=3: restore-server works and keeps the earlier snapshot ($count_before -> $count_after)"
else
    ko "keep=3 restore (rc=$rc, $count_before -> $count_after): $(cat "$WORK/keep3.log")"
fi

# --- an invalid retention setting only warns (round 3, owner rule): the
# rollback backup is made with the default retention and the restore runs.
printf 'GSR_SERVER_BACKUP_KEEP=zero\n' > "$XDG_CONFIG_HOME/gsr/backup.conf"
echo before-invalid > "$live/server.properties"
restore_point="$(readlink -e "$bk/current")"
expected="$(zstd -dcq "$restore_point/volume.tar.zst" | tar -xOf - ./server.properties)"
echo RESTORE-test | "$gsr_backup" restore-server test > "$WORK/invalid.out" 2> "$WORK/invalid.err"; rc=$?
rollback="$(readlink -e "$bk/current")"
if ((rc == 0)) && [[ "$(cat "$live/server.properties")" == "$expected" ]] \
    && zstd -dcq "$rollback/volume.tar.zst" | tar -xOf - ./server.properties | grep -qx before-invalid \
    && grep -q "WARNING: GSR_SERVER_BACKUP_KEEP in .*backup.conf .*'zero'" "$WORK/invalid.err"; then
    ok "invalid retention setting: restore-server warns, makes the rollback backup and restores"
else
    ko "invalid retention restore (rc=$rc): $(cat "$WORK/invalid.out" "$WORK/invalid.err")"
fi
rm -f "$XDG_CONFIG_HOME/gsr/backup.conf"

finish
