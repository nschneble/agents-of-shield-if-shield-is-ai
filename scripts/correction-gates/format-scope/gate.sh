#!/usr/bin/env bash
# format-scope gate — the scope-prettier-to-touched-files correction,
# compiled to an executable check. Provenance + compile trail: ./spec.md.
# Fails on either failure mode of a full-tree npm run format: a declared
# touched file that is not clean (A), or an undeclared clean change (B).
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

# resolved before the cd: the pin travels with the gate, not the repo
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

# absolutize before cd: keeps list-file paths DIR-relative for prettier
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

# pre-flight: wrong/missing prettier is an ENV error (2), never a violation
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

# B: an untouched changed file that is clean: drift or an undeclared edit
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
