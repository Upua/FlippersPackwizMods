#!/usr/bin/env bash
# gsr-backup prepare/finalize (the systemd stop hooks): finalize exports and
# rotates only after a clean stop. systemd results `success` and `signal`
# (normal under Quadlet, which ends the container with `podman rm -f`) are
# clean; `timeout` and every other result keep the previous backup (round 3,
# Astra #3). An invalid retention setting must not stop a hook backup.
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup
write_test_environment
install_fake_podman
gsr_backup="$REPO/scripts/bin/gsr-backup"
bk="$XDG_DATA_HOME/gsr/backups/test"
mkdir -p "$VOLUMES/testdata"
echo first > "$VOLUMES/testdata/server.properties"
"$gsr_backup" create test > "$WORK/setup.log" 2>&1 || ko "setup create failed: $(cat "$WORK/setup.log")"

# stop_with <SERVICE_RESULT>: prepare while running, stop, finalize.
stop_with() {
    touch "$WORK/running"
    "$gsr_backup" prepare test > "$WORK/prepare.log" 2>&1 || ko "prepare failed: $(cat "$WORK/prepare.log")"
    rm -f "$WORK/running"
    SERVICE_RESULT="$1" "$gsr_backup" finalize test > "$WORK/finalize.out" 2> "$WORK/finalize.err"
}

for result in success signal; do
    before="$(readlink -e "$bk/current")"
    echo "after-$result" > "$VOLUMES/testdata/server.properties"
    stop_with "$result"; rc=$?
    after="$(readlink -e "$bk/current")"
    if ((rc == 0)) && [[ "$after" != "$before" ]] && "$gsr_backup" verify test >/dev/null 2>&1 \
        && zstd -dcq "$after/volume.tar.zst" | tar -xOf - ./server.properties | grep -qx "after-$result"; then
        ok "SERVICE_RESULT=$result: finalize exports a new current backup"
    else
        ko "SERVICE_RESULT=$result (rc=$rc): $(cat "$WORK/finalize.out" "$WORK/finalize.err")"
    fi
done

for result in timeout exit-code core-dump oom-kill; do
    before="$(readlink -e "$bk/current")"
    snapshots_before="$(ls "$bk/snapshots")"
    : > "$WORK/podman.log"
    echo "after-$result" > "$VOLUMES/testdata/server.properties"
    stop_with "$result"; rc=$?
    if ((rc == 0)) && [[ "$(readlink -e "$bk/current")" == "$before" && "$(ls "$bk/snapshots")" == "$snapshots_before" ]] \
        && ! grep -q 'volume export' "$WORK/podman.log" \
        && grep -q "stopped abnormally (systemd result '$result').*previous backup kept" "$WORK/finalize.err"; then
        ok "SERVICE_RESULT=$result: finalize keeps the previous backup and says why"
    else
        ko "SERVICE_RESULT=$result (rc=$rc): $(cat "$WORK/finalize.out" "$WORK/finalize.err")"
    fi
    [[ ! -e "$XDG_STATE_HOME/gsr/backup-prepared/test.prepared" ]] || ko "SERVICE_RESULT=$result left the prepared marker"
done

# Without SERVICE_RESULT (finalize run by hand) it still exports, as before.
before="$(readlink -e "$bk/current")"
touch "$WORK/running"; "$gsr_backup" prepare test >/dev/null 2>&1; rm -f "$WORK/running"
if env -u SERVICE_RESULT "$gsr_backup" finalize test > "$WORK/finalize.out" 2>&1 \
    && [[ "$(readlink -e "$bk/current")" != "$before" ]]; then
    ok "finalize without SERVICE_RESULT exports as before"
else
    ko "finalize without SERVICE_RESULT: $(cat "$WORK/finalize.out")"
fi

# An invalid retention setting warns but the stop backup is still made.
mkdir -p "$XDG_CONFIG_HOME/gsr"
printf 'GSR_SERVER_BACKUP_KEEP=three\n' > "$XDG_CONFIG_HOME/gsr/backup.conf"
before="$(readlink -e "$bk/current")"
stop_with success; rc=$?
if ((rc == 0)) && [[ "$(readlink -e "$bk/current")" != "$before" ]] && grep -q "WARNING.*'three'" "$WORK/finalize.err"; then
    ok "invalid retention setting: the stop-hook backup is still made, with a warning"
else
    ko "invalid retention in finalize (rc=$rc): $(cat "$WORK/finalize.out" "$WORK/finalize.err")"
fi
rm -f "$XDG_CONFIG_HOME/gsr/backup.conf"

finish
