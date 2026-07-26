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

shopt -s nullglob

# /speckit-implement composition order — see "Composition order" in README.md.
#
# Five presets layer onto speckit.implement. The resolver sorts layers by
# (priority, preset-id) ascending; the LOWEST number is the OUTERMOST layer.
# A `replace` layer is the composition base and everything below it is
# discarded, so `explicit-task-dependencies` (the wave-DAG executor, which
# must stay `replace`) has to sit innermost or it would swallow the others.
# The `wrap` presets are ordered so their pre-seam steps run outside-in and
# their post-seam steps run inside-out.
#
#   5   worktree-isolation          cd into the worktree before anything reads files
#   8   graphify-on-implement       outermost post-seam step, so the refresh runs last
#   10  constitution-audit          default; post-seam audit of the code just written
#   10  implement-prelude-skills    default; innermost pre-seam step
#   50  explicit-task-dependencies  innermost, `replace` executor base
#
#   => worktree cd -> prelude skills -> implement -> constitution audit -> graphify refresh
#
# Only presets whose position is load-bearing are listed here; every other
# preset falls through to the CLI default (10). Auto-discovery is unchanged —
# this is an override map, not a roster.
preset_priority() {
  case "$1" in
    worktree-isolation)         echo 5  ;;
    graphify-on-implement)      echo 8  ;;
    explicit-task-dependencies) echo 50 ;;
    *)                          echo "" ;;
  esac
}

# install_one <kind> <name> <source-dir> [extra specify-add flags...]
install_one() {
  local kind="$1" name="$2" src="$3"
  shift 3
  local add_flags=("$@")
  local out rc

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
    add_out="$(yes | specify "$kind" add --dev "$src" ${add_flags[@]+"${add_flags[@]}"} 2>&1)"
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
  out="$(yes | specify "$kind" add --dev "$src" ${add_flags[@]+"${add_flags[@]}"} 2>&1)"
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

    # --dev means the existing registration already points at this source
    # tree, so file edits are live. Manifest changes still require --force.
    echo "  already installed (live via --dev; use --force to refresh manifest)"
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
  echo "==> preset: $name"
  priority="$(preset_priority "$name")"
  if [[ -n "$priority" ]]; then
    install_one preset "$name" "$preset_dir" --priority "$priority" || EXIT=1
    # --priority only takes effect on a fresh add, so an already-installed
    # preset would keep whatever priority it was first registered with.
    # set-priority is idempotent and reconciles it either way.
    specify preset set-priority "$name" "$priority" >/dev/null 2>&1 \
      || echo "  warning: could not set priority $priority" >&2
  else
    install_one preset "$name" "$preset_dir" || EXIT=1
  fi
done

echo
echo "Done. Target: $PROJECT_DIR"
exit $EXIT
