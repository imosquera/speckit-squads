#!/usr/bin/env bash
# spec-minimal preset: verify-minimal-tree.sh
# Post-flight: FAIL the run if the feature directory contains anything
# beyond the four allowed files (spec.md, plan.md, tasks.md,
# requirements.md), OR if the pre-flight sentinel directories were
# written into (i.e. became non-empty).
#
# This script never deletes user content. It exits non-zero on violation
# so the caller surfaces a clear error.
#
# It also cleans up the empty sentinel directories created by
# block-forbidden-artifacts.sh once verification passes.
#
# Usage: verify-minimal-tree.sh <feature-dir>

set -e

FEATURE_DIR="${1:-}"
if [[ -z "$FEATURE_DIR" ]]; then
    echo "error: feature directory argument required" >&2
    exit 2
fi
if [[ ! -d "$FEATURE_DIR" ]]; then
    echo "error: not a directory: $FEATURE_DIR" >&2
    exit 2
fi

ALLOWED=(spec.md plan.md tasks.md requirements.md)
SENTINELS=(research.md data-model.md quickstart.md contracts)

is_allowed() {
    for a in "${ALLOWED[@]}"; do [[ "$1" == "$a" ]] && return 0; done
    return 1
}
is_sentinel() {
    for s in "${SENTINELS[@]}"; do [[ "$1" == "$s" ]] && return 0; done
    return 1
}

violations=()
while IFS= read -r entry; do
    name="$(basename "$entry")"
    [[ "$name" == "." || "$name" == ".." ]] && continue

    if is_allowed "$name"; then
        continue
    fi

    if is_sentinel "$name"; then
        # Sentinels must be empty directories. Anything else means the stock
        # flow wrote into the blocked path (e.g. via rm + recreate).
        if [[ ! -d "$entry" ]]; then
            violations+=("$entry (forbidden artifact written as a file)")
            continue
        fi
        if [[ -n "$(ls -A "$entry" 2>/dev/null || true)" ]]; then
            violations+=("$entry (forbidden artifact: directory is non-empty)")
            continue
        fi
        continue
    fi

    violations+=("$entry (not in allowed set)")
done < <(find "$FEATURE_DIR" -mindepth 1 -maxdepth 1)

if (( ${#violations[@]} > 0 )); then
    echo "FAIL: spec-minimal violations in $FEATURE_DIR" >&2
    for v in "${violations[@]}"; do echo "  - $v" >&2; done
    echo "" >&2
    echo "spec-minimal forbids creating these files. Allowed set:" >&2
    for a in "${ALLOWED[@]}"; do echo "  - $a" >&2; done
    exit 1
fi

# Clean up empty sentinel directories now that verification passed.
for name in "${SENTINELS[@]}"; do
    path="$FEATURE_DIR/$name"
    if [[ -d "$path" ]]; then
        chmod -R u+w "$path" 2>/dev/null || true
        rmdir "$path" 2>/dev/null || true
    fi
done

echo "ok: $FEATURE_DIR matches spec-minimal allowed set"
