# speckit-squads

A collection of [Spec Kit](https://github.com/github/spec-kit) extensions and presets, packaged for local-dev installation via `specify`.

## Layout

```
extensions/   # Spec Kit extensions (commands + hooks)
  archive/         Archive completed feature folders, close linked GH issues
  autopilot/       Oldest eligible issue → draft PR, driving the whole pipeline unattended (+ launchd scheduler);
                   parks hard-blocked issues with a durable autopilot:blocked label so they aren't re-picked forever
  git/             Feature-branch + worktree + linked GitHub issue (incl. issue sync), clean, PR (+ --draft), auto-commit hooks
  progress/        before_tasks/before_implement hooks for the progress-report preset (covers the two phases a replace-strategy preset clobbers)
  review/          Multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)
  stale-tasks-guard/  before_implement hook that halts /speckit-implement when spec.md is newer than tasks.md (--force bypasses)

presets/      # Spec Kit presets (template + command overrides)
  claude-ask-questions/         Interactive clarify/checklist for Claude
  explicit-task-dependencies/   tasks-template with explicit dependency edges
  graphify-on-implement/        implement override that always runs graphify update last
  functional-constitution/      constitution override that enforces FP governance
  spec-minimal/                 Artifact minimalism: strips spec sections, keeps the feature tree to spec/plan/tasks
  spec-ui-preview/              GitHub-safe inline HTML UI preview for UI-touching specs
  library-research/             plan wrapper that web-searches for libraries to replace build-it-yourself surface area, writes research.md
  portfolio-audit/              Portfolio-wide analyze override
  worktree-isolation/           Forces /speckit-implement to run inside feature worktree
  implement-prelude-skills/     Invokes ponytail:ponytail + caveman skills before /speckit-implement starts
  parse-dont-validate/          constitution + plan + implement overrides enforcing "parse, don't validate" across TypeScript + Python, with a deterministic AST scan gate (Python ast + TS Compiler API)
  progress-report/           wraps the 5 cycle commands to keep a per-branch status card in ~/Code/agent-os current (pair with the progress extension for tasks/implement)
```

Each item is a self-contained directory with its own `extension.yml` or `preset.yml` manifest, conforming to Spec Kit's schema:

- Extensions: <https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md>
- Presets: <https://github.com/github/spec-kit/blob/main/presets/README.md>

## Prerequisite: the Spec Kit CLI

Everything here installs through Spec Kit's `specify` CLI. Install it once with `uv`, pinned to a release tag:

```bash
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git@vX.Y.Z
# e.g. the current release:
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git@v0.12.4
```

This puts `specify` on your PATH (`~/.local/bin`). Check the [latest release](https://github.com/github/spec-kit/releases/latest) for the newest `vX.Y.Z`, and re-run the same command to upgrade. Verify with `specify --version`.

## Install into a project

Set `SQUADS` to wherever you checked out this repo, then run the commands from any Spec Kit project:

```bash
export SQUADS=/path/to/your/speckit-squads   # adjust to your checkout

# extensions
specify extension add --dev "$SQUADS/extensions/archive"
specify extension add --dev "$SQUADS/extensions/autopilot"
specify extension add --dev "$SQUADS/extensions/git"
specify extension add --dev "$SQUADS/extensions/progress"
specify extension add --dev "$SQUADS/extensions/review"
specify extension add --dev "$SQUADS/extensions/stale-tasks-guard"

# presets
specify preset add --dev "$SQUADS/presets/claude-ask-questions"
specify preset add --dev "$SQUADS/presets/explicit-task-dependencies"
specify preset add --dev "$SQUADS/presets/graphify-on-implement"
specify preset add --dev "$SQUADS/presets/functional-constitution"
specify preset add --dev "$SQUADS/presets/spec-minimal"
specify preset add --dev "$SQUADS/presets/spec-ui-preview"
specify preset add --dev "$SQUADS/presets/library-research"
specify preset add --dev "$SQUADS/presets/portfolio-audit"
specify preset add --dev "$SQUADS/presets/worktree-isolation"
specify preset add --dev "$SQUADS/presets/implement-prelude-skills"
specify preset add --dev "$SQUADS/presets/parse-dont-validate"
specify preset add --dev "$SQUADS/presets/progress-report"
```

Or use the bundled script from inside the checkout:

```bash
./install.sh /path/to/your/spec-kit-project
./install.sh --force /path/to/your/spec-kit-project   # reinstall everything
```

`--dev` records this checkout as the install source, but it does **not** symlink: `specify` copies the
directory into the project (`shutil.copytree`) for both presets and extensions. Edits made here are
therefore **not** picked up live — re-run `./install.sh --force <project>` to refresh a consumer.

`install.sh` first runs `check-cli-usage.sh`, which verifies every `specify <verb>` a
command file tells an agent to execute against the installed CLI's actual verbs, and
aborts the install if one doesn't exist.

`install.sh` and `uninstall.sh` auto-discover every `extensions/*/extension.yml`, so new commands are included automatically once their manifest exists.

**Migrating from `spec-minimal` 1.x:** 2.0.0 is breaking — `spec-minimal` now only strips spec sections and holds the plan tree. The UI preview moved to the separate `spec-ui-preview` preset, and issue sync moved into the `git` extension. Install both to keep the 1.x behavior.

## Authoring

Edit the manifest (`extension.yml` / `preset.yml`) and the files under `commands/`, `templates/`, or `scripts/` in place. Because installs are copies rather than symlinks, re-run `./install.sh --force <project>` (or the matching `specify ... add --dev`) in any consuming project after *any* change — command text and scripts included, not just manifests.

### Preset composition: `wrap` vs `replace`

A preset's command template declares `strategy: "wrap"` (composes with other presets on the same command, via a `{CORE_TEMPLATE}` seam that expands to the next inner layer) or `strategy: "replace"` (fully owns the command body). **`replace` is the default when `strategy` is omitted** — that default is what made five `/speckit-implement` presets silently inert (issue #25), so declare it explicitly either way.

There is no `replaces:` key. It is not in the preset schema and `PresetManifest._validate()` never reads it, so it looks like it declares intent and does nothing. Use `strategy:`.

`specify` sorts installed presets by **(priority ASC, id ASC)** — lower number = higher precedence. Composition works like this:

- The **base** is the nearest `replace` layer scanning from highest precedence downward. Only layers *above* the base compose at all; anything below it is dead.
- If the highest-precedence layer is itself a `replace`, it short-circuits and wins outright — every other layer is dropped.
- Core templates are always appended as a final `replace` layer, so a stack of pure wrappers still composes over the stock command.
- Wrappers are applied bottom-up, so the **lowest priority number ends up outermost**: its pre-seam text runs first and its post-seam text runs last.

Presets also can't declare lifecycle hooks (`before_*`/`after_*`); only extensions can. So a preset that needs to survive being clobbered by a `replace`-strategy sibling ships a companion extension with lifecycle hooks as a fallback path (see `progress` next to `progress-report`, and `stale-tasks-guard`, which is a standalone extension for exactly this reason).

### The `/speckit-implement` ordering contract

Six presets target `speckit.implement`, so their install priorities are **load-bearing**. `install.sh` passes `--priority` for each; the map lives in `preset_priority()` there and must stay in sync with this table:

| Priority | Preset | Strategy | Role |
|---|---|---|---|
| 5 | `worktree-isolation` | wrap | outermost — the `cd` must precede every write |
| 6 | `graphify-on-implement` | wrap | post-seam `graphify update` lands last |
| 7 | `progress-report` | wrap | dashboard card |
| 8 | `implement-prelude-skills` | wrap | prelude runs just before implementation |
| 9 | `parse-dont-validate` | wrap | discipline + AST gate hug the implementation |
| 20 | `explicit-task-dependencies` | **replace** | the executor base, innermost |

Resulting execution order: worktree `cd` → progress card → prelude skills → parse-don't-validate discipline → **implement** (wave DAG, or the stock loop when `explicit-task-dependencies` isn't installed) → AST scan gate → progress card → `graphify update`.

`explicit-task-dependencies` stays `replace` because it genuinely substitutes wave-DAG subagent fan-out for the stock serial loop — wrapping it would execute every task twice. It sorts last so it becomes the base rather than swallowing the wrappers.

If you install presets by hand rather than via `install.sh`, pass the same `--priority` values or the composition silently degrades.

### The `/speckit-constitution` stack

Two presets inject a governance section into `.specify/memory/constitution.md`, and both are `wrap` (issue #37 — they were both `replace`, so one silently won and the other's section never reached the constitution):

| Priority | Preset | Section |
|---|---|---|
| 9 | `parse-dont-validate` | Parse, Don't Validate |
| 10 | `functional-constitution` | Functional Programming Paradigms |

Each layer runs the core flow, then edits the written constitution in place to enforce its own section. Two rules keep them from fighting:

- **Idempotency matches on the section title, not its roman numeral** — so a section stays recognized after renumbering.
- **Every layer renumbers all numbered principle sections sequentially** in document order after inserting. The numeral in a preset's canonical text is a placeholder; the outermost layer runs last and leaves the document consistently numbered.
- **Every layer repeats the core flow's bookkeeping if it changed anything.** The core flow does its version bump, Sync Impact Report, validation, and user summary *before* any wrapper runs, so a section injected afterwards is invisible to all of it. Each layer re-derives the version (added principle = `MINOR`, body-only edit = `PATCH`), amends the Sync Impact Report, and corrects the reported version — **bumping at most once per run**, so two presets each adding a principle produce one `MINOR` bump, not two.

A new preset that injects a constitution section should follow the same three rules.
