#!/usr/bin/env bash
# format-scope gate — the "scope prettier to the wave's touched files"
# correction, compiled to an executable check. Provenance and the compile
# trail live in ./spec.md; this file is just the runnable assertion. Given
# the wave's declared touched-file list it FAILS (exit 1) on either failure
# mode of a full-tree `npm run format`:
#
#   A  touched-unclean — a file the wave declared it touched is not
#      prettier-clean, so the wave would ship unformatted scope.
#   B  out-of-scope clean change — a file the wave changed but did NOT
#      declare is prettier-clean. Either a full-tree format reformatted it
#      (drift to revert) OR it is a real edit the wave never declared
#      (declare it). Both are out of scope for a wave that only claimed the
#      touched set, so the fix is the same: declare it or revert it.
#
# Scope (one class, deliberately narrow): B flags ANY changed file outside
# the declared set that is prettier-clean — on a clean OR a dirty tree.
# That is a real false-positive surface (a legitimate undeclared clean edit
# trips it), which is why the message names BOTH causes, not just "drift".
# A changed out-of-scope file that is NOT clean is some other change this
# gate does not adjudicate — scope review owns it. Deciding "pure prettier
# reformat vs a real edit?" needs a content diff and is the generalization
# this entry defers, not a bug in the check.
#
# Self-contained: pure bash + prettier, no hosted tool. prettier is found
# via $PRETTIER / --prettier (an executable) or, in a target repo,
# node <dir>/node_modules/.bin/prettier — the sandbox-safe `node <bin>`
# form (npx and npm run are denied). Since the gate cannot install
# prettier, ./prettier-version pins the version and the pre-flight CHECKS
# it: exit 2 if prettier cannot run at all or reports another version, so
# a missing or wrong install is an ENV error, not every touched file
# misread as unclean. Two prettier versions disagree about the same file,
# so an unchecked binary makes the verdict the caller's, not the gate's.
# Exit codes read as prettier's own:
# 0 clean, 1 style issues, >=2 unsupported/parse (a file prettier cannot
# handle is a note, never a violation — the out-of-glob carve-out).
#
# Usage:
#   gate.sh [--dir DIR] [--range REF] [--changed FILE] [--prettier CMD]
#           TOUCHED...
#   gate.sh [--dir DIR] --touched-from FILE [--range REF] [--changed FILE]
#
#   TOUCHED...        the wave's declared touched files (relative to DIR)
#   --touched-from F  read touched files from F (one per line) not args
#   --changed F       files that actually changed (one per line); default:
#                     git diff vs REF + untracked, resolved inside DIR
#   --range REF       git ref the changed set compares against (default
#                     HEAD). A committed wave passes its own base here so
#                     the check does not go dark post-commit; the registry
#                     must not assume "runs pre-commit".
#   --dir DIR         repo working root (default .)
#   --prettier CMD    prettier executable ($PRETTIER env is the same)
#
# Exit: 0 clean · 1 any violation · 2 usage/env error.
set -euo pipefail

# resolved before the cd into DIR: the pin travels with the gate, not with
# whatever repo it is pointed at
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIN_FILE="$here/prettier-version"

DIR="."
RANGE="HEAD"
CHANGED_FILE=""
TOUCHED_FILE=""
PRETTIER_CMD="${PRETTIER:-}"
touched=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)          DIR="$2"; shift 2;;
    --range)        RANGE="$2"; shift 2;;
    --changed)      CHANGED_FILE="$2"; shift 2;;
    --touched-from) TOUCHED_FILE="$2"; shift 2;;
    --prettier)     PRETTIER_CMD="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--dir DIR] [--range REF] [--changed FILE] [--prettier CMD] TOUCHED..." >&2
      echo "  fails if a touched file is not prettier-clean, or an" >&2
      echo "  out-of-scope file was changed and is prettier-clean" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   touched+=("$1"); shift;;
  esac
done

# absolutize inputs that live outside DIR before we cd into it, so paths
# inside the list files stay DIR-relative and prettier resolves DIR config
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
    { git diff --name-only "$RANGE"; git ls-files --others --exclude-standard; } | sort -u)
else
  echo "no --changed given and DIR is not a git work tree" >&2; exit 2
fi

run_prettier() {  # forwards to prettier, returns its own exit code
  if [ -n "$PRETTIER_CMD" ]; then "$PRETTIER_CMD" "$@"
  else node "./node_modules/.bin/prettier" "$@"; fi
}

# pre-flight: prettier must be runnable AND be the pinned version, else
# every --check misreads as unclean or answers for another formatter. A
# missing/broken/wrong install is an ENV error (2), not a violation.
[ -r "$PIN_FILE" ] || { echo "missing prettier pin: $PIN_FILE" >&2; exit 2; }
pin=$(tr -d '[:space:]' < "$PIN_FILE")
[ -n "$pin" ] || { echo "empty prettier pin: $PIN_FILE" >&2; exit 2; }

found=$(run_prettier --version 2>/dev/null | tr -d '[:space:]') || true
[ -n "$found" ] || {
  echo "prettier not runnable (set --prettier or install node_modules)" >&2
  exit 2
}
[ "$found" = "$pin" ] || {
  echo "prettier $found is not the pinned $pin (see $PIN_FILE)" >&2
  exit 2
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

# B — a changed file outside the touched set that is prettier-clean is
# either full-tree drift or an undeclared edit; both are out of scope
for f in ${changed[@]+"${changed[@]}"}; do
  in_touched "$f" && continue
  [ -e "$f" ] || continue
  if run_prettier --check "$f" >/dev/null 2>&1; then
    report+=("VIOLATION B  out-of-scope clean change (full-tree drift OR an undeclared edit) — declare it or revert: $f")
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
