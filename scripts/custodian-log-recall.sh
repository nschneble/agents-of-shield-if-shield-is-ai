#!/usr/bin/env bash
# custodian-log-recall — asserts that every log line the custodian spec
# REQUIRES a run to write has actually been written by some run.
#
# scripts/custodian-phase-order.sh asks whether the lines a run DID log
# came in the right order. It can only interrogate lines that exist, so a
# prescribed line nobody ever emits is invisible to it: the log reads
# clean because the missing line leaves no trace. This is the other
# direction — recall, not order.
#
# It found its own reason for existing. The Phase E usage-window gate
# (skills/looper-custodian/references/usage-window-gates.md) requires a
# re-probe after deep-research returns, logged as `action "window cost"`,
# and calls that line what turns the candidate cap "from a conservative
# guess into a calibrated number". Across every archived run the string
# appears zero times while five runs recorded deep-research returning.
# The calibrated number never had a measurement behind it.
#
# The four verdicts, the exit contract, why triggers are declared rather
# than mined from the spec, and the three limits a clean result does NOT
# buy all live in one place:
# skills/looper-custodian/references/log-recall-check.md
#
# Pure bash + jq, no third-party tool, no external store.
#
# Usage: custodian-log-recall.sh [--spec PATH] [--logs-root PATH] [--log PATH]
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
SPEC="${SPEC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/looper-custodian/SKILL.md}"
SINGLE_LOG=""

needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --spec)      needs_value --spec "$#";      SPEC="$2";           shift 2;;
    --logs-root) needs_value --logs-root "$#"; CUSTODIAN_HOME="$2"; shift 2;;
    --log)       needs_value --log "$#";       SINGLE_LOG="$2";     shift 2;;
    -h|--help)
      echo "usage: $0 [--spec PATH] [--logs-root PATH] [--log PATH]" >&2
      echo "  asserts every spec-prescribed log action has been observed" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -s "$SPEC" ] || { echo "empty or missing spec: $SPEC" >&2; exit 2; }

# When is each prescribed line due? A jq boolean over one log record.
# Keep these narrow: a trigger that over-fires manufactures violations.
trigger_for() {
  case "$1" in
    "window cost")
      # deep-research RETURNED. The exclusions matter: several runs logged
      # the phrase while recording that it never ran (not installed, not
      # invokable, not nestable, policy-barred), and those owe no re-probe.
      printf '%s' '(.phase == "E")
        and ((.action // "") | test("deep-research"))
        and (((.action // "") | test("not run|NOT RUN|not invokable|not installed|not nestable|bars deep-research")) | not)' ;;
    "deferred (usage-window)")
      # a probe actually at or over the threshold, in either window
      printf '%s' '(((.action // "") + " " + (.detail // ""))
        | test("0\\.9[5-9]|1\\.00|9[5-9]%|100%|rejected"))' ;;
    *) return 1 ;;
  esac
}

# Prescribed vocabulary, harvested from the spec in the one grammatical
# form it quotes: action "<string>". References are searched too, since
# extraction moves prose without changing what it requires.
spec_dir=$(dirname "$SPEC")
prescribed=$(
  { grep -ohE 'action "[^"]+"' "$SPEC"
    [ -d "$spec_dir/references" ] \
      && grep -rohE 'action "[^"]+"' "$spec_dir/references" || true
  } | sed 's/^action "//; s/"$//' | sort -u
)
[ -n "$prescribed" ] || { echo "no prescribed action strings found in $SPEC" >&2; exit 2; }

if [ -n "$SINGLE_LOG" ]; then
  [ -s "$SINGLE_LOG" ] || { echo "empty or missing log: $SINGLE_LOG" >&2; exit 2; }
  logs="$SINGLE_LOG"
else
  # `|| true`: find exits nonzero on a missing root, and under `set -e`
  # that aborts with 1 — the status the contract reserves for violations.
  # An unreadable corpus is unusable input, which is exit 2 below.
  logs=$(find "$CUSTODIAN_HOME" -name custodian-log.jsonl -type f 2>/dev/null | sort || true)
  [ -n "$logs" ] || { echo "no custodian-log.jsonl under $CUSTODIAN_HOME" >&2; exit 2; }
fi
log_count=$(printf '%s\n' "$logs" | grep -c .)

# Count logs in which a jq predicate holds for at least one record. Raw
# input with `fromjson?` so a malformed line cannot abort the sweep.
logs_matching() {
  local predicate="$1" hits=0 log
  while IFS= read -r log; do
    [ -n "$log" ] || continue
    if jq -Rn --argjson unused 0 "
          [inputs | fromjson? // empty | select($predicate)] | length > 0
        " "$log" 2>/dev/null | grep -q true; then
      hits=$((hits + 1))
    fi
  done <<EOF
$logs
EOF
  printf '%s' "$hits"
}

# A corpus with no parseable record cannot evidence anything, and
# scoring it 0 reports silence as conformance. custodian-phase-order.sh
# refuses the same shape with NOTHING CHECKED; callers read the exit
# code, not the prose, so this has to be an exit and not a printed line.
records=$(logs_matching 'true')
if [ "${records:-0}" -eq 0 ]; then
  echo "NOTHING CHECKED  no parseable phase record in any of $log_count log(s), so"
  echo "                 nothing was asserted — schema drift or the wrong files."
  exit 2
fi

echo "custodian-log-recall — prescribed-vs-observed over $log_count log(s)"
echo "  spec: $SPEC"
echo "  ASSERTS THE LOG ONLY: never observed means unevidenced, not never ran."
echo

violations=0
not_evaluable=0
while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  if ! trigger="$(trigger_for "$rule")"; then
    echo "  UNDECLARED  action \"$rule\" is prescribed by the spec but has no"
    echo "              trigger declared in trigger_for — when it comes due is"
    echo "              unknown, so it cannot be judged. Declare it."
    exit 2
  fi
  observed=$(logs_matching "((.action // \"\") | contains(\"$rule\"))")
  triggered=$(logs_matching "$trigger")

  if [ "$observed" -gt 0 ]; then
    echo "  SATISFIED      action \"$rule\" — observed in $observed of $log_count log(s)"
  elif [ "$triggered" -gt 0 ]; then
    echo "  VIOLATION      action \"$rule\" — PRESCRIBED, its trigger fired in"
    echo "                 $triggered of $log_count log(s), and it was never once logged"
    violations=$((violations + 1))
  else
    echo "  NOT EVALUABLE  action \"$rule\" — never observed, but its trigger never"
    echo "                 fired either, so nothing is asserted about it"
    not_evaluable=$((not_evaluable + 1))
  fi
done <<EOF
$prescribed
EOF

echo
echo "TOTAL VIOLATIONS: $violations  ($not_evaluable not evaluable)"
[ "$violations" -eq 0 ]
