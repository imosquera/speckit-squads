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

Every install uses `specify ... add --dev <repo-path>`. **`--dev` records this repo as the install source; it does not symlink.** Verified in the installed specify-cli:

- `PresetManager.install_from_directory()` (`specify_cli/presets/__init__.py`) ends in `shutil.copytree(source_dir, dest_dir)` — there are no symlink calls anywhere in the preset module.
- `ExtensionManager.install_from_directory()` (`specify_cli/extensions/__init__.py`) likewise does `shutil.copytree(source_dir, dest_dir, ignore=ignore_fn)`. The only `os.symlink` in that module is for rendered *agent skill* files in dev mode, not for the extension tree itself.
- On disk, both `.specify/presets/<id>/` and `.specify/extensions/<id>/` in a consumer (checked: `~/Code/adkit`) are plain directories timestamped at last install, not symlinks.

**Consequence: edits made in this repo are NOT picked up live.** Any change — command markdown, scripts, templates, or the manifest — requires a refresh in the consumer:

```bash
./install.sh --force /path/to/spec-kit-project
```

Plain `./install.sh <project>` treats "already installed" as a no-op success, so it will **not** propagate edits. Use `--force` whenever you have changed anything here.

`uninstall.sh` only de-registers items from the target project; it never touches the source files in this repo.

## Currently shipped

<!-- AGENT: keep this list in sync with the directories under extensions/ and presets/. Regenerate by running:
  ls -1 extensions/*/extension.yml presets/*/preset.yml | sed 's|/[^/]*\.yml$||'
-->

**Extensions**
- `archive` — archive a completed feature folder, close linked GitHub issues
- `git` — feature branches + worktree + linked GitHub issue (numbered to match the spec), issue sync via `speckit.git.issue` on the `after_specify` hook, clean, PR, auto-commit hooks across all phases
- `review` — multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)

**Presets**
- `claude-ask-questions` — interactive clarify/checklist for Claude
- `explicit-task-dependencies` — `tasks-template` with explicit dependency edges + Execution Wave DAG; overrides `/speckit-implement` to fan each wave's `[P]` tasks out to subagents in parallel
- `graphify-on-implement` — `/speckit-implement` override that always runs `graphify update` as the final mandatory step
- `functional-constitution` — `/speckit-constitution` override that always injects and normalizes a mandatory functional-programming governance section
- `spec-minimal` — one job: artifact minimalism. Wraps `/speckit-specify` to strip `## Assumptions`, `### Key Entities`, and `## Success Criteria` from `spec.md`; wraps `/speckit-plan` to hold the feature tree to `spec.md`, `plan.md`, `tasks.md`, and optional `quickstart.md` (`research.md`, `data-model.md`, `contracts/` are forbidden). Enforced by a mandatory prompt rule plus the self-healing `scripts/bash/enforce-minimal-tree.sh`, which folds any forbidden artifact into `plan.md` under a sentinel block and deletes it; unknown top-level entries only warn, so stacking is safe
- `spec-ui-preview` — adds a GitHub-safe inline HTML UI preview to UI-touching specs (split out of `spec-minimal`)
- `portfolio-audit` — portfolio-wide `/speckit-analyze` override
- `worktree-isolation` — forces `/speckit-implement` to run inside the feature worktree
- `implement-prelude-skills` — `/speckit-implement` override that invokes `ponytail:ponytail` and `caveman` skills (when available) as a mandatory prelude before implementation begins
- `constitution-audit` — overrides `/speckit-plan` and `/speckit-implement` to require a quoted, principle-by-principle audit of `.specify/memory/constitution.md` before code is written

`spec-minimal` 2.0.0 is a breaking split: UI preview → `spec-ui-preview`, issue sync → the `git` extension. See the migration note in `README.md`.

## When you add a new extension or preset

1. Drop the new directory under `extensions/<id>/` or `presets/<id>/` with a valid manifest. The install/uninstall scripts will pick it up automatically — do **not** edit them.
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
