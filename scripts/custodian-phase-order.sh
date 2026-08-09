#!/usr/bin/env bash
# custodian-phase-order — asserts the phase LINES of one maintenance run's
# custodian-log.jsonl land in the order the run was meant to execute.
#
# The rule it compiles (skills/looper-custodian/SKILL.md `## Maintenance run`,
# recorded as decision 24 in docs/looper-custodian.md): phases run ONE AT A
# TIME, a phase is done when its subagents have RETURNED rather than when they
# were dispatched, and Phase E is probed and dispatched only after Phase B has
# fully returned. Until now that rule was prose addressed to an unattended
# `claude -p` cron with nobody watching — the recall-is-not-enforcement gap
# scripts/correction-gates/README.md names.
#
# WHAT THIS ASSERTS, EXACTLY: log order, and nothing beyond it. Decision 24
# states the limit itself — "a run that dispatched out of order and logged in
# order would pass it." A clean result here is evidence the log is well
# ordered, NOT evidence the runtime was serialized. Nothing here measures
# dispatch, concurrency, or per-phase cost, and no such observable exists.
#
# P1  no phase-E line before a phase-B line inside one run segment
#     Segments split at a `phase:"resume"` marker: a resume replays its own
#     tail, and decision 24 binds that tail on its own terms. Only B and E
#     lines are read — C/A/F are not ordered by this check, and `D-apply` is a
#     separate human-triggered invocation rather than part of the run.
#
# Not-evaluable and malformed lines are REPORTED, never violations, the same
# per-line shape custodian-guardrails.sh gives its legacy exemption: a segment
# missing every B line or every E line has nothing to order, and a line with
# no parseable `phase` key is pre-schema. There is deliberately NO date-based
# exemption — `phase` predates every log on disk and the asserted C -> A -> B
# -> E order predates decision 24 (decision 16 already leaned on it), so an
# archived log is old, not pre-schema. Without the two report-only classes a
# naive check would flood false positives on archived runs and get ignored.
#
# Pure bash + jq, no third-party tool, no external store.
# Exit 0 clean · 1 any violation · 2 usage/env error.
#
# Usage: custodian-phase-order.sh [--log PATH] [--date YYYY-MM-DD]
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
DATE="$(date +%Y-%m-%d)"
LOG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --log)  LOG="$2"; shift 2;;
    --date) DATE="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--log PATH] [--date YYYY-MM-DD]" >&2
      echo "  asserts phase E never LOGS before phase B inside a run segment" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -n "$LOG" ] || LOG="$CUSTODIAN_HOME/$DATE/custodian-log.jsonl"
[ -s "$LOG" ] || { echo "empty or missing log: $LOG" >&2; exit 2; }

# Read raw so an unparseable line survives as a reported record. `fromjson?`
# alone yields EMPTY on a bad line, which would drop it from the roster
# silently — exactly the line the malformed class exists to surface.
report=$(jq -Rrn --arg log "$LOG" '
  ( [inputs]
    | to_entries
    | map({ lineno: (.key + 1), raw: .value, obj: (.value | fromjson? // null) })
    | map(select((.raw | test("^[[:space:]]*$")) | not)) )              as $lines
  | ($lines | map(select((.obj | type) == "object" and (.obj | has("phase"))))) as $good
  | ($lines | map(select((((.obj | type) == "object") and (.obj | has("phase"))) | not))) as $bad

  # segment at each `resume` marker; the marker line opens the new segment
  | ( reduce $good[] as $l ({ seg: 1, out: [] };
        (if $l.obj.phase == "resume" then .seg += 1 else . end)
        | .out += [{ lineno: $l.lineno, phase: $l.obj.phase,
                     action: ($l.obj.action // ""), seg: .seg }] )
      | .out )                                                          as $tagged
  | ( $tagged | map(select(.phase == "B" or .phase == "E")) | group_by(.seg)
      | map({ seg: .[0].seg,
              bs: map(select(.phase == "B")),
              es: map(select(.phase == "E")) }) )                       as $s
  | ($s | map(select((.bs | length) > 0 and (.es | length) > 0)))       as $checked
  | ($s | map(select((.bs | length) == 0 or (.es | length) == 0)))      as $skipped

  # one violation per E line that some LATER B line in its segment follows
  | ( $checked
      | map( . as $g
             | $g.es
             | map( . as $e
                    | ($g.bs | map(select(.lineno > $e.lineno)) | first) as $b
                    | select($b != null)
                    | { seg: $g.seg, e: $e, b: $b } ) )
      | add // [] )                                                     as $viol
  | ($viol | length) as $v

  | "custodian-phase-order — log-order check over \($log)",
    "  \($good | length) phase records · \($bad | length) malformed (reported, never violations)",
    "",
    "P1  no phase-E line before a phase-B line inside one run segment",
    "    (skills/looper-custodian/SKILL.md ## Maintenance run · decision 24, docs/looper-custodian.md)",
    "    ASSERTS LOG ORDER ONLY, never runtime serialization: a run that dispatched",
    "    out of order and logged in order passes this check (decision 24).",
    "    segments: checked \($checked | length) · not evaluable \($skipped | length) · violations \($v)",
    ($viol[] | "    VIOLATION  segment \(.seg) line \(.e.lineno) phase E \"\(.e.action)\"\n               precedes line \(.b.lineno) phase B \"\(.b.action)\""),
    ($skipped[] | "    NOT EVALUABLE  segment \(.seg): \(.bs | length) phase-B line(s), \(.es | length) phase-E line(s) — nothing to order"),
    ($bad[] | "    MALFORMED  line \(.lineno): no parseable phase key — reported, not a violation"),
    "",
    "TOTAL VIOLATIONS: \($v)  (P1 \($v) phase-E lines)"
' "$LOG")

printf '%s\n' "$report"

count=$(printf '%s\n' "$report" | grep '^TOTAL VIOLATIONS:' | grep -oE '[0-9]+' | head -1)
[ "${count:-0}" -gt 0 ] && exit 1 || exit 0
