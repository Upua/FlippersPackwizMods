#!/usr/bin/env bash
# gsr-backup: server-side retention (GSR_SERVER_BACKUP_KEEP in
# ~/.config/gsr/backup.conf). The default must keep exactly one snapshot,
# as before the setting existed.
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup
write_test_environment
install_fake_podman
gsr_backup="$REPO/scripts/bin/gsr-backup"
bk="$XDG_DATA_HOME/gsr/backups/test"
conf="$XDG_CONFIG_HOME/gsr/backup.conf"
mkdir -p "$VOLUMES/testdata" "$WORK/src" "$(dirname "$conf")"
echo live > "$VOLUMES/testdata/server.properties"
echo old > "$WORK/src/server.properties"

# Four older snapshots, current pointing at the newest, plus a leftover
# staging directory from an interrupted run.
OLD_IDS=(20200101T000000Z-1 20200102T000000Z-2 20200103T000000Z-3 20200104T000000Z-4)
seed() {
    local id
    rm -rf "$bk"
    for id in "${OLD_IDS[@]}"; do make_snapshot_archive "$bk/snapshots/$id" "$WORK/src"; done
    mkdir -p "$bk/snapshots/.staging.leftover"
    ln -sfn "snapshots/${OLD_IDS[3]}" "$bk/current"
}
# remaining: the sorted names left in the snapshot directory.
remaining() { (cd "$bk/snapshots" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '); }
current_id() { basename "$(readlink "$bk/current")"; }

# run_create <label>: create a backup and check that current is the new,
# valid snapshot.
run_create() {
    if ! "$gsr_backup" create test > "$WORK/create.log" 2>&1; then
        ko "$1: create failed: $(cat "$WORK/create.log")"
        return 1
    fi
    local id; id="$(current_id)"
    if [[ ! " ${OLD_IDS[*]} " == *" $id "* ]] && "$gsr_backup" verify test >/dev/null 2>&1; then
        ok "$1: new snapshot is current and verifies"
    else
        ko "$1: current=$id"
    fi
}

# Default: no config file -> exactly one snapshot, as before.
seed
rm -f "$conf"
run_create "default (no backup.conf)"
check "default keeps only the new snapshot" [ "$(remaining)" == "$(current_id) " ]
check "default prints the unchanged message" grep -qx 'gsr-backup: replaced previous local backup.' "$WORK/create.log"

# A config file without the key also means the default.
seed
printf '# no settings yet\n\n' > "$conf"
run_create "backup.conf with only comments"
check "comment-only backup.conf keeps only the new snapshot" [ "$(remaining)" == "$(current_id) " ]

# keep=1 explicitly.
seed
printf 'GSR_SERVER_BACKUP_KEEP=1\n' > "$conf"
run_create "keep=1"
check "keep=1 keeps only the new snapshot" [ "$(remaining)" == "$(current_id) " ]

# keep=3: the new snapshot plus the two newest older ones; the staging
# leftover and the two oldest are removed.
seed
printf '# server snapshots per environment\nGSR_SERVER_BACKUP_KEEP = 3  # current included\n' > "$conf"
run_create "keep=3"
expected="${OLD_IDS[2]} ${OLD_IDS[3]} $(current_id) "
check "keep=3 keeps the new and the two newest older snapshots" [ "$(remaining)" == "$expected" ]
check "keep=3 reports the retention" grep -q 'keeping up to 3 server backups' "$WORK/create.log"

# keep=3 with fewer snapshots than the limit deletes nothing but leftovers.
rm -rf "$bk"
run_create "keep=3 first backup"
run_create "keep=3 second backup"
check "keep=3 with two backups keeps both" [ "$(remaining | wc -w)" -eq 2 ]

# Invalid settings never stop a backup and never delete anything (round 4,
# owner rule): the backup is made, rotation is paused (every seeded snapshot
# and even the staging leftover stay), and a warning on stderr names the
# file, the bad value and the pause. stdout and stderr are captured
# separately to check that.
# Each entry: <config line>|<text the warning must quote>.
for case in 'GSR_SERVER_BACKUP_KEEP=0|0' 'GSR_SERVER_BACKUP_KEEP=abc|abc' \
    'GSR_SERVER_BACKUP_KEEP=1000|1000' "GSR_SERVER_BACKUP_KEEP=|''" \
    'GSR_SERVER_BACKUPS_KEEP=3|GSR_SERVER_BACKUPS_KEEP=3'; do
    bad="${case%%|*}" quoted="${case#*|}"
    seed
    printf '%s\n' "$bad" > "$conf"
    if ! "$gsr_backup" create test > "$WORK/create.out" 2> "$WORK/create.err"; then
        ko "invalid '$bad': create failed: $(cat "$WORK/create.out" "$WORK/create.err")"
        continue
    fi
    id="$(current_id)"
    if [[ " ${OLD_IDS[*]} " != *" $id "* && "$(remaining)" == ".staging.leftover ${OLD_IDS[*]} $id " ]] \
        && "$gsr_backup" verify test >/dev/null 2>&1; then
        ok "invalid '$bad' still backs up and deletes nothing"
    else
        ko "invalid '$bad': current=$id remaining=$(remaining)"
    fi
    if grep -q 'WARNING' "$WORK/create.err" && grep -qF "$conf" "$WORK/create.err" \
        && grep -qF "$quoted" "$WORK/create.err" && grep -q 'Rotation of server backups is PAUSED' "$WORK/create.err" \
        && grep -q 'no older backup was deleted' "$WORK/create.err" \
        && ! grep -q 'WARNING' "$WORK/create.out" && ! grep -q 'replaced previous' "$WORK/create.out"; then
        ok "invalid '$bad' warns on stderr, naming the file, the bad value and the pause"
    else
        ko "invalid '$bad': no proper warning: stderr=$(cat "$WORK/create.err")"
    fi
done

# An unreadable backup.conf (here: a directory) also pauses rotation.
seed
rm -f "$conf"
mkdir "$conf"
if "$gsr_backup" create test > "$WORK/create.out" 2> "$WORK/create.err" \
    && [[ "$(remaining)" == ".staging.leftover ${OLD_IDS[*]} $(current_id) " ]] \
    && grep -q "WARNING: cannot read $conf.*PAUSED" "$WORK/create.err"; then
    ok "unreadable backup.conf warns, backs up and deletes nothing"
else
    ko "unreadable backup.conf: $(cat "$WORK/create.out" "$WORK/create.err")"
fi
rmdir "$conf"

# The owner's case (round 4): keep=3 was working, then a typo is made in the
# file. The next backups must not delete any of the snapshots kept so far.
seed
printf 'GSR_SERVER_BACKUP_KEEP=3\n' > "$conf"
run_create "keep=3 before the typo"
before_typo="$(remaining)"
for typo in 'GSR_SERVER_BACKUP_KEEP=3O' 'GSR_SERVER_BACKUP_KEPP=3'; do
    printf '%s\n' "$typo" > "$conf"
    previous="$(remaining)"
    if "$gsr_backup" create test > "$WORK/create.out" 2> "$WORK/create.err" \
        && [[ "$(remaining)" == *"$(current_id) "* ]] \
        && (($(remaining | wc -w) == $(printf '%s' "$previous" | wc -w) + 1)); then
        missing=""
        for id in $before_typo; do [[ -d "$bk/snapshots/$id" ]] || missing+=" $id"; done
        if [[ -z "$missing" ]]; then ok "typo '$typo' after keep=3: backup made, nothing deleted"
        else ko "typo '$typo' after keep=3 deleted:$missing"; fi
    else
        ko "typo '$typo' after keep=3: before=[$previous] after=[$(remaining)]: $(cat "$WORK/create.out" "$WORK/create.err")"
    fi
done
rm -f "$conf"

finish
