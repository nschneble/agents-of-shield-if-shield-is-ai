#!/usr/bin/env bash
# custodian-experiments — the record of every Phase E experiment that ran.
# `record` validates and appends one line to experiments.jsonl; `list`
# prints them, so Phase E can link a candidate to a past result.
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
LOG="$CUSTODIAN_HOME/experiments.jsonl"
VERDICTS="adopted follow-up rejected inconclusive"

usage() {
  cat >&2 <<EOF
usage: $0 record --issue N --item E-N --verdict V --report PATH --summary TEXT
                 [--comment URL] [--follow-up TEXT]... [--date YYYY-MM-DD]
       $0 list [--issue N]

verdict is one of: $VERDICTS
record exits 2 on bad input or a duplicate (issue, item); list exits 0
EOF
}

die() { echo "$1" >&2; exit 2; }
needs_value() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

record() {
  local issue="" item="" verdict="" report="" summary="" comment="" day
  local follow_ups=()
  day=$(date +%Y-%m-%d)
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)     needs_value "$1" "$#"; issue="$2"; shift 2;;
      --item)      needs_value "$1" "$#"; item="$2"; shift 2;;
      --verdict)   needs_value "$1" "$#"; verdict="$2"; shift 2;;
      --report)    needs_value "$1" "$#"; report="$2"; shift 2;;
      --summary)   needs_value "$1" "$#"; summary="$2"; shift 2;;
      --comment)   needs_value "$1" "$#"; comment="$2"; shift 2;;
      --follow-up) needs_value "$1" "$#"; follow_ups+=("$2"); shift 2;;
      --date)      needs_value "$1" "$#"; day="$2"; shift 2;;
      *) usage; exit 2;;
    esac
  done
  [[ "$issue" =~ ^[0-9]+$ ]] || die "--issue must be a number"
  [[ "$item" =~ ^E-[0-9]+$ ]] || die "--item must look like E-3"
  [[ " $VERDICTS " == *" $verdict "* ]] || die "--verdict must be one of: $VERDICTS"
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date must be YYYY-MM-DD"
  [ -n "$summary" ] || die "--summary needs a value"
  [ -f "$report" ] || die "report not found: $report"
  mkdir -p "$CUSTODIAN_HOME"
  if [ -s "$LOG" ] && jq -e --argjson i "$issue" --arg t "$item" \
      'select(.issue == $i and .item == $t)' "$LOG" >/dev/null; then
    die "already recorded: #$issue $item"
  fi
  jq -nc --argjson issue "$issue" --arg item "$item" --arg date "$day" \
    --arg verdict "$verdict" --arg summary "$summary" --arg report "$report" \
    --arg comment "$comment" \
    --args '{issue: $issue, item: $item, date: $date, verdict: $verdict,
      summary: $summary, follow_ups: $ARGS.positional, report: $report,
      comment: (if $comment == "" then null else $comment end)}' \
    ${follow_ups[@]+"${follow_ups[@]}"} >> "$LOG"
  echo "recorded #$issue $item ($verdict)"
}

list() {
  local issue=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) needs_value "$1" "$#"; issue="$2"; shift 2;;
      *) usage; exit 2;;
    esac
  done
  [ -s "$LOG" ] || { echo "no experiments recorded" >&2; exit 0; }
  jq -r --arg i "$issue" 'select($i == "" or (.issue | tostring) == $i)
    | "#\(.issue) \(.item)  \(.date)  \(.verdict)  \(.summary)"' "$LOG"
}

case "${1:-}" in
  record) shift; record "$@";;
  list)   shift; list "$@";;
  -h|--help) usage; exit 0;;
  *) usage; exit 2;;
esac
