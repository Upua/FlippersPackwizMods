#!/usr/bin/env bash
# mc-whitelist: `apply` and `add offline` succeed when no environment runs
# (round 1, fix b1420d2).
. "$(dirname "$0")/lib.sh"

install_script scripts/bin/mc-whitelist scripts/whitelist-json.py
write_test_environment
install_fake_podman
mkdir -p "$XDG_CONFIG_HOME/gsr/shared"
printf '{"schema_version": 1, "players": []}\n' > "$XDG_CONFIG_HOME/gsr/shared/identities.json"
mc_whitelist="$REPO/scripts/bin/mc-whitelist"

out="$("$mc_whitelist" apply 2>&1)"; rc=$?
if ((rc == 0)) && [[ "$out" == *"will be applied when an environment starts"* ]]; then ok "apply with nothing running"
else ko "apply with nothing running (rc=$rc): $out"; fi

out="$("$mc_whitelist" add offline Steve_1 2>&1)"; rc=$?
if ((rc == 0)) && grep -q Steve_1 "$XDG_CONFIG_HOME/gsr/shared/whitelist.json"; then ok "add offline with nothing running"
else ko "add offline (rc=$rc): $out"; fi

finish
