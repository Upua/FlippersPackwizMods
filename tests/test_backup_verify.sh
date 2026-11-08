#!/usr/bin/env bash
# gsr-backup: a snapshot that fails verification must never be served, and a
# stale .current.new from an interrupted run must not break rotation.
# (Round 1, fixes f777b16 and fe6aae6.)
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup
write_test_environment
install_fake_podman
gsr_backup="$REPO/scripts/bin/gsr-backup"
bk="$XDG_DATA_HOME/gsr/backups/test"

mkdir -p "$WORK/src"
echo hello > "$WORK/src/server.properties"
make_snapshot_archive "$bk/snapshots/good" "$WORK/src"
ln -sfn snapshots/good "$bk/current"

out="$("$gsr_backup" share-info test 2>&1)"
if [[ "$out" == *'"environment"'* ]]; then ok "share-info on a valid snapshot prints the manifest"
else ko "share-info on a valid snapshot: $out"; fi

# Corrupt the archive: the checksum no longer matches.
printf 'garbage' >> "$bk/snapshots/good/volume.tar.zst"
out="$("$gsr_backup" share-info test 2>&1)"; rc=$?
if ((rc != 0)) && [[ "$out" != *'"environment"'* ]]; then ok "share-info refuses a corrupt snapshot (rc=$rc)"
else ko "share-info served a corrupt snapshot (rc=$rc): $out"; fi

bytes="$("$gsr_backup" share-bundle test 2>/dev/null | wc -c)"
if ((bytes == 0)); then ok "share-bundle sends nothing for a corrupt snapshot"
else ko "share-bundle sent $bytes bytes of a corrupt snapshot"; fi

if "$gsr_backup" verify test >/dev/null 2>&1; then ko "verify accepted a corrupt snapshot"
else ok "verify rejects a corrupt snapshot"; fi

rm -f "$bk/current"
if "$gsr_backup" share-info test >/dev/null 2>&1; then ko "share-info without current succeeded"
else ok "share-info without current fails"; fi

# create, then a stale .current.new left by a crash between ln and mv.
rm -rf "$bk"
mkdir -p "$VOLUMES/testdata"
echo props > "$VOLUMES/testdata/server.properties"
"$gsr_backup" create test > "$WORK/create1.log" 2>&1 || ko "first create failed: $(cat "$WORK/create1.log")"
first="$(readlink "$bk/current")"
ln -s "$first" "$bk/.current.new"
"$gsr_backup" create test > "$WORK/create2.log" 2>&1 || ko "second create failed: $(cat "$WORK/create2.log")"
second="$(readlink "$bk/current")"
if [[ "$second" != "$first" && -d "$bk/$second" ]] && "$gsr_backup" verify test >/dev/null 2>&1; then
    ok "stale .current.new does not break rotation"
else
    ko "after a stale .current.new: current=$second first=$first"
fi

# create refuses a running container.
touch "$WORK/running"
if "$gsr_backup" create test >/dev/null 2>&1; then ko "create exported a running environment"
else ok "create refuses a running environment"; fi
rm -f "$WORK/running"

finish
