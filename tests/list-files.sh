#!/usr/bin/env bash
# Lists the repository's tracked and new (not ignored) files of one kind, by
# shebang or extension, NUL-separated, for the lint steps in CI:
#   tests/list-files.sh shell | xargs -0 shellcheck -S warning
#   tests/list-files.sh python | xargs -0 python3 -m py_compile
set -euo pipefail

kind="${1:-}"
case "$kind" in
    shell|python) ;;
    *) echo "usage: tests/list-files.sh shell|python" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
found=0
while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    first=""
    IFS= read -r first < "$file" || true
    case "$kind:$file:$first" in
        shell:*.sh:*|shell:*:'#!'*bash*|shell:*:'#!'*/sh) ;;
        python:*.py:*|python:*:'#!'*python*) ;;
        *) continue ;;
    esac
    printf '%s\0' "$file"
    found=$((found + 1))
done < <(git ls-files -z --cached --others --exclude-standard)

if ((found == 0)); then
    echo "tests/list-files.sh: no $kind files found" >&2
    exit 1
fi
