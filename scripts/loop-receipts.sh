#!/usr/bin/env bash
# loop-receipts — checks a wave's verified_by:"executable" claim against
# the runtime's own receipts log, since that gate field is the audited
# agent's own say-so. No receipts log = NOT EVALUABLE, never a violation.
# Usage: loop-receipts.sh --dir local/loops/<branch> [--strict]
set -uo pipefail

DIR=""
STRICT=0
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    needs_value --dir "$#"; DIR="$2"; shift 2;;
    --strict) STRICT=1; shift;;  # unevaluable fails instead of skipping
    -h|--help)
      echo "usage: $0 --dir local/loops/<branch> [--strict]" >&2
      echo "  checks a wave's executable claim against the runtime's receipts" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -n "$DIR" ] || { echo "--dir is required" >&2; exit 2; }
[ -d "$DIR" ] || { echo "no such dir: $DIR" >&2; exit 2; }

gates="$DIR/gates.jsonl"
receipts="$DIR/receipts.jsonl"
[ -s "$gates" ] || { echo "no gate lines at $gates" >&2; exit 2; }

# fromjson? guards one malformed line (custodian-log-recall.sh's shape)
count_matching() { # file, jq predicate
  jq -Rn "[inputs | fromjson? // empty | select($2)] | length" "$1" 2>/dev/null || printf '0'
}

claims=$(count_matching "$gates" '(.verified_by // "") == "executable"')
readable=$(count_matching "$gates" 'true')
if [ "${readable:-0}" -eq 0 ]; then
  echo "no parseable gate line in $gates" >&2
  exit 2
fi

echo "loop-receipts — executable claims vs the runtime's own record"
echo "  dir:      $DIR"
echo "  claims:   $claims gate line(s) declaring verified_by executable"

if [ ! -s "$receipts" ]; then
  echo "  NOT EVALUABLE  no receipts log beside these gates. Receipts begin when"
  echo "                 the hook is installed, so a branch older than it carries"
  echo "                 no evidence either way — unevidenced, not disproved."
  [ "$STRICT" -eq 0 ] && exit 0
  echo "  STRICT: a branch expected to carry receipts has none" >&2
  exit 1
fi

# one uninterrupted receipt is the bar: no gate line names its command
passing=$(count_matching "$receipts" '(.interrupted // false) != true')
total=$(count_matching "$receipts" 'true')
echo "  receipts: $total recorded, $passing uninterrupted"

if [ "$claims" -gt 0 ] && [ "$passing" -eq 0 ]; then
  echo "  VIOLATION  $claims line(s) claim executable verification and the runtime"
  echo "             recorded no uninterrupted command on this branch at all."
  exit 1
fi

if [ "$claims" -eq 0 ]; then
  echo "  nothing claimed: no executable assertion to check"
else
  echo "  ok: every executable claim has runtime evidence behind it"
fi
exit 0
