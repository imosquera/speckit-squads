# graph-first-navigation

Make knowledge-graph queries the default way an agent navigates a codebase. Grep is demoted to a stated fallback, not
forbidden.

## The problem

In a repo containing `graphify-out/`, agents still reach for Grep/Glob to answer
structural questions — who calls this function, what imports this type, which
modules read this collection. The graph stores those edges definitively, having
been built by parsing rather than text matching, so grep is the slower and
noisier instrument for exactly the questions the graph exists to answer. The
same gap exists for typed refactors: agents edit blind and run `tsc --noEmit` in
a loop to discover a blast radius that `graphify query "what calls <symbol>"`
would have scoped before the first edit.

A language server used to be part of this preset (LSP `findReferences` before
every TypeScript rename, reached through a `PATH` shim). 2.0.0 dropped it:
TypeScript 7 ships no `tsserver`, which `typescript-language-server` is built
on, and the graph plus one run of the project's typecheck cover the same
ground — the graph scopes the change, the compiler lists every call site the
edit broke. Installing or reinstalling 2.0.0 removes a shim an older version
left on `PATH`, and so does uninstalling.

## Why a new preset, not an extension of `implement-prelude-skills`

`implement-prelude-skills` was read first, as the closest existing seam. It does
not stretch:

- It is registered against **`speckit.implement` only**. This obligation spans
  `speckit.plan` and `speckit.tasks` as well — the plan is where callers and
  dependents have to be recorded, and it is upstream of implementation.
- Its one job is *loading skills* before implementation, and it says so in its
  own wrapper text. Folding a navigation discipline and a freshness gate
  into it would make "prelude skills" a lie and leave one file
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
| `.claude/settings.json` entry | consumer project | fires the guard on `Grep\|Glob\|Bash` |
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

`FRESH` (exit 0), `STALE` (1), `ABSENT` (2), `UNKNOWN` (3). **A stale graph
means rebuild it, not fall back to grep.** Every wrapper says so, and the hook
prints the built-commit / HEAD divergence when it detects one.

Three things keep the gate from crying wolf, which matters because it opens the
plan phase of every unattended run and a gate that always cries stale is one
people route around:

- **No provenance is `UNKNOWN`, not `STALE`.** A graph built before graphify
  recorded `built_at_commit` cannot be compared to anything; that is an
  unanswerable question, not a failed one. It bought a full rebuild at the top
  of every run for nothing. `UNKNOWN` says to carry on and treat only
  *negative* findings as unverified.
- **The remedy always carries the path** — `graphify update <checkout>`, never
  a bare `graphify update`, which rebuilds whichever project the CWD resolves
  to and has already rebuilt the wrong worktree.

- **HEAD past `built_at_commit` is STALE only if code moved too.** The gate
  diffs the built commit against HEAD excluding `graphify-out/`; an empty diff
  means the commits since touched only the graph (typically the commit that
  carries it) and the verdict proceeds to the clean-tree check and `FRESH`. A
  built commit missing from the clone is `UNKNOWN`, not `STALE`.

Whether `graphify-out/` is committed is the repo's call. `post-install.sh`
excludes an **untracked** graph in the repo's `info/exclude`, so a rebuild is
never committed by accident. A **tracked** graph is left tracked and visible —
no exclude, no `skip-worktree` — and an earlier install that hid it is healed.
Hiding it was justified only by the gate calling a committed graph stale by
construction, which it no longer does. `pre-uninstall.sh` removes our exclude
stanza and any `skip-worktree` bits.

The one file that must not be committed is `graphify-out/.graphify_root`: it
holds an absolute checkout path that graphify's post-commit/post-checkout hooks
rebuild, so a committed copy makes every checkout rebuild whichever worktree last
committed it. The gate and `post-install.sh` warn with the fix —
`git rm --cached graphify-out/.graphify_root`, then add it to `.gitignore`
(graphify rewrites it on every build and falls back to the checkout root when it
is absent) — and never untrack it in a consumer themselves.

## When grep remains correct

A rule with no stated exceptions gets ignored wholesale the first time it is
wrong. Grep is the right instrument for:

- literal string searches, and comment, log, or prose text
- config values, env-var names, and anything inside `.env`/`.yml`/`.json`
- generated, vendored, or minified files
- languages and file formats the graph does not model
- confirming an exact textual occurrence at a site the graph already
  identified
- any project with no `graphify-out/` at all

Those are real gaps, not a hedge. Measured against a built graph: a config
file is a node and so are its *keys* (`dependencies` at `web/package.json:L19`),
but **values are not**, and neither are env-var names — every
`import.meta.env.VITE_*` name in that repo resolves to zero nodes, because
property access off `process.env` is not an edge the parser records. There is
no graph query for "where is this exact string".

**But grep locating a literal is the start of the answer, not the end.** Once
it names a file or a symbol, hand off to the graph for what depends on it: a
config value found in one file is rarely read in only that file. The
grep -> graph handoff is the one this table used to describe in only one
direction (graph finds the site, grep confirms the text); it runs both ways.

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
