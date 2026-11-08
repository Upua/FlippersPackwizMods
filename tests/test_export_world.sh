#!/usr/bin/env bash
# gsr-backup-pull verify / export-world on a local snapshot whose world is
# listed first, followed by many entries: an early `awk exit` used to kill the
# pipeline with SIGPIPE under pipefail (round 1, fix d505e49).
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/gsr-backup-pull
root="$WORK/backups"
mkdir -p "$XDG_CONFIG_HOME/gsr-backup-pull" "$WORK/src/world" "$WORK/src/zz"
cat > "$XDG_CONFIG_HOME/gsr-backup-pull/config.json" <<EOF
{"ssh_host": "h", "ssh_port": 22, "ssh_user": "u", "service_user": "s",
 "local_root": "$root", "retention": 2, "environments": ["test"]}
EOF
echo level > "$WORK/src/world/level.dat"
(cd "$WORK/src/zz" && seq -f 'f%.0f' 1 30000 | xargs touch)
echo "level-name=world" > "$WORK/src/server.properties"

# An older-style snapshot: no world_directory in the manifest, so export-world
# falls back to server.properties inside the archive.
snap="$root/test/snapshots/20260101T000000Z-1"
mkdir -p "$snap"
tar -C "$WORK/src" -cf - ./world ./server.properties ./zz | zstd -q -o "$snap/volume.tar.zst"
digest="$(sha256sum "$snap/volume.tar.zst" | cut -d' ' -f1)"
printf '%s  volume.tar.zst\n' "$digest" > "$snap/volume.tar.zst.sha256"
size="$(stat -c %s "$snap/volume.tar.zst")"
printf '{"environment":"test","archive":"volume.tar.zst","sha256":"%s","archive_bytes":%s}\n' "$digest" "$size" > "$snap/manifest.json"
ln -s snapshots/20260101T000000Z-1 "$root/test/current"

pull="$REPO/scripts/bin/gsr-backup-pull"
out="$("$pull" verify test current 2>&1)"; rc=$?
if ((rc == 0)); then ok "verify accepts a valid local snapshot"; else ko "verify (rc=$rc): $out"; fi

out="$("$pull" export-world test current "$WORK/out" 2>&1)"; rc=$?
if ((rc == 0)) && [[ -f "$WORK/out/world/level.dat" ]]; then ok "export-world via the server.properties fallback"
else ko "export-world (rc=$rc): $out"; fi

finish
