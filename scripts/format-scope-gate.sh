#!/usr/bin/env bash
# format-scope-gate — compile the "scope prettier to the wave's touched files"
# correction into one executable verify-gate (issue #40 E-greenlight-1 pilot).
#
# The correction, re-learned as prose across branches (memories
# feedback-format-drift-not-wave-scope + its consolidated sibling
# feedback-format-glob-vs-prettier-check): scope prettier to the files the wave
# actually touched, never the full-tree `npm run format`. Memory-only recall let
# it re-violate — the C1/C25 thesis this pilot tests. Full-tree format has two
# failure modes the gate now catches mechanically, so a later wave cannot repeat
# them:
#
#   A  touched-unclean — a file the wave declared it touched is not prettier-clean.
#      The wave would ship unformatted scope; memory-only recall caught this LATE,
#      post-build, by crew (linklater dyslexic-font wave 4: index.css).
#   B  out-of-scope drift — a file the wave changed but did NOT declare is
#      prettier-clean, i.e. a full-tree format reformatted it. That drift belongs
#      in a dedicated reformat wave, not bundled here; revert it.
#
# Given the wave's declared touched-file list the gate FAILS (exit 1) on either.
# It is the scoped `prettier --check <touched>` the memory prescribes, as a gate.
#
# Scope assumption (kept deliberately narrow, ONE class): B treats any changed
# file outside the declared set that is prettier-clean as full-tree drift. A
# changed out-of-scope file that is NOT clean is some other change this gate does
# not adjudicate — scope review owns it. A precise git-content diff (was-dirty-at-
# HEAD, clean-now) would remove the rare false positive; deferred, not needed here.
#
# Self-contained: pure bash + prettier, no hosted tool. prettier is located via
# $PRETTIER / --prettier (an executable) or, in a target repo, node <dir>/
# node_modules/.bin/prettier — the sandbox-safe `node <bin>` form, since npx and
# npm run are denied. Exit codes read as prettier's own: 0 clean, 1 style issues,
# >=2 unsupported/parse (a file prettier cannot handle is a note, never a
# violation — this is the memory's out-of-glob-extension carve-out).
#
# Usage:
#   format-scope-gate.sh [--dir DIR] [--changed FILE] [--prettier CMD] TOUCHED...
#   format-scope-gate.sh [--dir DIR] --touched-from FILE [--changed FILE]
#
#   TOUCHED...        the wave's declared touched files (paths relative to DIR)
#   --touched-from F  read touched files from F (one per line) instead of args
#   --changed F       files that actually changed (one per line); default: git
#                     diff vs HEAD + untracked, resolved inside DIR
#   --dir DIR         repo working root (default .)
#   --prettier CMD    prettier executable ($PRETTIER env is the same override)
#
# Exit: 0 clean · 1 any violation · 2 usage/env error.
set -euo pipefail

DIR="."
CHANGED_FILE=""
TOUCHED_FILE=""
PRETTIER_CMD="${PRETTIER:-}"
touched=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)          DIR="$2"; shift 2;;
    --changed)      CHANGED_FILE="$2"; shift 2;;
    --touched-from) TOUCHED_FILE="$2"; shift 2;;
    --prettier)     PRETTIER_CMD="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--dir DIR] [--changed FILE] [--prettier CMD] TOUCHED..." >&2
      echo "  fails if a touched file is not prettier-clean, or an out-of-scope" >&2
      echo "  file was reformatted (full-tree drift)" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   touched+=("$1"); shift;;
  esac
done

# absolutize inputs that live outside DIR before we cd into it, so paths inside
# the list files stay DIR-relative and prettier resolves DIR's own config
abspath() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$(pwd)" "$1";; esac; }
[ -n "$CHANGED_FILE" ] && CHANGED_FILE="$(abspath "$CHANGED_FILE")"
[ -n "$TOUCHED_FILE" ] && TOUCHED_FILE="$(abspath "$TOUCHED_FILE")"
[ -n "$PRETTIER_CMD" ] && case "$PRETTIER_CMD" in */*) PRETTIER_CMD="$(abspath "$PRETTIER_CMD")";; esac

[ -d "$DIR" ] || { echo "no such dir: $DIR" >&2; exit 2; }
cd "$DIR"

if [ -n "$TOUCHED_FILE" ]; then
  [ -s "$TOUCHED_FILE" ] || { echo "empty touched-from file: $TOUCHED_FILE" >&2; exit 2; }
  while IFS= read -r line; do [ -n "$line" ] && touched+=("$line"); done < "$TOUCHED_FILE"
fi
[ ${#touched[@]} -gt 0 ] || { echo "no touched files given" >&2; exit 2; }

changed=()
if [ -n "$CHANGED_FILE" ]; then
  while IFS= read -r line; do [ -n "$line" ] && changed+=("$line"); done < "$CHANGED_FILE"
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r line; do [ -n "$line" ] && changed+=("$line"); done < <(
    { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)
else
  echo "no --changed given and DIR is not a git work tree" >&2; exit 2
fi

run_prettier() {  # forwards to prettier, returns its own exit code
  if [ -n "$PRETTIER_CMD" ]; then "$PRETTIER_CMD" "$@"
  else node "./node_modules/.bin/prettier" "$@"; fi
}

in_touched() { printf '%s\n' "${touched[@]}" | grep -Fxq -- "$1"; }

violations=0
report=()

# A — every declared touched file must be prettier-clean
for f in "${touched[@]}"; do
  [ -e "$f" ] || continue   # a declared-but-deleted file has nothing to format
  run_prettier --check "$f" >/dev/null 2>&1 && rc=0 || rc=$?
  case "$rc" in
    0) : ;;
    1) report+=("VIOLATION A  touched file not prettier-clean: $f"); violations=$((violations + 1));;
    *) report+=("note         prettier cannot check (unsupported/parse), skipped: $f");;
  esac
done

# B — a changed file outside the touched set that is prettier-clean is drift
for f in ${changed[@]+"${changed[@]}"}; do
  in_touched "$f" && continue
  [ -e "$f" ] || continue
  if run_prettier --check "$f" >/dev/null 2>&1; then
    report+=("VIOLATION B  out-of-scope file reformatted (full-tree drift), revert: $f")
    violations=$((violations + 1))
  fi
done

if [ "$violations" -eq 0 ]; then
  printf 'format-scope-gate: clean (%d touched, %d changed)\n' "${#touched[@]}" "${#changed[@]}"
  for line in ${report[@]+"${report[@]}"}; do printf '  %s\n' "$line"; done
  exit 0
fi
printf 'format-scope-gate: %d violation(s)\n' "$violations"
for line in "${report[@]}"; do printf '  %s\n' "$line"; done
exit 1
