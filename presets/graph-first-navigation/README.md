# graph-first-navigation

Make knowledge-graph queries and the TypeScript language server the default way
an agent navigates a codebase. Grep is demoted to a stated fallback, not
forbidden.

## The problem

In a repo containing `graphify-out/`, agents still reach for Grep/Glob to answer
structural questions — who calls this function, what imports this type, which
modules read this collection. The graph stores those edges definitively, having
been built by parsing rather than text matching, so grep is the slower and
noisier instrument for exactly the questions the graph exists to answer. The
same gap exists for the language server: agents run `tsc --noEmit` in a loop to
discover breakage that `findReferences` would have enumerated before the first
edit.

## Why a new preset, not an extension of `implement-prelude-skills`

`implement-prelude-skills` was read first, as the closest existing seam. It does
not stretch:

- It is registered against **`speckit.implement` only**. This obligation spans
  `speckit.plan` and `speckit.tasks` as well — the plan is where callers and
  dependents have to be recorded, and it is upstream of implementation.
- Its one job is *loading skills* before implementation, and it says so in its
  own wrapper text. Folding a navigation discipline, a freshness gate, and an
  LSP requirement into it would make "prelude skills" a lie and leave one file
  that two unrelated concerns have to share.
- The load-bearing half of this feature is a **harness** hook, not a Spec Kit
  layer at all. It needs its own `post-install.sh`; bolting that onto the
  prelude preset would mean uninstalling the prelude also unregisters an
  unrelated hook.

So: a separate preset, three thin wrappers, one shared script directory.

## What it installs

| Piece | Where it lands | What it does |
| --- | --- | --- |
| `scripts/python/graph_first_guard.py` | `.specify/presets/graph-first-navigation/` | PreToolUse hook body |
| `.claude/settings.json` entry | consumer project | fires the guard on `Grep\|Glob` |
| `CLAUDE.md` block | consumer project | the standing rule, sentinel-delimited |
| `commands/speckit.{plan,tasks,implement}.md` | preset templates | the phase obligations |
| `scripts/bash/graph-freshness.sh` | `.specify/presets/graph-first-navigation/` | the staleness verdict |

The hook and the CLAUDE.md block are written by `scripts/bash/post-install.sh`,
which `install.sh` runs after registering the preset, and removed by
`scripts/bash/pre-uninstall.sh`, which `uninstall.sh` runs before removing it.
Both are idempotent and re-runnable. `specify` has no reach into the Claude Code
harness — a preset cannot declare a PreToolUse hook and an extension's `hooks:`
block covers only Spec Kit lifecycle phases — so this is the only available
seam.

## The hook is designed to be survivable

A hook that cries wolf gets disabled within a day. This one:

- **fires only when `graphify-out/graph.json` exists.** No graph, no reminder.
- **never blocks.** It emits no `permissionDecision`, so the search runs exactly
  as it would have. The agent is redirected, not stopped.
- **fires only on structurally-shaped patterns.** A Grep pattern containing
  whitespace, a quote, or `://` is a literal-string search and is left alone, as
  is any search already scoped to non-code files. A pattern has to look like an
  identifier to trip it. Glob trips only on source-code extensions.
- **states what to use instead and when grep is still right**, so the redirect is
  actionable rather than nagging.
- **spends a budget of 3 reminders per session** and then goes quiet.
- **exits 0 silently on any internal error.** A broken guard must never
  interfere with a working search.

## The staleness rule

This is the one real failure mode, and the only legitimate reason to break the
rule. A graph is built against a commit; a feature worktree diverges from it.
Before trusting a negative answer — "nothing else reads this" — run:

```bash
.specify/presets/graph-first-navigation/scripts/bash/graph-freshness.sh .
```

`FRESH` (exit 0), `STALE` (1), `ABSENT` (2). **A stale graph means rebuild it
(`graphify update`), not fall back to grep.** Every wrapper says so, and the
hook prints the built-commit / HEAD divergence when it detects one.

## When grep remains correct

A rule with no stated exceptions gets ignored wholesale the first time it is
wrong. Grep is the right instrument for:

- literal string searches, and comment, log, or prose text
- config values, env-var names, and anything inside `.env`/`.yml`/`.json`
- generated, vendored, or minified files
- languages and file formats the graph does not model
- confirming an exact textual occurrence at a site the graph or LSP already
  identified
- any project with no `graphify-out/` at all

## Composition

`speckit.implement` is targeted by six other presets; the ordering contract
lives in the repo `README.md` and in `install.sh`'s `preset_priority()` map.
This preset installs at **priority 12** — innermost of the wrappers, so its
scoping pass sits closest to the first edit, and outside only the
`explicit-task-dependencies` executor base at 20. It is deliberately *not*
slotted at 9: that number belongs to `parse-dont-validate`, whose priority also
orders the `/speckit-constitution` pair, and moving it would flip that pair for
no benefit here.

On `speckit.tasks`, `explicit-task-dependencies` **replaces** the body. This
preset's priority 12 sorts above that layer's 20, so it composes on top of the
replacement rather than being killed by it.
