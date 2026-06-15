# speckit-squads — agent guide

This repo is the source of truth for a personal set of Spec Kit extensions and presets. Consumer projects (e.g. `~/Code/beadbits`) install from here via `specify ... add --dev`.

## Layout

```
extensions/<id>/   extension.yml + commands/ + scripts/
presets/<id>/      preset.yml    + commands/ + templates/
install.sh         install every extension+preset into a Spec Kit project
uninstall.sh       remove every extension+preset from a Spec Kit project
```

## Install / uninstall

Both scripts auto-discover every directory under `extensions/` and `presets/` that contains a manifest — there is **no hardcoded list to maintain**.

Both require a `<project-dir>` argument — there is no implicit `$PWD` default, so you can't accidentally install into the wrong place.

```bash
./install.sh /path/to/spec-kit-project
./uninstall.sh /path/to/spec-kit-project
```

Every install uses `specify ... add --dev <repo-path>`, which keeps the project's `.specify/extensions/<id>/` and `.specify/presets/<id>/` pointed at this repo's source tree. Edits to command files, scripts, or templates here are picked up live — no reinstall step. `install.sh` therefore treats "already installed" as a no-op success.

The one case where a registry refresh is required: changes to a manifest itself (`extension.yml` / `preset.yml`) — adding a new command, renaming the id, changing hooks. For that, run `./install.sh --force <project>`.

`uninstall.sh` only de-registers items from the target project; it never touches the source files in this repo.

## Currently shipped

<!-- AGENT: keep this list in sync with the directories under extensions/ and presets/. Regenerate by running:
  ls -1 extensions/*/extension.yml presets/*/preset.yml | sed 's|/[^/]*\.yml$||'
-->

**Extensions**
- `archive` — archive a completed feature folder, close linked GitHub issues
- `git` — feature branches, worktree+clean, PR, auto-commit hooks across all phases
- `review` — multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)

**Presets**
- `claude-ask-questions` — interactive clarify/checklist for Claude
- `explicit-task-dependencies` — `tasks-template` with explicit dependency edges + Execution Wave DAG; overrides `/speckit-implement` to fan each wave's `[P]` tasks out to subagents in parallel
- `graphify-on-implement` — `/speckit-implement` override that always runs `graphify update` as the final mandatory step
- `functional-constitution` — `/speckit-constitution` override that always injects and normalizes a mandatory functional-programming governance section
- `spec-minimal` — composable wrapper for `/speckit-specify` (drops Assumptions + Key Entities + Success Criteria, adds UI preview for UI-touching specs, and syncs the issue) and `/speckit-plan` (skips `data-model.md`, `quickstart.md`, `contracts/`)
- `portfolio-audit` — portfolio-wide `/speckit-analyze` override
- `worktree-isolation` — forces `/speckit-implement` to run inside the feature worktree
- `implement-prelude-skills` — `/speckit-implement` override that invokes `ponytail:ponytail` and `caveman` skills (when available) as a mandatory prelude before implementation begins

## When you add a new extension or preset

1. Drop the new directory under `extensions/<id>/` or `presets/<id>/` with a valid manifest. The install/uninstall scripts will pick it up automatically — do **not** edit them.
2. Update the **Currently shipped** list above with one bullet: `` `<id>` — one-line description ``.
3. Update the matching list in `README.md` so the user-facing doc stays in sync.
4. If a consumer project should pick it up, run `./install.sh <project>` from there.

## When you remove an extension or preset

1. `rm -rf extensions/<id>` or `presets/<id>`.
2. Delete its bullet from **Currently shipped** above and from `README.md`.
3. Run `./uninstall.sh <project>` in any consumer that still has it registered, or `specify {extension,preset} remove <id>` ad-hoc.

## Manifest references

- Extension dev guide: <https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md>
- Extension API: <https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-API-REFERENCE.md>
- Preset architecture: <https://github.com/github/spec-kit/blob/main/presets/ARCHITECTURE.md>
- Preset README: <https://github.com/github/spec-kit/blob/main/presets/README.md>
