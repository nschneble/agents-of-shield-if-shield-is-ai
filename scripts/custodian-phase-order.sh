#!/usr/bin/env bash
# custodian-phase-order — asserts a run's phase lines land in the order
# it was meant to execute (phases run one at a time; Phase E waits for
# Phase B). Full contract: references/phase-order-check.md (decision 24).
# Usage: custodian-phase-order.sh [--log PATH] [--date YYYY-MM-DD]
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
DATE="$(date +%Y-%m-%d)"
LOG=""

# exit 2 for usage errors: 1 is reserved for "violations found"
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --log)  needs_value --log  "$#"; LOG="$2";  shift 2;;
    --date) needs_value --date "$#"; DATE="$2"; shift 2;;
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

# raw input: fromjson? alone would silently drop a bad line from the roster
# one JSON object out, so a logged action can't inject a fake total
# no apostrophes below: this whole jq program is one single-quoted string
analysis=$(jq -Rn --arg log "$LOG" '
  def has_phase: (type == "object") and has("phase");

  ( [inputs]
    | to_entries
    | map({ lineno: (.key + 1), raw: .value, obj: (.value | fromjson? // null) })
    | map(select(.raw | test("\\S"))) )                                 as $lines
  | ($lines | map(select(.obj | has_phase)))                            as $good
  | ($lines | map(select((.obj | has_phase) | not)))                    as $bad

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
  | ($s | map(select((.es | length) > 0 and (.bs | length) > 0)))       as $checked
  | ($s | map(select((.es | length) == 0)))                             as $skipped

  # split the no-B segments by whether a phase-B line exists EARLIER
  | ($tagged | map(select(.phase == "B")))                              as $allbs
  | ($s | map(select((.es | length) > 0 and (.bs | length) == 0))
        | map(. as $g
              | . + { priorb: ($allbs
                               | map(select(.lineno < $g.es[0].lineno))
                               | length) }))                            as $nob
  | ($nob | map(select(.priorb == 0)))                                  as $unord
  | ($nob | map(select(.priorb > 0)))                                   as $tail

  # first() is nearest-following-B only because $g.bs ascends by lineno
  | [ $checked[] as $g
      | $g.es[] as $e
      | (first($g.bs[] | select(.lineno > $e.lineno))) as $b
      | { seg: $g.seg, e: $e, b: $b } ]                                 as $viol

  | ($viol | length) as $p1
  | ($unord | length) as $p2
  | ($good | length) as $records

  | ( [ "custodian-phase-order — log-order check over \($log)",
        "  \($records) phase records · \($bad | length) malformed (reported, never violations)",
        "  segments are split at each `resume` marker, which replays its own tail",
        "" ]
      + (if $records == 0 then
          [ "NOTHING CHECKED  this log carries no parseable phase record, so no",
            "                 phase order was asserted — schema drift or the wrong",
            "                 file, not a clean run.",
            "" ]
         else [] end)
      + [ "P1  no phase-E line before a phase-B line inside one run segment",
          "P2  no segment carrying phase-E lines with no phase-B line logged at or before it",
          "    (a no-B segment with an EARLIER phase-B line is a resume tail, reported not counted)",
          "    (spec skills/looper-custodian/references/phase-order-check.md · rule SKILL.md ## Maintenance run, decision 24 in docs/decisions/looper-custodian.md)",
          "    ASSERTS LOG ORDER ONLY, never runtime serialization: a run that dispatched",
          "    out of order and logged in order passes this check (decision 24).",
          "    segments: checked \($checked | length) · unordered \($p2) · resume tail \($tail | length) · not evaluable \($skipped | length) · violations \($p1 + $p2)" ]
      + [ ($viol[] | "    VIOLATION P1  segment \(.seg) line \(.e.lineno) phase E \"\(.e.action)\"\n                  precedes line \(.b.lineno) phase B \"\(.b.action)\"") ]
      + [ ($unord[] | "    VIOLATION P2  segment \(.seg): \(.es | length) phase-E line(s), no phase-B line anywhere at or before it — cannot be shown ordered\n                  first at line \(.es[0].lineno) phase E \"\(.es[0].action)\"") ]
      + [ ($tail[] | "    RESUME TAIL  segment \(.seg): \(.es | length) phase-E line(s), no phase-B line, but \(.priorb) phase-B line(s) logged earlier — the documented resume shape, not a violation") ]
      + [ ($skipped[] | "    NOT EVALUABLE  segment \(.seg): \(.bs | length) phase-B line(s), 0 phase-E line(s) — nothing to order") ]
      + [ ($bad[] | "    MALFORMED  line \(.lineno): no parseable phase key — reported, not a violation") ]
      + [ "" ]
      + (if $records == 0 then
          [ "TOTAL VIOLATIONS: none asserted — NOTHING CHECKED (0 phase records)" ]
         else
          [ "TOTAL VIOLATIONS: \($p1 + $p2)  (P1 \($p1) phase-E lines · P2 \($p2) segments)" ]
         end) )                                                         as $report

  | { records: $records, total: ($p1 + $p2), report: $report }
' "$LOG")

printf '%s\n' "$analysis" | jq -r '.report[]'

# verdict off the computed field, never rendered report (skill-lint shape)
records=$(printf '%s\n' "$analysis" | jq -r '.records')
violations=$(printf '%s\n' "$analysis" | jq -r '.total')
[ "$records" -gt 0 ] || exit 2
[ "$violations" -eq 0 ]
