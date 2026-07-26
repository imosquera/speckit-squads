---
description: "Execute /speckit-implement, but first cd into the feature's dedicated git worktree resolved from .specify/feature.json (BeadBits Constitution v2.3.0 Principle VII, Feature-Work Isolation)."
argument-hint: "Optional implementation guidance or task filter"
compatibility: "Requires spec-kit project structure with .specify/ directory"
metadata:
  author: "beadbits"
  source: ".specify/presets/worktree-isolation/commands/speckit.implement.md"
user-invocable: true
disable-model-invocation: false
---

## Behavior

Execute the canonical `/speckit-implement` flow, but **only after** the agent's
cwd has been moved into the feature's dedicated worktree.

### 0. cd into the feature's worktree (MANDATORY — Principle VII)

Per BeadBits Constitution v2.3.0 Principle VII (Feature-Work Isolation),
`/speckit-implement` MUST execute with the agent's cwd set to the feature's
worktree. This step runs **before** any filesystem read or write performed by
the rest of this command — including anything the inner flow does.

1. Read `.specify/feature.json` (relative to the current cwd). If the file
   is missing or cannot be parsed as JSON, ERROR with:
   "Cannot resolve feature: .specify/feature.json is missing or malformed.
   Run /speckit-specify to (re)initialize a feature."
   Do NOT proceed.

2. Let `WT = feature.json.worktree_path`.

3. If `WT` is null or the field is absent:
   Emit a single-sentence warning:
   "This feature has no recorded worktree_path (likely created before
   Constitution v2.3.0). Proceeding in the current cwd; Principle VII
   isolation is not enforced for this invocation."
   Then proceed in the current cwd. Skip steps 4–6.

4. If `WT` is non-null but the directory does NOT exist on disk:
   The recorded path is machine-local (e.g. created in another clone or by
   another author) and is meaningless here. Emit a single-sentence warning:
   "Recorded worktree_path '<WT>' does not exist on disk (likely a path from
   another clone). Proceeding in the current cwd; Principle VII isolation is
   not enforced for this invocation."
   Then proceed in the current cwd. Skip steps 5–6.

5. If `WT` is non-null, exists on disk, and matches the current cwd
   (resolved to absolute path), proceed silently — no cd needed.

6. Otherwise (`WT` is non-null, exists, and differs from cwd):
   Prefix every subsequent shell invocation in this command with
   `cd "<WT>" && ...` so the cd is visible in the session log. All
   filesystem writes performed by the rest of this command land inside
   the worktree. Do not silently rely on tools that ignore cwd
   (absolute-path file writers) as a substitute — the cd MUST appear
   in the session log for post-hoc isolation auditing.

### End cd-block (Principle VII enforcement complete)

### 1. Core implement flow

Everything below runs with the cwd established above. The core-flow seam that
follows expands to the next inner layer — any other presets wrapping
`/speckit-implement` (this preset is installed at the lowest priority number so
it is the outermost layer) and ultimately the canonical implement flow. Those
inner layers therefore read and write files inside the worktree, not the
original cwd.

{CORE_TEMPLATE}

## Rationale

The substantive behaviour this layer adds beyond the canonical
`/speckit-implement` flow is:

1. Reading `worktree_path` from `.specify/feature.json` at the cwd.
2. `cd`-ing into that path before any filesystem write performed by the inner flow.
3. Falling back to the current cwd (with a warning) when the recorded worktree
   directory does not exist on disk — because `worktree_path` is a machine-local
   absolute path committed to `.specify/feature.json`, a fresh clone would
   otherwise abort on a path it can never have.

A missing worktree directory degrades to the current cwd rather than erroring,
so implementation stays portable across clones.
