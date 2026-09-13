#!/usr/bin/env bash
# button-design preset: check-buttons.sh
# Deterministic half of the button-design rules. Read-only: never edits a file.
#
#   spec <spec.md>       `## Actions & Buttons` exists and is either `None.` or a
#                        table where: kind is button|link; links take no role;
#                        each screen has at most one primary; button labels are
#                        1–3 words and not generic; destructive labels name
#                        their object and carry a confirm/type/undo safeguard.
#   plan <feature-dir>   when the spec declares actions, plan.md has a
#                        `## Button System` with all five markers populated and
#                        no touch target under 44×44.
#
# Prose rules (jargon, "match the moment", placement quality) stay in the
# command prompts. A checker that guesses at those cries wolf, and one that
# cries wolf gets disabled.
#
# Usage: check-buttons.sh spec <spec.md>
#        check-buttons.sh plan <feature-dir>
# Exit:  0 pass   1 rule violation (stderr says which)   2 bad usage

set -uo pipefail

MODE="${1:-}"
TARGET="${2:-}"
usage() {
    echo "usage: $(basename "$0") spec <spec.md> | plan <feature-dir>" >&2
    exit 2
}
case "$MODE" in
    spec) [[ -f "$TARGET" ]] || { echo "error: not a file: $TARGET" >&2; usage; } ;;
    plan) [[ -f "$TARGET/plan.md" ]] || { echo "error: no plan.md in: $TARGET" >&2; usage; } ;;
    *) usage ;;
esac

exec python3 - "$MODE" "$TARGET" <<'PY'
import pathlib
import re
import sys

mode, target = sys.argv[1], pathlib.Path(sys.argv[2])

SPEC_TITLE = "Actions & Buttons"
PLAN_TITLE = "Button System"
PLAN_MARKERS = ("Component", "Color roles", "States", "Touch targets", "Placement")
GENERIC = {"ok", "okay", "yes", "no", "submit", "confirm", "click", "click here", "here", "go", "press"}
# First word that makes a button destructive. `cancel` only counts with an
# object (`Cancel Subscription`): a bare `Cancel` is the ordinary dismiss button.
DESTRUCTIVE = {"delete", "remove", "erase", "destroy", "discard", "revoke", "purge", "wipe", "terminate"}
SAFEGUARD = re.compile(r"confirm|undo|type", re.I)
TARGET_SIZE = re.compile(r"(\d+)\s*(?:px|pt|dp)?\s*[x×]\s*(\d+)")
MIN_TARGET = 44
DASH = {"", "-", "—", "–", "n/a"}
MARKER = re.compile(r"^\s*(?:[-*]\s+)?\*\*([^*]+?):\*\*\s*(.*)$")

SPEC_SHAPE = """  Expected shape (or `None — no user-facing UI.` under the heading):

    ## Actions & Buttons

    | Screen | Label | Kind | Role | Safeguard |
    |---|---|---|---|---|
    | Export dialog | Download Report | button | primary | — |
    | Export dialog | Cancel | button | secondary | — |
    | Settings | Delete Account | button | secondary | type-to-confirm |
    | Settings | Privacy policy | link | — | — |"""

PLAN_SHAPE = "  Expected markers, each populated:\n" + "\n".join(
    f"    **{m}:** ..." for m in PLAN_MARKERS)


def section(lines, title):
    """Body lines of `## <title>` up to the next `## ` heading, or None."""
    head = re.compile(r"^##\s+" + re.escape(title) + r"\s*$", re.I)
    for i, line in enumerate(lines):
        if head.match(line):
            body = []
            for nxt in lines[i + 1:]:
                if re.match(r"^##\s", nxt):
                    break
                body.append(nxt)
            return body
    return None


def declared_none(body):
    first = next((l for l in body if l.strip()), "")
    return bool(re.match(r"^\s*None\b", first, re.I))


def table(body):
    rows = [[c.strip() for c in l.strip().strip("|").split("|")]
            for l in body if l.lstrip().startswith("|")]
    if len(rows) < 2:
        return None, []
    data = [r for r in rows[1:] if not all(re.fullmatch(r":?-+:?", c) for c in r if c)]
    return [h.lower() for h in rows[0]], data


def check_spec(spec):
    body = section(spec.read_text().splitlines(), SPEC_TITLE)
    if body is None:
        return [f"missing section: `## {SPEC_TITLE}`\n{SPEC_SHAPE}"], []
    if declared_none(body):
        return [], ["spec declares no user-facing actions"]
    header, rows = table(body)
    if header is None or not rows:
        return [f"`## {SPEC_TITLE}` has no action table\n{SPEC_SHAPE}"], []
    idx = {w: next((i for i, h in enumerate(header) if w in h), None)
           for w in ("screen", "label", "kind", "role", "safeguard")}
    missing = [w for w, i in idx.items() if i is None]
    if missing:
        return [f"action table lacks column(s): {', '.join(missing)}\n{SPEC_SHAPE}"], []

    problems, notes = [], []
    primaries, button_screens = {}, []
    for n, r in enumerate(rows, 1):
        def get(w):
            return r[idx[w]].strip() if idx[w] < len(r) else ""
        screen = get("screen")
        label = get("label").strip("`*\"' ")
        kind = get("kind").strip("`").lower()
        role = get("role").strip("`").lower()
        words = label.split()
        where = f"row {n} ({screen or '?'} / {label or '?'})"

        if kind not in ("button", "link"):
            problems.append(f"{where}: kind must be `button` or `link`, got `{kind}`")
            continue
        if label.lower().rstrip(".!") in GENERIC:
            problems.append(f"{where}: generic label; say what happens next "
                            "(`Download Report`, not `Submit`)")
        if kind == "link":
            if role not in DASH:
                problems.append(f"{where}: links navigate and take no button role; "
                                "use `—`, or make it a button")
            continue
        if role not in ("primary", "secondary", "tertiary"):
            problems.append(f"{where}: button role must be primary|secondary|tertiary, got `{role}`")
            continue
        button_screens.append(screen)
        if role == "primary":
            primaries[screen] = primaries.get(screen, 0) + 1
        if not 1 <= len(words) <= 3:
            problems.append(f"{where}: button labels are 1–3 words, got {len(words)}")
        verb = words[0].lower() if words else ""
        if verb in DESTRUCTIVE or (verb == "cancel" and len(words) > 1):
            if len(words) < 2:
                problems.append(f"{where}: destructive label must name what it destroys "
                                "(`Delete Account`, not `Delete`)")
            if not SAFEGUARD.search(get("safeguard")):
                problems.append(f"{where}: destructive action needs a safeguard: "
                                "`confirm dialog`, `type-to-confirm`, or `undo`")

    for screen, count in primaries.items():
        if count > 1:
            problems.append(f"screen `{screen}`: {count} primary buttons; exactly one "
                            "action is the next step, demote the rest to secondary")
    for screen in dict.fromkeys(button_screens):
        if screen not in primaries:
            notes.append(f"screen `{screen}` has buttons but no primary; "
                         "fine for a toolbar, suspicious for a task")
    return problems, notes


def marker(body, name):
    """Text after `**<name>:**` up to the next plan marker or heading, or None."""
    for i, line in enumerate(body):
        m = MARKER.match(line)
        if m and m.group(1).strip().lower() == name.lower():
            parts = [m.group(2)]
            for nxt in body[i + 1:]:
                nm = MARKER.match(nxt)
                # Only the five plan markers end a block; a nested `**Primary:**`
                # bullet under Color roles is content, not a boundary.
                if (nm and nm.group(1).strip() in PLAN_MARKERS) or re.match(r"^#{1,6}\s", nxt):
                    break
                parts.append(nxt)
            return "\n".join(parts)
    return None


def check_plan(fdir):
    spec = fdir / "spec.md"
    body = section(spec.read_text().splitlines(), SPEC_TITLE) if spec.is_file() else None
    if body is None:
        return [], [f"spec has no `## {SPEC_TITLE}` section (written without this "
                    "preset's specify layer); nothing to hold the plan to"]
    if declared_none(body):
        return [], ["spec declares no user-facing actions; no button system required"]
    plan = section((fdir / "plan.md").read_text().splitlines(), PLAN_TITLE)
    if plan is None:
        return [f"missing section in plan.md: `## {PLAN_TITLE}`\n{PLAN_SHAPE}"], []
    problems = []
    for name in PLAN_MARKERS:
        content = marker(plan, name)
        if content is None:
            problems.append(f"`## {PLAN_TITLE}` lacks `**{name}:**`")
        elif not content.strip():
            problems.append(f"`**{name}:**` is empty")
        elif name == "Touch targets":
            for a, b in TARGET_SIZE.findall(content):
                if min(int(a), int(b)) < MIN_TARGET:
                    problems.append(f"touch target {a}×{b} is under {MIN_TARGET}×{MIN_TARGET}")
    return problems, []


problems, notes = (check_spec if mode == "spec" else check_plan)(target)
if problems:
    print(f"error: {target} breaks the button-design rules", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)
for note in notes:
    print(f"button-design: note: {note}")
print(f"button-design: {mode} check passed.")
PY
