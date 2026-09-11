#!/usr/bin/env python3
"""Evaluate the open-issue backlog and emit a single descriptive log line.

Three modes, selected by argv:
  preflight-issues.py <issues.json>              — auto-pick the highest-ranked eligible issue
  preflight-issues.py <issues.json> <N>          — validate ONE specific issue number
  preflight-issues.py --worktree-check <N>       — branch/worktree/PR existence + liveness

`--cross-repo` may be added to either of the first two modes; `--unattended` /
`--attended` override the `SPECKIT_AUTOPILOT_UNATTENDED` environment variable
that decides whether a STALE worktree is offered back or refused.

The first two modes share the same eligibility rules (block labels, empty
body, in-progress) so the auto-pick path and the explicit-issue path can
never drift apart — that drift (the explicit path skipping the
`autopilot:claimed` check) was one of the root causes of two autopilot runs
colliding on the same issue (repo issue #19).

`--worktree-check` is deliberately narrower: it skips the label/body checks
entirely and only asks "does a branch, worktree, or PR already exist for
#N?" It exists for the skill's post-claim re-check (Step 2) — by that point
the run has already added `autopilot:claimed` to its OWN issue, so re-running
the full label-aware check would see that self-applied label and immediately
(and incorrectly) treat every run as colliding with itself.

`autopilot:blocked` is the *durable* counterpart to the transient
`autopilot:claimed` lock. A run that hits a hard, non-recoverable blocker
removes its claim (transient) and adds `autopilot:blocked` (durable), so the
issue leaves the eligible pool for good instead of being re-picked on the very
next tick. Without it the cleanup path wrote no durable state at all and one
issue was re-picked in 10 consecutive sessions (repo issue #32). The reason
travels in an issue comment tagged with BLOCK_SENTINEL, which
`blocked_reason()` reads back so an explicit re-run is *told why* rather than
silently skipped.

`--cross-repo` closes the blind spot that `in_progress()` cannot see: a PR that
delivered the issue **in a different repository**. `has_open_pr()` searches only
the current repo, so when the fix for an issue ships elsewhere — a skills repo, a
sibling service — nothing here notices. On 2026-08-20 that cost three full
autopilot sessions on one issue: run 1 shipped the work as a PR in another repo,
and runs 2, 3 and 4 each got `PICK: ... (explicit)`, claimed the issue, and only
then discovered by hand that it was already done (repo issue #34). One of them
started 35 seconds after the delivering run finished.

The scan reads the issue's own thread — body plus comments, the same fetch
`blocked_reason()` already pays for — pulls every `github.com/<owner>/<repo>/pull/<n>`
URL out of it, and resolves each with `gh pr view --repo`. A **merged** PR wins over
a merely open one; a **closed, unmerged** PR is ignored, since abandoned work must
not park an issue forever. Draft status is reported but does not change the verdict:
an open draft still means someone is on it, matching the "existence alone means skip"
rule below.

It is opt-in because it costs one `gh issue view` plus one `gh pr view` per linked
PR, and on the auto-pick path it runs **only against the issue about to be picked**
— the one place the answer changes the outcome — never against every candidate.

This script only ever *reads*. A confirmed cross-repo delivery still needs the
durable `autopilot:blocked` park, and that write belongs to the caller — via the
shared `park-issue.sh`, the single writer of the label and sentinel.

To make that possible for *every* caller, a cross-repo finding is also emitted as
machine-readable `DELIVERED: <n> <url> (<state>)` lines after the verdict line.
Two callers need them and neither can recover the finding from the verdict prose:

  * `autopilot-run.sh` exits on `SKIP:` **before** launching the skill, so when a
    delivered issue leaves nothing else eligible the skill — the only component
    that used to park — never runs at all. The finding would be rediscovered, with
    the same GitHub lookups, on every scheduled tick forever.
  * A delivered issue does not stop the scan (see `auto_pick`), so a run can report
    `PICK:` for a *later* issue while still having found a delivered earlier one.
    That one needs parking too, on the success path.

The verdict is always the FIRST line, so the existing "read the first word to
decide" contract is unchanged; callers that do not care about parking can keep
reading `head -1` and ignore the rest.

Existence of a branch/worktree/PR still stops every unattended path — nothing
is ever auto-resumed (issue #19 fix #3). What changed with issue #60 is that the
stop now carries **evidence** instead of a bare verdict. "A live sibling run and
an abandoned worktree look identical from the outside" was true of the output,
not of the worktree: `liveness()` reads the tip commit's age, whether the tree is
dirty, how far `tasks.md` got, and whether a PR is open, and `classify()` turns
those into LIVE or STALE. An operator who pasted an issue URL and got
`SKIP: #237 in-progress:237-…` had nothing to act on and had to judge staleness
by hand — in seven sessions over fifty days.

The classification is deliberately asymmetric: **ambiguity resolves to LIVE.** A
tree whose state could not be read, a tip with no readable date, a checkout with
no readable creation stamp, and a `gh pr list` that errored all count as live.
Reaping a running sibling's worktree is unrecoverable; refusing a dead one costs
a human one command, which the STALE output now prints for them.

**Age is the age of the work, not of the commit it started from.** A worktree
created seconds ago off a base commit from months back inherits that old date,
is clean, and has no PR yet — three quarters of a STALE verdict for a checkout
a sibling is still setting up (PR #98 review). `worktree_touched()` supplies the
missing signal from the checkout's own git dir mtime and the branch ref's newest
reflog entry, and `classify()` takes the **most recent** of the two ages, so only
a worktree that is both old and untouched is ever called stale.

STALE downgrades the verdict on exactly one path: an **attended** explicit-issue
run, where a human typed the number and is owed resume-or-clean rather than a
refusal. The unattended paths — auto-pick, and the explicit path under
`SPECKIT_AUTOPILOT_UNATTENDED=1` (exported by `autopilot-run.sh`) — keep the hard
SKIP, because there guessing is genuinely unsafe and nobody is reading the
evidence anyway.

Auto-pick orders the eligible pool by (priority, bug-before-feature, age) — see
the "ordering" block below — instead of taking the oldest. The chosen issue's
rank is echoed in the PICK line so a scheduled log says *why* it won.

Output format (callers read the first word to decide):
  PICK: #42 "Fix the thing" [p0, bug] — 7 open (2 parked, 1 in-progress)
  SKIP: backlog clear — 3 open, all parked/in-progress
  SKIP: no open issues
  SKIP: 5 open but all in-progress (branches: 003-foo, 005-bar)
  PICK: #42 "Fix the thing" (explicit)
  SKIP: #42 parked:autopilot:claimed
  SKIP: #42 blocked — fix target is outside any git repo
  SKIP: #42 in-progress:082-fix-thing (live — uncommitted changes, …)
  SKIP: #42 blocked-by:#40,#41
  SKIP: #42 delivered — https://github.com/o/r/pull/3 (merged)
  SKIP: #42 not open or not found
  STALE: #42 082-fix-thing — commit abc1234, clean, last commit 3d ago, no open PR

Plus, after the verdict line, zero or more machine-readable follow-ups:
  DELIVERED: 42 https://github.com/o/r/pull/3 (merged)
  RESUME: 42 082-fix-thing /path/to/worktree
  CLEAN: 42 git worktree remove /path/to/worktree && git branch -D 082-fix-thing

`--worktree-check` prints one of:
  CLEAR
  LIVE: 082-fix-thing — uncommitted changes, last commit 4m ago, no open PR
  LIVE: 082-fix-thing — commit abc1234, clean, last commit 40d ago, worktree
        touched just now, no open PR
  STALE: 082-fix-thing — commit abc1234, clean, last commit 3d ago, no open PR
"""
import glob
import io
import json
import os
import re
import subprocess
import sys
import time

BLOCK = {
    "blocked", "wontfix", "duplicate",
    "needs-discussion", "needs discussion",
    "on-hold", "on hold", "question", "epic",
    "autopilot:claimed",
    "autopilot:blocked",
}

# Durable "do not retry" label, and the marker autopilot writes into the issue
# comment that explains why. Kept here so the writer (the skill) and the reader
# (this script) can never disagree about the string.
BLOCKED_LABEL = "autopilot:blocked"
BLOCK_SENTINEL = "AUTOPILOT-BLOCKED:"

# Cross-repo delivery detection. Only fully-qualified PR URLs count: the
# `owner/repo#N` shorthand is ambiguous (it renders identically for issues) and
# resolving it would spend a `gh` call per false positive.
PR_URL_RE = re.compile(
    r"https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/(\d+)")

# ------------------------------------------------------------ dependencies ---
# `/speckit-git-issue` splits a full-stack feature into frontend(mock), backend,
# and wire-up children (`split-issue.sh`). The wire-up child cannot be started
# until both siblings land, and says so in its own body:
#
#     Blocked by: #43, #44
#
# Without this check autopilot would rank that child level with its siblings and
# could pick it first, "integrating" a frontend and a backend that do not exist
# yet. The dependency is resolved against the open-issue list this run already
# fetched — a dependency that is not in it is closed (or not in this repo) and
# therefore satisfied — so the test costs no `gh` calls at all.
#
# The parent of a split needs no rule here: `split-issue.sh` labels it `epic`,
# which is already in BLOCK.
BLOCKED_BY_RE = re.compile(r"^[ \t>*-]*blocked[ _-]?by\s*:?\s*(.*)$", re.I)
ISSUE_REF_RE = re.compile(r"#(\d+)")

# A wrapped dependency line is one line. Bodies are prose and every editor wraps
# prose, so `Blocked by: #43,\n#44` used to yield [43] and the wire-up child read
# as unblocked the moment #43 closed (issue #76) — the same defect class as #68,
# whose fix lives in the diff-minimal preset's own script tree and so cannot be
# imported here. A continuation is any non-blank line that does not itself open
# something; a blank line ends the marker. Folding one line too many can only
# over-block, which is the safe direction.
_CONTINUATION_STOP_RE = re.compile(
    r"^\s*(?:#{1,6}\s|[-*+]\s|\d+[.)]\s|>|\||```|~~~"
    r"|\*{2}[^*]+\*{2}\s*:|[A-Za-z][\w \t-]{0,40}:(?:\s|$))")

# A PR in these states means someone already delivered the issue. CLOSED is
# absent on purpose — a closed, unmerged PR is abandoned work, and treating it
# as delivery would park the issue permanently on a dead end.
DELIVERED_STATES = ("MERGED", "OPEN")

# Bound on how many linked PRs one issue thread is worth resolving. A chatty
# thread can accumulate many links; the delivering PR is effectively never the
# 11th one mentioned.
MAX_PR_LOOKUPS = 10

# ---------------------------------------------------------------- ordering ---
# The backlog arrives oldest-first (`fetch-open-issues.sh` sorts by createdAt),
# but "oldest" is not the same as "most important": a P0 outage filed this
# morning sat behind a year-old chore, every tick, until a human intervened.
# Eligible candidates are therefore ordered by (priority, kind, layer, age)
# instead of age alone. Age remains the final tiebreak, so the previous behaviour is what
# you get on a backlog with no priority or type labels at all.
#
# Priority is read from labels in any of the common spellings — `p0`, `P1`,
# `priority: p2`, `priority/p3`, `priority-p1` — plus the severity words teams
# use instead (`critical` → p0, `high` → p1, `medium` → p2, `low` → p3). The
# LOWEST rank found on an issue wins, so a mislabelled `p2, critical` pair is
# treated as p0 rather than silently averaged.
PRIORITY_WORDS = {"critical": 0, "urgent": 0, "high": 1, "medium": 2, "normal": 2, "low": 3}
PRIORITY_RE = re.compile(r"^(?:priority[:/ -]*)?p(\d)$")

# An issue with NO priority label sorts in the middle, level with p2 — not last.
# Ranking it last would let an explicitly deprioritized `p3` chore outrank every
# untriaged bug in the backlog, which inverts the point of the label.
DEFAULT_PRIORITY = 2

# Within one priority tier, defects come before new work: a broken system is
# worth more than an addition to it. Across tiers priority still wins, so an
# explicit p0 feature outranks a p2 bug — the labels a human set are the
# strongest signal available.
BUG_LABELS = {"bug", "defect", "regression", "fix", "broken", "incident", "outage"}
BUG_TITLE_RE = re.compile(r"^\s*(?:\[[^\]]*\]\s*)?(?:bug|fix|hotfix)\b[:( ]", re.I)

# Within one priority tier and one kind, the mock-first split's frontend child
# comes before its backend sibling: the mock freezes the data shape the backend
# then implements, so building the backend first hands the UI a contract it did
# not get to choose. This used to fall out of `split-issue.sh`'s creation order
# via the age tiebreak, which held only while both children kept equal priority,
# equal kind, and their original relative age — none of which is enforced
# (issue #56). The labels are the ones `label-issue.sh` writes (`LAYERS`).
# An issue with no layer label ranks in the middle, level with `backend`, so an
# unlabelled backlog sorts exactly as it did before.
LAYER_RANKS = {"frontend": 0, "backend": 1, "integration": 2}
DEFAULT_LAYER = 1


def _blocked_by_lines(body):
    """Every `Blocked by:` tail in `body`, with wrapped continuations folded in."""
    lines = body.splitlines()
    for i, line in enumerate(lines):
        m = BLOCKED_BY_RE.match(line)
        if not m:
            continue
        tail = [m.group(1)]
        for nxt in lines[i + 1:]:
            if not nxt.strip() or _CONTINUATION_STOP_RE.match(nxt):
                break
            tail.append(nxt.strip())
        yield " ".join(tail)


def blocked_by(issue, open_numbers):
    """Open issues #N must close before this one starts; [] when unblocked."""
    body = issue.get("body") or ""
    deps = []
    for line in _blocked_by_lines(body):
        for ref in ISSUE_REF_RE.findall(line):
            n = int(ref)
            if n != issue.get("number") and n in open_numbers and n not in deps:
                deps.append(n)
    return deps


def priority_ranks(labels):
    """Every priority rank an issue's labels spell out, in no order."""
    ranks = []
    for name in labels:
        m = PRIORITY_RE.match(name.strip())
        if m:
            ranks.append(int(m.group(1)))
        elif name in PRIORITY_WORDS:
            ranks.append(PRIORITY_WORDS[name])
    return ranks


def priority_rank(labels):
    """Lowest priority rank among an issue's labels; DEFAULT_PRIORITY if none."""
    ranks = priority_ranks(labels)
    return min(ranks) if ranks else DEFAULT_PRIORITY


def labelled_priority(labels):
    """True when a human actually set a priority, vs DEFAULT_PRIORITY standing in."""
    return bool(priority_ranks(labels))


def is_bug(issue, labels):
    """True when the issue is a defect rather than new work.

    Labels are authoritative; the title prefix (`fix: …`, `bug(x): …`) is a
    fallback for repos that file bugs without ever applying a label — this one
    included, where conventional-commit-style titles carry the type.
    """
    if labels & BUG_LABELS or any("bug" in l for l in labels):
        return True
    return bool(BUG_TITLE_RE.match(issue.get("title") or ""))


def layer_ranks(labels):
    """Every layer rank an issue's labels spell out, in no order."""
    return [LAYER_RANKS[l] for l in labels if l in LAYER_RANKS]


def layer_rank(labels):
    """Lowest layer rank among an issue's labels; DEFAULT_LAYER if none."""
    ranks = layer_ranks(labels)
    return min(ranks) if ranks else DEFAULT_LAYER


def rank_key(issue, seq):
    """Sort key for candidates: priority, then bugs, then layer, then oldest.

    `seq` is the issue's index in the (oldest-first) fetch, which keeps the
    sort stable and makes age the final tiebreak without re-parsing dates.
    """
    labels = {l["name"].lower() for l in issue.get("labels", [])}
    return (
        priority_rank(labels),
        0 if is_bug(issue, labels) else 1,
        layer_rank(labels),
        seq,
    )


def rank_reason(issue):
    """Short why-this-one tag for the PICK line: `p0, bug, frontend`, `p2 default`.

    Says explicitly when the priority was assumed rather than labelled, so a log
    line never implies a triage decision nobody made.
    """
    labels = {l["name"].lower() for l in issue.get("labels", [])}
    p = priority_rank(labels)
    bits = [f"p{p}" if labelled_priority(labels) else f"p{p} default"]
    if is_bug(issue, labels):
        bits.append("bug")
    layers = sorted(labels & set(LAYER_RANKS), key=LAYER_RANKS.get)
    if layers:
        bits.append(layers[0])
    return ", ".join(bits)


def sh(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True).stdout.strip()
    except Exception:
        return ""


def sh_rc(*args):
    """(returncode, stdout) — for the calls where "failed" and "empty" differ.

    `sh()` collapses the two, which is fine for "did this print a branch name"
    but not for "is this tree dirty": an empty answer from a git that errored
    would read as `clean`, and clean is half of the STALE verdict.
    """
    try:
        p = subprocess.run(args, capture_output=True, text=True)
        return p.returncode, p.stdout.strip()
    except Exception:
        return 1, ""


# ---------------------------------------------------------------- liveness ---
# How recent a commit still counts as a live run. Two hours is generous on
# purpose: an autopilot pass that is deep in `/speckit-implement` can go a long
# while between commits, and the cost of calling a live run stale is a reaped
# worktree, while the cost of calling a stale one live is one manual cleanup.
LIVE_WINDOW_MIN = int((os.environ.get("SPECKIT_AUTOPILOT_LIVE_WINDOW_MIN") or "120").strip() or 120)
LIVE_WINDOW_SEC = LIVE_WINDOW_MIN * 60


def unattended():
    """True when nobody is reading the output.

    `autopilot-run.sh` exports `SPECKIT_AUTOPILOT_UNATTENDED=1` before launching
    the session, so the skill's explicit-issue preflight can tell a scheduled
    tick apart from a human who typed the issue number. There is no other seam:
    both paths arrive as the same `preflight-issues.py <file> <N>` call.
    """
    v = (os.environ.get("SPECKIT_AUTOPILOT_UNATTENDED") or "").strip().lower()
    return v not in ("", "0", "false", "no", "off")


# How many open PRs one `has_open_pr` search may return before a miss stops
# meaning anything. `gh pr list --limit` caps exactly, so a page that comes back
# full may have left the matching PR off the end.
PR_SEARCH_CAP = 100

# `has_open_pr`'s fourth answer: the search answered but came back full, so its
# "not found" proves nothing. It votes LIVE exactly as `None` does, because it
# is an unknown, but it is not a failed lookup, and reporting it as one sent the
# operator to debug `gh` auth when the cause was a hundred PRs sharing a token
# (#104). A string, so it is readable wherever it surfaces, and truthy, so every
# reader has to test for it before testing `open_pr` for truth.
TRUNCATED = "truncated"


def has_open_pr(n):
    r"""True / False / None / TRUNCATED — None when the lookup could not answer.

    Mirrors `is_dirty`: `gh` failing on auth, network, or an API error is not
    evidence that no PR exists, and handing that `False` to `classify()` as if
    it were would let a worktree with an open PR be reported STALE and offered
    for deletion — the one direction that is unrecoverable. Ambiguity votes LIVE
    (PR #98 review), so the failure has to survive as its own state.

    GitHub's full-text search tokenizes a bare number, so searching `401` matched
    every open PR whose prose mentions an HTTP **401** — unrelated PRs, none of
    them referencing the issue — and issue 401 was refused forever with no tree
    state a human could clean up (#102). HTTP statuses, ports, and years
    all collide this way.

    The local `#N\b` regex is what decides. The `#` in the query buys nothing —
    GitHub strips it during tokenization, so `#401` and `401` return the same
    candidates — it is there to say what is being looked for, and the regex is
    the whole of the fix. `\b` keeps `#401` off `#4010`.

    That removes false *positives*. Recall still rests entirely on the search:
    a PR the search does not return is one the regex never sees, and the answer
    would be `False` — the unrecoverable direction. So a result set that came
    back at the `--limit` is reported as `TRUNCATED`, because a truncated page and
    an empty one are indistinguishable from here. It votes LIVE like `None`; only
    the words it produces differ.
    """
    rc, out = sh_rc("gh", "pr", "list", "--state", "open",
                    "--search", f"#{n} in:title,body", "--limit", str(PR_SEARCH_CAP),
                    "--json", "title,body")
    if rc != 0:
        return None
    try:
        prs = json.loads(out) if out else []
        ref = re.compile(rf"#{n}\b")
        hit = any(ref.search(f"{p.get('title') or ''}\n{p.get('body') or ''}")
                  for p in prs)
    except Exception:
        # Not just a parse error: a payload that is valid JSON but not a list of
        # objects (`{"message": "rate limited"}`, `null`, `[1]`) walks straight
        # into `p.get` and raises. `main()` has no top-level handler and
        # `autopilot-run.sh` discards stderr, so an escape here does not answer
        # one issue wrong — it collapses the whole preflight to empty output.
        return None
    return hit or (TRUNCATED if len(prs) >= PR_SEARCH_CAP else False)


def worktrees():
    """[(path, branch)] from `git worktree list --porcelain`."""
    out = sh("git", "worktree", "list", "--porcelain")
    res, path, branch = [], "", ""
    for line in out.splitlines() + [""]:
        if line.startswith("worktree "):
            path, branch = line[len("worktree "):].strip(), ""
        elif line.startswith("branch "):
            branch = line[len("branch "):].strip().split("/")[-1]
        elif not line.strip():
            if path:
                res.append((path, branch))
            path, branch = "", ""
    return res


def locate(n):
    """(name, worktree path, git ref) for issue #N's work; ("","","") if none.

    The branch scan stays authoritative for the NAME — it also sees a branch
    that has no worktree at all — and the worktree list only supplies the PATH
    the dirty-tree and tasks.md evidence is read from.

    `name` is the display form with any prefix stripped (`fix/60-x` → `60-x`),
    which is what every existing caller prints. `ref` is the full branch as git
    knows it, because `git log <name>` on a stripped name resolves nothing and a
    missing commit date reads as ambiguity — which votes LIVE, so a stale
    `feat/`-prefixed branch would never be reportable as stale.

    Names come from `--format=%(refname:short)`, never from the default output,
    which is written for people and broke the parse three ways. It prefixes a
    marker: `* ` here, and since git 2.23 `+ ` for a branch checked out in
    **another worktree**, which is every feature branch when preflight runs from
    the main checkout. Stripping only `* ` left `ref` as `+ 368-slug`, which
    `git log` cannot resolve, so the age read as unknown and no worktree-backed
    branch could ever be reported STALE (#102). `color.ui=always` wraps names in
    escape codes. And `column.ui=always` packs several branches onto one line, so
    the "first line" held two names and the parse could hand back another
    issue's branch (#104). The format atom prints the bare short refname and
    nothing else. `--no-column` is load-bearing rather than tidy: a column
    setting still packs `--format` output. Nothing is stripped, so nothing can be
    stripped wrong.

    The globs anchor the number to the start of the branch name, or of any
    `/`-delimited segment of it. git matches `*` across `/`, so `*/416-*`
    reaches `origin/416-slug` and `origin/feature/fix/416-deep` alike. Matching
    is against the *shortened* refname, which is what `%(refname:short)` prints
    too: `origin/416-slug` rather than `remotes/origin/416-slug`, unless another
    ref shares the name, when git qualifies it (`heads/416-slug`,
    `remotes/origin/416-slug`). The globs still match a qualified name, and
    `git log` resolves it to the branch rather than to a tag of the same name,
    which the old bare parse did not. `--sort=refname` keeps local branches ahead
    of remotes: without it a `branch.sort` setting such as `-committerdate` put
    `origin/416-slug` first and had its tip read in place of the local branch's.
    A bare `*416-*` also matched
    `v2.416-x` and `foo-416-bar` — the same tokenizer-class bug `has_open_pr`
    carried, and the other half of #102. The zero-padded glob is added back
    because a branch for issue 82 is named `082-slug`, coverage the old leading
    `*` gave away for free.
    """
    num, pad = str(n), str(n).zfill(3)
    name = ref = ""
    branches = sh("git", "branch", "-a", "--list", "--no-column",
                  "--sort=refname", "--format=%(refname:short)",
                  f"{num}-*", f"*/{num}-*", f"{pad}-*", f"*/{pad}-*")
    if branches:
        ref = branches.splitlines()[0].strip()
        name = ref.split("/")[-1]
    wts = worktrees()
    if name:
        for path, branch in wts:
            if branch == name:
                return name, path, ref
    for path, branch in wts:
        if f"/{num}-" in path or f"/{num.zfill(3)}-" in path:
            base = name or path.rstrip("/").split("/")[-1]
            return base, path, ref or base
    return name, "", ref


def find_worktree_or_branch(n):
    return locate(n)[0]


def tip_commit(ref):
    """(short sha, unix timestamp) of `ref`'s tip; ("", 0) when unreadable."""
    parts = sh("git", "log", "-1", "--format=%h %ct", ref, "--").split()
    if len(parts) == 2 and parts[1].isdigit():
        return parts[0], int(parts[1])
    return "", 0


def is_dirty(path):
    """True / False / None — None when the answer could not be obtained.

    None is not False: an unreadable tree is ambiguous, and ambiguity is LIVE.
    """
    if not path or not os.path.isdir(path):
        return None
    rc, out = sh_rc("git", "-C", path, "status", "--porcelain")
    return None if rc != 0 else bool(out)


def task_progress(name, path):
    """"4/12" from the feature's `tasks.md`, or "" when there is none."""
    root = path or "."
    for cand in sorted(glob.glob(os.path.join(root, "specs", f"{name}*", "tasks.md"))):
        try:
            with open(cand, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        done = len(re.findall(r"^\s*[-*]\s*\[[xX]\]", text, re.M))
        total = done + len(re.findall(r"^\s*[-*]\s*\[ \]", text, re.M))
        if total:
            return f"{done}/{total}"
    return ""


def worktree_touched(path, ref):
    """Unix ts of the newest signal that the *work* — not its base commit — moved.

    A worktree created seconds ago from a base commit that is months old
    inherits that old commit date. With a clean tree and no PR yet, tip-commit
    age alone therefore classifies a sibling's brand-new checkout as STALE and
    the attended path offers it for deletion before the sibling makes its first
    edit (PR #98 review). Two signals date the checkout itself:

      * the worktree's own git dir — written at creation (`HEAD`, `index`,
        `logs/HEAD`) and rewritten by every checkout, commit, and index update;
      * the branch ref's reflog, whose newest entry is the branch's own
        creation when nothing has happened since.

    Returns 0 when neither can be read, which the caller turns into "unknown" —
    and unknown votes LIVE, exactly as everything else ambiguous here does.
    """
    stamps = []
    if path and os.path.isdir(path):
        rc, gitdir = sh_rc("git", "-C", path, "rev-parse", "--absolute-git-dir")
        if rc == 0 and gitdir and os.path.isdir(gitdir):
            for cand in (gitdir, *(os.path.join(gitdir, f)
                                   for f in ("HEAD", "index", "logs/HEAD"))):
                try:
                    stamps.append(int(os.stat(cand).st_mtime))
                except OSError:
                    pass
    if ref:
        out = sh("git", "log", "-g", "-1", "--format=%ct", ref)
        if out.isdigit():
            stamps.append(int(out))
    return max(stamps) if stamps else 0


def age_words(age_sec):
    if age_sec is None:
        return "commit date unknown"
    if age_sec < 90 * 60:
        return f"last commit {age_sec // 60}m ago"
    if age_sec < 36 * 3600:
        return f"last commit {age_sec // 3600}h ago"
    return f"last commit {age_sec // 86400}d ago"


def touch_words(sec):
    if sec is None:
        return "worktree age unknown"
    if sec < 120:
        return "worktree touched just now"
    if sec < 90 * 60:
        return f"worktree touched {sec // 60}m ago"
    if sec < 36 * 3600:
        return f"worktree touched {sec // 3600}h ago"
    return f"worktree touched {sec // 86400}d ago"


def classify(dirty, age_sec, open_pr, tasks="", window_sec=None, touched_sec=None):
    """(state, evidence) for work that exists — "LIVE" or "STALE".

    Pure by construction so the rule is testable without a repo, and so the
    evidence string and the verdict are built from the same inputs and can
    never disagree. Every unknown votes LIVE (see the module docstring), and
    that now includes both of the signals a caller may fail to obtain:
    `open_pr=None` (the `gh` lookup failed) and `touched_sec=None` (no
    creation/heartbeat stamp for the checkout). `touched_sec` defaults to None
    on purpose: a caller that does not measure it gets LIVE, never STALE.

    The two ages are read as "most recent evidence wins" — a months-old tip
    commit under a checkout created a minute ago is a run that has not committed
    yet, not an abandoned worktree.
    """
    window = LIVE_WINDOW_SEC if window_sec is None else window_sec
    live = False
    bits = []
    if dirty is None:
        bits.append("tree state unknown")
        live = True
    elif dirty:
        bits.append("uncommitted changes")
        live = True
    else:
        bits.append("clean")
    bits.append(age_words(age_sec))
    # The touch stamp is only worth printing when it says something the commit
    # age does not: a checkout younger than its own tip commit, or no stamp at
    # all. A worktree touched when it was last committed to adds no evidence.
    if touched_sec is None or age_sec is None or age_sec - touched_sec >= 60:
        bits.append(touch_words(touched_sec))
    if age_sec is None or touched_sec is None:
        live = True
    elif min(age_sec, touched_sec) < window:
        live = True
    if open_pr is None:
        bits.append("PR lookup failed")
        live = True
    elif open_pr is TRUNCATED:
        # Truthy, so it has to be caught here or `elif open_pr` calls it a PR.
        bits.append(f"PR search truncated at {PR_SEARCH_CAP} results")
        live = True
    elif open_pr:
        bits.append("open PR")
        live = True
    else:
        bits.append("no open PR")
    if tasks:
        bits.append(f"{tasks} tasks done")
    return ("LIVE" if live else "STALE"), ", ".join(bits)


_LIVE_CACHE = {}


def liveness(n):
    """(state, name, evidence) for issue #N; ("", "", "") when nothing exists.

    Cached: `eligibility_reason()` and the explicit-issue verdict both need it
    for the same issue in one run, and it costs several git calls plus a `gh`.
    """
    if n in _LIVE_CACHE:
        return _LIVE_CACHE[n]
    name, path, ref = locate(n)
    now = int(time.time())
    if not name:
        # A failed lookup (None) is not "no PR": with nothing else to go on it
        # is the only signal there is, so it counts as work-in-flight rather
        # than as a clear field.
        pr = has_open_pr(n)
        if pr is None:
            result = ("LIVE", f"#{n}", "PR lookup failed, no branch or worktree")
        elif pr is TRUNCATED:
            result = ("LIVE", f"#{n}", f"PR search truncated at {PR_SEARCH_CAP} "
                      "results, no branch or worktree")
        elif pr:
            result = ("LIVE", f"PR referencing #{n}", "open PR, no branch or worktree")
        else:
            result = ("", "", "")
    else:
        sha, ts = tip_commit(ref or name)
        age = max(0, now - ts) if ts else None
        touched_ts = worktree_touched(path, ref or name)
        touched = max(0, now - touched_ts) if touched_ts else None
        state, ev = classify(is_dirty(path), age, has_open_pr(n),
                             task_progress(name, path), touched_sec=touched)
        head = f"commit {sha}" if sha else "no commit"
        result = (state, name, f"{head}, {ev}")
    _LIVE_CACHE[n] = result
    return result


def in_progress(n):
    """Legacy shim: a description when #N has a branch, worktree, or open PR."""
    return liveness(n)[1]


_THREAD_CACHE = {}


def issue_thread(n):
    """Return (body, [comment bodies…]) for issue #N, fetched at most once.

    `blocked_reason()` and `delivered_by()` both need the same thread, and on
    the explicit-issue path both can run for one issue. Caching keeps that to a
    single `gh issue view` instead of two.
    """
    if n not in _THREAD_CACHE:
        out = sh("gh", "issue", "view", str(n), "--json", "body,comments")
        try:
            data = json.loads(out) if out else {}
        except Exception:
            data = {}
        body = data.get("body") or ""
        comments = [(c.get("body") or "") for c in (data.get("comments") or [])]
        _THREAD_CACHE[n] = (body, comments)
    return _THREAD_CACHE[n]


def blocked_reason(n):
    """Read back WHY autopilot durably blocked issue #N.

    The stopping run posts a comment containing a BLOCK_SENTINEL line; the
    newest such comment wins (a later run may have refined the diagnosis).
    Returns "" when no tagged comment exists — e.g. a human applied the label
    by hand — so callers must treat the reason as best-effort, never as proof
    the label is real. Only the explicit-issue path pays for this extra `gh`
    call; auto-pick just counts the issue as parked.
    """
    _, comments = issue_thread(n)
    for body in reversed(comments):
        for line in body.splitlines():
            if BLOCK_SENTINEL in line:
                return line.split(BLOCK_SENTINEL, 1)[1].strip().strip("*_` ")[:160]
    return ""


def linked_prs(n):
    """Every distinct PR URL mentioned in issue #N's body or comments.

    Order is preserved (body first, then comments oldest→newest) and duplicates
    are dropped, so a PR linked once by autopilot and again by a human costs one
    lookup, not two.
    """
    body, comments = issue_thread(n)
    seen = []
    for text in [body, *comments]:
        for owner, repo, num in PR_URL_RE.findall(text):
            key = (owner, repo, num)
            if key not in seen:
                seen.append(key)
    return seen[:MAX_PR_LOOKUPS]


def delivered_by(n):
    """Return "<url> (<state>)" if a PR in ANY repo already delivered issue #N.

    Resolves every linked PR and prefers a MERGED one over a merely OPEN one, so
    the message names the PR that actually shipped rather than whichever was
    mentioned first. Returns "" when nothing is linked, nothing resolves (a
    private repo the token cannot read, a deleted PR), or every linked PR is
    closed-unmerged — all of which mean "no evidence of delivery", never
    "definitely not delivered".
    """
    fallback = ""
    for owner, repo, num in linked_prs(n):
        out = sh("gh", "pr", "view", num, "--repo", f"{owner}/{repo}",
                 "--json", "state,isDraft,url")
        try:
            pr = json.loads(out) if out else {}
        except Exception:
            continue
        state = (pr.get("state") or "").upper()
        if state not in DELIVERED_STATES:
            continue
        url = pr.get("url") or f"https://github.com/{owner}/{repo}/pull/{num}"
        detail = state.lower()
        if pr.get("isDraft"):
            detail += ", draft"
        if state == "MERGED":
            return f"{url} ({detail})"
        fallback = fallback or f"{url} ({detail})"
    return fallback


def eligibility_reason(i, explain=False, cross_repo=False, open_numbers=frozenset()):
    """Return "" if eligible, else a SKIP reason string.

    `explain` costs one extra `gh` call and is only worth it on the
    explicit-issue path, where a human typed the number and deserves to be
    told why their re-run is refusing (repo issue #32).

    `cross_repo` is checked last because it is the most expensive test here —
    every cheaper local signal gets a chance to skip the issue first.
    """
    n = i["number"]
    labels = {l["name"].lower() for l in i.get("labels", [])}
    blocking = labels & BLOCK
    if blocking:
        if explain and BLOCKED_LABEL in blocking:
            why = blocked_reason(n)
            return f"blocked — {why}" if why else \
                f"blocked — {BLOCKED_LABEL} label set, no recorded reason"
        return "parked:" + ",".join(sorted(blocking))
    if not (i.get("body") or "").strip():
        return "empty-body"
    deps = blocked_by(i, open_numbers)
    if deps:
        return "blocked-by:" + ",".join(f"#{d}" for d in deps)
    state, name, ev = liveness(n)
    if state:
        return f"in-progress:{name} ({state.lower()} — {ev})"
    if cross_repo:
        pr = delivered_by(n)
        if pr:
            return f"delivered — {pr}"
    return ""


def validate_one(issues, target, cross_repo=False, headless=None):
    match = next((i for i in issues if i.get("number") == target), None)
    if match is None:
        print(f"SKIP: #{target} not open or not found")
        return
    headless = unattended() if headless is None else headless
    reason = eligibility_reason(match, explain=True, cross_repo=cross_repo,
                                open_numbers={i.get("number") for i in issues})
    if reason:
        # A human typed this number. If the only thing standing in the way is
        # work that the evidence says is dead, refusing with nothing to act on
        # is the dead end issue #60 reports — hand back the two commands that
        # resolve it instead. Unattended, the refusal stands: there is nobody
        # to choose, and reaping a sibling run's worktree is unrecoverable.
        state, name, ev = liveness(target)
        if state == "STALE" and not headless and reason.startswith("in-progress:"):
            path = locate(target)[1]
            print(f"STALE: #{target} {name} — {ev}")
            print(f"RESUME: {target} {name} {path or '-'}")
            clean = f"git branch -D {name}"
            if path:
                clean = f"git worktree remove {path} && {clean}"
            print(f"CLEAN: {target} {clean}")
            return
        print(f"SKIP: #{target} {reason}")
        if reason.startswith("delivered — "):
            print(f"DELIVERED: {target} {reason[len('delivered — '):]}")
        return
    title = match.get("title", "").strip()[:70]
    # No rank tag here: an explicitly requested issue is worked regardless of
    # where it would have sorted, and printing a rank would suggest otherwise.
    print(f'PICK: #{target} "{title}" (explicit)')


def auto_pick(issues, cross_repo=False):
    total = len(issues)
    if total == 0:
        print("SKIP: no open issues")
        return

    parked = []
    in_prog = []
    empty_body = []
    blocked_deps = []
    delivered = []
    candidates = []

    open_numbers = {i.get("number") for i in issues}

    for seq, i in enumerate(issues):
        n = i["number"]
        labels = {l["name"].lower() for l in i.get("labels", [])}

        blocking = labels & BLOCK
        if blocking:
            parked.append(f"#{n}")
            continue

        if not (i.get("body") or "").strip():
            empty_body.append(f"#{n}")
            continue

        deps = blocked_by(i, open_numbers)
        if deps:
            blocked_deps.append(f"#{n}(needs {', '.join(f'#{d}' for d in deps)})")
            continue

        # Auto-pick keeps the hard skip for LIVE *and* STALE: nobody is reading
        # this log at the moment it is written, so resume-or-clean has no one to
        # offer itself to. The state is recorded so a human reading the log
        # afterwards can see which leftovers are worth cleaning up.
        state, name, _ev = liveness(n)
        if state:
            in_prog.append(f"#{n}({name}: {state.lower()})")
            continue

        candidates.append((rank_key(i, seq), i))

    # Order the whole eligible pool before choosing, rather than taking the
    # first one the (oldest-first) scan happens to reach. This is the only
    # place the ordering policy is applied — the explicit-issue path never
    # ranks, because a human who typed a number has already chosen.
    candidates.sort(key=lambda c: c[0])

    pick = None
    for _, i in candidates:
        # Cross-repo delivery is tested only on the candidate about to be
        # picked, in rank order: it is the sole position where the answer
        # changes what this run does, and testing every candidate would spend
        # `gh` calls on issues we are not going to touch anyway. A delivered
        # one is recorded for parking and the next-ranked candidate is tried.
        if cross_repo:
            pr = delivered_by(i["number"])
            if pr:
                delivered.append((i["number"], pr))
                continue
        pick = i
        break

    parts = []
    if parked:
        parts.append(f"{len(parked)} parked")
    if empty_body:
        parts.append(f"{len(empty_body)} empty-body")
    if blocked_deps:
        parts.append(f"{len(blocked_deps)} blocked-by "
                     f"({', '.join(blocked_deps[:3])}{'…' if len(blocked_deps) > 3 else ''})")
    if in_prog:
        parts.append(f"{len(in_prog)} in-progress ({', '.join(in_prog[:3])}{'…' if len(in_prog) > 3 else ''})")
    if delivered:
        parts.append(f"{len(delivered)} delivered "
                     f"({', '.join(f'#{n} {pr}' for n, pr in delivered)})")
    ctx = f"{total} open" + (f" — {', '.join(parts)}" if parts else "")

    if pick:
        title = pick.get("title", "").strip()[:70]
        print(f'PICK: #{pick["number"]} "{title}" [{rank_reason(pick)}] ({ctx})')
    else:
        print(f"SKIP: nothing eligible — {ctx}")

    # After the verdict, never before it: the first line is the caller's contract.
    for n, pr in delivered:
        print(f"DELIVERED: {n} {pr}")


def main():
    # Pull flags out first so `--cross-repo` can sit in any position without
    # ever being mistaken for the issue-number positional.
    argv = sys.argv[1:]
    cross_repo = "--cross-repo" in argv
    # Explicit flags beat the environment in both directions, so a caller that
    # knows which it is never has to unset a variable it did not set.
    headless = True if "--unattended" in argv else (False if "--attended" in argv else None)
    argv = [a for a in argv
            if a not in ("--cross-repo", "--unattended", "--attended")]

    if not argv:
        print("SKIP: no issues file given")
        return

    if argv[0] == "--selftest":
        selftest()
        return

    if argv[0] == "--worktree-check":
        if len(argv) < 2:
            print("SKIP: --worktree-check requires an issue number")
            return
        try:
            n = int(argv[1].lstrip("#"))
        except ValueError:
            print(f"SKIP: bad issue number {argv[1]!r}")
            return
        state, name, ev = liveness(n)
        print(f"{state}: {name} — {ev}" if state else "CLEAR")
        return

    try:
        issues = json.load(open(argv[0]))
    except Exception as e:
        print(f"SKIP: could not parse issues ({e})")
        return

    if len(argv) >= 2 and argv[1].strip():
        try:
            target = int(argv[1].lstrip("#"))
        except ValueError:
            print(f"SKIP: bad issue number {argv[1]!r}")
            return
        validate_one(issues, target, cross_repo=cross_repo, headless=headless)
        return

    auto_pick(issues, cross_repo=cross_repo)


def _capture(fn, *a, **kw):
    """Run `fn` and return what it printed — the verdict lines ARE the contract."""
    buf, old = io.StringIO(), sys.stdout
    sys.stdout = buf
    try:
        fn(*a, **kw)
    finally:
        sys.stdout = old
    return buf.getvalue()


def selftest():
    """Dependency parsing, liveness, and ranking. `--selftest` runs it."""
    open_numbers = {43, 44, 99}

    def deps(body, number=50):
        return blocked_by({"number": number, "body": body}, open_numbers)

    assert deps("Blocked by: #43, #44") == [43, 44]
    # issue #76: the wrapped form used to lose every ref after the first.
    assert deps("Blocked by: #43,\n#44") == [43, 44]
    assert deps("Parent: #7\n\nBlocked by: #43,\n#44\n\nWire it up.") == [43, 44]
    # A blank line, a bullet, and a new `key:` each end the marker.
    assert deps("Blocked by: #43\n\n#44") == [43]
    assert deps("Blocked by: #43\n- see #44") == [43]
    assert deps("Blocked by: #43\nParent: #44") == [43]
    # Closed (absent from open_numbers) and self-references stay out.
    assert deps("Blocked by: #43, #77") == [43]
    assert deps("Blocked by: #43, #50") == [43]
    assert deps("nothing here") == []

    # issue #56: the layer term, between kind and age.
    def issue(number, *names, title="add saved searches"):
        return {"number": number, "title": title,
                "labels": [{"name": n} for n in names]}

    def order(*issues):
        ranked = sorted(enumerate(issues), key=lambda p: rank_key(p[1], p[0]))
        return [i["number"] for _, i in ranked]

    fe, be = issue(1, "frontend", "mock-first"), issue(2, "backend")
    # Frontend wins whatever the creation order was...
    assert order(be, fe) == [1, 2]
    # ...and however the age tiebreak would have fallen out.
    assert order(fe, be) == [1, 2]
    # But priority and kind still outrank it.
    assert order(fe, issue(2, "backend", "p1")) == [2, 1]
    assert order(fe, issue(2, "backend", "bug")) == [2, 1]
    # An unlabelled issue sits level with backend, so age decides as before.
    assert order(issue(1), issue(2, "backend")) == [1, 2]
    assert order(issue(1, "backend"), issue(2)) == [1, 2]
    assert order(issue(1, "integration"), issue(2)) == [2, 1]
    assert rank_reason(fe) == "p2 default, frontend"
    assert rank_reason(issue(3, "p0", "bug", "backend")) == "p0, bug, backend"
    assert rank_reason(issue(4)) == "p2 default"

    # issue #60: stale vs live is decided from evidence, and ambiguity is live.
    DAY = 86400

    def cls(dirty, age, pr, tasks="", touched="same"):
        # Most cases predate the touch signal and mean "the checkout is as old
        # as its commit"; `touched=None` is the distinct "could not measure".
        return classify(dirty, age, pr, tasks,
                        touched_sec=age if touched == "same" else touched)

    assert cls(False, 3 * DAY, False)[0] == "STALE"
    assert cls(True, 3 * DAY, False)[0] == "LIVE"           # dirty tree
    assert cls(False, 60, False)[0] == "LIVE"               # committed a minute ago
    assert cls(False, 3 * DAY, True)[0] == "LIVE"           # open PR
    assert cls(None, 3 * DAY, False)[0] == "LIVE"           # tree unreadable
    assert cls(False, None, False)[0] == "LIVE"             # commit date unreadable
    assert "4/12 tasks done" in cls(False, 3 * DAY, False, "4/12")[1]
    assert "no open PR" in cls(False, 3 * DAY, False)[1]

    # PR #98 review, P1: a worktree created seconds ago off an old base commit
    # is clean, has no PR, and inherits the old commit date. Age alone called it
    # STALE and the attended path offered to delete a sibling's live checkout.
    assert cls(False, 90 * DAY, False, touched=30)[0] == "LIVE"
    assert "worktree touched just now" in cls(False, 90 * DAY, False, touched=30)[1]
    # An unmeasurable checkout age is an unknown, and unknowns vote LIVE.
    assert cls(False, 90 * DAY, False, touched=None)[0] == "LIVE"
    assert "worktree age unknown" in cls(False, 90 * DAY, False, touched=None)[1]
    # A genuinely abandoned worktree — old commit AND untouched since — is still
    # STALE, so the fix does not simply disable the classification.
    assert cls(False, 3 * DAY, False, touched=3 * DAY)[0] == "STALE"
    assert cls(False, 3 * DAY, False, touched=2 * DAY)[0] == "STALE"
    # A touch signal is never *only* read: a fresh commit under an old gitdir
    # mtime (impossible in practice, but the rule is "most recent wins") is live.
    assert cls(False, 60, False, touched=90 * DAY)[0] == "LIVE"

    # PR #98 review, P2: a failed `gh pr list` is not evidence of "no PR".
    real_sh_rc = sh_rc

    argv = []

    def prs(*items):
        """Stand in for `gh pr list`, capturing argv so the query is testable."""
        payload = json.dumps([p if isinstance(p, dict) else {"body": p}
                              for p in items])

        def fake(*a):
            argv.append(list(a))
            return 0, payload
        return fake

    try:
        globals()["sh_rc"] = lambda *a: (1, "")           # gh could not answer
        assert has_open_pr(7) is None
        globals()["sh_rc"] = lambda *a: (0, "[]")         # answered: none open
        assert has_open_pr(7) is False
        globals()["sh_rc"] = prs("Closes #7")
        assert has_open_pr(7) is True
        globals()["sh_rc"] = lambda *a: (0, "not json")   # answered nonsense
        assert has_open_pr(7) is None
        # Valid JSON that is not a list of objects reaches `p.get` and raises, and
        # the `except` answers None. Before #102 nothing here raised at all:
        # `bool(json.loads(out))` answered True for `{"message":…}`, `5` and `[1]`
        # and False for `null`, the unsafe direction, with no error to see.
        for payload in ('{"message":"rate limited"}', "null", "5", "[1]", '["#7"]'):
            globals()["sh_rc"] = lambda *a, _p=payload: (0, _p)
            assert has_open_pr(7) is None, payload

        # Issue #102: the regex decides, not GitHub's tokenizer. A PR whose prose
        # mentions the bare number is not a PR about issue #N — searching `401`
        # matched every open PR discussing the HTTP status, and refused #401
        # forever with no tree state a human could clear.
        globals()["sh_rc"] = prs("returns a 401 when unauthenticated",
                                 "retries on 401 then gives up")
        assert has_open_pr(401) is False
        globals()["sh_rc"] = prs("returns 401 — see #401 for the gate")
        assert has_open_pr(401) is True
        # `\b` keeps #401 off #4010; the title counts as well as the body; and a
        # payload with no `body` key at all exercises the `or ''` coalesce.
        globals()["sh_rc"] = prs("supersedes #4010")
        assert has_open_pr(401) is False
        globals()["sh_rc"] = prs({"title": "Closes #401"})
        assert has_open_pr(401) is True
        # The query itself is part of the fix, and a mock that ignores argv would
        # let a revert to the bare-number search pass green.
        assert "#401 in:title,body" in argv[-1], argv[-1]
        assert "--limit" in argv[-1], argv[-1]
        # A full page is a truncated page as far as this function can tell, and
        # "not found" here is the direction that gets a live worktree deleted.
        # TRUNCATED rather than None, so the operator is told why (#104).
        globals()["sh_rc"] = prs(*["no reference here"] * PR_SEARCH_CAP)
        assert has_open_pr(401) is TRUNCATED
        globals()["sh_rc"] = prs(*(["no reference here"] * 99 + ["Closes #401"]))
        assert has_open_pr(401) is True
    finally:
        globals()["sh_rc"] = real_sh_rc

    # Issue #102's other half, and #104. `fake_sh` stands in for
    # `git branch -a --list` rather than for the glob list, so this exercises the
    # patterns AND the name parsing below them. Asserting on the argv alone is a
    # change detector that cannot tell a correct glob from a wrong one.
    #
    # What it reproduces, all confirmed against git 2.50.1: matching is against
    # the SHORTENED refname (`origin/x`, so a `remotes/` pattern selects
    # nothing); `*` crosses `/`, because git's `match_pattern` calls wildmatch
    # without `WM_PATHNAME`; and `--format=%(refname:short)` with `--no-column`
    # prints those short names, one per line, with no marker and no colour even
    # under `color.ui=always` and `column.ui=always`. Git qualifies a name
    # (`heads/x`) only when another ref shares it, and no fixture here does.
    # `sorted()` stands in for `--sort=refname`. `fnmatchcase`,
    # not `fnmatch`: the latter normcases, and git is case-sensitive by default.
    import fnmatch

    REFS = ["416-picker-number-collision", "082-fix-thing",
            "origin/feature/fix/416-deep", "v2.416-x",
            "269-unreadable-416-cart", "4416-something"]
    real_sh, real_worktrees = sh, worktrees
    try:
        globals()["worktrees"] = lambda: []

        def fake_sh(*a):
            # The three flags are #104's fix, and this fake models none of what
            # they prevent, so this assertion is the only thing guarding them;
            # their effect was checked against real git, not here. Without
            # --format the output carries markers and colour, without --no-column
            # a column setting packs several names onto the one line this reads,
            # and without --sort=refname a `branch.sort` setting can put a
            # remote ahead of the local branch.
            assert a[:7] == ("git", "branch", "-a", "--list", "--no-column",
                             "--sort=refname", "--format=%(refname:short)"), a
            return "\n".join(m for m in sorted(REFS)
                             if any(fnmatch.fnmatchcase(m, g) for g in a[7:]))

        globals()["sh"] = fake_sh
        # Under --sort=refname the local branch sorts ahead of any remote and
        # wins, and `ref` is the bare name `git log` resolves.
        assert locate(416)[0] == "416-picker-number-collision", locate(416)
        assert locate(416)[2] == "416-picker-number-collision", locate(416)
        # `*` crosses `/`, so `*/416-*` still reaches a nested remote branch, and
        # its ref is the short `origin/...` form, which `git log` resolves.
        REFS[:] = ["origin/feature/fix/416-deep"]
        assert locate(416)[0] == "416-deep", locate(416)
        assert locate(416)[2] == "origin/feature/fix/416-deep", locate(416)
        # All three of these matched the old `*416-*`; none is issue 416's work.
        REFS[:] = ["v2.416-x", "269-unreadable-416-cart", "4416-something"]
        assert locate(416) == ("", "", ""), locate(416)
        # Each glob on its own, for an issue whose padded and unpadded forms
        # differ. For 416 the two are the same string, so only `{pad}-*` had a
        # case of its own (`082-fix-thing`) and deleting any of the other three
        # still passed (#104).
        for only, found in (("82-x", "82-x"),                    # {num}-*
                            ("origin/82-x", "82-x"),             # */{num}-*
                            ("082-fix-thing", "082-fix-thing"),  # {pad}-*
                            ("origin/082-x", "082-x")):          # */{pad}-*
            REFS[:] = [only]
            assert locate(82)[0] == found, (only, locate(82))
    finally:
        globals()["sh"], globals()["worktrees"] = real_sh, real_worktrees
    assert cls(False, 3 * DAY, None, touched=3 * DAY)[0] == "LIVE"
    assert "PR lookup failed" in cls(False, 3 * DAY, None, touched=3 * DAY)[1]
    assert "no open PR" not in cls(False, 3 * DAY, None, touched=3 * DAY)[1]
    # TRUNCATED votes LIVE like None, but says what happened. It is truthy, so a
    # `classify` that forgot it would fall through and report an open PR (#104).
    assert cls(False, 3 * DAY, TRUNCATED, touched=3 * DAY)[0] == "LIVE"
    assert "truncated" in cls(False, 3 * DAY, TRUNCATED, touched=3 * DAY)[1]
    assert "open PR" not in cls(False, 3 * DAY, TRUNCATED, touched=3 * DAY)[1]
    # `liveness` reads `has_open_pr` itself when there is no branch or worktree,
    # without going through `classify`, so it needs its own check. Without one a
    # truncated search printed "open PR", the exact misreport TRUNCATED exists
    # to prevent.
    real_locate, real_has_open_pr = locate, has_open_pr
    try:
        globals()["locate"] = lambda n: ("", "", "")
        globals()["has_open_pr"] = lambda n: TRUNCATED
        _LIVE_CACHE.pop(9104, None)
        state, name, ev = liveness(9104)
        assert state == "LIVE", (state, name, ev)
        assert "truncated" in ev and "open PR" not in ev, ev
    finally:
        globals()["locate"], globals()["has_open_pr"] = real_locate, real_has_open_pr
        _LIVE_CACHE.pop(9104, None)

    # …and the verdict it produces on the explicit-issue path depends on who is
    # reading. This is the whole of issue #60: the operator pasted an issue URL
    # and got `SKIP: #237 in-progress:237-…` with nothing to act on.
    real_liveness, real_locate = liveness, locate
    issues = [{"number": 237, "title": "uniqueness", "body": "do the thing",
               "labels": []}]
    try:
        globals()["liveness"] = lambda n: (
            "STALE", "237-contacts", "commit abc1234, clean, last commit 3d ago, no open PR")
        globals()["locate"] = lambda n: ("237-contacts", "/tmp/wt/237-contacts", "237-contacts")

        attended = _capture(validate_one, issues, 237, headless=False)
        assert attended.startswith("STALE: #237 237-contacts — commit abc1234"), attended
        assert "RESUME: 237 237-contacts /tmp/wt/237-contacts" in attended, attended
        assert "CLEAN: 237 git worktree remove /tmp/wt/237-contacts" in attended, attended

        # Unattended, the hard SKIP stands — with the evidence attached.
        headless = _capture(validate_one, issues, 237, headless=True)
        assert headless.startswith("SKIP: #237 in-progress:237-contacts (stale — "), headless

        # A LIVE verdict never downgrades, attended or not.
        globals()["liveness"] = lambda n: (
            "LIVE", "237-contacts", "uncommitted changes, last commit 4m ago, no open PR")
        live = _capture(validate_one, issues, 237, headless=False)
        assert live.startswith("SKIP: #237 in-progress:237-contacts (live — "), live
    finally:
        globals()["liveness"], globals()["locate"] = real_liveness, real_locate

    print("OK: preflight-issues selftest")


if __name__ == "__main__":
    main()
