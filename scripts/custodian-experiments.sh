#!/usr/bin/env bash
# custodian-experiments — the record of every Phase E experiment that ran.
# `record` appends one line per experiment to experiments.jsonl, `status`
# appends a later verdict, `list` prints each with its newest verdict.
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
LOG="$CUSTODIAN_HOME/experiments.jsonl"
VERDICTS="adopted follow-up rejected inconclusive"

usage() {
  cat >&2 <<EOF
usage: $0 record --issue N --item E-N --verdict V --report PATH --summary TEXT
                 [--comment URL] [--follow-up TEXT]... [--date YYYY-MM-DD]
       $0 status --issue N --item E-N --verdict V --note TEXT [--date YYYY-MM-DD]
       $0 list [--issue N]

verdict is one of: $VERDICTS
record exits 2 on bad input or a duplicate (issue, item); status exits 2
on bad input or an (issue, item) never recorded; list exits 0
EOF
}

die() { echo "$1" >&2; exit 2; }
needs_value() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

check_fields() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "--issue must be a number"
  [[ "$2" =~ ^E-[0-9]+$ ]] || die "--item must look like E-3"
  [[ " $VERDICTS " == *" $3 "* ]] || die "--verdict must be one of: $VERDICTS"
  [[ "$4" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date must be YYYY-MM-DD"
}

is_recorded() {
  [ -s "$LOG" ] && jq -e --argjson i "$1" --arg t "$2" \
    'select(.issue == $i and .item == $t)' "$LOG" >/dev/null
}

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
  check_fields "$issue" "$item" "$verdict" "$day"
  [ -n "$summary" ] || die "--summary needs a value"
  [ -f "$report" ] || die "report not found: $report"
  mkdir -p "$CUSTODIAN_HOME"
  if is_recorded "$issue" "$item"; then
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

status() {
  local issue="" item="" verdict="" note="" day
  day=$(date +%Y-%m-%d)
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)   needs_value "$1" "$#"; issue="$2"; shift 2;;
      --item)    needs_value "$1" "$#"; item="$2"; shift 2;;
      --verdict) needs_value "$1" "$#"; verdict="$2"; shift 2;;
      --note)    needs_value "$1" "$#"; note="$2"; shift 2;;
      --date)    needs_value "$1" "$#"; day="$2"; shift 2;;
      *) usage; exit 2;;
    esac
  done
  check_fields "$issue" "$item" "$verdict" "$day"
  [ -n "$note" ] || die "--note needs a value"
  is_recorded "$issue" "$item" || die "not recorded: #$issue $item"
  jq -nc --argjson issue "$issue" --arg item "$item" --arg date "$day" \
    --arg verdict "$verdict" --arg note "$note" \
    '{type: "status", issue: $issue, item: $item, date: $date,
      verdict: $verdict, note: $note}' >> "$LOG"
  echo "status #$issue $item ($verdict)"
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
  jq -rs --arg i "$issue" '
    (map(select(.type == "status")) | group_by([.issue, .item])
      | map({key: "\(.[0].issue) \(.[0].item)", value: .[-1]}) | from_entries)
      as $newest
    | .[] | select(.type != "status")
    | select($i == "" or (.issue | tostring) == $i)
    | $newest["\(.issue) \(.item)"] as $s
    | if $s == null then "#\(.issue) \(.item)  \(.date)  \(.verdict)  \(.summary)"
      else "#\(.issue) \(.item)  \($s.date)  \($s.verdict)  \(.summary)"
        + "  (was \(.verdict): \($s.note))"
      end' "$LOG"
}

case "${1:-}" in
  record) shift; record "$@";;
  status) shift; status "$@";;
  list)   shift; list "$@";;
  -h|--help) usage; exit 0;;
  *) usage; exit 2;;
esac
