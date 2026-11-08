#!/usr/bin/env bash
# gsr-backup: a per-environment lock serializes creates and restores (round 3,
# Astra #1). Without it, the first create to finish rotates away the second
# one's staging directory while it is still exporting, and the second create
# fails and its snapshot is lost.
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup
write_test_environment
install_fake_podman
# The stateful mock (round 6): `stop` runs the real hooks, `start` marks the
# service active and the container running, as the real unit does.
install_hooked_systemctl
gsr_backup="$REPO/scripts/bin/gsr-backup"
bk="$XDG_DATA_HOME/gsr/backups/test"
mkdir -p "$VOLUMES/testdata" "$XDG_CONFIG_HOME/gsr"
echo props > "$VOLUMES/testdata/server.properties"
# keep=3: both new snapshots and the seeded one must all survive.
printf 'GSR_SERVER_BACKUP_KEEP=3\n' > "$XDG_CONFIG_HOME/gsr/backup.conf"
"$gsr_backup" create test > "$WORK/setup.log" 2>&1 || ko "setup create failed: $(cat "$WORK/setup.log")"
seeded="$(basename "$(readlink -e "$bk/current")")"

# Each export takes 2 s; the second create starts while the first exports.
echo 2 > "$WORK/export-delay"
timeout 60 "$gsr_backup" create test > "$WORK/a.log" 2>&1 &
pid_a=$!
sleep 0.5
timeout 60 "$gsr_backup" create test > "$WORK/b.log" 2>&1 &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
rm -f "$WORK/export-delay"

if ((rc_a == 0 && rc_b == 0)); then ok "two concurrent creates both succeed"
else ko "concurrent creates: rc_a=$rc_a rc_b=$rc_b: $(cat "$WORK/a.log" "$WORK/b.log")"; fi
if "$gsr_backup" verify test >/dev/null 2>&1; then ok "current is valid after two concurrent creates"
else ko "current is not valid after two concurrent creates"; fi
mapfile -t snapshots < <(find "$bk/snapshots" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
valid=0
for snapshot in "${snapshots[@]}"; do
    [[ "$snapshot" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] \
        && (cd "$bk/snapshots/$snapshot" && sha256sum --check --status volume.tar.zst.sha256) \
        && valid=$((valid + 1))
done
if ((${#snapshots[@]} == 3 && valid == 3)) && [[ " ${snapshots[*]} " == *" $seeded "* ]]; then
    ok "no snapshot was lost: the seeded one and both new ones exist, no staging left"
else
    ko "snapshots after concurrent creates: ${snapshots[*]}"
fi
# Normally b waits for a; on a slow machine a may start second and wait.
check "the waiting create says so" grep -q 'waiting for another backup or restore' "$WORK/a.log" "$WORK/b.log"

# wait_for_log <file> <text>: wait (up to 30 s) until <file> contains <text>.
wait_for_log() {
    local tries=0
    until grep -q "$2" "$1" 2>/dev/null; do
        ((tries++ < 300)) || return 1
        sleep 0.1
    done
}

# restore_with_waiting_create <name> <text in restore.log while it holds the
# lock>: runs restore-server, starts a create once the restore holds the lock
# and waits for both. `systemctl start` takes 1 s (start-delay).
restore_with_waiting_create() {
    local name="$1" marker="$2" pid_r pid_c
    rm -f "$WORK/podman.log"
    echo 1 > "$WORK/start-delay"
    echo RESTORE-test | timeout 60 "$gsr_backup" restore-server test > "$WORK/$name-restore.log" 2>&1 &
    pid_r=$!
    wait_for_log "$WORK/$name-restore.log" "$marker" || ko "$name: restore never logged '$marker'"
    timeout 60 "$gsr_backup" create test > "$WORK/$name-create.log" 2>&1 &
    pid_c=$!
    wait "$pid_r"; rc_r=$?
    wait "$pid_c"; rc_c=$?
    rm -f "$WORK/start-delay" "$WORK/export-delay" "$WORK/import-delay"
}

# expect_create_refused <name> <description>: the restore succeeded and the
# service runs; the create waited for the whole restore, including
# `systemctl start`, then saw the running container and refused without
# exporting (round 6, Astra-2 #1/#2). Before, the restore released the lock
# before `systemctl start`, and the waiting create exported from a container
# that was being started.
expect_create_refused() {
    local name="$1" description="$2"
    if ((rc_r == 0 && rc_c != 0)) && grep -q 'waiting for another backup or restore' "$WORK/$name-create.log" \
        && grep -q 'test is still running; stop it before using create' "$WORK/$name-create.log" \
        && ! grep -q 'exporting' "$WORK/$name-create.log" \
        && [[ -e "$WORK/active" && -e "$WORK/running" ]] \
        && "$gsr_backup" verify test >/dev/null 2>&1; then
        ok "$description"
    else
        ko "$description (rc_r=$rc_r rc_c=$rc_c): $(cat "$WORK/$name-restore.log" "$WORK/$name-create.log")"
    fi
}

# A create that starts during a restore-server of a STOPPED service (the
# restore makes the rollback backup itself; each export takes 2 s).
printf 'GSR_SERVER_BACKUP_KEEP=1\n' > "$XDG_CONFIG_HOME/gsr/backup.conf"
echo before-restore > "$VOLUMES/testdata/server.properties"
rm -f "$WORK/active" "$WORK/running"
echo 2 > "$WORK/export-delay"
restore_with_waiting_create stopped 'exporting testdata'
expect_create_refused stopped "stopped service: a create during restore-server waits through systemctl start, then refuses the running container without exporting"

# The same for a RUNNING service: the lock is released for `systemctl stop`
# (its stop hook takes it), re-acquired after the stop and held through the
# import and `systemctl start`. The create starts while the import (2 s) runs.
rm -f "$WORK/hooks.log"
touch "$WORK/active" "$WORK/running"
echo 2 > "$WORK/import-delay"
restore_with_waiting_create running 'replacing live volume'
expect_create_refused running "running service: a create during restore-server waits through systemctl start, then refuses the running container without exporting"
check "running service: the stop hook made the rollback backup (no deadlock)" grep -q 'verified backup of test is now current' "$WORK/hooks.log"
rm -f "$WORK/active" "$WORK/running"

# The lock is released when gsr-backup ends, also after a failure.
echo 1 > "$WORK/import-failures"
echo RESTORE-test | timeout 60 "$gsr_backup" restore-server test > "$WORK/fail.log" 2>&1
rm -f "$WORK/import-failures"
rm -rf "$bk"/.restore-source.*
if timeout 20 "$gsr_backup" create test > "$WORK/after.log" 2>&1 && ! grep -q waiting "$WORK/after.log"; then
    ok "the lock is free again after a failed restore"
else
    ko "lock after a failed restore: $(cat "$WORK/after.log")"
fi
rm -f "$XDG_CONFIG_HOME/gsr/backup.conf"

# restore-server on a running environment gives up waiting for the lock
# AFTER it has stopped the service (round 4). The message must not claim that
# nothing was changed: the service was stopped and stays stopped. A private
# copy of the script waits 2 s instead of 600 s, and the fake `systemctl
# stop` leaves a process holding the lock for 6 s.
sed 's/^BACKUP_LOCK_WAIT_SECONDS=600$/BACKUP_LOCK_WAIT_SECONDS=2/' "$gsr_backup" > "$WORK/gsr-backup-short"
grep -q '^BACKUP_LOCK_WAIT_SECONDS=2$' "$WORK/gsr-backup-short" || ko "could not shorten the lock wait"
cp "$WORK/gsr-backup-short" "$gsr_backup"
cat > "$FAKE_BIN/systemctl" <<EOF
#!/usr/bin/env bash
work="$WORK"
lock="$bk/.lock"
EOF
cat >> "$FAKE_BIN/systemctl" <<'EOF'
args=" $* "
if [[ "$args" == *" is-active "* ]]; then [[ -e "$work/active" ]]; exit; fi
if [[ "$args" == *" stop "* ]]; then
    rm -f "$work/active" "$work/running" "$work/held"
    flock "$lock" -c "touch '$work/held'; sleep 6" >/dev/null 2>&1 &
    while [[ ! -e "$work/held" ]]; do sleep 0.1; done
fi
exit 0
EOF
chmod +x "$FAKE_BIN/systemctl"
touch "$WORK/active" "$WORK/running"
echo RESTORE-test | timeout 60 "$gsr_backup" restore-server test > "$WORK/timeout.log" 2>&1; rc=$?
if ((rc != 0)) && ! grep -q 'nothing was changed' "$WORK/timeout.log" \
    && grep -q 'test was stopped for the restore and stays stopped' "$WORK/timeout.log"; then
    ok "lock timeout after the stop: says the service stays stopped, not 'nothing was changed'"
else
    ko "lock timeout after the stop (rc=$rc): $(cat "$WORK/timeout.log")"
fi
rm -rf "$bk"/.restore-source.*

finish
