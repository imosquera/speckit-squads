---
description: "Hook target fired at before_implement: halts /speckit-implement when spec.md is newer than tasks.md (a late /speckit-clarify or /speckit-specify edit that invalidated the task plan), unless --force is present. Runs via a lifecycle hook so it fires regardless of which preset owns the /speckit-implement command body."
---

## Stale-Tasks Guard (lifecycle hook — before_implement)

The `before_implement` hook invoked this command before the `/speckit-implement` body
runs, so this guard applies no matter which preset owns that body. Hook targets do not
receive the triggering command's `$ARGUMENTS` — check the arguments the user actually
typed on the `/speckit-implement` invocation still visible earlier in this conversation.

If `--force` appears anywhere in those arguments, log
`⚠️ Stale-tasks guard skipped (--force)` and skip the rest of this section.

1. **Resolve `FEATURE_DIR`** from `.specify/feature.json`:
   ```bash
   FEATURE_DIR=$(python3 -c "import json; print(json.load(open('.specify/feature.json'))['feature_directory'])")
   ```

2. **If `tasks.md` or `spec.md` is absent** from `FEATURE_DIR`, skip this guard entirely —
   the implementation loop's existing missing-file handling covers both cases unchanged.

3. **Compare mtimes** (`$FEATURE_DIR` is the shell variable set in step 1 and expands via
   the double-quoted `-c` string):
   ```bash
   python3 -c "
   import os, sys
   spec  = os.path.getmtime('$FEATURE_DIR/spec.md')
   tasks = os.path.getmtime('$FEATURE_DIR/tasks.md')
   if spec > tasks:
       delta = int((spec - tasks) / 60)
       print('⚠️  STALE TASKS DETECTED')
       print(f'   spec.md  was modified {delta}m after tasks.md was last generated.')
       print('   Run /speckit-tasks to reconcile, then re-run /speckit-implement.')
       print('   To bypass: /speckit-implement --force')
       sys.exit(1)
   "
   ```
   Equal mtimes are treated as current (the standard pipeline order — spec, then tasks —
   is a silent no-op).

4. **Check the exit code.** If the command exited non-zero, halt immediately with the
   printed warning and do **not** invoke `/speckit-implement`'s body. No implementation
   code is written until the operator reconciles tasks (`/speckit-tasks`) or opts in with
   `--force`.

## Failure Policy

- A non-zero exit from the mtime check is a hard stop before the implementation loop
  starts — this hook must prevent the `/speckit-implement` body from running at all.
- Missing `spec.md` or `tasks.md` skips the guard; the core command's existing error
  paths for those cases are unchanged.
