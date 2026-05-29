# speckit-squads

A collection of [Spec Kit](https://github.com/github/spec-kit) extensions and presets, packaged for local-dev installation via `specify`.

## Layout

```
extensions/   # Spec Kit extensions (commands + hooks)
  archive/         Archive completed feature folders, close linked GH issues
  git/             Feature-branch workflow, init, PR, auto-commit hooks
  graphify/        Refresh graphify-out/ knowledge graph after specify/implement
  review/          Multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)

presets/      # Spec Kit presets (template + command overrides)
  claude-ask-questions/         Interactive clarify/checklist for Claude
  explicit-task-dependencies/   tasks-template with explicit dependency edges
  lite/                         trim /speckit-specify and /speckit-plan markdown output
  portfolio-audit/              Portfolio-wide analyze override
  ui-preview-in-spec/           specify override that embeds UI previews
  worktree-isolation/           Forces feature commands to run inside their worktree
```

Each item is a self-contained directory with its own `extension.yml` or `preset.yml` manifest, conforming to Spec Kit's schema:

- Extensions: <https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md>
- Presets: <https://github.com/github/spec-kit/blob/main/presets/README.md>

## Install into a project

From any Spec Kit project:

```bash
# extensions
specify extension add --dev ~/Code/speckit-squads/extensions/archive
specify extension add --dev ~/Code/speckit-squads/extensions/git
specify extension add --dev ~/Code/speckit-squads/extensions/graphify
specify extension add --dev ~/Code/speckit-squads/extensions/review

# presets
specify preset add --dev ~/Code/speckit-squads/presets/claude-ask-questions
specify preset add --dev ~/Code/speckit-squads/presets/explicit-task-dependencies
specify preset add --dev ~/Code/speckit-squads/presets/lite
specify preset add --dev ~/Code/speckit-squads/presets/portfolio-audit
specify preset add --dev ~/Code/speckit-squads/presets/ui-preview-in-spec
specify preset add --dev ~/Code/speckit-squads/presets/worktree-isolation
```

`--dev` keeps each install pointed at this source tree, so edits here are picked up without re-adding.

## Authoring

Edit the manifest (`extension.yml` / `preset.yml`) and the files under `commands/`, `templates/`, or `scripts/` in place. After non-trivial changes, re-run the matching `specify ... add --dev` in any consuming project to refresh registered commands.
