#!/usr/bin/env bash
# bootstrap.sh refuse_unsafe_removal (round 1, fix 40d7d57): the rm -rf of the
# repository path must refuse /, $HOME and directories that are not a checkout.
# bootstrap.sh runs its install logic at top level, so only the function is
# extracted from it and evaluated here.
. "$(dirname "$0")/lib.sh"

definition="$(sed -n '/^refuse_unsafe_removal() {$/,/^}$/p' "$SOURCE_ROOT/gsr/bootstrap.sh")"
if [[ -z "$definition" ]]; then
    ko "refuse_unsafe_removal not found in gsr/bootstrap.sh"
    finish
    exit
fi

# guard <path>: run the guard in a subshell (it calls exit), print its status.
guard() {
    (
        # Globals that bootstrap.sh defines and the extracted function reads.
        # shellcheck disable=SC2034
        ENVIRONMENTS_DIR=environments
        # shellcheck disable=SC2034
        COMMANDS_DIR=scripts/bin
        eval "$definition"
        refuse_unsafe_removal "$1"
    ) >/dev/null 2>&1
}

mkdir -p "$WORK/plain" "$WORK/checkout/environments" "$WORK/checkout/scripts/bin"
printf '#!/bin/sh\n' > "$WORK/checkout/scripts/bin/gsr"
chmod +x "$WORK/checkout/scripts/bin/gsr"
mkdir -p "$HOME/environments" "$HOME/scripts/bin"
cp "$WORK/checkout/scripts/bin/gsr" "$HOME/scripts/bin/gsr"

if guard /; then ko "guard allowed /"; else ok "guard refuses /"; fi
if guard "$HOME"; then ko "guard allowed \$HOME (even when it looks like a checkout)"; else ok "guard refuses \$HOME"; fi
if guard "$WORK/plain"; then ko "guard allowed a non-checkout directory"; else ok "guard refuses a non-checkout directory"; fi
if guard "$WORK/checkout"; then ok "guard allows a checkout"; else ko "guard refused a checkout"; fi
if guard "$SOURCE_ROOT"; then ok "guard allows this repository"; else ko "guard refused this repository"; fi

finish
