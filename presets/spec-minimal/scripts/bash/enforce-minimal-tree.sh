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
# ALLOWED top-level entries:  spec.md, plan.md, tasks.md, quickstart.md
# FORBIDDEN (any form):       research.md, data-model.md, contracts (file or dir)
#
# Anything else at the top level is UNKNOWN: warned about on stderr and left
# alone. Other stacked presets legitimately write files here (checklists/, …),
# so unknown entries must never fail the run.
#
# Exit codes:
#   0  tree is clean (with or without healing, with or without warnings)
#   1  healing was required but could not be completed (e.g. plan.md missing)
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

python3 - "$FEATURE_DIR" <<'PY'
import shutil
import sys
from pathlib import Path

feature_dir = Path(sys.argv[1])

ALLOWED = ("spec.md", "plan.md", "tasks.md", "quickstart.md")
# Deterministic processing order — keeps plan.md stable across runs.
FORBIDDEN = ("research.md", "data-model.md", "contracts")

PLAN = feature_dir / "plan.md"


def err(msg):
    print(msg, file=sys.stderr)


def begin_sentinel(name):
    return f"<!-- BEGIN: spec-minimal inlined {name} -->"


def end_sentinel(name):
    return f"<!-- END: spec-minimal inlined {name} -->"


def read_text_or_none(path):
    """Return the file's text, or None if it can't be decoded as UTF-8."""
    try:
        return path.read_bytes().decode("utf-8")
    except (UnicodeDecodeError, OSError):
        return None


def gather_file(path, skipped):
    text = read_text_or_none(path)
    if text is None:
        skipped.append(str(path.name))
        return ""
    return text


def gather_dir(root, skipped):
    """Concatenate every file under root, each under a '### <relpath>' heading."""
    chunks = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        text = read_text_or_none(path)
        if text is None:
            skipped.append(f"{root.name}/{rel}")
            continue
        body = text.strip("\n")
        chunks.append(f"### {rel}\n\n{body}\n" if body else f"### {rel}\n")
    return "\n".join(chunks)


def gather(path, skipped):
    if path.is_dir() and not path.is_symlink():
        return gather_dir(path, skipped)
    return gather_file(path, skipped)


def make_block(name, content):
    body = content.strip("\n")
    return (
        begin_sentinel(name) + "\n"
        f"## Inlined from {name}\n"
        "\n"
        + body + "\n"
        + end_sentinel(name) + "\n"
    )


def upsert_block(plan_text, name, block):
    """Replace an existing sentinel block in place, else append. Idempotent."""
    begin = begin_sentinel(name)
    end = end_sentinel(name)
    start = plan_text.find(begin)
    if start != -1:
        stop = plan_text.find(end, start)
        if stop != -1:
            stop += len(end)
            # Swallow the newline that terminates the END sentinel line, since
            # `block` already carries its own.
            if plan_text[stop:stop + 1] == "\n":
                stop += 1
            return plan_text[:start] + block + plan_text[stop:]
    # Append, separated from prior content by exactly one blank line.
    if plan_text and not plan_text.endswith("\n"):
        plan_text += "\n"
    if plan_text:
        plan_text += "\n"
    return plan_text + block


# ---------------------------------------------------------------- scan

present = [name for name in FORBIDDEN if (feature_dir / name).exists()]

unknown = sorted(
    p.name
    for p in feature_dir.iterdir()
    if p.name not in ALLOWED and p.name not in FORBIDDEN
)
for name in unknown:
    err(f"warning: unknown top-level entry (left in place): {name}")

if not present:
    print(f"ok: {feature_dir} matches spec-minimal allowed set")
    sys.exit(0)

# Hard error: we must not destroy content we cannot rehome.
if not PLAN.is_file():
    err(f"FAIL: forbidden artifact(s) present but plan.md is missing in {feature_dir}")
    for name in present:
        err(f"  - {name}")
    err("")
    err("Nothing was removed. Create plan.md first, then re-run this script so")
    err("the content can be inlined instead of lost.")
    sys.exit(1)

# ---------------------------------------------------------------- heal

plan_text = PLAN.read_text()
inlined, removed, empties = [], [], []
failures = []

for name in present:
    path = feature_dir / name
    skipped = []
    try:
        content = gather(path, skipped)
    except OSError as exc:
        failures.append(f"{name}: could not read ({exc})")
        continue

    for s in skipped:
        err(f"warning: undecodable file, bytes skipped: {s}")

    if content.strip():
        plan_text = upsert_block(plan_text, name, make_block(name, content))
        inlined.append(name)
    else:
        empties.append(name)

    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
        removed.append(name)
    except OSError as exc:
        failures.append(f"{name}: could not remove ({exc})")

PLAN.write_text(plan_text)

for name in inlined:
    print(f"inlined: {name} -> plan.md (block '{begin_sentinel(name)}')")
for name in empties:
    print(f"empty:   {name} had no content — nothing inlined")
for name in removed:
    print(f"removed: {name}")

if failures:
    err(f"FAIL: spec-minimal healing incomplete in {feature_dir}")
    for f in failures:
        err(f"  - {f}")
    sys.exit(1)

print(f"ok: {feature_dir} healed to the spec-minimal allowed set")
PY
