#!/usr/bin/env bash
# loop-finding-audit — asserts a run only spent corrective waves on
# findings it can justify.
#
# The drift this catches is not lost state, it is lost purpose: a run
# that ships the ask in wave 1 and then spends nine waves on findings
# nobody requested. Every one of those waves is individually defensible,
# which is exactly why prose rules do not stop it — each corrective has
# a real defect behind it, cited at a real line. What it does not have
# is a claim on THIS run.
#
# So the check is admissibility, not correctness. A gating finding must
# name the severity class that lets it block (SKILL.md `## Finding
# severity floor`) and the thing it protects — a goal-contract ask, or a
# line this run changed. Findings that can name neither are real and get
# batched; they just do not get a wave.
#
# ASSERTS THE RUN'S OWN RECORDS ONLY. It says nothing about whether a
# finding was correct, whether the fix worked, or whether the class was
# chosen honestly. A clean result means every corrective the snapshot
# counted was paid for by a logged, justified gating finding — no more.
#
# Over the ~100-line bar, and the header is the first thing to trim if
# it needs to come down — same posture as loop-state-audit.sh. The code
# is five comparison arms at a dozen lines each; splitting them out
# would put an arm and the rule it enforces in different files.
#
# No `-e`: several arms end on a `[ ... ] && var=...` whose false branch
# is a normal outcome, and errexit would abort the audit on the first
# one that did not fire. Every risky command is guarded explicitly.
#
# Usage: loop-finding-audit.sh [--branch NAME] [--dir PATH]
#                              [--max-per-wave N] [--interim-agents N]
# Exit:  0 clean · 1 violation · 2 could not run
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BRANCH=""
DIR=""
MAX_PER_WAVE=1
INTERIM_AGENTS=3

# a value-taking flag given no value must not fall through to `$2`
# unbound. Usage errors exit 2; the contract reserves 1 for violations.
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

# the five classes that may block a wave. Kept here rather than derived
# from the SKILL so a spec reword cannot silently widen the gate; the
# list moving is a code change with a test, which is the point.
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

# --- Arm 1: a gating claim carries its justification. ------------------
# `gates: true` is the orchestrator asserting this finding earns a
# corrective. Both fields or it is not a gating finding, whatever the
# reviewing agent called it.
checked=$((checked + 1))
while IFS= read -r line; do
  [ -n "$line" ] || continue
  flag "unjustified gating claim: $line"
done < <(jq -r --argjson classes "$CLASSES" '
  select(.gates == true)
  | select((.gated_by | IN($classes[]) | not) or .contract_ref == null or .contract_ref == "")
  | "wave \(.wave) \(.agent // "?") — gated_by=\(.gated_by // "null") contract_ref=\(.contract_ref // "null")"
' "$GATES")

# --- Arm 2: a contract_ref resolves to something real. ----------------
# Either an ask id the snapshot actually declares, or a citation into
# the run's own diff. An id naming no ask is the failure mode worth
# catching: it reads as justified and protects nothing.
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

# --- Arm 3: every corrective was paid for. ----------------------------
# The load-bearing arm: one justified gating finding per corrective,
# minimum. Justification is counted from the log, never the snapshot —
# the snapshot cannot be trusted to describe its own spending.
#
# Spending is counted from BOTH and the larger wins, because each source
# is blind where the other sees. The snapshot's counter is the only
# record of a corrective numbered as an ordinary queue wave, which the
# log cannot distinguish from real queue work. The log's `-corrective-`
# labels are the only record that survives an under-reported counter,
# and nothing else in this repo reconciles that counter — the sibling
# state audit never reads it. Trusting the counter alone let ten
# labelled correctives against `corrective_waves: 0` audit clean.
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
  # a snapshot that cannot be read, or whose counter is not a number,
  # leaves this arm on the log's evidence alone. Say so — an arm running
  # on half its sources has not settled the question, and exit 0 has to
  # keep meaning fully checked.
  ''|*[!0-9]*)
    [ "$state_ok" -eq 1 ] \
      && skip "corrective spending: run-state.json counter '$counted' is not a count; counting labelled correctives only" \
      || skip "corrective spending: no readable run-state.json; counting labelled correctives only"
    spent="$labelled";;
  *) spent="$counted"; [ "$labelled" -gt "$spent" ] && spent="$labelled";;
esac
[ "$spent" -le "$paid" ] \
  || flag "$spent corrective wave(s) spent, $paid justified gating finding(s) logged"

# --- Arm 4: one corrective per wave. ----------------------------------
# Labels of the form `<N>-corrective-<M>` are the only spending this arm
# can see; a corrective numbered as a plain queue wave hides from it,
# which is why arm 3 counts from the snapshot instead of here.
checked=$((checked + 1))
while IFS=$'\t' read -r count parent; do
  [ -n "$parent" ] || continue
  [ "$count" -le "$MAX_PER_WAVE" ] \
    || flag "wave $parent spent $count correctives, cap is $MAX_PER_WAVE"
done < <(jq -r '.wave | tostring | select(test("-corrective-"))' "$GATES" \
         | sort -u | sed 's/-corrective-.*//' | sort | uniq -c \
         | awk '{printf "%s\t%s\n", $1, $2}')

# --- Arm 5: an interim crew pass is domain-matched, not the full crew.
# The last labelled pass is the final crew and runs all seven; a
# `cleanup` pass is likewise terminal. Everything before them is interim.
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

echo
for note in ${notes+"${notes[@]}"}; do echo "  $note"; done
[ ${#notes[@]} -eq 0 ] || echo

# Violations outrank incompleteness: an unjustified corrective is
# actionable now, a skipped arm is only a reason to go looking. Exit 0
# means every arm ran AND agreed, so a caller gating a run on this code
# never reads a half-run audit as a clean one.
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
