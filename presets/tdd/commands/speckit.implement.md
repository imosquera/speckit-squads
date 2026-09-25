---
description: "Composable wrapper for /speckit-implement that drives every task through Red-Green-Refactor and gates completion on a green suite with tests accompanying every production change."
strategy: "wrap"
---

## Wrapper Layer

This preset wraps `/speckit-implement` (and any inner wrapper the core-flow seam
expands to). It changes **how** each task's code gets written: test first, one
scenario at a time. It does not change which tasks run or in what order.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

### Before the first task — find the test command (MANDATORY)

Read `plan.md` and the project's manifests (`package.json`, `pyproject.toml`,
`go.mod`, `Cargo.toml`, `Makefile`, …) and settle on the **one command that runs
the whole suite**. Run it once now and record the baseline: how many tests, and
which ones (if any) already fail. A test failing at baseline is not yours to fix
and must not be mistaken for your Red later.

If the project has no test harness, setting up the smallest one the ecosystem
uses by default (`pytest`, `vitest`/`node --test`, `go test`, …) is the first
piece of work. A change that is genuinely untestable (docs, pure config, a
generated file) is exempt — say which files and why in the completion report.

### The cycle (MANDATORY for every task that changes behaviour)

**The TDD Cycle** — this block is copied verbatim into every subagent prompt
the core flow dispatches (see *Subagents* below):

> 1. **List the scenarios.** Before any code, write down the variants of the
>    behaviour this task asks for: the basic case, then each what-if — the
>    dependency times out, the key isn't there yet, the input is empty, the
>    caller lacks permission. Take them from the task line, `spec.md`'s user
>    stories and acceptance scenarios, and `plan.md`. This list is the
>    requirement; code comes after it.
> 2. **Red — write one test for one scenario.** Small, automated, and it would
>    pass only if that scenario's behaviour exists.
> 3. **Run the whole suite. The new test must fail, for the expected reason.**
>    Expected: an assertion that the behaviour is missing, or the symbol under
>    test not existing yet. Not expected: a syntax error, a broken import in the
>    test file, a misconfigured harness — fix those and run again, they are not
>    Red. A new test that **passes immediately** is flawed or the behaviour
>    already exists: find out which before going on. Never count it as Red.
> 4. **Green — write the simplest code that passes the new test.** Hard-coding
>    and inelegance are allowed; step 6 cleans them up. Add no code beyond what
>    the tests exercise.
> 5. **Run the whole suite. Everything must pass** — the new test and every test
>    that passed at baseline. If something fails, fix it with the smallest
>    change. If you are debugging instead of fixing, revert to the last green
>    state and take a smaller step.
> 6. **Refactor — test code and production code, with the suite green.** Remove
>    hard-coded test data from production code, remove duplication, make names
>    self-documenting, move code to where it belongs, split long functions. Run
>    the suite after **each** refactor. Refactor only what this cycle wrote or
>    directly touched; that is not an opportunistic refactor.
> 7. **Repeat from step 2** with the next scenario until the list is done.
>
> Keep each test small and commit at each green-and-refactored point, so a
> broken step is reverted rather than debugged. Test **your** code, not the
> libraries it uses: a test that only proves the library works adds nothing,
> unless there is a stated reason to distrust that library.
>
> For every scenario, keep a one-line record: `scenario — test name — the Red
> failure line — green`. Report it back with your result.

### Tasks that are already split into test and code

When `tasks.md` gives a story separate test tasks and implementation tasks
(the `explicit-task-dependencies` template does), the split **is** the cycle,
spread over two waves:

- A **test task** is Red. When it finishes, run the suite and confirm its tests
  fail for the expected reason **before** the wave holding the implementation
  tasks starts. A test that already passes stops the run: the task plan and
  the code disagree, and that is a finding to report, not to paper over.
- An **implementation task** is Green then Refactor, against those tests. Each
  scenario it covers that has no test yet still goes through the full cycle.

### Subagents

When the core flow dispatches tasks to subagents, every subagent prompt MUST
include **The TDD Cycle** block above verbatim, plus the suite command and the
baseline failures from the first step. A subagent that reports back without its
per-scenario record has not shown Red, and its task is not done.

### Core Flow

{CORE_TEMPLATE}

### Completion gate (MANDATORY — after the core flow)

1. Run the whole suite. Every test that passed at baseline, and every test this
   run added, must pass. A red suite is an incomplete run.
2. Check that the change set carries tests:

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
"$PROJECT_DIR/.specify/presets/tdd/scripts/bash/check-tests-accompany.sh"
```

Run it from the feature worktree; it resolves its own root and base
(`--base <ref>` overrides). Handle the exit code:

- **`0`**: production changes are accompanied by test changes. Proceed.
- **`1`**: production source changed with no test file changed. Go back and run
  the cycle for the listed files. The one way past it is the exemption above,
  named file by file in the report. A missing test is not an exemption.
- **`2`**: the check could not run (no base, not a worktree). Fix the cause and
  re-run; never read this as a pass.
- **`4`**: nothing changed. Proceed only if this run truly wrote no code.

## Completion Report

On success, include:

- The suite command, and the baseline and final test counts.
- The per-scenario records (`scenario — test — Red failure — green`), grouped
  by task.
- Any test that passed on first run and what that turned out to mean.
- Exempt files, each with its reason.
- The `check-tests-accompany.sh` result.
