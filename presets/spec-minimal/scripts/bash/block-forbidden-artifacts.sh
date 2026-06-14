#!/usr/bin/env bash
# spec-minimal preset: block-forbidden-artifacts.sh
# Pre-flight: pre-occupy the forbidden artifact paths with empty,
# write-blocked entries so the stock /speckit-plan flow CANNOT create them.
#
# Strategy:
#   * research.md, data-model.md, quickstart.md  -> created as empty 0-byte
#     directories. Any attempt to open(...O_WRONLY|O_CREAT) one of these
#     names errors out with EISDIR, so the stock flow's file-write step
#     fails fast instead of silently producing a forbidden artifact.
#   * contracts/                                 -> created as an empty
#     directory with mode 0500 (read+exec only), so attempts to write
#     files inside it fail with EACCES.
#
# Idempotent. Safe to run before every plan.
#
# Usage: block-forbidden-artifacts.sh <feature-dir>

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

FILE_BLOCKS=(research.md data-model.md quickstart.md)
DIR_BLOCKS=(contracts)

for name in "${FILE_BLOCKS[@]}"; do
    path="$FEATURE_DIR/$name"
    if [[ -e "$path" && ! -d "$path" ]]; then
        echo "error: $path already exists as a file; spec-minimal forbids it." >&2
        echo "Delete it and re-run, or stop using the spec-minimal preset." >&2
        exit 1
    fi
    mkdir -p "$path"
done

for name in "${DIR_BLOCKS[@]}"; do
    path="$FEATURE_DIR/$name"
    if [[ -e "$path" && ! -d "$path" ]]; then
        echo "error: $path exists as a file; expected a directory or nothing." >&2
        exit 1
    fi
    mkdir -p "$path"
    chmod 0500 "$path"
done

echo "ok: forbidden artifact paths pre-blocked in $FEATURE_DIR"
