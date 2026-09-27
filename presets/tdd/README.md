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

- **Priority 11**: inside `parse-dont-validate` (9), outside the
  `explicit-task-dependencies` executor (20). See the ordering contract in the top-level `README.md`.
- With `explicit-task-dependencies`, a story's test tasks are the Red wave and
  its implementation tasks are Green + Refactor. The wrapper confirms the tests
  fail before the implementation wave starts. Every subagent prompt carries the
  cycle verbatim.

## Gates

- A full suite run after the core flow. It must be green.
- `scripts/ts/check-tests-accompany.ts`: exit 1 when production source
  changed since the merge-base with no test file changed, 2 when it cannot run,
  4 on an empty change set. It only checks that tests came with the change.
  Whether each test went red before green is recorded per scenario in the
  completion report and cannot be checked mechanically.

## Jev assist (optional)

`scripts/ts/jev-judge.ts` answers the cycle's four bounded judgment calls with
Jev, TypeSafe's System One model, through `@typesafe-ai/sdk` (issue #116):

| Command | Question | Decides when |
|---|---|---|
| `red-reason` | Did the new test fail for the expected reason? (Choice) | confidence ≥ 0.85, not `none_of_these`, and `TDD_JEV_AUTOMATE_RED=1` |
| `baseline` | Was this failing test passing at baseline? (Noul) | p ≥ 0.85 (regression) or ≤ 0.15 (not ours) |
| `covers` | Does this test exercise this scenario? (Noul) | always; < 0.85 flags the pair in the report |
| `exempt` | Is this file untestable? (Noul) | always; < 0.85 refuses the exemption |

Exit 0 means act on the decision; exit 3 means decide exactly as the preset
did before Jev. That covers no `TYPESAFE_API_KEY`, no SDK, any API error, a
low-confidence answer, and `red-reason` in shadow mode. Every call's answer
and confidence go into the per-scenario record.

`red-reason` stays in shadow mode (logs, never decides) until
`TDD_JEV_AUTOMATE_RED=1`. Turn it on only after
`bun jev-judge.ts measure --records past-reds.jsonl` reports a good agreement
rate and confident share over past Red records
(`{scenario, test, output, label}` per line).

The key is read from `TYPESAFE_API_KEY` by the SDK and nowhere else.
`scripts/ts/post-install.ts` installs the SDK with bun into
`~/.cache/speckit-squads/tdd-jev`, not the project or `.specify/`, which
consumers commit. The helper prefers a project's own copy.

## Runtime

Everything in this preset is TypeScript run by bun. Consumers need bun on
`PATH`.

`bun scripts/ts/selftest-tdd.ts` is the check: the gate, the Jev fallback
path, and a fixture per use case against a fake Jev server.
