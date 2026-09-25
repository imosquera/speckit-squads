# tdd

Wraps `/speckit-implement` in the Red-Green-Refactor cycle.

For every task that changes behaviour, the implementer first lists the
scenarios (the basic case plus each what-if), then for each one:

1. **Red**: write one test, run the whole suite, and watch the new test fail
   for the expected reason. A test that passes straight away is flawed or the
   behaviour already exists. It never counts as Red.
2. **Green**: write the simplest code that passes it. Hard-coding is fine here.
3. **Refactor**: clean up test and production code, running the suite after
   each change.

Commits are small and frequent, so a bad step is reverted rather than debugged.
Tests target the project's own code, not the libraries it calls.

## Composition

- **Priority 11**: inside `parse-dont-validate` (9), outside
  `graph-first-navigation` (12) and the `explicit-task-dependencies` executor
  (20). See the ordering contract in the top-level `README.md`.
- With `explicit-task-dependencies`, a story's test tasks are the Red wave and
  its implementation tasks are Green + Refactor. The wrapper confirms the tests
  fail before the implementation wave starts. Every subagent prompt carries the
  cycle verbatim.

## Gates

- A full suite run after the core flow. It must be green.
- `scripts/bash/check-tests-accompany.sh`: exit 1 when production source
  changed since the merge-base with no test file changed, 2 when it cannot run,
  4 on an empty change set. It only checks that tests came with the change.
  Whether each test went red before green is recorded per scenario in the
  completion report and cannot be checked mechanically.

`scripts/bash/selftest-tdd.sh` is the check for the gate.
