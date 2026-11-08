#!/usr/bin/env bash
# Runs every offline test (tests/test_*.sh) and exits non-zero if any fails.
# Needs bash, coreutils, tar, zstd, python3 and flock (util-linux); no root,
# network, Podman or systemd. Usage: tests/run.sh [test_name.sh ...]
set -uo pipefail

tests_dir="$(cd "$(dirname "$0")" && pwd)"
missing=()
for tool in tar zstd python3 sha256sum find sort flock timeout; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ((${#missing[@]})); then
    echo "tests/run.sh: missing required tools: ${missing[*]}" >&2
    exit 2
fi

if (($#)); then
    tests=()
    for name in "$@"; do tests+=("$tests_dir/$(basename "$name")"); done
else
    tests=("$tests_dir"/test_*.sh)
fi

failed=()
for test in "${tests[@]}"; do
    name="$(basename "$test")"
    echo "=== $name"
    if [[ ! -f "$test" ]]; then
        echo "FAIL: no such test: $test"
        failed+=("$name")
    elif ! bash "$test"; then
        failed+=("$name")
    fi
done

echo
if ((${#failed[@]})); then
    echo "tests/run.sh: ${#failed[@]} of ${#tests[@]} test files FAILED: ${failed[*]}"
    exit 1
fi
echo "tests/run.sh: all ${#tests[@]} test files passed"
