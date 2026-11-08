#!/bin/bash
set -e

REPO_URL="https://github.com/itsflipper/FlippersPackwizMods.git"
BRANCH="main"
SYSTEMD_DIR="$HOME/.config/containers/systemd"
ANCHOR_SERVICE="gsr"
ANCHOR_SYMLINK="$SYSTEMD_DIR/$ANCHOR_SERVICE"
ENVIRONMENTS_DIR="environments"
USER_BIN_DIR="$HOME/.local/bin"
COMMANDS_DIR="scripts/bin"
BASHRC_FILE="$HOME/.bashrc"
DEFAULT_REPO_PATH="${DEFAULT_REPO_PATH:-$HOME/FlippersPackwizMods}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PRIVATE_CONFIG_DIR="$CONFIG_HOME/gsr"
SHARED_DIR="$PRIVATE_CONFIG_DIR/shared"
MASTER_WHITELIST="$SHARED_DIR/whitelist.json"
MASTER_IDENTITIES="$SHARED_DIR/identities.json"
ICONS_DIR="$PRIVATE_CONFIG_DIR/icons"

mkdir -p "$SYSTEMD_DIR"

is_running() {
    local service_name="$1"
    systemctl --user is-active --quiet "$service_name" 2>/dev/null
}

environment_container_files() {
    local repo_path="$1" container_file

    for container_file in "$repo_path/$ENVIRONMENTS_DIR"/*/*.container; do
        [[ -f "$container_file" ]] || continue
        printf '%s\n' "$container_file"
    done
}

environment_services() {
    local repo_path="$1" container_file

    while IFS= read -r container_file; do
        basename "$container_file" .container
    done < <(environment_container_files "$repo_path")
}

active_environment_services() {
    local repo_path="$1" service_name

    while IFS= read -r service_name; do
        if is_running "$service_name"; then
            printf '%s\n' "$service_name"
        fi
    done < <(environment_services "$repo_path")
}

container_name_for_file() {
    sed -nE 's/^ContainerName=([^[:space:]#]+).*/\1/p' "$1" | head -n1
}

seed_master_whitelist() {
    local repo_path="$1" container_file container_name priority temp_dir temp_file json_tool migrated=false

    mkdir -p "$SHARED_DIR"
    # The bind mount is created by the rootless Podman owner. The source
    # remains private to that account; the image copies the whitelist during
    # its root-owned startup phase.
    chmod 700 "$PRIVATE_CONFIG_DIR" "$SHARED_DIR"
    temp_dir="$(mktemp -d "$SHARED_DIR/.whitelist.XXXXXX")"
    temp_file="$temp_dir/whitelist.json"
    json_tool="$repo_path/scripts/whitelist-json.py"

    if [[ ! -f "$MASTER_IDENTITIES" ]]; then
        if [[ -f "$MASTER_WHITELIST" ]]; then
            python3 "$json_tool" migrate "$MASTER_WHITELIST" "$MASTER_IDENTITIES"
            migrated=true
            echo "==> Created private identities from the existing master whitelist"
        else
            # Prefer the live server: its whitelist is the authoritative current one.
            # A stopped container is only a migration fallback for an idle installation.
            for priority in running any; do
                while IFS= read -r container_file; do
                    container_name="$(container_name_for_file "$container_file")"
                    [[ -n "$container_name" ]] || continue
                    if ! podman container exists "$container_name" 2>/dev/null; then
                        continue
                    fi
                    if [[ "$priority" == running ]] && \
                        ! podman inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; then
                        continue
                    fi
                    if podman cp "$container_name:/data/whitelist.json" "$temp_file" 2>/dev/null && \
                        grep -q '^[[:space:]]*\[' "$temp_file"; then
                        chmod 644 "$temp_file"
                        mv -f "$temp_file" "$MASTER_WHITELIST"
                        python3 "$json_tool" migrate "$MASTER_WHITELIST" "$MASTER_IDENTITIES"
                        migrated=true
                        echo "==> Created private identities and master whitelist from $container_name"
                        break 2
                    fi
                done < <(environment_container_files "$repo_path")
            done

            if [[ "$migrated" == false ]]; then
                printf '[]\n' > "$temp_file"
                python3 "$json_tool" migrate "$temp_file" "$MASTER_IDENTITIES"
                echo "==> Created empty private identities"
            fi
        fi
    fi

    if [[ ! -f "$MASTER_WHITELIST" ]]; then
        python3 "$json_tool" build "$MASTER_IDENTITIES" "$MASTER_WHITELIST"
        echo "==> Generated master whitelist from private identities"
    fi

    rm -f "$temp_file"
    rmdir "$temp_dir"
}

sync_private_whitelist() {
    local repo_path="$1"

    seed_master_whitelist "$repo_path"
}

sync_environment_icons() {
    local repo_path="$1" environment icon_source icon_target temp_icon

    mkdir -p "$ICONS_DIR"
    chmod 700 "$PRIVATE_CONFIG_DIR" "$ICONS_DIR"

    for environment in "$repo_path"/$ENVIRONMENTS_DIR/*; do
        [[ -d "$environment" ]] || continue
        icon_source="$environment/server-icon.png"
        [[ -f "$icon_source" ]] || continue
        icon_target="$ICONS_DIR/$(basename "$environment").png"
        temp_icon="$(mktemp "$ICONS_DIR/.server-icon.XXXXXX")"
        cp "$icon_source" "$temp_icon"
        chmod 644 "$temp_icon"
        mv -f "$temp_icon" "$icon_target"
        echo "    server icon: $(basename "$environment")"
    done
}

sync_systemd() {
    local repo_path container_file environment_dir service_name link_path
    repo_path="$(cd "$1" && pwd)"
    sync_private_whitelist "$repo_path"
    sync_environment_icons "$repo_path"
    echo "==> Linking environments + reloading systemd"
    while IFS= read -r container_file; do
        [[ -f "$container_file" ]] || continue
        environment_dir="$(dirname "$container_file")"
        service_name="$(basename "$container_file" .container)"
        link_path="$SYSTEMD_DIR/$service_name"
        if [[ -e "$link_path" && ! -L "$link_path" ]]; then
            echo "Refusing to replace non-symlink: $link_path" >&2
            return 1
        fi
        rm -f "$link_path"
        ln -s "$environment_dir" "$link_path"
        echo "    $service_name -> $environment_dir"
    done < <(environment_container_files "$repo_path")
    systemctl --user daemon-reload
    sync_user_commands "$repo_path"
}
inside_repo() {
    local repo_path="$1" cwd; cwd="$(pwd -P)"
    [[ "$cwd" == "$repo_path" || "$cwd" == "$repo_path"/* ]]
}

# repo_path comes from `git rev-parse` on whatever the anchor symlink points
# at. Before an rm -rf, make sure it really is this project's checkout and
# not, for example, a dotfiles repository rooted at $HOME.
refuse_unsafe_removal() {
    local repo_path="$1" resolved home_resolved
    resolved="$(readlink -f "$repo_path")"
    home_resolved="$(readlink -f "$HOME")"
    if [[ -z "$resolved" || "$resolved" == / || "$resolved" == "$home_resolved" ]] || \
        [[ ! -d "$resolved/$ENVIRONMENTS_DIR" || ! -x "$resolved/$COMMANDS_DIR/gsr" ]]; then
        echo "Refusing to remove $repo_path: it does not look like a FlippersPackwizMods checkout." >&2
        exit 1
    fi
}

clone_fresh() {
    echo "==> Cloning into $1"
    git clone -b "$BRANCH" "$REPO_URL" "$1"
}

fresh_install() {
    local repo_path="$1"
    clone_fresh "$repo_path"
    sync_systemd "$repo_path"

    read -rp "Start the default Vanilla server now? [y/N] " ans
    if [[ "$ans" == y ]]; then
        systemctl --user start "$ANCHOR_SERVICE"
        echo "==> Started. Following logs (Ctrl+C to exit):"
        journalctl --user -u "$ANCHOR_SERVICE" -f
    else
        echo "==> Done. Start with: systemctl --user start $ANCHOR_SERVICE"
    fi
}

update() {
    local repo_path="$1" service_name
    local -a running_services=()

    mapfile -t running_services < <(active_environment_services "$repo_path")

    echo "==> Pulling latest changes"
    # --ff-only: never create a merge commit or half-merged tree on the server.
    if ! git -C "$repo_path" pull --ff-only; then
        echo "Pull failed (diverged history, conflict or dirty tree) — services left untouched." >&2
        return 1
    fi

    sync_systemd "$repo_path"

    if ((${#running_services[@]})); then
        echo "==> Rebuilding and restarting active environment(s)"
        for service_name in "${running_services[@]}"; do
            systemctl --user restart "${service_name}-build.service"
            systemctl --user restart "$service_name.service"
        done
    else
        echo "==> No environment was running, skipping rebuild and restart"
    fi

    echo "==> Done"
}

ensure_user_bin_path() {
    local marker="# FlippersPackwizMods user commands"

    mkdir -p "$USER_BIN_DIR"
    export PATH="$USER_BIN_DIR:$PATH"

    if [[ ! -f "$BASHRC_FILE" ]] || ! grep -Fqx "$marker" "$BASHRC_FILE"; then
        {
            printf '\n%s\n' "$marker"
            printf 'case ":$PATH:" in\n'
            printf '  *":$HOME/.local/bin:"*) ;;\n'
            printf '  *) export PATH="$HOME/.local/bin:$PATH" ;;\n'
            printf 'esac\n'
        } >> "$BASHRC_FILE"
    fi
}

sync_user_commands() {
    local repo_path command_dir command_path command_name link_path legacy_path

    repo_path="$(cd "$1" && pwd)"
    command_dir="$repo_path/$COMMANDS_DIR"
    [[ -d "$command_dir" ]] || return 0

    ensure_user_bin_path

    command_name="gsr"
    command_path="$command_dir/$command_name"
    link_path="$USER_BIN_DIR/$command_name"
    [[ -f "$command_path" && -x "$command_path" ]] || {
        echo "Missing executable command: $command_path" >&2
        return 1
    }
    if [[ -e "$link_path" && ! -L "$link_path" ]]; then
        echo "Refusing to replace non-symlink command: $link_path" >&2
        return 1
    fi
    ln -sfn "$command_path" "$link_path"
    echo "    command: gsr"

    # Old public aliases made it too easy to bypass the central GSR command.
    # Remove only links that demonstrably belong to this checkout; user-owned
    # files with the same names are never touched.
    for command_name in switchenv mc-whitelist gsr-backup gsr-identity gsr-properties; do
        legacy_path="$USER_BIN_DIR/$command_name"
        if [[ -L "$legacy_path" && "$(readlink -f "$legacy_path" 2>/dev/null || true)" == "$command_dir/$command_name" ]]; then
            rm -f "$legacy_path"
            echo "    removed legacy alias: $command_name"
        fi
    done
}

# -- main --

if [[ ! -L "$ANCHOR_SYMLINK" ]]; then
    fresh_install "$DEFAULT_REPO_PATH"
    exit 0
fi

anchor_target="$(readlink -f "$ANCHOR_SYMLINK")"
repo_path="$(git -C "$anchor_target" rev-parse --show-toplevel 2>/dev/null || true)"

# Dangling/broken link: target gone or not a real checkout -> repair.
if [[ -z "$repo_path" || ! -d "$repo_path/$ENVIRONMENTS_DIR" ]]; then
    echo "Anchor symlink is broken or not part of an environment checkout — repairing via fresh install." >&2
    rm -f "$ANCHOR_SYMLINK"
    fresh_install "$DEFAULT_REPO_PATH"
    exit 0
fi

mapfile -t managed_services < <(environment_services "$repo_path")
mapfile -t running_services < <(active_environment_services "$repo_path")

echo "Existing install at $repo_path"
read -rp "[u]pdate / [r]einstall / [d]elete / [l]eave repo (resync only)? " mode
case "$mode" in
    u|U)
        update "$repo_path"
        ;;
    r|R)
        read -rp "This wipes $repo_path and reclones. Sure? [y/N] " confirm
        [[ "$confirm" == y ]] || { echo "Aborted" >&2; exit 1; }
        if inside_repo "$repo_path"; then
            echo "You're inside $repo_path — cd out before nuking." >&2
            exit 1
        fi
        refuse_unsafe_removal "$repo_path"
        for service_name in "${running_services[@]}"; do
            systemctl --user stop "$service_name.service"
        done
        rm -rf "$repo_path"
        clone_fresh "$repo_path"
        sync_systemd "$repo_path"
        for service_name in "${running_services[@]}"; do
            systemctl --user start "$service_name.service"
        done
        ;;
d|D)
    read -rp "Uninstall: stop environments, remove $repo_path and environment links. Sure? [y/N] " confirm
    [[ "$confirm" == y ]] || { echo "Aborted" >&2; exit 1; }
    if inside_repo "$repo_path"; then
        echo "You're inside $repo_path — cd out before deleting." >&2
        exit 1
    fi
    refuse_unsafe_removal "$repo_path"
    for service_name in "${running_services[@]}"; do
        systemctl --user stop "$service_name.service"
    done
    for service_name in "${managed_services[@]}"; do
        if [[ -L "$SYSTEMD_DIR/$service_name" ]]; then
            rm -f "$SYSTEMD_DIR/$service_name"
        fi
    done
    systemctl --user daemon-reload
    rm -rf "$repo_path"
    echo "==> Removed."
    ;;
    l|L)
        sync_systemd "$repo_path"
        for service_name in "${running_services[@]}"; do
            systemctl --user restart "$service_name.service"
        done
        ;;
    *)
        echo "Invalid choice" >&2
        exit 1
        ;;
esac
