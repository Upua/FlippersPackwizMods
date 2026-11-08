# Shared helpers for the offline tests. Source it from a test script:
#   . "$(dirname "$0")/lib.sh"
# Everything runs in a private temporary directory with its own HOME, XDG
# directories and fake `podman`/`systemctl` first on PATH. Nothing needs
# root, the network, a real Podman or systemd.
# shellcheck shell=bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gsr-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

# Fake repository: the scripts derive REPO_ROOT from their own path, so they
# are copied into $WORK/repo next to a minimal test environment.
REPO="$WORK/repo"
FAKE_BIN="$WORK/bin"
VOLUMES="$WORK/volumes"
mkdir -p "$REPO/scripts/bin" "$REPO/environments/test" "$FAKE_BIN" "$VOLUMES" "$WORK/home"

export HOME="$WORK/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CONFIG_HOME="$HOME/.config"
export PATH="$FAKE_BIN:$PATH"
unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS GSR_REPO_ROOT

ok() { echo "PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
ko() { echo "FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# check <description> <command...>: PASS if the command succeeds.
check() {
    local description="$1"
    shift
    if "$@"; then ok "$description"; else ko "$description"; fi
}

finish() {
    echo "passed=$PASS_COUNT failed=$FAIL_COUNT"
    ((FAIL_COUNT == 0))
}

# install_script <repo-relative path>...: copy scripts into the fake repo.
install_script() {
    local path
    for path in "$@"; do
        mkdir -p "$REPO/$(dirname "$path")"
        cp "$SOURCE_ROOT/$path" "$REPO/$path"
    done
}

# The test environment: container testc, volume testdata, world "world".
write_test_environment() {
    cat > "$REPO/environments/test/test.container" <<'EOF'
[Container]
ContainerName=testc
Environment=VERSION=1.0
Environment=LEVEL=world
Volume=testdata:/data
EOF
}

# A fake podman. Volumes are directories under $VOLUMES. Behaviour switches:
#   $WORK/running          exists -> the container reports Running=true
#   $WORK/import-failures  holds N -> the next N `volume import`s fail
#   $WORK/export-delay     holds S -> each `volume export` first sleeps S s
#   $WORK/exec-fails       exists -> `podman exec` (the RCON flush) fails
# `podman exec` otherwise succeeds without doing anything.
# Every call is appended to $WORK/podman.log.
install_fake_podman() {
    cat > "$FAKE_BIN/podman" <<EOF
#!/usr/bin/env bash
work="$WORK"
volumes="$VOLUMES"
EOF
    cat >> "$FAKE_BIN/podman" <<'EOF'
echo "podman $*" >> "$work/podman.log"
case "$1 ${2:-}" in
    "volume exists") [[ -d "$volumes/$3" ]] ;;
    "volume create") mkdir -p "$volumes/$3" ;;
    "volume rm") [[ -d "$volumes/$3" ]] && rm -rf -- "${volumes:?}/$3" ;;
    "volume export")
        delay="$(cat "$work/export-delay" 2>/dev/null || echo 0)"
        sleep "$delay"
        tar -C "$volumes/$3" -cf - . ;;
    "exec "*) [[ ! -e "$work/exec-fails" ]] ;;
    "volume import")
        failures="$(cat "$work/import-failures" 2>/dev/null || echo 0)"
        if ((failures > 0)); then
            cat > /dev/null
            echo $((failures - 1)) > "$work/import-failures"
            echo "fake podman: import failed" >&2
            exit 1
        fi
        tar -C "$volumes/$3" -xf - ;;
    "inspect -f")
        if [[ -e "$work/running" ]]; then echo true; else echo false; fi ;;
    "ps --all") exit 0 ;;
    *) echo "fake podman: unsupported: $*" >&2; exit 1 ;;
esac
EOF
    chmod +x "$FAKE_BIN/podman"
}

# A fake systemctl: services are inactive unless $WORK/active exists;
# start/stop/daemon-reload succeed. Calls are logged to $WORK/systemctl.log.
install_fake_systemctl() {
    cat > "$FAKE_BIN/systemctl" <<EOF
#!/usr/bin/env bash
work="$WORK"
EOF
    cat >> "$FAKE_BIN/systemctl" <<'EOF'
echo "systemctl $*" >> "$work/systemctl.log"
args=" $* "
if [[ "$args" == *" is-active "* ]]; then
    [[ -e "$work/active" ]]
    exit
fi
exit 0
EOF
    chmod +x "$FAKE_BIN/systemctl"
}

# A fake systemctl that behaves like the real unit for test.service: `stop`
# runs the real stop hooks (ExecStop=gsr backup prepare, then the container
# stops, then ExecStopPost=gsr backup finalize with SERVICE_RESULT) and marks
# the service inactive; `start` marks it active and running. Switches:
#   $WORK/active                exists -> is-active succeeds
#   $WORK/service-result        holds the SERVICE_RESULT for finalize
#                               (default success)
#   $WORK/stop-fails-after-hooks exists -> stop fails after both hooks ran
# Hook output goes to $WORK/hooks.log, calls to $WORK/systemctl.log.
install_hooked_systemctl() {
    cat > "$FAKE_BIN/systemctl" <<EOF
#!/usr/bin/env bash
work="$WORK"
gsr_backup="$REPO/scripts/bin/gsr-backup"
EOF
    cat >> "$FAKE_BIN/systemctl" <<'EOF'
echo "systemctl $*" >> "$work/systemctl.log"
args=" $* "
if [[ "$args" == *" is-active "* ]]; then
    [[ -e "$work/active" ]]
    exit
fi
if [[ "$args" == *" stop test.service "* ]]; then
    # The hooks are `-` prefixed in the unit: their failures are ignored.
    "$gsr_backup" prepare test >> "$work/hooks.log" 2>&1 || true
    rm -f "$work/running"
    SERVICE_RESULT="$(cat "$work/service-result" 2>/dev/null || echo success)" \
        "$gsr_backup" finalize test >> "$work/hooks.log" 2>&1 || true
    rm -f "$work/active"
    if [[ -e "$work/stop-fails-after-hooks" ]]; then
        echo "fake systemctl: stop failed" >&2
        exit 1
    fi
    exit 0
fi
if [[ "$args" == *" start test.service "* ]]; then
    touch "$work/active" "$work/running"
    exit 0
fi
exit 0
EOF
    chmod +x "$FAKE_BIN/systemctl"
}

# make_snapshot_archive <snapshot dir> <source dir>: a valid volume.tar.zst,
# its .sha256 and a manifest for environment "test".
make_snapshot_archive() {
    local snapshot="$1" source="$2" digest size
    mkdir -p "$snapshot"
    tar -C "$source" -cf - . | zstd -q -o "$snapshot/volume.tar.zst"
    digest="$(sha256sum "$snapshot/volume.tar.zst" | cut -d' ' -f1)"
    printf '%s  volume.tar.zst\n' "$digest" > "$snapshot/volume.tar.zst.sha256"
    size="$(stat -c %s "$snapshot/volume.tar.zst")"
    printf '{"environment": "test", "created_at": "2020-01-01T00:00:00+00:00", "archive": "volume.tar.zst", "sha256": "%s", "archive_bytes": %s, "world_directory": "world"}\n' \
        "$digest" "$size" > "$snapshot/manifest.json"
}
