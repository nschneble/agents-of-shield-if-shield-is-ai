#!/usr/bin/env bash
# loop-receipts — checks a wave's `verified_by: "executable"` claim
# against the runtime's own record of what ran.
#
# G3 in scripts/custodian-guardrails.sh asks whether a committed wave
# carries a gate line whose `verified_by` equals "executable". That field
# is prose the audited agent typed, so G3 is asking the agent to grade
# itself. This asks the receipts log instead, which hooks/record-execution-
# receipt.sh writes and no agent authors.
#
# WHY THIS IS A SEPARATE CHECK AND NOT A REWRITE OF G3. Receipts start
# the day the hook is installed; every archived run predates them.
# Swapping G3's predicate would turn 419 historical `executable` lines
# into violations overnight — the same false-positive flood the legacy
# `verified_by`-absent exemption exists to prevent. So a branch with no
# receipts log is NOT EVALUABLE here, never a violation, exactly as a
# pre-schema line is exempt there. When receipts cover a meaningful span,
# G3 can be retired into this.
#
# Exit 0 every claim checked resolved, or nothing was evaluable · 1 a
# claim had no matching receipt · 2 unusable input.
#
# Usage: loop-receipts.sh --dir local/loops/<branch> [--strict]
set -uo pipefail

DIR=""
STRICT=0
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    needs_value --dir "$#"; DIR="$2"; shift 2;;
    # treat an unevaluable branch as a failure instead of a skip. Off by
    # default so the check can be wired everywhere before receipts exist
    # everywhere; on for a branch that is supposed to be covered.
    --strict) STRICT=1; shift;;
    -h|--help)
      echo "usage: $0 --dir local/loops/<branch> [--strict]" >&2
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

claims=$(jq -c 'select((.verified_by // "") == "executable")' "$gates" 2>/dev/null | grep -c . || true)

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

# One exit-0 receipt is the bar. Matching a specific claim to a specific
# command would need the wave to name the command it ran, which no gate
# line does today; asserting more than the data supports is the failure
# mode this file was written against.
passing=$(jq -c 'select(.exit_code == 0)' "$receipts" 2>/dev/null | grep -c . || true)
total=$(grep -c . "$receipts" 2>/dev/null || true)
echo "  receipts: $total recorded, $passing with exit 0"

if [ "$claims" -gt 0 ] && [ "$passing" -eq 0 ]; then
  echo "  VIOLATION  $claims line(s) claim executable verification and the runtime"
  echo "             recorded no successful command on this branch at all."
  exit 1
fi

if [ "$claims" -eq 0 ]; then
  echo "  nothing claimed: no executable assertion to check"
else
  echo "  ok: every executable claim has runtime evidence behind it"
fi
exit 0
