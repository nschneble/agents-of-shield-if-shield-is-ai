#!/usr/bin/env bash
# custodian-phase-order — asserts the phase LINES of one maintenance
# run's custodian-log.jsonl land in the order the run was meant to
# execute.
#
# The rule it compiles (skills/looper-custodian/SKILL.md
# `## Maintenance run`, recorded as decision 24 in
# docs/decisions/looper-custodian.md): phases run ONE AT A TIME, a phase is done
# when its subagents have RETURNED rather than when they were
# dispatched, and Phase E is probed and dispatched only after Phase B
# has fully returned. Until now that rule was prose addressed to an
# unattended `claude -p` cron with nobody watching — the
# recall-is-not-enforcement gap scripts/correction-gates/README.md names.
#
# This asserts log order and nothing beyond it.
#
# What it reads, the two predicates, every class the report prints, the
# exit contract, why the "at or before it" discriminator is decidable
# rather than guessed, and the three limits a clean result does NOT buy
# all live in one place:
# skills/looper-custodian/references/phase-order-check.md
#
# Pure bash + jq, no third-party tool, no external store.
#
# Usage: custodian-phase-order.sh [--log PATH] [--date YYYY-MM-DD]
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
DATE="$(date +%Y-%m-%d)"
LOG=""

# a value-taking flag given no value must not fall through to `$2`
# unbound: under `set -u` that aborts with status 1, which the exit
# contract reserves for "violations found". Usage errors exit 2 here and
# in custodian-guardrails.sh.
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

# Read raw so an unparseable line survives as a reported record.
# `fromjson?` alone yields EMPTY on a bad line, which would drop it from
# the roster silently — exactly the line the malformed class surfaces.
#
# One object out, not rendered text: the verdict below reads `.total`
# from this JSON, so a newline inside a logged `action` cannot inject a
# counterfeit total.
#
# EVERYTHING BELOW, to the closing quote, is one single-quoted shell
# string — jq program and jq comments alike. No apostrophes anywhere
# inside it: one ends the string, and the error surfaces somewhere else
# entirely.
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

  # one P1 violation per E line that some LATER B line in its segment
  # follows. `first` is the NEAREST following B only because $g.bs
  # ascends by lineno, which holds because to_entries, map(select) and
  # group_by all preserve input order. That is the one assumption this
  # check takes on faith. What the P2 discriminator
  # (skills/looper-custodian/references/phase-order-check.md) does NOT
  # depend on is WHICH phase-E line it measures from: segments are
  # contiguous line ranges and a no-B segment holds no B line, so no
  # phase-B line lies between its first and last phase E and `priorb` is
  # identical for every one of them. Only the printed `first at line N`
  # on that class is order-sensitive.
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

# verdict off the computed field, never off the rendered report — the
# shape scripts/custodian-skill-lint.sh `run_lint` already uses.
records=$(printf '%s\n' "$analysis" | jq -r '.records')
violations=$(printf '%s\n' "$analysis" | jq -r '.total')
[ "$records" -gt 0 ] || exit 2
[ "$violations" -eq 0 ]
