#!/usr/bin/env bash
# Install every extension and preset in this repo into a Spec Kit project
# via `specify ... add --dev`.
#
# --dev records this repo as the install source, but it does NOT symlink:
# `specify` copies the directory into the project (shutil.copytree) for both
# presets and extensions. Edits made here are therefore NOT picked up live.
#
# Plain `./install.sh <project>` treats "already installed" as a no-op success,
# so it will not propagate changes. Run with --force after changing ANYTHING —
# command markdown, scripts, templates, or a manifest — to refresh the target.
#
# Usage:
#   ./install.sh [--force] <project-dir>
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE_REINSTALL=0

PROJECT_DIR=""
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "usage: $(basename "$0") [--force|-f] <project-dir>"
      exit 0
      ;;
    -f|--force)
      FORCE_REINSTALL=1
      ;;
    -*)
      echo "error: unknown flag: $arg" >&2
      echo "usage: $(basename "$0") [--force|-f] <project-dir>" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PROJECT_DIR" ]]; then
        echo "error: only one project-dir may be given" >&2
        exit 2
      fi
      PROJECT_DIR="$arg"
      ;;
  esac
done

if [[ -z "$PROJECT_DIR" ]]; then
  echo "usage: $(basename "$0") [--force|-f] <project-dir>" >&2
  exit 2
fi

if [[ ! -d "$PROJECT_DIR/.specify" ]]; then
  echo "error: $PROJECT_DIR is not a Spec Kit project (.specify/ missing)" >&2
  exit 1
fi

cd "$PROJECT_DIR"

# Pre-flight: every `specify <verb>` a command file tells an agent to run must exist
# in the installed CLI. Catches invented CLI surface before it ships to a project.
"$REPO_DIR/check-cli-usage.sh" || exit 1


shopt -s nullglob

# ---------------------------------------------------------------- priorities
#
# ORDERING CONTRACT for /speckit-implement (issue #25).
#
# `specify` resolves a command by walking installed presets sorted by
# (priority ASC, id ASC) — lower number = higher precedence. For `wrap` layers
# the highest-precedence layer is composed LAST, so it ends up OUTERMOST: its
# pre-seam text runs first and its post-seam text runs last. The composition
# base is the nearest `replace` layer scanning from highest precedence down;
# only layers above the base compose at all.
#
# Six presets target speckit.implement. Without explicit priorities they all sit
# at the default 10 and the alphabetical tie-break decides, which is how
# explicit-task-dependencies came to win outright and silently kill the other
# five (issue #25). These numbers are therefore load-bearing, not cosmetic:
#
#   5  worktree-isolation          outermost — the cd must precede every write
#   6  graphify-on-implement       post-seam `graphify update` lands last
#   7  progress-report             dashboard card wrap
#   8  implement-prelude-skills    prelude runs just before implementation
#   9  parse-dont-validate         discipline + AST gate hug the implementation
#  20  explicit-task-dependencies  `replace` — the executor base, innermost
#
# explicit-task-dependencies must sort LAST so it becomes the base rather than
# swallowing the wrappers. When it is not installed the stock core template is
# the base (core templates are always appended as a final `replace` layer) and
# the five wrappers still compose.
#
# Anything not listed here installs at the CLI default of 10.
preset_priority() {
  case "$1" in
    worktree-isolation)         echo 5  ;;
    graphify-on-implement)      echo 6  ;;
    progress-report)            echo 7  ;;
    implement-prelude-skills)   echo 8  ;;
    parse-dont-validate)        echo 9  ;;
    explicit-task-dependencies) echo 20 ;;
    *)                          echo 10 ;;
  esac
}

# install_one <kind> <name> <source-dir> [priority]
install_one() {
  local kind="$1" name="$2" src="$3" priority="${4:-}"
  local out rc
  local -a prio_args=()
  if [[ -n "$priority" ]]; then
    prio_args=(--priority "$priority")
  fi

  reinstall_one() {
    local rm_out rm_rc add_out add_rc

    set +o pipefail
    rm_out="$(yes | specify "$kind" remove "$name" 2>&1)"
    rm_rc=$?
    set -o pipefail

    if [[ $rm_rc -ne 0 ]] && ! grep -qi "not installed\|not found\|unknown" <<<"$rm_out"; then
      echo "  FAILED during remove:"
      sed 's/^/    /' <<<"$rm_out" >&2
      return 1
    fi

    set +o pipefail
    add_out="$(yes | specify "$kind" add --dev "$src" ${prio_args[@]+"${prio_args[@]}"} 2>&1)"
    add_rc=$?
    set -o pipefail

    if [[ $add_rc -eq 0 ]]; then
      echo "  reinstalled (--force refresh)"
      return 0
    fi

    echo "  FAILED during re-add:"
    sed 's/^/    /' <<<"$add_out" >&2
    return 1
  }

  # `yes | specify` produces SIGPIPE on `yes`; pipefail would surface it as
  # the pipeline's exit code even when `specify` itself succeeded. Disable
  # pipefail just for this call so we read `specify`'s real status.
  set +o pipefail
  out="$(yes | specify "$kind" add --dev "$src" ${prio_args[@]+"${prio_args[@]}"} 2>&1)"
  rc=$?
  set -o pipefail

  if [[ $rc -eq 0 ]]; then
    echo "  installed"
    return 0
  fi

  if grep -q "already installed" <<<"$out"; then
    if [[ $FORCE_REINSTALL -eq 1 ]]; then
      reinstall_one
      return $?
    fi

    # --dev is a copy, not a symlink: an existing registration is a stale
    # snapshot of this tree, and its recorded priority is whatever it was
    # installed with. Use --force to refresh both.
    echo "  already installed (stale snapshot; use --force to refresh)"
    return 0
  fi

  echo "  FAILED:"
  sed 's/^/    /' <<<"$out" >&2
  return 1
}

EXIT=0

for ext_dir in "$REPO_DIR"/extensions/*/; do
  [[ -f "$ext_dir/extension.yml" ]] || continue
  name="$(basename "$ext_dir")"
  echo "==> extension: $name"
  install_one extension "$name" "$ext_dir" || EXIT=1
done

for preset_dir in "$REPO_DIR"/presets/*/; do
  [[ -f "$preset_dir/preset.yml" ]] || continue
  name="$(basename "$preset_dir")"
  prio="$(preset_priority "$name")"
  echo "==> preset: $name (priority $prio)"
  install_one preset "$name" "$preset_dir" "$prio" || EXIT=1
done

# The installed layout does not match this repo's, and command names do not predict
# script names. A consumer-side agent cannot read this repo's CLAUDE.md, so the
# command -> script mapping is generated into the project on every install.
"$REPO_DIR/gen-agent-index.py" "$REPO_DIR" "$PROJECT_DIR" || EXIT=1

echo
echo "Done. Target: $PROJECT_DIR"
exit $EXIT
