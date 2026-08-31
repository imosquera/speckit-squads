---
description: "Wraps /speckit-git-feature: after the branch, worktree, and tracking issue exist, classify the feature by layer — and when it spans both the UI and the API, make this feature the frontend mock (static fixtures, no network) and file the backend and wire-up siblings beside it."
---

## Layer policy — read this before creating anything

This project does not start a feature that touches both the UI and the API as one
unit of work. Two rules govern everything below:

1. **Frontend and backend are separate issues.** They are different work with
   different reviewers, and a combined issue means the UI only appears at the end,
   wired to an API nobody has looked at.
2. **The frontend is always built as a mock first.** Static in-repo fixtures, **no
   network calls at all** — no `fetch`, no API client, no MSW handler, no live
   endpoint. The mock starts immediately, is reviewable on its own, and freezes the
   data shape the backend then implements.

Rule 2 decides the shape of the split at this point in the cycle. Create the feature
exactly as the core command does — then, if it is full-stack, **this feature becomes
the frontend mock** and its siblings are filed for later. The branch, worktree, and
issue number the core command just created all stay as they are.

{CORE_TEMPLATE}

## Classify the feature

You have the user's feature description and, now, a tracking issue. You do **not**
have a spec — `/speckit-specify` has not run yet — so classify from the description
and from anything the user said in this turn:

| The description asks for | Layer |
|---|---|
| A screen, a component, a view, interaction, styling, client-side state | frontend |
| An endpoint, schema, migration, job, auth check, business rule, external call | backend |
| Both of the above | **full-stack → split** |
| Neither (tooling, docs, CI, a library with no UI and no API) | no layer |

When the description is too thin to judge and a human is in the loop, ask — one
`AskUserQuestion` with `Full-stack`, `Frontend only`, `Backend only`, `Neither`, led
by your best reading marked `(Recommended)`. When nobody is in the loop, infer, and
say in your output that you inferred rather than asked.

### Single layer, or none

No split. Label the tracking issue and stop:

```bash
LABEL="$CLAUDE_PROJECT_DIR/.specify/presets/frontend-mock-first/scripts/bash/label-issue.sh"
bash "$LABEL" <issue-number> --layer backend
bash "$LABEL" <issue-number> --layer frontend --mock-first   # only if the API it needs does not exist yet
```

A frontend feature consuming an API that **already exists** is `--layer frontend` but
**not** `--mock-first` — there is nothing to mock, and the label would ask an
implementer to build fixtures against a live endpoint.

### Already split

A feature created from an existing backend or wire-up sibling already carries a layer
label, and a frontend one already lists its siblings. Never re-split:

```bash
SPLIT="$CLAUDE_PROJECT_DIR/.specify/presets/frontend-mock-first/scripts/bash/split-layers.sh"
bash "$SPLIT" <issue-number> --show     # prints "<layer> <number>" per sibling
```

## Full-stack: this feature is the frontend mock

Write the backend requirements — everything from the description that is *not* UI — to
a file, then run the splitter. Do **not** open the siblings with a hand-rolled
`gh issue create`: the script owns the titles, the `Blocked by:` line, the sibling
block, and every label.

```bash
SPLIT="$CLAUDE_PROJECT_DIR/.specify/presets/frontend-mock-first/scripts/bash/split-layers.sh"
bash "$SPLIT" <issue-number> \
  --title "<feature title, no layer prefix>" \
  --backend-body /tmp/be.md \
  [--integration-body /tmp/int.md] \
  [--priority p1] [--kind feature]
```

What it does, so you do not reimplement any of it:

- Relabels **this** issue `frontend` + `mock-first`. It keeps its number, branch, and
  worktree — the numbering contract that ties branch, spec, and issue together is
  untouched.
- Files `backend: <title>` and `wire-up: <title>` as siblings.
- Writes `Blocked by: #<frontend>, #<backend>` into the wire-up sibling, which
  autopilot's picker reads — it will not start that one until both close.
- Appends a `<!-- speckit:layer-siblings -->` block to this issue's body listing the
  siblings, and is idempotent through it: a re-run edits those two issues rather than
  opening a second pair.

### What the backend sibling's body must say

- The endpoints, schema, and rules — stated against **the same field names the
  fixtures will use**, because that is the contract the mock is about to freeze.
- Explicitly out of scope: any UI change. A backend PR that touches components is
  this split failing.

## Then: build this feature as a mock

Everything downstream of here — `/speckit-specify`, `/speckit-plan`, `/speckit-tasks`,
`/speckit-implement` — is scoped to the **frontend mock only**. Carry these constraints
into the spec you are about to write:

- Fixture module(s) with a concrete data shape: field names and types. This is the
  contract the backend sibling implements, so vagueness here costs a rewrite later.
- Every state rendered from fixtures: populated, empty, loading, error.
- No network calls, no API client, no server dependency. The feature must be fully
  exercisable with the backend absent.
- A way to demonstrate it — a route, a story, a screenshot — so the mock is reviewable
  on its own.

Report in one line: the layer verdict, and either the two sibling numbers or why no
split was warranted.
