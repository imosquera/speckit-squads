#!/usr/bin/env bash
# spec-minimal preset: enforce-minimal-tree.sh
# The SINGLE enforcement mechanism for spec-minimal. Run as the last step of
# the wrapped /speckit-plan.
#
# Unlike a read-only verifier, this script is SELF-HEALING: it never leaves a
# forbidden artifact on disk. For each forbidden path it finds, it inlines the
# content into plan.md inside an idempotent sentinel block, then removes the
# path.
#
# ALLOWED top-level entries:  spec.md, plan.md, tasks.md, quickstart.md,
#                             research.md, checklists (dir)
# FORBIDDEN (any form):       data-model.md, contracts (file or dir)
#
# `checklists/` is allowed, not merely tolerated: core Spec Kit's own
# /speckit-specify mandates writing checklists/requirements.md, so warning about
# it fired on every single run. A warning that always fires is noise that gets
# ignored, which is worse than no warning at all. It is only in ALLOWED (never
# FORBIDDEN), so nothing about it is removed or folded into plan.md.
#
# Anything else at the top level is UNKNOWN: warned about on stderr and left
# alone. Dotfiles are ignored entirely. Other stacked presets legitimately write
# files here, so unknown entries must never fail the run.
#
# ---------------------------------------------------------------------------
# SAFETY INVARIANTS (this script deletes files — read before editing)
#
# 1. WRITE-BEFORE-REMOVE. All content is gathered first, the complete new
#    plan.md is built in memory, and it is written ATOMICALLY (temp file in the
#    same directory + fsync + rename, always UTF-8). Only after
#    that write is confirmed does anything get removed. If the write fails,
#    nothing is removed and the script exits 1. plan.md is never truncated in
#    place, so a failed write can never destroy existing plan content.
#    The original plan.md permission bits are carried over to the replacement;
#    a read-only plan.md is therefore still healed (the directory, not the
#    file, is what must be writable).
#
# 2. SENTINELS CAN NEVER APPEAR IN A BLOCK BODY. Gathered content is sanitized
#    before it is wrapped: any literal "<!-- BEGIN: spec-minimal inlined" or
#    "<!-- END: spec-minimal inlined" is rewritten to
#    "<!-- (escaped by spec-minimal) BEGIN: …" / "… END: …", which is not
#    itself a sentinel. This IS deliberate and it IS lossy — but only in the
#    escaping sense: the text stays fully readable, only the exact comment
#    prefix changes. Without it, inlined content that merely quotes a sentinel
#    (this preset's own README.md does) would make block parsing ambiguous and
#    silently eat the rest of plan.md. The escape is idempotent, so repeated
#    runs converge.
#
# 3. UNBALANCED SENTINELS ARE A HARD ERROR. A BEGIN with no matching END (or an
#    END with no BEGIN, or a mismatched pair) means plan.md cannot be parsed
#    unambiguously. The script reports which sentinel is unbalanced and on what
#    line, writes nothing, removes nothing, and exits 1.
#
# 4. SYMLINKS ARE NEVER FOLLOWED. A forbidden path that is a symlink (including
#    a dangling one) is detected via lexists, is NOT read or inlined, and only
#    the link itself is removed — the target is left untouched. This is
#    reported truthfully rather than as "empty".
#
# 5. A FORBIDDEN ARTIFACT IS NEVER LEFT ON DISK JUST BECAUSE plan.md IS ABSENT.
#    plan.md is itself in the allowed set, so if it is missing the enforcer
#    CREATES it (with a minimal header) and rehomes the content into it. There
#    is no "refuse and leave the artifact there" outcome.
# ---------------------------------------------------------------------------
#
# Exit codes:
#   0  the tree matches the allowed set — no forbidden artifact remains on
#      disk. Healing (including creating plan.md) and warnings may have
#      happened; both are reported.
#   1  one of two distinct situations, always stated explicitly on stderr:
#        (a) HEALING IMPOSSIBLE — nothing was written to plan.md and nothing
#            was removed. Causes: the feature dir cannot be listed, plan.md
#            exists but cannot be read as UTF-8, plan.md has unbalanced
#            sentinels, a forbidden artifact cannot be read, or plan.md cannot
#            be written.
#        (b) PARTIALLY HEALED — the content IS safely inlined in plan.md, but
#            at least one forbidden artifact could not be removed from disk and
#            is still there.
#   2  bad usage
#
# Usage: enforce-minimal-tree.sh <feature-dir>

set -euo pipefail

FEATURE_DIR="${1:-}"
if [[ -z "$FEATURE_DIR" ]]; then
    echo "error: feature directory argument required" >&2
    exit 2
fi
if [[ ! -d "$FEATURE_DIR" ]]; then
    echo "error: not a directory: $FEATURE_DIR" >&2
    exit 2
fi

if ! command -v bun >/dev/null 2>&1; then
    echo "error: bun is required but not on PATH (install: https://bun.sh)" >&2
    exit 127
fi
exec bun "$(dirname "${BASH_SOURCE[0]}")/../ts/enforce-minimal-tree.ts" "$FEATURE_DIR"
