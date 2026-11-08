#!/usr/bin/env bash
# gsr-backup create: every staged regular file and directory, including
# shared/ and the identity files in it, is flushed to disk before the new
# snapshot is published and older ones are rotated away (round 6, Astra-2
# #4), as gsr-backup-pull does. Syncing a directory does not flush its
# children, so each path must be synced itself. A fake `sync` first on PATH
# logs its arguments and runs the real one.
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup
write_test_environment
install_fake_podman
gsr_backup="$REPO/scripts/bin/gsr-backup"
bk="$XDG_DATA_HOME/gsr/backups/test"
shared="$XDG_CONFIG_HOME/gsr/shared"
mkdir -p "$VOLUMES/testdata/world" "$shared"
echo props > "$VOLUMES/testdata/server.properties"
echo '{}' > "$shared/identities.json"
echo '[]' > "$shared/whitelist.json"

real_sync="$(command -v sync)"
cat > "$FAKE_BIN/sync" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$WORK/sync.log"
exec "$real_sync" "\$@"
EOF
chmod +x "$FAKE_BIN/sync"

if "$gsr_backup" create test > "$WORK/create.log" 2>&1; then ok "create succeeds"
else ko "create failed: $(cat "$WORK/create.log")"; fi
snapshot="$(readlink -e "$bk/current")"

# Every file and directory of the published snapshot must have been synced
# under its staging name (.staging.XXXXXX/...), i.e. before publication.
missing=()
while IFS= read -r -d '' path; do
    relative="${path#"$snapshot"}"
    grep -qE "/snapshots/\.staging\.[^/]+${relative//./\\.}\$" "$WORK/sync.log" || missing+=("${relative:-/}")
done < <(find "$snapshot" \( -type f -o -type d \) -print0)
check "the snapshot has shared/identities.json and shared/whitelist.json" \
    [ -f "$snapshot/shared/identities.json" -a -f "$snapshot/shared/whitelist.json" ]
if ((${#missing[@]} == 0)); then ok "every staged file and directory (shared/ included) was synced before publication"
else ko "not synced before publication: ${missing[*]} (sync log: $(tr '\n' ' ' < "$WORK/sync.log"))"; fi

finish
