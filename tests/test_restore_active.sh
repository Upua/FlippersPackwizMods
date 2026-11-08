#!/usr/bin/env bash
# gsr-backup restore-server on a RUNNING environment (round 3, Astra #7 and
# #2). The fake systemctl stop runs the real prepare/finalize hooks, so the
# stop hook makes the rollback backup and rotates the old snapshot away; it
# then updates the running state and can fail after that rotation.
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup
write_test_environment
install_fake_podman
install_hooked_systemctl
gsr_backup="$REPO/scripts/bin/gsr-backup"
bk="$XDG_DATA_HOME/gsr/backups/test"
live="$VOLUMES/testdata"

# reset <content of the backup> <live content>: one backup (current), then a
# changed live volume and a running service.
reset() {
    rm -rf "$bk" "$live" "$WORK"/{active,running,stop-fails-after-hooks,service-result,exec-fails,import-failures}
    rm -f "$WORK"/{systemctl,podman,hooks}.log
    mkdir -p "$live"
    echo "$1" > "$live/server.properties"
    "$gsr_backup" create test > "$WORK/setup.log" 2>&1 || ko "setup create failed: $(cat "$WORK/setup.log")"
    echo "$2" > "$live/server.properties"
    touch "$WORK/active" "$WORK/running"
}
archive_content() { zstd -dcq "$1/volume.tar.zst" | tar -xOf - ./server.properties; }
exports() { grep -c 'volume export' "$WORK/podman.log"; }

# --- the normal path: the stop hook makes the rollback backup.
reset backed-up live-now
source_snapshot="$(readlink -e "$bk/current")"
echo RESTORE-test | timeout 60 "$gsr_backup" restore-server test > "$WORK/ok.log" 2>&1; rc=$?
rollback="$(readlink -e "$bk/current")"
if ((rc == 0)) && [[ "$(cat "$live/server.properties")" == backed-up ]]; then ok "active restore replaces the live volume"
else ko "active restore (rc=$rc): $(cat "$WORK/ok.log" "$WORK/hooks.log" 2>/dev/null)"; fi
check "the stop hook ran prepare and finalize" grep -q 'verified backup of test is now current' "$WORK/hooks.log"
if [[ "$rollback" != "$source_snapshot" && "$(archive_content "$rollback")" == live-now ]] && (($(exports) == 2)); then
    ok "the stop hook's backup is the rollback point; restore made no second one"
else
    ko "rollback point: $rollback (source $source_snapshot), exports=$(exports)"
fi
check "the old snapshot was rotated away by the hook (keep=1)" [ ! -e "$source_snapshot" ]
check "the service runs again" [ -e "$WORK/active" -a -e "$WORK/running" ]
leftover=( "$bk"/.restore-source.* )
check "a successful restore removes the protected source" [ ! -e "${leftover[0]}" ]

# --- Astra #2: stop rotates the source away and then fails. The protected
# copy is now the last copy of the restore point and must be kept.
reset wanted-restore-point live-now
touch "$WORK/stop-fails-after-hooks"
source_snapshot="$(readlink -e "$bk/current")"
echo RESTORE-test | timeout 60 "$gsr_backup" restore-server test > "$WORK/stopfail.log" 2>&1; rc=$?
kept=( "$bk"/.restore-source.* )
if ((rc != 0)) && [[ ! -e "$source_snapshot" && -f "${kept[0]}/volume.tar.zst" ]] \
    && [[ "$(archive_content "${kept[0]}")" == wanted-restore-point ]] \
    && grep -q "source backup was kept at ${kept[0]}" "$WORK/stopfail.log"; then
    ok "stop that rotates and then fails: the restore source is kept and its path printed"
else
    ko "stop rotates then fails (rc=$rc, kept=${kept[0]}): $(cat "$WORK/stopfail.log")"
fi
check "a failed stop leaves the live volume untouched" grep -qx live-now "$live/server.properties"

# --- a hook failure is ignored: the RCON flush fails, so the hook makes no
# backup; the restore must make the rollback backup itself.
reset backed-up live-now
touch "$WORK/exec-fails"
echo RESTORE-test | timeout 60 "$gsr_backup" restore-server test > "$WORK/flushfail.log" 2>&1; rc=$?
rollback="$(readlink -e "$bk/current")"
if ((rc == 0)) && [[ "$(cat "$live/server.properties")" == backed-up && "$(archive_content "$rollback")" == live-now ]] \
    && grep -q 'cannot flush test' "$WORK/hooks.log"; then
    ok "failed flush in the stop hook: restore makes its own rollback backup"
else
    ko "flush fails (rc=$rc): $(cat "$WORK/flushfail.log" "$WORK/hooks.log")"
fi

# --- an abnormal stop (SERVICE_RESULT=timeout): finalize keeps the previous
# backup; the restore still makes and uses its own rollback backup.
reset backed-up live-now
echo timeout > "$WORK/service-result"
echo RESTORE-test | timeout 60 "$gsr_backup" restore-server test > "$WORK/timeout.log" 2>&1; rc=$?
rollback="$(readlink -e "$bk/current")"
if ((rc == 0)) && [[ "$(cat "$live/server.properties")" == backed-up && "$(archive_content "$rollback")" == live-now ]] \
    && grep -q "stopped abnormally (systemd result 'timeout')" "$WORK/hooks.log"; then
    ok "timeout stop: finalize does not rotate; restore makes its own rollback backup"
else
    ko "timeout stop (rc=$rc): $(cat "$WORK/timeout.log" "$WORK/hooks.log")"
fi

finish
