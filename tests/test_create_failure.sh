#!/usr/bin/env bash
# gsr-backup create: a create that fails part-way (here: the compressor fails,
# as on a full disk) must not leave its partial archive behind in a
# `.staging.*` directory (round 4). Before, set -e ended the script without
# running the RETURN trap, so the partial archive stayed until the next
# rotation, and forever while rotation is paused by an invalid setting.
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup
write_test_environment
install_fake_podman
gsr_backup="$REPO/scripts/bin/gsr-backup"
bk="$XDG_DATA_HOME/gsr/backups/test"
conf="$XDG_CONFIG_HOME/gsr/backup.conf"
mkdir -p "$VOLUMES/testdata" "$(dirname "$conf")"
echo props > "$VOLUMES/testdata/server.properties"
"$gsr_backup" create test > "$WORK/setup.log" 2>&1 || ko "setup create failed: $(cat "$WORK/setup.log")"
first="$(readlink -e "$bk/current")"

# A zstd that fails when it writes an archive (-o) and works otherwise.
real_zstd="$(command -v zstd)"
cat > "$FAKE_BIN/zstd" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    if [[ "\$arg" == -o ]]; then
        cat > /dev/null
        echo "fake zstd: No space left on device" >&2
        exit 1
    fi
done
exec "$real_zstd" "\$@"
EOF
chmod +x "$FAKE_BIN/zstd"

for setting in default 'GSR_SERVER_BACKUP_KEEP=x'; do
    if [[ "$setting" == default ]]; then rm -f "$conf"; else printf '%s\n' "$setting" > "$conf"; fi
    "$gsr_backup" create test > "$WORK/fail.log" 2>&1; rc=$?
    staging=( "$bk"/snapshots/.staging.* )
    if ((rc != 0)) && [[ ! -e "${staging[0]}" && "$(readlink -e "$bk/current")" == "$first" ]] \
        && grep -q 'backup of test FAILED' "$WORK/fail.log"; then
        ok "failed create ($setting): non-zero exit, says FAILED, no staging left, current unchanged"
    else
        ko "failed create ($setting): rc=$rc staging=${staging[*]} current=$(readlink -e "$bk/current")"
    fi
done
rm -f "$FAKE_BIN/zstd" "$conf"

if "$gsr_backup" verify test >/dev/null 2>&1; then ok "the previous backup still verifies"
else ko "the previous backup does not verify"; fi

finish
