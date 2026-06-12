# speckit-squads

A collection of [Spec Kit](https://github.com/github/spec-kit) extensions and presets, packaged for local-dev installation via `specify`.

## Layout

```
extensions/   # Spec Kit extensions (commands + hooks)
  archive/         Archive completed feature folders, close linked GH issues
  git/             Feature-branch + worktree + linked GitHub issue, clean, PR, auto-commit hooks
  review/          Multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)

presets/      # Spec Kit presets (template + command overrides)
  claude-ask-questions/         Interactive clarify/checklist for Claude
  explicit-task-dependencies/   tasks-template with explicit dependency edges
  graphify-on-implement/        implement override that always runs graphify update last
  functional-constitution/      constitution override that enforces FP governance
  spec-minimal/                 composable wrapper for /speckit-specify and /speckit-plan, with UI preview support
  portfolio-audit/              Portfolio-wide analyze override
  worktree-isolation/           Forces /speckit-implement to run inside feature worktree
```

Each item is a self-contained directory with its own `extension.yml` or `preset.yml` manifest, conforming to Spec Kit's schema:

- Extensions: <https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md>
- Presets: <https://github.com/github/spec-kit/blob/main/presets/README.md>

## Install into a project

Set `SQUADS` to wherever you checked out this repo, then run the commands from any Spec Kit project:

```bash
export SQUADS=/path/to/your/speckit-squads   # adjust to your checkout

# extensions
specify extension add --dev "$SQUADS/extensions/archive"
specify extension add --dev "$SQUADS/extensions/git"
specify extension add --dev "$SQUADS/extensions/review"

# presets
specify preset add --dev "$SQUADS/presets/claude-ask-questions"
specify preset add --dev "$SQUADS/presets/explicit-task-dependencies"
specify preset add --dev "$SQUADS/presets/graphify-on-implement"
specify preset add --dev "$SQUADS/presets/functional-constitution"
specify preset add --dev "$SQUADS/presets/spec-minimal"
specify preset add --dev "$SQUADS/presets/portfolio-audit"
specify preset add --dev "$SQUADS/presets/worktree-isolation"
```

Or use the bundled script from inside the checkout:

```bash
./install.sh /path/to/your/spec-kit-project
./install.sh --force /path/to/your/spec-kit-project   # reinstall everything
```

`--dev` keeps each install pointed at this source tree, so edits here are picked up without re-adding.

`install.sh` and `uninstall.sh` auto-discover every `extensions/*/extension.yml`, so new commands are included automatically once their manifest exists.

## Authoring

Edit the manifest (`extension.yml` / `preset.yml`) and the files under `commands/`, `templates/`, or `scripts/` in place. After non-trivial changes, re-run the matching `specify ... add --dev` in any consuming project to refresh registered commands.
