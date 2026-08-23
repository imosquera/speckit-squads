# autopilot extension

Registers two commands:

- **`/speckit-autopilot-run`** — take the oldest eligible open GitHub issue (or a
  given issue number) from backlog to a reviewed **draft PR**, driving the whole
  speckit pipeline unattended — pick → worktree → specify → clarify (auto-answered)
  → plan → tasks → implement → review → draft PR — and posting progress to the issue
  at every stage.
- **`/speckit-autopilot-schedule`** — put `/speckit-autopilot-run` on a recurring
  **launchd** timer so the backlog drains itself (default **every 2h**, configurable
  via `--interval-hours N`). Opt-in and macOS-only; also `uninstall`, `status`, and
  `run-now`. `.run` detects whether a schedule exists and *suggests* setting one up
  when it doesn't — it never schedules itself.

## The two labels: `autopilot:claimed` and `autopilot:blocked`

Autopilot keeps its state on the issue itself, in two labels that mean opposite
things and are cleaned up by different actors.

| Label | Lifetime | Written by | Cleared by |
|---|---|---|---|
| `autopilot:claimed` | **transient** — one run | the skill body, once, at Step 1 | the skill on every exit path; `autopilot-run.sh`'s `EXIT` trap as a safety net if the session dies ungracefully |
| `autopilot:blocked` | **durable** — until the blocker is fixed | the skill body, on a hard non-recoverable stop | **a human**, deliberately |

Both are in `preflight-issues.py`'s `BLOCK` set, so a labelled issue is skipped by
the auto-pick and explicit-issue paths alike.

`autopilot:blocked` exists because removing the claim on a hard stop restores the
issue to the eligible pool in full: the next scheduled tick re-picks it,
rediscovers the identical blocker, posts a near-duplicate comment, and unclaims.
One issue went through that loop **10 times over two days** before anyone noticed
(issue #32). The blocking run now also posts a comment carrying a machine-readable
marker line:

```
AUTOPILOT-BLOCKED: fix target `~/.claude/skills/hindsight/hindsight.py` resolves outside any git repo
```

`preflight-issues.py`'s `blocked_reason()` reads that line back (newest matching
comment wins) so an explicit `/speckit-autopilot-run N` on a parked issue prints
`SKIP: #N blocked — <reason>` instead of silently repeating the cycle. Nothing
automatic ever removes `autopilot:blocked` — clearing it is the human signal that
the blocker is actually resolved.

## Binding a worktree to an existing issue

Autopilot creates its worktree with `GIT_BRANCH_NAME` set, which makes
`/speckit-git-feature` skip issue creation — so nothing writes the issue linkage,
and the fresh worktree may still carry an *inherited* `.specify/feature.json` from
the base branch. `scripts/bash/bind-feature-issue.sh <issue> [worktree]` performs
that binding through the git extension's shared writer,
`spec_kit_write_feature_json()`, so the file is gitignored (and `git rm --cached`ed
in a project whose older layout still tracks it) on this path too. Writing the file
with a raw `printf` skips that half and leaves a tracked `feature.json` that the
next worktree inherits — the stale-state bug of issue #33, on the one code path that
runs unattended (issue #21). The git extension is required.

See `commands/speckit.autopilot.run.md` for the full workflow and the decisions behind
it (one issue per run, full autonomy with an issue-comment audit trail, stop only
on hard blockers), and `commands/speckit.autopilot.schedule.md` for the scheduler.

## Scheduling (recurring unattended runs)

```bash
/speckit-autopilot-schedule                       # schedule every 2h (default)
/speckit-autopilot-schedule install --interval-hours 4
/speckit-autopilot-schedule status                # is it on? interval + log tail
/speckit-autopilot-schedule run-now               # fire one pass immediately
/speckit-autopilot-schedule uninstall             # stop it
```

Each repo gets its own launchd agent
(`~/Library/LaunchAgents/com.speckit.autopilot.<repo>.plist`) that runs
`scripts/bash/autopilot-run.sh <repo>` on the interval, which invokes
`claude -p "/speckit-autopilot-run" --dangerously-skip-permissions` inside the repo.
The permission bypass is what makes an *unattended* pass possible; runs are
single-flight (a long pass won't stack a second one), and output lands in
`~/Library/Logs/speckit-autopilot/<repo>.log`. Nothing recurring is installed until
you run `install` — it's strictly opt-in.

## Install

```bash
specify extension add --dev /path/to/speckit-squads/extensions/autopilot
# or, for the whole repo:  /path/to/speckit-squads/install.sh <project>
```

## Optional: name each session after its issue (SessionStart hook)

`hooks/session-title.sh` titles a Claude Code session after the speckit feature /
GitHub issue it belongs to, so parallel backlog runs are easy to tell apart. It's
a **Claude Code** hook (settings.json), not a speckit pipeline hook, so `specify`
does not wire it up — add it to the consumer project's `.claude/settings.json`
yourself:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.specify/extensions/autopilot/hooks/session-title.sh"
          }
        ]
      }
    ]
  }
}
```

(Adjust the path if your install location differs; with `--dev` installs the
extension resolves back to this repo's source tree, so you can also point at
`/path/to/speckit-squads/extensions/autopilot/hooks/session-title.sh` directly.)

### What it does

- Fires on session **startup** and **resume** (Claude ignores a hook-set title
  after `/clear` and during compaction, so it stays silent then).
- Reads `source_issue` from `.specify/feature.json` → `#N: <issue title>` (via `gh`),
  else the live git branch. On the main checkout with no feature, it emits
  nothing and Claude keeps its auto-generated title.
- Never blocks a session from starting — every failure degrades quietly.

### Known limitation

The session that *runs* `/speckit-autopilot-run` starts before the issue is picked, so
it can't rename itself — there's no supported way to rename a **running** Claude
session (only `startup`/`resume` via this hook, or a manual `/rename`). The command
sets a best-effort terminal-tab title for the running session; the durable
Claude-session title applies whenever you open or resume a session **inside the
issue's worktree**.
