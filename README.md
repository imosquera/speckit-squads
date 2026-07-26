# speckit-squads

A collection of [Spec Kit](https://github.com/github/spec-kit) extensions and presets, packaged for local-dev installation via `specify`.

## Layout

```
extensions/   # Spec Kit extensions (commands + hooks)
  archive/         Archive completed feature folders, close linked GH issues
  git/             Feature-branch + worktree + linked GitHub issue (incl. issue sync), clean, PR, auto-commit hooks
  review/          Multi-agent code review (run/code/comments/tests/errors/types/simplify/pr)

presets/      # Spec Kit presets (template + command overrides)
  claude-ask-questions/         Interactive clarify/checklist for Claude
  explicit-task-dependencies/   tasks-template with explicit dependency edges; replaces the implement executor (see Composition order)
  graphify-on-implement/        implement override that always runs graphify update last
  functional-constitution/      constitution override that enforces FP governance
  spec-minimal/                 Artifact minimalism: strips spec sections, keeps the feature tree to spec/plan/tasks
  spec-ui-preview/              GitHub-safe inline HTML UI preview for UI-touching specs
  portfolio-audit/              Portfolio-wide analyze override
  worktree-isolation/           Forces /speckit-implement to run inside feature worktree
  implement-prelude-skills/     Invokes ponytail:ponytail + caveman skills before /speckit-implement starts
  constitution-audit/           Plan + implement overrides requiring a quoted, principle-by-principle constitution audit
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
specify preset add --dev "$SQUADS/presets/explicit-task-dependencies" --priority 50
specify preset add --dev "$SQUADS/presets/graphify-on-implement" --priority 8
specify preset add --dev "$SQUADS/presets/functional-constitution"
specify preset add --dev "$SQUADS/presets/spec-minimal"
specify preset add --dev "$SQUADS/presets/spec-ui-preview"
specify preset add --dev "$SQUADS/presets/portfolio-audit"
specify preset add --dev "$SQUADS/presets/worktree-isolation" --priority 5
specify preset add --dev "$SQUADS/presets/implement-prelude-skills"
specify preset add --dev "$SQUADS/presets/constitution-audit"
```

Or use the bundled script from inside the checkout:

```bash
./install.sh /path/to/your/spec-kit-project
./install.sh --force /path/to/your/spec-kit-project   # reinstall everything
```

`--dev` records this checkout as the install source, but it does **not** symlink: `specify` copies the
directory into the project (`shutil.copytree`) for both presets and extensions. Edits made here are
therefore **not** picked up live — re-run `./install.sh --force <project>` to refresh a consumer.

`install.sh` and `uninstall.sh` auto-discover every `extensions/*/extension.yml`, so new commands are included automatically once their manifest exists. `install.sh` passes `--priority` only for the presets whose layer position is load-bearing (below); everything else takes the CLI default of 10.

## Composition order (`/speckit-implement`)

Five presets layer onto `speckit.implement`. They are **not** independent — they compose into a single command, and the order is set by install priority, not by the manifests. The resolver sorts layers by `(priority, preset-id)` ascending and the **lowest number is the outermost layer**. A `replace` layer becomes the composition base and everything below it is discarded, so the one preset that must stay `replace` has to sit innermost.

| Priority | Preset | Strategy | Role |
| --- | --- | --- | --- |
| 5 | `worktree-isolation` | wrap | `cd` into the worktree before any layer reads files |
| 8 | `graphify-on-implement` | wrap | outermost post-seam step, so the refresh runs last |
| 10 | `constitution-audit` | wrap | post-seam audit of the code just written |
| 10 | `implement-prelude-skills` | wrap | innermost pre-seam step (ponytail + caveman) |
| 50 | `explicit-task-dependencies` | replace | executor base: wave-DAG subagent fan-out |

A wrapper's pre-seam content runs before everything nested inside it and its post-seam content runs after all of it, so pre-seam steps fire outside-in and post-seam steps inside-out:

```
worktree cd → prelude skills → implement (DAG) → constitution audit → graphify refresh
```

`explicit-task-dependencies` stays `replace` because it substitutes the execution model rather than adding to it — wrapping it would run every task twice. Drop it and the stock core template becomes the base; the four wrappers still compose unchanged.

Priorities at equal numbers are broken alphabetically, which is why `constitution-audit` (post-seam) lands outside `implement-prelude-skills` (pre-seam) at the shared default of 10 — both orderings are correct for their seam side, so neither needs an override.

**Migrating from `spec-minimal` 1.x:** 2.0.0 is breaking — `spec-minimal` now only strips spec sections and holds the plan tree. The UI preview moved to the separate `spec-ui-preview` preset, and issue sync moved into the `git` extension. Install both to keep the 1.x behavior.

## Authoring

Edit the manifest (`extension.yml` / `preset.yml`) and the files under `commands/`, `templates/`, or `scripts/` in place. Because installs are copies rather than symlinks, re-run `./install.sh --force <project>` (or the matching `specify ... add --dev`) in any consuming project after *any* change — command text and scripts included, not just manifests.
