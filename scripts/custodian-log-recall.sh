#!/usr/bin/env bash
# custodian-log-recall — asserts every spec-prescribed log line has
# actually been written (recall, not order; phase-order.sh checks order).
# Full contract: skills/looper-custodian/references/log-recall-check.md
# Usage: custodian-log-recall.sh [--spec P] [--logs-root P] [--log P]
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

# each trigger is a jq boolean, kept narrow or it over-fires violations
trigger_for() {
  case "$1" in
    "window cost")
      # excludes runs that logged deep-research as never having run at all
      printf '%s' '(.phase == "E")
        and ((.action // "") | test("deep-research"))
        and (((.action // "") | test("not run|NOT RUN|not invokable|not installed|not nestable|bars deep-research")) | not)' ;;
    "deferred (usage-window)")  # a probe at/over threshold, either window
      printf '%s' '(((.action // "") + " " + (.detail // ""))
        | test("0\\.9[5-9]|1\\.00|9[5-9]%|100%|rejected"))' ;;
    *) return 1 ;;
  esac
}

# harvested as action "<string>"; references/ searched too (extraction)
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
  # || true: find's nonzero on a missing root would abort under set -e
  logs=$(find "$CUSTODIAN_HOME" -name custodian-log.jsonl -type f 2>/dev/null | sort || true)
  [ -n "$logs" ] || { echo "no custodian-log.jsonl under $CUSTODIAN_HOME" >&2; exit 2; }
fi
log_count=$(printf '%s\n' "$logs" | grep -c .)

# fromjson? guards one malformed line from aborting the sweep
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

# a corpus with no parseable record proves nothing: exit, don't print
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
