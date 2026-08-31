# speckit-squads — agent guide

This repo is the source of truth for a personal set of Spec Kit extensions and presets. Consumer projects (e.g. `~/Code/beadbits`) install from here via `specify ... add --dev`.

## Layout

```
extensions/<id>/   extension.yml + commands/ + scripts/
presets/<id>/      preset.yml    + commands/ + templates/
install.sh         install every extension+preset into a Spec Kit project
uninstall.sh       remove every extension+preset from a Spec Kit project
check-cli-usage.sh validate `specify <verb>` calls AND every script path in command files
gen-agent-index.py  generate the consumer-side command->script index (run by install.sh)
```

**Installed layout is not the same shape.** In a consumer project, `specify` copies each
extension whole into `.specify/extensions/<id>/`, preserving its internal structure. It
never merges extension scripts into the core tree, so a consumer has **two** script trees:

```
.specify/scripts/bash/                    core Spec Kit scripts — FLAT, no per-extension subdirs
    check-prerequisites.sh  common.sh  create-new-feature.sh  setup-plan.sh  setup-tasks.sh
.specify/extensions/<id>/scripts/bash/    one tree per extension
.specify/presets/<id>/
```

There is no `.specify/scripts/bash/<extension-id>/`. Never guess a script path from the
command name: **command names and script names do not correspond.** `/speckit-git-feature`
runs `create-new-feature.sh` (not `feature.sh`), and that filename also collides with the
unrelated core `scripts/bash/create-new-feature.sh`. The authoritative path for every
extension command is the `- **Bash**:` line in its own `commands/*.md`; `ls` the extension
tree before invoking anything.

## Install / uninstall

Both scripts auto-discover every directory under `extensions/` and `presets/` that contains a manifest — there is **no hardcoded list to maintain**.

Both require a `<project-dir>` argument — there is no implicit `$PWD` default, so you can't accidentally install into the wrong place.

```bash
./install.sh /path/to/spec-kit-project
./uninstall.sh /path/to/spec-kit-project
```

Every install uses `specify ... add --dev <repo-path>`. **`--dev` records this repo as the install source; it does not symlink.** Verified in the installed specify-cli:

- `PresetManager.install_from_directory()` (`specify_cli/presets/__init__.py`) ends in `shutil.copytree(source_dir, dest_dir)` — there are no symlink calls anywhere in the preset module.
- `ExtensionManager.install_from_directory()` (`specify_cli/extensions/__init__.py`) likewise does `shutil.copytree(source_dir, dest_dir, ignore=ignore_fn)`. The only `os.symlink` in that module is for rendered *agent skill* files in dev mode, not for the extension tree itself.
- On disk, both `.specify/presets/<id>/` and `.specify/extensions/<id>/` in a consumer (checked: `~/Code/adkit`) are plain directories timestamped at last install, not symlinks.

**Consequence: edits made in this repo are NOT picked up live.** Any change — command markdown, scripts, templates, or the manifest — requires a refresh in the consumer:

```bash
./install.sh --force /path/to/spec-kit-project
```

Plain `./install.sh <project>` treats "already installed" as a no-op success, so it will **not** propagate edits. Use `--force` whenever you have changed anything here.

Note on capabilities (verified empirically): **only extensions can declare `hooks:` and register brand-new standalone commands**; a `hooks:` block or a new command in a `preset.yml` is silently dropped by `specify` — the installed preset manager contains **zero** occurrences of the string `hooks`, and a probe preset declaring a brand-new command installed cleanly, copied its file into `.specify/presets/<id>/commands/`, and registered **0** skills against the 10 that were already there. **Only presets can `wrap`/`replaces` an existing command body**; extensions add new commands and hooks but never rewrite a core command. When a feature needs both (e.g. `progress-report` wraps cycle commands *and* needs `before_*` hooks), ship it as a preset + companion extension pair.

The command a preset wraps **does not have to be a core command** — it can be one an
extension provides. `PresetResolver` tries `resolve_core(cmd_name)`, then
`resolve_extension_command_via_manifest(cmd_name)`, then `resolve_core(short_name)`, so
`{CORE_TEMPLATE}` in a preset resolves against an extension's command body via that
extension's manifest. Two presets here rely on it: `progress-report` wraps
`speckit.review.run` (the `review` extension) and `frontend-mock-first` wraps
`speckit.git.feature` (the `git` extension). This is the escape hatch when a command must
stay an extension — because it is standalone or hook-registered — but its *policy* should
be optional and per-project: keep the command in the extension and put the policy, and any
scripts only that policy needs, in a preset that wraps it.

Note on composition (issue #25): a preset command template's `strategy` defaults
to **`replace`** when omitted, and a `replace` layer kills every layer below it —
that default silently disabled five `/speckit-implement` presets at once. Always
declare `strategy:` explicitly. There is no `replaces:` key; it is not in the
schema and is silently dropped. Presets are ordered by `(priority ASC, id ASC)`,
lowest number outermost, and priority is an **install-time** argument, not a
manifest field — so `install.sh`'s `preset_priority()` map is load-bearing
wherever more than one preset targets a command. The `/speckit-implement`
ordering contract is tabulated in `README.md`; keep the two in sync.

`install.sh` runs `check-cli-usage.sh` as a pre-flight and aborts on failure: every
`specify <verb> [<subverb>]` inside a fenced bash block in `*/commands/*.md` is checked
against `specify --help`, so a command file can't ship instructions to run CLI surface
that doesn't exist. Prose outside code fences is ignored. Run it standalone any time.

`uninstall.sh` only de-registers items from the target project; it never touches the source files in this repo.

## Feature identity: `.specify/feature.json`

The file is **gitignored per-worktree state and carries exactly one key**, `source_issue`
— the only part of a feature's identity that cannot be derived from git. Branch, feature
number, worktree path, and spec directory are resolved at read time by
`spec_kit_resolve_feature()` in `extensions/git/scripts/bash/git-common.sh`.

Never reintroduce `branch_name`, `feature_num`, `worktree_path`, or `feature_directory`
into that file, and never read a feature's paths out of it. Because the file used to be
tracked, every new worktree inherited the *previous* feature's copy from the base branch,
which pointed `/speckit-git-pr` at the wrong issue and `/speckit-git-clean` at the wrong
worktree (issue #33). `/speckit-git-feature` gitignores the file and `git rm --cached`s it
on first run in a project that still tracks it, so the migration is automatic.

## Currently shipped

<!-- AGENT: keep this list in sync with the directories under extensions/ and presets/. Regenerate by running:
  ls -1 extensions/*/extension.yml presets/*/preset.yml | sed 's|/[^/]*\.yml$||'
-->

**Extensions**
- `archive` — archive a completed feature folder, close linked GitHub issues
- `autopilot` — `/speckit-autopilot-run`: take the **highest-ranked** eligible open issue (or a given issue number) from backlog to a reviewed **draft PR** by driving the whole pipeline unattended (specify → clarify auto-answered → plan → tasks → implement → review), binding the worktree to the existing issue and posting progress comments at every stage.
  A hard, non-recoverable stop writes a durable `autopilot:blocked` label plus an
  `AUTOPILOT-BLOCKED:`-tagged comment, which `preflight-issues.py` skips on and reads
  the reason back out of — without it, removing the transient `autopilot:claimed`
  label left no durable state and one issue was re-picked in 10 consecutive runs
  (issue #32); only a human clears `autopilot:blocked`.
  **A run is bound to one repo and one checkout in both directions.** Input and
  schedule always were (`gh issue list` with no `--repo`; one launchd plist per repo
  root). Output was not: nothing checked where the *fix* had to land, so an issue
  whose target resolved into a different repo got worked and delivered there while
  staying open behind it (issue #34). `check-target-repo.sh` is the guard — Step 1.5
  hands it every path the issue names, and a `FOREIGN`/`OUTSIDE` verdict is a durable
  stop. It keys on the git **common dir**, never `--show-toplevel`: autopilot always
  runs in a worktree, so comparing toplevels would flag every in-repo file as foreign.
  `preflight-issues.py --cross-repo` (passed by both the skill and the wrapper) is the
  cleanup net for deliveries that already exist — it scans an issue's own thread for
  PR links, resolves them with `gh pr view --repo`, and skips an issue already
  delivered elsewhere. It never *sources* work from another repo; a finding can only
  cause a skip. Merged beats open, closed-unmerged never counts, and the script stays
  read-only: it emits `DELIVERED: <n> <url> (<state>)` after the verdict and the
  caller parks via `park-issue.sh` — the single writer of `autopilot:blocked` and the
  `AUTOPILOT-BLOCKED:` sentinel, shared by the skill and the wrapper. Both must park:
  the wrapper exits on `SKIP:` before the skill ever launches, and a delivered issue
  doesn't stop the scan, so a run can `PICK:` a later issue while an earlier delivered
  one still needs parking.
  **`optional:` hooks are run, not skipped.** With no phase policy the coordinator
  read "optional" as "skip when unattended" and silently dropped the `after_specify`
  graphify / agent-context refreshes, leaving later phases on stale context (issue
  #14). The Operating contract now states the opposite default — run every enabled
  `before_*`/`after_*` hook for the phase, answer its `prompt:` yes, and skip only for
  a stated reason (tool missing/unauthed, or plainly inapplicable) recorded in the
  phase's issue comment. Step 3 enumerates the `after_specify` slot explicitly, and
  Steps 5–7 name their own; Step 8 *is* the `after_implement` review hook, so it
  isn't run twice.
  **The per-repo log is timestamped and attributed from the stream, not from the
  decoder.** `stream-decode.py` used to stamp `datetime.now()` at decode time, so a
  buffered burst of turns minutes apart all printed on one wall-clock second and in
  an order that implied a history that never happened — the tail once read
  "reviews still running" as the last line of a pass that had already opened a draft
  PR. It now stamps each line with the event's own `timestamp` (falling back to
  now(), marked `~HH:MM:SS`, only for `result`/`system` frames that carry none), tags
  every line with the subagent that produced it (from `parent_tool_use_id`; the main
  session is untagged) using a `tool_use_id` -> label map built from
  `system/task_started`, and renders `task_started`/`task_notification` so a
  subagent's start and finish are visible. `autopilot-run.sh` tees the raw
  stream-json to `<slug>.raw.jsonl` beside the decoded log so a finished pass can be
  re-decoded after a decoder fix without re-running it. Deliberately NOT per-run log
  files: passes are already single-flight under the wrapper's lock, so what was
  missing was per-line attribution, not per-file separation.
  **The pick is ranked, not oldest-first.** `preflight-issues.py`'s `auto_pick`
  sorts the eligible pool by (priority label, bug-before-feature, age) instead of
  taking the first row of an oldest-first fetch, so a `p0` filed today no longer
  waits behind a year-old chore. `p0`/`P1`/`priority: p2`/`priority/p3` spellings
  and the severity words (`critical`/`urgent`→p0, `high`→p1, `medium`/`normal`→p2,
  `low`→p3) all read the same, lowest rank on the issue wins, and **an unlabelled
  issue ranks `p2` — mid-pack, not last**, so an explicitly deprioritized `p3`
  chore can't outrank every untriaged bug. Age stays the final tiebreak, so an
  unlabelled backlog behaves exactly as before. The `PICK:` line carries the
  winning rank (`[p0, bug]`); the explicit-issue path prints no rank because a
  typed number is already a choice. `--cross-repo` now runs per candidate in rank
  order until one is not already delivered, instead of only against the oldest.
  The writer of this vocabulary is the git extension's `label-issue.sh` — keep
  `PRIORITY_RE`/`PRIORITY_WORDS`/`BUG_LABELS` in sync with it.
  Eligibility also honours **dependencies**: an issue whose body says
  `Blocked by: #N` is skipped while any named issue is still open
  (`blocked_by()`, checked against the fetched open-issue list, so it costs no
  `gh` calls). This is what keeps autopilot off the wire-up sibling filed by the
  `frontend-mock-first` preset until the frontend and backend issues land.
  Plus `/speckit-autopilot-schedule` to put `.run` on a recurring launchd timer (default every 2h, configurable; opt-in, macOS-only)
- `git` — feature branches + worktree + linked GitHub issue (numbered to match the spec), clean, PR, auto-commit hooks across all phases.
  **It no longer owns an issue-sync command.** `speckit.git.issue`, its
  `after_specify` hook entry, and the `label-issue.sh`/`split-issue.sh` writers were
  removed and the whole capability now ships as the `frontend-mock-first` **preset**,
  which wraps `/speckit-git-feature` instead. Consequence to remember: the tracking
  issue's body stays the stub `create-new-feature.sh` wrote unless a preset enriches
  it, and nothing in this extension writes triage labels any more — so an autopilot
  backlog is unlabelled, and therefore ranked `p2`-default and oldest-first, unless
  that preset (or a human) labels it. `after_specify` is back to a single entry
  (`speckit.git.commit`), so the declaration-order rule that used to be load-bearing
  there no longer has two entries to order. `create-new-feature.sh --source-issue N` binds a worktree to an **already existing** issue: it skips `gh issue create`, numbers from `N` unless `GIT_BRANCH_NAME`/`--number`/`--timestamp` fixes the name, writes `{"source_issue": N}` itself, and leaves the pre-existing issue title alone (only stubs it created get the `NNN: ` prefix). Without it, `GIT_BRANCH_NAME` alone leaves the worktree unlinked and every such caller had to post-patch `feature.json` in a second step (issue #44). `/speckit-git-pr --draft` is the human-review handoff mode: it passes `--draft` to `gh pr create` directly (no create-then-`gh pr ready --undo`) **and** skips the `/speckit-archive-feature` pre-step, so the tracking issue stays open and the spec stays unarchived until a human merges — autopilot's Step 9 uses it (issue #28). `commit_exclude:` in `git-config.yml` lists repo-tracked generated artifacts whose canonical copy CI rebuilds on the default branch (`graphify-out/`): `auto-commit.sh` holds them out of `git add` via `:(exclude)` pathspecs, and `create-pr.sh` resets them to the base before opening the PR — both the working tree (otherwise the squash path aborts on a dirty tree) and any divergence already committed on the branch. The reset removes the path from the index *before* restoring the base's copy, because `git checkout <base> -- <dir>` leaves branch-added files behind and a dated snapshot dir is entirely branch-added. Empty by default (issue #22)
- `progress` — companion to the `progress-report` preset: `before_tasks`/`before_implement` lifecycle hooks that mark those two phases active on the dashboard card. Exists because presets can't declare hooks and the preset's `wrap` is clobbered whenever another preset **replaces** the same command body; a hook fires regardless. Since #25 the `before_implement` half is belt-and-braces — `/speckit-implement` now composes properly — but `explicit-task-dependencies` still **replaces** `speckit.tasks`, so the `before_tasks` hook remains the only thing covering that phase. Owns no writer — resolves the preset's `progress_report.py` and no-ops if absent. Install alongside the preset.
- `review` — multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)
- `stale-tasks-guard` — `before_implement` lifecycle hook that halts `/speckit-implement` when `spec.md` was modified more recently than `tasks.md` (the signal that a late `/speckit-clarify`/`/speckit-specify` edit invalidated the task plan), directing the operator to re-run `/speckit-tasks`; `--force` bypasses with a logged acknowledgement. Shipped as an extension rather than a preset wrap/replace so it fires regardless of which preset owns the `/speckit-implement` command body.

**Presets**
- `claude-ask-questions` — interactive clarify/checklist for Claude
- `explicit-task-dependencies` — `tasks-template` with explicit dependency edges + Execution Wave DAG; overrides `/speckit-implement` to fan each wave's `[P]` tasks out to subagents in parallel
- `graphify-on-implement` — `/speckit-implement` override that always runs `graphify update` as the final mandatory step
- `functional-constitution` — `/speckit-constitution` **wrapper** that injects and normalizes a mandatory functional-programming governance section. Stacks with `parse-dont-validate`'s constitution layer: both match their section by title (not roman numeral) and renumber all principle sections sequentially, so neither clobbers the other (issue #37)
- `frontend-mock-first` — **`/speckit-git-feature` wrapper** owning the whole
  layer policy, and the only home for it since the `git` extension's issue command
  was removed. Classifies the feature *description* (there is no spec yet at this
  point in the cycle) and, when it spans both layers, **the feature being created
  becomes the frontend mock** — static in-repo fixtures, no network calls at all —
  while `backend:` and `wire-up:` siblings are filed beside it. That shape is forced
  by the seam: `/speckit-git-feature` binds one branch, worktree, and issue number
  together, so a parent-epic-plus-three-children split would bind the worktree to a
  container nobody implements. The frontend keeps the number the core command just
  created, so nothing is undone. The wire-up sibling carries `Blocked by: #fe, #be`,
  which autopilot's `blocked_by()` enforces. Self-contained: ships its own
  `label-issue.sh` and `split-layers.sh` under `provides.scripts:`, so it needs no
  extension beyond the one whose command it wraps.
  Two things learned the hard way here, both verified in a scratch project:
  **a preset can wrap a command an *extension* provides** (`PresetResolver` falls
  back to `resolve_extension_command_via_manifest()`), which is what makes this
  possible at all; and **a preset can NOT register a command that has no base** — a
  probe preset declaring a brand-new command installed cleanly and produced 0 skills
  against 10 registered, the file sitting unused in `.specify/presets/`. So a preset
  can only ever adjust a command that already exists.
- `spec-minimal` — one job: artifact minimalism. Wraps `/speckit-specify` to strip `## Assumptions`, `### Key Entities`, and `## Success Criteria` from `spec.md`; wraps `/speckit-plan` to hold the feature tree to `spec.md`, `plan.md`, `tasks.md`, and optional `quickstart.md` (`research.md`, `data-model.md`, `contracts/` are forbidden). Enforced by a mandatory prompt rule plus the self-healing `scripts/bash/enforce-minimal-tree.sh`, which folds any forbidden artifact into `plan.md` under a sentinel block and deletes it; unknown top-level entries only warn, so stacking is safe
- `spec-ui-preview` — adds a GitHub-safe inline HTML UI preview to UI-touching specs (split out of `spec-minimal`)
- `library-research` — `/speckit-plan` wrapper (chainable via `{CORE_TEMPLATE}`) that, after the plan is written, uses live web search to check whether existing libraries can replace hand-rolled build-it-yourself surface area (auth, parsing, queues, retries, etc.); writes findings + a recommendation per unknown to `research.md` and revises `plan.md` in place when a library is a clear win. No-ops when the plan has no such surface area.
- `portfolio-audit` — portfolio-wide `/speckit-analyze` override
- `worktree-isolation` — forces `/speckit-implement` to run inside the feature worktree
- `implement-prelude-skills` — `/speckit-implement` override that invokes `ponytail:ponytail` and `caveman` skills (when available) as a mandatory prelude before implementation begins
- `parse-dont-validate` — overrides `/speckit-constitution` (injects a canonical "Parse, Don't Validate" governance section), `/speckit-plan` (requires a "Parse Boundaries" design section: trust boundaries + branded domain types + parsers; chainable via `{CORE_TEMPLATE}`), and `/speckit-implement` (applies the discipline while writing TypeScript/Python, then gates completion on a deterministic AST scanner — Python via stdlib `ast`, TypeScript via a Node helper on the TS Compiler API — flagging `any`/`Any`, stray `JSON.parse`/`json.loads`, boolean validators, and narrowing casts outside parser modules)
- `progress-report` — wraps the five cycle commands (specify/plan/tasks/implement/review) to keep a per-branch status card current in an agent-os dashboard repo (default `~/Code/agent-os`, configurable via `AGENT_OS_DASHBOARD`); rewrites `<dashboard>/branches/<slug>.md` with per-phase status + review substeps on each transition, no-op when the dashboard is absent. The `wrap` on tasks/implement is dropped when another preset **replaces** those bodies, so pair it with the `progress` **extension** (above), whose lifecycle hooks cover those two phases clobber-immune.

`spec-minimal` 2.0.0 is a breaking split: UI preview → `spec-ui-preview`, issue sync → the `git` extension. See the migration note in `README.md`.

## When you add a new extension or preset

1. Drop the new directory under `extensions/<id>/` or `presets/<id>/` with a valid manifest. The install/uninstall scripts will pick it up automatically — do **not** edit them.
1a. **Declare every script under `provides.scripts:`** with `file:` and, when one command owns it, `command:`. This is not decoration — `check-cli-usage.sh` fails the install when a command file references a script that is undeclared or missing, and `gen-agent-index.py` builds the consumer's command→script table from these entries. An undeclared script is invisible to agents working in a consumer project.
2. Update the **Currently shipped** list above with one bullet: `` `<id>` — one-line description ``.
3. Update the matching list in `README.md` so the user-facing doc stays in sync.
4. If a consumer project should pick it up, run `./install.sh --force <project>` from there.

## When you remove an extension or preset

1. `rm -rf extensions/<id>` or `presets/<id>`.
2. Delete its bullet from **Currently shipped** above and from `README.md`.
3. Run `./uninstall.sh <project>` in any consumer that still has it registered, or `specify {extension,preset} remove <id>` ad-hoc.

## Manifest references

- Extension dev guide: <https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md>
- Extension API: <https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-API-REFERENCE.md>
- Preset architecture: <https://github.com/github/spec-kit/blob/main/presets/ARCHITECTURE.md>
- Preset README: <https://github.com/github/spec-kit/blob/main/presets/README.md>
