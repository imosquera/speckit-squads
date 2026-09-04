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

Note on capabilities (verified empirically): **only extensions can declare `hooks:` and register brand-new standalone commands**; a `hooks:` block or a new command in a `preset.yml` is silently dropped by `specify`. **Only presets can `wrap`/`replaces` an existing command body**; extensions add new commands and hooks but never rewrite a core command. When a feature needs both (e.g. `progress-report` wraps cycle commands *and* needs `before_*` hooks), ship it as a preset + companion extension pair.

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

Anything that must reach *outside* `specify` — the Claude Code harness
(`.claude/settings.json`) or the project's `CLAUDE.md` — ships as
`scripts/bash/post-install.sh <project-dir>` inside the extension or preset that
owns it. `install.sh` runs every executable one it finds after registration, and
`uninstall.sh` runs the matching `scripts/bash/pre-uninstall.sh` before
de-registering. Both are auto-discovered; both must be idempotent, since
`--force` re-runs them. `graph-first-navigation` is the first user.

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
  `gh` calls). This is what keeps autopilot off the wire-up child of a
  `/speckit-git-issue` layer split until its frontend and backend siblings land.
  Plus `/speckit-autopilot-schedule` to put `.run` on a recurring launchd timer (default every 2h, configurable; opt-in, macOS-only)
- `git` — feature branches + worktree + linked GitHub issue (numbered to match the spec), issue sync via `speckit.git.issue` on the `after_specify` hook, clean, PR, auto-commit hooks across all phases.
  `/speckit-git-issue` also owns **triage labels**, the input side of autopilot's
  ranked picker: `label-issue.sh` is the single writer of `p0`..`p3`,
  `bug`/`feature` and `frontend`/`backend`/`integration`, plus the `mock-first`
  and `epic` markers — creating any label the repo lacks and keeping each axis
  exclusive (`--priority p1` removes the other three; `--layer backend` removes
  the other two). Markers are independent and only ever touch themselves.
  **A manual `/speckit-git-issue` with no linked issue checks for a duplicate
  before it creates anything.** `find-duplicate-issues.sh` is the scan: it
  reduces the prospective title to its distinctive tokens and searches each one
  **separately**, because GitHub ANDs the terms of a single query and a
  full-sentence search returns nothing; candidates score one point per distinct
  token hit plus one per token that also lands in *their* title, and closed
  issues are in scope on purpose ("already fixed" and "already declined" are
  both answers). The score only ranks — the agent reads the candidates and the
  human decides, via `AskUserQuestion`, between merging into `#N`, filing
  cross-linked, and stopping. Two rules keep the merge honest: it runs **before**
  the clarify pass (nothing to clarify on an issue you are about to merge away),
  and adopting `#N` means folding that issue's own report into `spec.md` first —
  the body is regenerated from the spec on every later sync, so a reporter's
  repro steps left only on the issue are erased by the next `after_specify` run.
  Unattended it never merges and never files: it prints the candidates and
  leaves the feature unlinked, since silently rewriting a stranger's issue body
  is worse than an unlinked feature. `--no-dupe-check` skips it; `--dupe-check`
  forces it on the update path.
  **A manual `/speckit-git-issue` with no linked issue clarifies before it
  creates.** It runs `/speckit-clarify` first when the spec still carries
  `[NEEDS CLARIFICATION]` markers or no `## Clarifications` session, then asks the
  issue-shaped gaps clarify does not cover (definition of done, reproduction, what
  is out of scope, the layer when the split is ambiguous) in **one**
  `AskUserQuestion` call batched with the priority/kind question. Delegating to
  clarify is not stylistic: the body is regenerated from `spec.md` on every later
  sync, so an answer captured only in the issue body is erased by the next
  `after_specify` run — every answer must land in `spec.md`, and the spec must be
  re-read after clarify returns or you publish the pre-clarification copy. Never on
  the `after_specify` hook path (it fires seconds after `/speckit-specify`, and
  clarify is the operator's own next step) and never unattended; `--no-clarify` /
  `--clarify` override.
  The command asks the human
  for a priority — leading with the value it would infer, marked recommended — and
  falls back to inferring **only** when nobody is in the loop (the `after_specify`
  hook under autopilot), saying so when it does; an existing human-set priority is
  never re-asked or overwritten. Label failures are warnings, never errors.
  **A full-stack feature is filed as three issues, not one, and the frontend one
  is always a mock.** `split-issue.sh` turns the tracking issue into a parent with
  `frontend(mock): T`, `backend: T`, and `wire-up: T` children. The frontend child
  is `mock-first`: built against static in-repo fixtures with **no network calls at
  all**, so it starts immediately, is reviewable on its own, and freezes the data
  shape the backend child then implements; the wire-up child retires the fixtures.
  Three pieces of the mechanism are load-bearing and easy to break:
  **creation order** is frontend → backend → integration, because the picker breaks
  equal-priority ties by age — that is the *entire* implementation of "mock first",
  there is no rule for it in `preflight-issues.py`; the wire-up child's body carries
  `Blocked by: #fe, #be`, which `preflight-issues.py`'s new `blocked_by()` resolves
  against the open-issue list it already fetched (no extra `gh` calls, and a
  dependency absent from that list counts as closed); and the parent is labelled
  `epic`, already a member of the picker's `BLOCK` set, so autopilot works the
  children instead of re-implementing all three from the parent in one pass.
  The split is idempotent — the parent's `<!-- speckit:work-breakdown -->` block is
  the registry of children, so a re-spec **edits** the existing three rather than
  opening a second set — which means the parent body sync must run **before** the
  split, never after, or the block is erased and the next run duplicates. Each
  breakdown line must **lead with its layer word** (`- [ ] integration — wire-up…`);
  the parser anchors there, and a line reading `- [ ] wire-up …` made the
  integration child invisible to re-runs. A child is never split again: it carries a
  layer label and a `Parent: #N` line. Single-layer specs get the layer label and no
  split — and a frontend feature against an API that already exists is `frontend`
  but **not** `mock-first`. `create-new-feature.sh --source-issue N` binds a worktree to an **already existing** issue: it skips `gh issue create`, numbers from `N` unless `GIT_BRANCH_NAME`/`--number`/`--timestamp` fixes the name, writes `{"source_issue": N}` itself, and leaves the pre-existing issue title alone (only stubs it created get the `NNN: ` prefix). Without it, `GIT_BRANCH_NAME` alone leaves the worktree unlinked and every such caller had to post-patch `feature.json` in a second step (issue #44). `/speckit-git-pr --draft` is the human-review handoff mode: it passes `--draft` to `gh pr create` directly (no create-then-`gh pr ready --undo`) **and** skips the `/speckit-archive-feature` pre-step, so the tracking issue stays open and the spec stays unarchived until a human merges — autopilot's Step 9 uses it (issue #28). `commit_exclude:` in `git-config.yml` lists repo-tracked generated artifacts whose canonical copy CI rebuilds on the default branch (`graphify-out/`): `auto-commit.sh` holds them out of `git add` via `:(exclude)` pathspecs, and `create-pr.sh` resets them to the base before opening the PR — both the working tree (otherwise the squash path aborts on a dirty tree) and any divergence already committed on the branch. The reset removes the path from the index *before* restoring the base's copy, because `git checkout <base> -- <dir>` leaves branch-added files behind and a dated snapshot dir is entirely branch-added. Empty by default (issue #22)
- `progress` — companion to the `progress-report` preset: `before_tasks`/`before_implement` lifecycle hooks that mark those two phases active on the dashboard card. Exists because presets can't declare hooks and the preset's `wrap` is clobbered whenever another preset **replaces** the same command body; a hook fires regardless. Since #25 the `before_implement` half is belt-and-braces — `/speckit-implement` now composes properly — but `explicit-task-dependencies` still **replaces** `speckit.tasks`, so the `before_tasks` hook remains the only thing covering that phase. Owns no writer — resolves the preset's `progress_report.py` and no-ops if absent. Install alongside the preset.
- `review` — multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)
- `stale-tasks-guard` — `before_implement` lifecycle hook that halts `/speckit-implement` when `spec.md` was modified more recently than `tasks.md` (the signal that a late `/speckit-clarify`/`/speckit-specify` edit invalidated the task plan), directing the operator to re-run `/speckit-tasks`; `--force` bypasses with a logged acknowledgement. Shipped as an extension rather than a preset wrap/replace so it fires regardless of which preset owns the `/speckit-implement` command body.

**Presets**
- `claude-ask-questions` — interactive clarify/checklist for Claude
- `explicit-task-dependencies` — `tasks-template` with explicit dependency edges + Execution Wave DAG; overrides `/speckit-implement` to fan each wave's `[P]` tasks out to subagents in parallel
- `graphify-on-implement` — `/speckit-implement` override that always runs `graphify update` as the final mandatory step
- `functional-constitution` — `/speckit-constitution` **wrapper** that injects and normalizes a mandatory functional-programming governance section. Stacks with `parse-dont-validate`'s constitution layer: both match their section by title (not roman numeral) and renumber all principle sections sequentially, so neither clobbers the other (issue #37)
- `spec-minimal` — one job: artifact minimalism. Wraps `/speckit-specify` to strip `## Assumptions`, `### Key Entities`, and `## Success Criteria` from `spec.md`; wraps `/speckit-plan` to hold the feature tree to `spec.md`, `plan.md`, `tasks.md`, and optional `quickstart.md` (`research.md`, `data-model.md`, `contracts/` are forbidden). Enforced by a mandatory prompt rule plus the self-healing `scripts/bash/enforce-minimal-tree.sh`, which folds any forbidden artifact into `plan.md` under a sentinel block and deletes it; unknown top-level entries only warn, so stacking is safe
- `diff-minimal` — sibling to `spec-minimal`, and the distinction is the whole
  point: that one makes the **spec** shorter, this one makes the **change**
  smaller. A spec that faithfully restates an issue's seven-file wish list yields
  a seven-file diff because nothing ever asks whether the change needs those
  files (seasonpass#182: a composite index for a query the database already
  served, and a rules edit nothing evaluates — two of seven, both removable).
  Wraps `/speckit-specify` with a minimum-diff mandate (re-derive every path and
  precondition the issue asserts against current `main`; extend before adding;
  every file the issue names is a hypothesis; no drive-by refactors) and makes
  two sections mandatory: `## Corrections to the issue as filed`, which reaches
  the tracking issue for free because `/speckit-git-issue` renders whatever
  sections `spec.md` contains, and `## Scope discipline`, whose
  `**MUST NOT touch:**` backticked-glob list is the machine-checkable half.
  `check-scope-sections.sh` asserts both exist and are populated after specify —
  `None.` is an accepted answer for either, since a spec with no corrections
  should say so rather than invent one — and the `/speckit-plan` wrap runs
  `check-plan-scope.sh`, which fails with `file:line` when `plan.md`/`tasks.md`
  plan work in a forbidden path. It reads the **artifacts, not the diff**: at
  plan time there is no diff, and the plan is the cheap moment to catch it.
  Two exemptions keep it from crying wolf (a checker that does gets disabled
  within a day): lines whose own text negates (`MUST NOT`, `out of scope`, …)
  and everything under a heading matching scope/non-goals/corrections/constraints.
  **It mandates the smallest change, not small changes** — a migration or a
  rename is legitimately wide, and the escape hatch is an explicit
  `**Scope justification:**` line. A sibling preset rather than an extension of
  `spec-minimal` because that one is a pure deterministic post-processor and this
  adds a prompt layer; both sit at the default priority 10 and compose as `wrap`
  layers in id order, and the stripper never touches either new section
- `spec-ui-preview` — adds a GitHub-safe inline HTML UI preview to UI-touching specs (split out of `spec-minimal`)
- `library-research` — `/speckit-plan` wrapper (chainable via `{CORE_TEMPLATE}`) that, after the plan is written, uses live web search to check whether existing libraries can replace hand-rolled build-it-yourself surface area (auth, parsing, queues, retries, etc.); writes findings + a recommendation per unknown to `research.md` and revises `plan.md` in place when a library is a clear win. No-ops when the plan has no such surface area.
- `portfolio-audit` — portfolio-wide `/speckit-analyze` override
- `worktree-isolation` — forces `/speckit-implement` to run inside the feature worktree
- `implement-prelude-skills` — `/speckit-implement` override that invokes `ponytail:ponytail` and `caveman` skills (when available) as a mandatory prelude before implementation begins
- `parse-dont-validate` — overrides `/speckit-constitution` (injects a canonical "Parse, Don't Validate" governance section), `/speckit-plan` (requires a "Parse Boundaries" design section: trust boundaries + branded domain types + parsers; chainable via `{CORE_TEMPLATE}`), and `/speckit-implement` (applies the discipline while writing TypeScript/Python, then gates completion on a deterministic AST scanner — Python via stdlib `ast`, TypeScript via a Node helper on the TS Compiler API — flagging `any`/`Any`, stray `JSON.parse`/`json.loads`, boolean validators, and narrowing casts outside parser modules)
- `graph-first-navigation` — makes knowledge-graph queries and the TypeScript
  language server the default navigation instruments and demotes grep to a
  **stated** fallback. Two halves, and the harness half is the one that binds:
  a **PreToolUse hook on `Grep|Glob`** written into the consumer's
  `.claude/settings.json`, which fires regardless of what any agent decides,
  plus `wrap` layers on `speckit.plan` (a mandatory `## Navigation` section
  recording each touched module's callers and dependents *as the graph reported
  them*), `speckit.tasks` (fold those edges into task coverage and ordering),
  and `speckit.implement` (scope renames/signature/type changes with LSP
  `findReferences` **before** the first edit, not by compiling in a loop).
  Deliberately a new preset rather than an extension of
  `implement-prelude-skills`: that one is registered against `speckit.implement`
  alone and exists to load skills — see `presets/graph-first-navigation/README.md`
  for the full decision.
  **The hook is tuned not to cry wolf, because one that does gets disabled
  within a day.** It fires only when `graphify-out/graph.json` exists, never
  blocks (no `permissionDecision` — the search runs), and fires only on
  identifier-shaped patterns: whitespace, a quote, or `://` in the pattern marks
  a literal-string search and is left alone, as is any search already scoped to
  non-code files, and Glob trips only on source extensions. It spends a budget of
  3 reminders per session and then goes quiet, and exits 0 silently on any
  internal error.
  **`built_at_commit` is megabytes into `graph.json`, not at the top** — reading
  the first 8KB finds nothing. The guard mmaps and byte-scans; `graph-freshness.sh`
  uses `grep -m1 -oa`. Neither parses the JSON.
  **The staleness rule is the one legitimate reason to break the rule, and it
  resolves the other way:** a stale graph means **rebuild** (`graphify update`),
  never fall back to grep. Every layer says so.
  Presets cannot declare harness hooks and extension `hooks:` cover only Spec Kit
  lifecycle phases, so the settings.json and CLAUDE.md edits ship as
  `scripts/bash/post-install.sh` / `pre-uninstall.sh` — run by a **generic**
  auto-discovered step in `install.sh`/`uninstall.sh` (`scripts/bash/post-install.sh`
  in any extension or preset is run with the project dir), so there is still no
  list to maintain
- `progress-report` — wraps the five cycle commands (specify/plan/tasks/implement/review) to keep a per-branch status card current in an agent-os dashboard repo (default `~/Code/agent-os`, configurable via `AGENT_OS_DASHBOARD`); rewrites `<dashboard>/branches/<slug>.md` with per-phase status + review substeps on each transition, no-op when the dashboard is absent. The `wrap` on tasks/implement is dropped when another preset **replaces** those bodies, so pair it with the `progress` **extension** (above), whose lifecycle hooks cover those two phases clobber-immune.

`spec-minimal` 2.0.0 is a breaking split: UI preview → `spec-ui-preview`, issue sync → the `git` extension. See the migration note in `README.md`.

## When you add a new extension or preset

1. Drop the new directory under `extensions/<id>/` or `presets/<id>/` with a valid manifest. The install/uninstall scripts will pick it up automatically — do **not** edit them.
1a. **Declare every script under `provides.scripts:`** with `file:` and, when one command owns it, `command:`. This is not decoration — `check-cli-usage.sh` fails the install when a command file references a script that is undeclared or missing, and `gen-agent-index.py` builds the consumer's command→script table from these entries. An undeclared script is invisible to agents working in a consumer project.
1b. If the item needs harness-level wiring (a `.claude/settings.json` hook, a
    `CLAUDE.md` rule), ship it as `scripts/bash/post-install.sh` plus a
    `scripts/bash/pre-uninstall.sh` that reverses it exactly. Declare both under
    `provides.scripts:`.
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
