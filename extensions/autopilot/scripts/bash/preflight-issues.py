#!/usr/bin/env python3
"""Evaluate the open-issue backlog and emit a single descriptive log line.

Two modes, selected by argv:
  preflight-issues.py <issues.json>       — auto-pick the oldest eligible issue
  preflight-issues.py <issues.json> <N>   — validate ONE specific issue number

Both modes share the same eligibility rules (block labels, empty body,
in-progress liveness) so the auto-pick path and the explicit-issue path can
never drift apart — that drift (the explicit path skipping the
`autopilot:claimed` check) was one of the root causes of two autopilot runs
colliding on the same issue (repo issue #19).

Output format (callers read the first word to decide):
  PICK: #42 "Fix the thing" — 7 open (2 parked, 1 in-progress)
  SKIP: backlog clear — 3 open, all parked/in-progress
  SKIP: no open issues
  SKIP: 5 open but all in-progress (branches: 003-foo, 005-bar)
  PICK: #42 "Fix the thing" (explicit)
  SKIP: #42 parked:autopilot:claimed
  SKIP: #42 in-progress:082-fix-thing
  SKIP: #42 not open or not found
"""
import json
import subprocess
import sys

BLOCK = {
    "blocked", "wontfix", "duplicate",
    "needs-discussion", "needs discussion",
    "on-hold", "on hold", "question", "epic",
    "autopilot:claimed",
}

# Liveness windows for deciding whether an existing branch/worktree for an
# issue is a live sibling run or a dead leftover safe to skip past. Either
# way the caller must SKIP, never auto-resume — these windows only decide
# how the skip reason reads, not whether resuming is ever attempted.
RECENT_COMMENT_WINDOW_SECS = 300    # a "picked this up" comment newer than this = live
RECENT_ACTIVITY_WINDOW_SECS = 1800  # a commit on the branch newer than this = live


def sh(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


def now():
    ts = sh("date", "+%s")
    return int(ts) if ts.isdigit() else 0


def has_open_pr(n):
    out = sh("gh", "pr", "list", "--state", "open",
             "--search", f"{n} in:title,body",
             "--json", "number,headRefName")
    try:
        return bool(json.loads(out)) if out else False
    except Exception:
        return False


def has_recent_pickup_comment(n):
    """A "picked this up" comment newer than RECENT_COMMENT_WINDOW_SECS means a
    sibling run just started on this issue — the exact race from issue #19
    (empty worktree, zero commits, started ~10s earlier)."""
    out = sh("gh", "issue", "view", str(n), "--json", "comments",
             "--jq", '.comments[] | select(.body | test("picked this up"; "i")) | .createdAt')
    if not out:
        return False
    latest = 0
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        ts = sh("date", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", line, "+%s")  # BSD/macOS date
        if not ts.isdigit():
            ts = sh("date", "-d", line, "+%s")  # GNU date fallback
        if ts.isdigit():
            latest = max(latest, int(ts))
    if latest == 0:
        return False
    return (now() - latest) < RECENT_COMMENT_WINDOW_SECS


def has_recent_branch_activity(branch):
    """A commit on the branch newer than RECENT_ACTIVITY_WINDOW_SECS means work
    is actively landing. A branch with zero commits past its fork point looks
    identical to a dead one here — that's why this check alone can't prove
    liveness; it's combined with the comment and PR checks."""
    ts = sh("git", "log", "-1", "--format=%ct", branch)
    if not ts.isdigit():
        return False
    return (now() - int(ts)) < RECENT_ACTIVITY_WINDOW_SECS


def has_live_claude_process():
    """Best-effort, system-wide — not scoped to this issue. A live `claude`
    process alongside a fresh worktree/branch is ambiguous, and per the
    project's "when in doubt, skip" rule that ambiguity should block a resume,
    not permit one."""
    out = sh("bash", "-c", "ps aux | grep -i '[c]laude'")
    return bool(out.strip())


def find_worktree_or_branch(n):
    num = str(n)
    branches = sh("git", "branch", "-a", "--list", f"*{num}-*")
    if branches:
        name = branches.splitlines()[0].strip().lstrip("* ").split("/")[-1]
        return name
    worktrees = sh("git", "worktree", "list")
    for line in worktrees.splitlines():
        if f"/{num}-" in line or f"/{num.zfill(3)}-" in line:
            return line.split()[0].split("/")[-1]
    return ""


def in_progress(n):
    """Return a branch/worktree name if issue #N is LIVE — proven, not assumed.

    "Dead" requires proving all liveness signals absent (issue #19 fix #3): no
    open PR, no seconds-old pickup comment, no recent branch activity, no live
    claude process. When any signal is present, treat as live. When all are
    absent, this is a dead leftover — don't report it as in-progress so the
    backlog doesn't wedge forever, but the caller must still never silently
    resume the old branch/worktree; that's a separate, explicit decision
    outside this script's scope.
    """
    name = find_worktree_or_branch(n)
    if not name:
        return ""

    if has_open_pr(n):
        return name
    if has_recent_pickup_comment(n):
        return name
    if has_recent_branch_activity(name):
        return name
    if has_live_claude_process():
        return name

    return ""


def eligibility_reason(i):
    """Return "" if eligible, else a SKIP reason string."""
    n = i["number"]
    labels = {l["name"].lower() for l in i.get("labels", [])}
    blocking = labels & BLOCK
    if blocking:
        return "parked:" + ",".join(sorted(blocking))
    if not (i.get("body") or "").strip():
        return "empty-body"
    wip = in_progress(n)
    if wip:
        return f"in-progress:{wip}"
    return ""


def validate_one(issues, target):
    match = next((i for i in issues if i.get("number") == target), None)
    if match is None:
        print(f"SKIP: #{target} not open or not found")
        return
    reason = eligibility_reason(match)
    if reason:
        print(f"SKIP: #{target} {reason}")
        return
    title = match.get("title", "").strip()[:70]
    print(f'PICK: #{target} "{title}" (explicit)')


def auto_pick(issues):
    total = len(issues)
    if total == 0:
        print("SKIP: no open issues")
        return

    parked = []
    in_prog = []
    empty_body = []
    pick = None

    for i in issues:
        n = i["number"]
        title = i.get("title", "").strip()[:70]
        labels = {l["name"].lower() for l in i.get("labels", [])}

        blocking = labels & BLOCK
        if blocking:
            parked.append(f"#{n}")
            continue

        if not (i.get("body") or "").strip():
            empty_body.append(f"#{n}")
            continue

        wip = in_progress(n)
        if wip:
            in_prog.append(f"#{n}({wip})")
            continue

        if pick is None:
            pick = (n, title)
            # keep scanning to count the rest accurately
            continue

    parts = []
    if parked:
        parts.append(f"{len(parked)} parked")
    if empty_body:
        parts.append(f"{len(empty_body)} empty-body")
    if in_prog:
        parts.append(f"{len(in_prog)} in-progress ({', '.join(in_prog[:3])}{'…' if len(in_prog) > 3 else ''})")
    ctx = f"{total} open" + (f" — {', '.join(parts)}" if parts else "")

    if pick:
        n, title = pick
        print(f'PICK: #{n} "{title}" ({ctx})')
    else:
        print(f"SKIP: nothing eligible — {ctx}")


def main():
    if len(sys.argv) < 2:
        print("SKIP: no issues file given")
        return

    try:
        issues = json.load(open(sys.argv[1]))
    except Exception as e:
        print(f"SKIP: could not parse issues ({e})")
        return

    if len(sys.argv) >= 3 and sys.argv[2].strip():
        try:
            target = int(sys.argv[2].lstrip("#"))
        except ValueError:
            print(f"SKIP: bad issue number {sys.argv[2]!r}")
            return
        validate_one(issues, target)
        return

    auto_pick(issues)


if __name__ == "__main__":
    main()
