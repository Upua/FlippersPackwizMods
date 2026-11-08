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

# Invalid settings refuse the backup before exporting and delete nothing.
for bad in 'GSR_SERVER_BACKUP_KEEP=0' 'GSR_SERVER_BACKUP_KEEP=abc' 'GSR_SERVER_BACKUP_KEEP=1000' \
    'GSR_SERVER_BACKUP_KEEP=' 'GSR_SERVER_BACKUPS_KEEP=3'; do
    seed
    before="$(remaining)"
    printf '%s\n' "$bad" > "$conf"
    : > "$WORK/podman.log"
    if "$gsr_backup" create test > "$WORK/create.log" 2>&1; then
        ko "invalid '$bad': create succeeded"
    elif [[ "$(remaining)" == "$before" && "$(current_id)" == "${OLD_IDS[3]}" ]] \
        && ! grep -q 'volume export' "$WORK/podman.log" \
        && grep -q 'GSR_SERVER_BACKUP_KEEP' "$WORK/create.log"; then
        ok "invalid '$bad' refuses the backup and changes nothing"
    else
        ko "invalid '$bad': $(cat "$WORK/create.log")"
    fi
done

finish
