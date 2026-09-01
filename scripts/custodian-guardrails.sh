#!/usr/bin/env bash
# custodian-guardrails — replays G1/G2/G3 (Sefz pattern, arXiv 2605.13044) as
# jq predicates over the cross-repo history index, with a per-line legacy
# exemption for pre-schema records. Rationale: decisions/looper-custodian.md
# decision 18. Usage: custodian-guardrails.sh [--index PATH]
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
INDEX="${INDEX:-$CUSTODIAN_HOME/history-index.jsonl}"

# exit 2 for usage errors, since exit 1 means "violations found" here
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --index) needs_value --index "$#"; INDEX="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--index PATH]" >&2
      echo "  replays G1/G2/G3 guardrail predicates over the history index" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -s "$INDEX" ] || { echo "empty or missing index: $INDEX" >&2; exit 2; }

# one JSON object out, so an indexed field can't inject a fake total
analysis=$(jq -n --arg index "$INDEX" '
  def legacy: (has("verified_by") | not);

  def g1_applicable: (.verdict != null);
  def g1_violation:  ((.ran == false) or (.task_tool_available == false));

  # reuses the state-schemas.md provenance lint; drift-checked by the tests
  def g2_applicable: (.ran == true and (.kind == "crew" or .kind == "pre-build-specialist"));
  def g2_violation:  (.verified_by == null
                      or (.kind == "crew" and .agent == "the-diamantaire" and .outcome == null));

  # files[] not used: indexer resolves it once per run, not per wave
  def committed_line:
    (((.kind // "") | test("crew|ship|review"))
     or ((.summary // "") | test("\\b(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\\b")));

  ([inputs]) as $rows
  | ($rows | length) as $n
  | ($rows | map(select(legacy | not)) | length) as $modern
  | ($rows | map(select(legacy)) | length) as $legacyn

  # G1 — line level
  | ($rows | map(select(g1_applicable)))          as $g1app
  | ($g1app | map(select(legacy | not)))          as $g1checked
  | ($g1app | map(select(legacy)) | length)       as $g1exempt
  | ($g1checked | map(select(g1_violation)))      as $g1viol

  # G2 — line level
  | ($rows | map(select(g2_applicable)))          as $g2app
  | ($g2app | map(select(legacy | not)))          as $g2checked
  | ($g2app | map(select(legacy)) | length)       as $g2exempt
  | ($g2checked | map(select(g2_violation)))      as $g2viol

  # G3 — wave level (group by repo|branch|wave)
  | ($rows | group_by([.repo, .branch, (.wave | tostring)]))          as $waves
  | ($waves | map(select(any(.[]; committed_line))))                  as $committed
  | ($committed | map(select(any(.[]; legacy | not))))                as $g3checked
  | ($committed | map(select(all(.[]; legacy))) | length)             as $g3exempt
  | ($g3checked | map(select(all(.[]; .verified_by != "executable")))) as $g3viol

  | ($g1viol | length) as $v1 | ($g2viol | length) as $v2 | ($g3viol | length) as $v3
  | ($v1 + $v2 + $v3) as $total

  | [ "custodian-guardrails — replay over \($index)",
    "  \($n) records · \($modern) modern (checked-era) · \($legacyn) legacy (exempt-era)",
    "",
    "G1  no verdict without a run",
    "    (loop-de-looper ## Gate artifacts: task_tool_available:false ⇒ ran:false ⇒ no verdict)",
    "    lines: checked \($g1checked | length) · legacy-exempt \($g1exempt) · violations \($v1)",
    ($g1viol[] | "    VIOLATION  \(.cite)  verdict=\(.verdict|tostring) ran=\(.ran|tostring) task_tool_available=\(.task_tool_available|tostring)"),
    "",
    "G2  provenance on every ran verdict-bearing gate",
    "    (provenance lint — skills/loop-de-looper/references/state-schemas.md ## Provenance lint)",
    "    lines: checked \($g2checked | length) · legacy-exempt \($g2exempt) · violations \($v2)",
    ($g2viol[] | "    VIOLATION  \(.cite)  kind=\(.kind) agent=\(.agent) verified_by=\(.verified_by|tostring) outcome=\(.outcome|tostring)"),
    "",
    "G3  no committed wave without execution evidence",
    "    (issue #29 cap-overflow item: a committed wave needs a verified_by==\"executable\" gate line)",
    "    waves: checked \($g3checked | length) · legacy-exempt \($g3exempt) · violations \($v3)",
    ($g3viol[] | "    VIOLATION  \(.[0].repo)/\(.[0].branch) wave \(.[0].wave)\n      cites: \([.[].cite] | join(", "))"),
    "",
    "TOTAL VIOLATIONS: \($total)  (G1 \($v1) lines · G2 \($v2) lines · G3 \($v3) waves)" ] as $report

  | { total: $total, report: $report }
' "$INDEX")

printf '%s\n' "$analysis" | jq -r '.report[]'

# verdict off the computed field, never the rendered report (skill-lint's shape)
violations=$(printf '%s\n' "$analysis" | jq -r '.total')
[ "$violations" -eq 0 ]
