#!/usr/bin/env bash
# loop-finding-audit — asserts corrective waves are paid for by justified
# gating findings (admissibility, not correctness), from the run's own
# records only. No -e: several arms treat a false test as a normal branch.
# Usage: loop-finding-audit.sh [--branch N] [--dir P] ...  Exit 0/1/2
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BRANCH=""
DIR=""
MAX_PER_WAVE=1
INTERIM_AGENTS=3

# exit 2 for usage errors: 1 is reserved for violations
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --branch)         needs_value --branch "$#";         BRANCH="$2";         shift 2;;
    --dir)            needs_value --dir "$#";            DIR="$2";            shift 2;;
    --max-per-wave)   needs_value --max-per-wave "$#";   MAX_PER_WAVE="$2";   shift 2;;
    --interim-agents) needs_value --interim-agents "$#"; INTERIM_AGENTS="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--branch NAME] [--dir PATH] [--max-per-wave N] [--interim-agents N]" >&2
      echo "  asserts every corrective wave was paid for by a justified gating finding" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

case "$MAX_PER_WAVE$INTERIM_AGENTS" in *[!0-9]*) echo "counts must be non-negative integers" >&2; exit 2;; esac

[ -n "$BRANCH" ] || BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ -n "$DIR" ] || DIR="$REPO_ROOT/local/loops/$BRANCH"
GATES="$DIR/gates.jsonl"
STATE="$DIR/run-state.json"

# hardcoded, not derived from the skill: a reword can't silently widen this
CLASSES='["correctness-regression","security","data-loss","a11y-regression","false-user-string"]'

violations=0
checked=0
skipped=0
notes=()

flag() { notes+=("VIOLATION  $1"); violations=$((violations + 1)); }
skip() { notes+=("NOT EVALUABLE  $1"); skipped=$((skipped + 1)); }

echo "loop-finding-audit — $BRANCH"
echo "  ASSERTS THE RUN'S OWN RECORDS ONLY, never whether a finding was right"
echo

[ -d "$DIR" ] || { echo "no run dir: $DIR" >&2; echo "NOTHING CHECKED"; exit 2; }
[ -s "$GATES" ] || { echo "empty or missing gate log: $GATES" >&2; echo "NOTHING CHECKED"; exit 2; }
jq -e . "$GATES" >/dev/null 2>&1 \
  || { echo "unparseable gate log: $GATES" >&2; echo "NOTHING CHECKED"; exit 2; }

state_ok=0
if [ -s "$STATE" ] && jq -e . "$STATE" >/dev/null 2>&1; then state_ok=1; fi

# arm 1: a gating claim (gates:true) needs both fields, however labeled
checked=$((checked + 1))
while IFS= read -r line; do
  [ -n "$line" ] || continue
  flag "unjustified gating claim: $line"
done < <(jq -r --argjson classes "$CLASSES" '
  select(.gates == true)
  | select((.gated_by | IN($classes[]) | not) or .contract_ref == null or .contract_ref == "")
  | "wave \(.wave) \(.agent // "?") — gated_by=\(.gated_by // "null") contract_ref=\(.contract_ref // "null")"
' "$GATES")

# arm 2: contract_ref must resolve to a real ask or a real diff citation
checked=$((checked + 1))
refs=$(jq -r 'select(.gates == true) | select(.contract_ref != null and .contract_ref != "") | "\(.wave)\t\(.contract_ref)"' "$GATES")
if [ -n "$refs" ]; then
  ask_ids=""
  if [ "$state_ok" -eq 1 ]; then
    ask_ids=$(jq -r '(.goal_contract.asks // [])[] | .id' "$STATE" 2>/dev/null)
  fi
  while IFS=$'\t' read -r wave ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      A[0-9]*)
        if [ "$state_ok" -eq 0 ]; then
          skip "wave $wave contract_ref '$ref': no snapshot to resolve the ask against"
        elif ! printf '%s\n' "$ask_ids" | grep -qx "$ref"; then
          flag "wave $wave cites ask '$ref', which the goal contract does not declare"
        fi;;
      *:L[0-9]*) : ;;                    # a diff citation, shape-checked only
      *) flag "wave $wave contract_ref '$ref' is neither an ask id nor a path:Lstart-Lend citation";;
    esac
  done <<< "$refs"
fi

# arm 3: spending is max(log labels, counter); see skill's budget section
checked=$((checked + 1))
labelled=$(jq -r '.wave | tostring | select(test("-corrective-"))' "$GATES" | sort -u | grep -c . || true)
paid=$(jq -s --argjson classes "$CLASSES" '
  [ .[] | select(.gates == true)
        | select(.gated_by | IN($classes[]))
        | select(.contract_ref != null and .contract_ref != "") ] | length
' "$GATES")
counted=""
if [ "$state_ok" -eq 1 ]; then
  counted=$(jq -r '.counters.corrective_waves // 0' "$STATE" 2>/dev/null)
fi
case "$counted" in
  # an unreadable/non-numeric counter leaves this arm on log evidence alone
  ''|*[!0-9]*)
    [ "$state_ok" -eq 1 ] \
      && skip "corrective spending: run-state.json counter '$counted' is not a count; counting labelled correctives only" \
      || skip "corrective spending: no readable run-state.json; counting labelled correctives only"
    spent="$labelled";;
  *) spent="$counted"; [ "$labelled" -gt "$spent" ] && spent="$labelled";;
esac
[ "$spent" -le "$paid" ] \
  || flag "$spent corrective wave(s) spent, $paid justified gating finding(s) logged"

# arm 4: only sees `<N>-corrective-<M>` labels, not arm 3's snapshot count
checked=$((checked + 1))
while IFS=$'\t' read -r count parent; do
  [ -n "$parent" ] || continue
  [ "$count" -le "$MAX_PER_WAVE" ] \
    || flag "wave $parent spent $count correctives, cap is $MAX_PER_WAVE"
done < <(jq -r '.wave | tostring | select(test("-corrective-"))' "$GATES" \
         | sort -u | sed 's/-corrective-.*//' | sort | uniq -c \
         | awk '{printf "%s\t%s\n", $1, $2}')

# arm 5: interim crew is capped; the final crew/cleanup pass isn't
checked=$((checked + 1))
final_label=$(jq -r 'select(.kind == "crew") | .wave | tostring' "$GATES" | tail -1)
while IFS=$'\t' read -r count wave; do
  [ -n "$wave" ] || continue
  [ "$wave" = "$final_label" ] && continue
  case "$wave" in *cleanup*|*final*) continue;; esac
  [ "$count" -le "$INTERIM_AGENTS" ] \
    || flag "interim crew on wave $wave ran $count agents, cap is $INTERIM_AGENTS"
done < <(jq -r 'select(.kind == "crew" and .ran != false) | "\(.wave)\t\(.agent)"' "$GATES" \
         | sort -u | cut -f1 | uniq -c | awk '{printf "%s\t%s\n", $1, $2}')

# arm 6: kind is a closed enum; a spelling variant hides from crew arms
checked=$((checked + 1))
while IFS= read -r bad_kind; do
  [ -n "$bad_kind" ] || continue
  flag "gates.jsonl carries kind \`$bad_kind\`, which is not in the closed enum — put the variant in \`pass\`"
done < <(jq -r '.kind // empty' "$GATES" 2>/dev/null | sort -u | grep -vxE \
  'crew|pre-build-specialist|wave-retry|stale-skip|executor-handback|usage-window|finding-audit|pr-finalization|orchestration-incident')

echo
for note in ${notes+"${notes[@]}"}; do echo "  $note"; done
[ ${#notes[@]} -eq 0 ] || echo

# violations outrank incompleteness; exit 0 means every arm ran and agreed
if [ "$violations" -gt 0 ]; then
  echo "FINDING AUDIT: $violations violation(s) across $checked check(s)"
  exit 1
fi
if [ "$skipped" -gt 0 ]; then
  echo "FINDING AUDIT: 0 violations across $checked check(s) — INCOMPLETE, $skipped arm(s) could not be settled"
  exit 2
fi
echo "FINDING AUDIT: 0 violations across $checked check(s)"
exit 0
