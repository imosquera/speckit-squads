# speckit-squads

A collection of [Spec Kit](https://github.com/github/spec-kit) extensions and presets, packaged for local-dev installation via `specify`.

## Layout

```
extensions/   # Spec Kit extensions (commands + hooks)
  archive/         Archive completed feature folders, close linked GH issues
  autopilot/       Oldest eligible issue → draft PR, driving the whole pipeline unattended (+ launchd scheduler)
  git/             Feature-branch + worktree + linked GitHub issue, clean, PR, auto-commit hooks
  progress/        before_tasks/before_implement hooks for the progress-report preset (covers the two phases a replace-strategy preset clobbers)
  review/          Multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)
  stale-tasks-guard/  before_implement hook that halts /speckit-implement when spec.md is newer than tasks.md (--force bypasses)

presets/      # Spec Kit presets (template + command overrides)
  claude-ask-questions/         Interactive clarify/checklist for Claude
  explicit-task-dependencies/   tasks-template with explicit dependency edges
  graphify-on-implement/        implement override that always runs graphify update last
  functional-constitution/      constitution override that enforces FP governance
  spec-minimal/                 composable wrapper for /speckit-specify and /speckit-plan, with UI preview support
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

`--dev` keeps each install pointed at this source tree, so edits here are picked up without re-adding.

`install.sh` first runs `check-cli-usage.sh`, which verifies every `specify <verb>` a
command file tells an agent to execute against the installed CLI's actual verbs, and
aborts the install if one doesn't exist.

`install.sh` and `uninstall.sh` auto-discover every `extensions/*/extension.yml`, so new commands are included automatically once their manifest exists.

## Authoring

Edit the manifest (`extension.yml` / `preset.yml`) and the files under `commands/`, `templates/`, or `scripts/` in place. After non-trivial changes, re-run the matching `specify ... add --dev` in any consuming project to refresh registered commands.

### Preset composition: `wrap` vs `replace`

A preset's command template uses `strategy: "wrap"` (composes with other presets on the same command, via a `{CORE_TEMPLATE}` seam that expands to the next inner wrapper) or `strategy: "replace"` / `replaces:` (fully owns the command body). **A `wrap` loses to a `replace`**: if two presets target the same command and one of them replaces it, that preset's body wins outright and any other preset's `wrap` on that command is dropped — it never runs. Presets also can't declare lifecycle hooks (`before_*`/`after_*`); only extensions can. So a preset that needs to survive being clobbered by a `replace`-strategy sibling ships a companion extension with lifecycle hooks as a fallback path (see `progress` next to `progress-report`, and `stale-tasks-guard`, which is a standalone extension for exactly this reason).
