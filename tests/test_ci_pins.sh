#!/usr/bin/env bash
# Every action used by a workflow is pinned to a full 40-character commit SHA
# with a trailing "# vX.Y.Z" comment naming the release (round 3). Offline:
# it checks the form only, not that the SHA belongs to that release.
. "$(dirname "$0")/lib.sh"

found=0
while IFS= read -r line; do
    found=$((found + 1))
    if [[ "$line" =~ uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]+(\.[0-9]+)*[[:space:]]*$ ]]; then
        ok "pinned: ${line#*uses:}"
    else
        ko "not pinned to a commit SHA with a version comment: ${line#*uses:}"
    fi
done < <(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:' "$SOURCE_ROOT"/.github/workflows/*.yml)
check "the workflows use at least one action" [ "$found" -gt 0 ]
check "actions/checkout is pinned to 3d3c42e5 (v7.0.1)" \
    grep -qE 'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1$' "$SOURCE_ROOT/.github/workflows/check.yml"

finish
