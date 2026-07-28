#!/usr/bin/env bash
# custodian-guardrails — replayable trace queries over the looper history index.
#
# The Sefz pattern (arXiv 2605.13044): a natural-language skill guardrail becomes
# a reachability query over an annotated execution trace, so violation-checking is
# a deterministic graph/predicate query rather than a judgement. Our trace is
# `gates.jsonl`, rolled up cross-repo into `local/custodian/history-index.jsonl`
# (the same store Phase C mines). This runner encodes three of the loop's own
# "never/always" guardrails as `jq` predicates and replays them over that index.
#
# Guardrails:
#   G1  no verdict without a run
#       loop-de-looper `## Gate artifacts` hard rule:
#       task_tool_available:false ⇒ ran:false ⇒ no verdict.
#       Violation: a line carries a verdict while ran==false OR task_tool_available==false.
#   G2  provenance on every ran verdict-bearing gate
#       The provenance lint is owned by skills/loop-de-looper/references/state-schemas.md
#       (`## Provenance lint`) — REUSED here verbatim, not re-encoded, so there is one
#       source of truth. Its crew-or-specialist scope + diamantaire-outcome check apply.
#   G3  no committed wave without execution evidence
#       Issue #29 cap-overflow item ("execution-evidence log assertion"): every wave
#       that shipped a commit must have >=1 gate line with verified_by=="executable".
#
# Legacy exemption (HARD RULE): lines from runs predating the verified_by/outcome
# schema are EXEMPT — counted + reported separately, NEVER violations. Era is
# detected by field absence exactly as state-schemas.md's legacy note prescribes:
# the ingest writer emits `verified_by` (possibly null) on every modern line, so a
# line with NO `verified_by` key predates the schema. Without this, a naive replay
# floods hundreds of false G2/G3 violations on archived pre-schema runs.
#
# Reads the cross-repo index (survives Phase A reaps); pure bash + jq, no third-party
# tools, no SQLite. Per-violation output cites the record's `cite` field verbatim.
# Exit 0 clean, exit 1 if any guardrail has >=1 violation.
#
# Usage: custodian-guardrails.sh [--index PATH]
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
INDEX="${INDEX:-$CUSTODIAN_HOME/history-index.jsonl}"

while [ $# -gt 0 ]; do
  case "$1" in
    --index) INDEX="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--index PATH]" >&2
      echo "  replays G1/G2/G3 guardrail predicates over the history index" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -s "$INDEX" ] || { echo "empty or missing index: $INDEX" >&2; exit 2; }

report=$(jq -rn --arg index "$INDEX" '
  # --- era gate: a line predates the schema iff it has no verified_by key ---
  def legacy: (has("verified_by") | not);

  # --- G1: no verdict without a run (loop-de-looper ## Gate artifacts) ---
  def g1_applicable: (.verdict != null);          # subject only to verdict-bearing lines
  def g1_violation:  ((.ran == false) or (.task_tool_available == false));

  # --- G2: provenance lint, VERBATIM from state-schemas.md ## Provenance lint ---
  # select(.ran == true and (.kind == "crew" or .kind == "pre-build-specialist"))
  # | select(.verified_by == null
  #          or (.kind == "crew" and .agent == "the-diamantaire" and .outcome == null))
  def g2_applicable: (.ran == true and (.kind == "crew" or .kind == "pre-build-specialist"));
  def g2_violation:  (.verified_by == null
                      or (.kind == "crew" and .agent == "the-diamantaire" and .outcome == null));

  # --- G3: a wave "shipped a commit" iff it shows post-build activity ---
  # crew/review/ship gate lines run AFTER build+commit; a commit-SHA named in a
  # summary is direct evidence. (files[] is NOT used: the indexer resolves it once
  # per run, so it is branch-uniform and cannot distinguish which wave committed.)
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

  | "custodian-guardrails — replay over \($index)",
    "  \($n) records · \($modern) modern (checked-era) · \($legacyn) legacy (exempt-era)",
    "",
    "G1  no verdict without a run",
    "    (loop-de-looper ## Gate artifacts: task_tool_available:false ⇒ ran:false ⇒ no verdict)",
    "    lines: checked \($g1checked | length) · legacy-exempt \($g1exempt) · violations \($v1)",
    ($g1viol[] | "    VIOLATION  \(.cite)  verdict=\(.verdict|tostring) ran=\(.ran|tostring) task_tool_available=\(.task_tool_available|tostring)"),
    "",
    "G2  provenance on every ran verdict-bearing gate",
    "    (verbatim provenance lint — skills/loop-de-looper/references/state-schemas.md)",
    "    lines: checked \($g2checked | length) · legacy-exempt \($g2exempt) · violations \($v2)",
    ($g2viol[] | "    VIOLATION  \(.cite)  kind=\(.kind) agent=\(.agent) verified_by=\(.verified_by|tostring) outcome=\(.outcome|tostring)"),
    "",
    "G3  no committed wave without execution evidence",
    "    (issue #29 cap-overflow item: a committed wave needs a verified_by==\"executable\" gate line)",
    "    waves: checked \($g3checked | length) · legacy-exempt \($g3exempt) · violations \($v3)",
    ($g3viol[] | "    VIOLATION  \(.[0].repo)/\(.[0].branch) wave \(.[0].wave)\n      cites: \([.[].cite] | join(", "))"),
    "",
    "TOTAL VIOLATIONS: \($total)  (G1 \($v1) lines · G2 \($v2) lines · G3 \($v3) waves)"
' "$INDEX")

printf '%s\n' "$report"

count=$(printf '%s\n' "$report" | grep '^TOTAL VIOLATIONS:' | grep -oE '[0-9]+' | head -1)
[ "${count:-0}" -gt 0 ] && exit 1 || exit 0
