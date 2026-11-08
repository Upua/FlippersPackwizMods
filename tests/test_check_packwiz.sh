#!/usr/bin/env bash
# tests/check-packwiz.py on a Python without tomllib (older than 3.11) must
# exit with a clear message, not a traceback (round 3). Older Pythons are
# simulated by blocking the tomllib import.
. "$(dirname "$0")/lib.sh"

script="$SOURCE_ROOT/tests/check-packwiz.py"
python3 -I - "$script" > "$WORK/out.log" 2>&1 <<'PY'
import runpy
import sys

sys.modules["tomllib"] = None  # makes `import tomllib` raise ImportError
path = sys.argv[1]
sys.argv = [path]
runpy.run_path(path, run_name="__main__")
PY
rc=$?
if ((rc == 2)) && grep -q 'needs Python 3.11 or newer' "$WORK/out.log" && ! grep -q Traceback "$WORK/out.log"; then
    ok "without tomllib: clear message and exit 2, no traceback"
else
    ko "without tomllib (rc=$rc): $(cat "$WORK/out.log")"
fi

finish
