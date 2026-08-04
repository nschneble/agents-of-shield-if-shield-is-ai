#!/usr/bin/env bash
# run-correction-gates — execute every registered correction-gate as one
# verify step (issue #40 E-greenlight-2). This is the compile step's
# RUNTIME. The format-scope pilot proved a single recorded correction can
# be compiled into an executable gate; this runner generalizes that to a
# REGISTRY — this directory, where each subdir holding a spec.md is one
# compiled correction — so ANY recorded correction becomes a check
# looper-verify runs. A recall-only correction (the C1/C25 gap: recall !=
# enforcement) then cannot re-violate for ANY entry, not just format-scope.
#
# Adding a correction is dropping a directory: the runner discovers specs
# and runs each spec's own `exec:` line, so it does not change as the
# registry grows. See ./README.md for the check-spec schema and the
# recorded-correction -> executable-gate compile procedure.
#
# The runner exports a fixed wave-context contract the exec lines read:
#   CG_DIR          repo working root the wave built in (absolute)
#   CG_RANGE        git ref/range a gate compares against (default HEAD)
#   CG_TOUCHED_FILE wave's declared touched files, one per line (may be "")
#   CG_CHANGED_FILE explicit changed-file list, one per line (may be "")
#
# A spec's exec: runs via `bash -c` from its entry dir. Specs are
# repo-committed and reviewed, not untrusted input — same trust posture as
# any in-tree script.
#
# Usage:
#   run-correction-gates.sh [--registry DIR] [--dir DIR] [--range REF]
#                           [--touched-from FILE] [--changed FILE]
#
# Exit: 0 all clean · 1 any gate reported a violation · 2 usage/env error
#       (a gate could not run, or a spec is malformed).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REGISTRY="$here"
DIR="."
RANGE="HEAD"
TOUCHED_FILE=""
CHANGED_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --registry)     REGISTRY="$2"; shift 2;;
    --dir)          DIR="$2"; shift 2;;
    --range)        RANGE="$2"; shift 2;;
    --touched-from) TOUCHED_FILE="$2"; shift 2;;
    --changed)      CHANGED_FILE="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--registry DIR] [--dir DIR] [--range REF] [--touched-from FILE] [--changed FILE]" >&2
      exit 0;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done

[ -d "$REGISTRY" ] || { echo "no such registry: $REGISTRY" >&2; exit 2; }

abspath() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$(pwd)" "$1";; esac; }
export CG_DIR; CG_DIR="$(abspath "$DIR")"
export CG_RANGE="$RANGE"
export CG_TOUCHED_FILE=""; [ -n "$TOUCHED_FILE" ] && CG_TOUCHED_FILE="$(abspath "$TOUCHED_FILE")"
export CG_CHANGED_FILE=""; [ -n "$CHANGED_FILE" ] && CG_CHANGED_FILE="$(abspath "$CHANGED_FILE")"

# read one top-level frontmatter scalar verbatim (no quote stripping, so an
# exec: line keeps its embedded quotes). Frontmatter = between the first
# two `---` fences.
spec_field() { # spec-file key
  awk -v k="$2" '
    /^---[[:space:]]*$/ { n++; if (n>=2) exit; next }
    n==1 && index($0, k ":")==1 { sub("^" k ":[[:space:]]*", ""); print; exit }
  ' "$1"
}

entries=0; failed=0; errored=0; skipped=0
for spec in "$REGISTRY"/*/spec.md; do
  [ -e "$spec" ] || continue   # empty registry: the glob stayed literal
  entry_dir=$(dirname "$spec")
  id=$(spec_field "$spec" id); [ -n "$id" ] || id=$(basename "$entry_dir")
  if [ "$(spec_field "$spec" enabled)" = "false" ]; then
    printf 'SKIP  %s (disabled)\n' "$id"; skipped=$((skipped + 1)); continue
  fi
  exec_line=$(spec_field "$spec" exec)
  if [ -z "$exec_line" ]; then
    printf 'ERROR %s (spec has no exec:)\n' "$id"; errored=$((errored + 1)); continue
  fi
  entries=$((entries + 1))
  out=$( cd "$entry_dir" && bash -c "$exec_line" 2>&1 ); rc=$?
  case "$rc" in
    0) printf 'PASS  %s\n' "$id";;
    1) printf 'FAIL  %s\n' "$id"; failed=$((failed + 1));;
    *) printf 'ERROR %s (exit %d)\n' "$id" "$rc"; errored=$((errored + 1));;
  esac
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/      /'
done

printf 'correction-gates: %d ran · %d fail · %d error · %d skip\n' \
  "$entries" "$failed" "$errored" "$skipped"
[ "$failed" -gt 0 ] && exit 1
[ "$errored" -gt 0 ] && exit 2
exit 0
