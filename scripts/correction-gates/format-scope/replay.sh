#!/usr/bin/env bash
# format-scope-replay — score the format-scope gate against the loop's
# own history (issue #40 E-greenlight-1). Replays two predicates over
# local/custodian/history-index.jsonl (the Sefz trace-as-query pattern
# custodian-guardrails.sh already mines):
#
#   class      a crew/gate record about prettier / format-glob SCOPE —
#              the recurring correction in its memory-only form (no gate).
#   violation  a class record reporting an ACTUAL format-scope failure the
#              scoped gate catches at build time: `prettier --check` fails,
#              or a full-tree `npm run format` that no-oped the file.
#
# Baseline is memory-only recall: the correction lived as prose across >=2
# memories (feedback-format-drift-not-wave-scope + its consolidated sibling
# feedback-format-glob-vs-prettier-check), and its violations were caught
# LATE by crew — one recurred across a corrective wave because a full-tree
# `npm run format` no-oped an out-of-glob .css. The gate goes RED at
# verify time and stays red until the touched file is clean, so that
# recurrence is impossible under it. Reports would-have-caught / class /
# total, grouped by branch.
#
# Read-only, pure bash + jq. Exit 0 (a report, not a gate); 2 if the index
# is missing. The predicate is published here so the count is reproducible
# — issue #40's hand-count used an unpublished query; the direction, not
# the exact N, is the test.
#
# Usage: format-scope-replay.sh [--index PATH]
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
INDEX="${INDEX:-$CUSTODIAN_HOME/history-index.jsonl}"

while [ $# -gt 0 ]; do
  case "$1" in
    --index) INDEX="$2"; shift 2;;
    -h|--help) echo "usage: $0 [--index PATH]" >&2; exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -s "$INDEX" ] || { echo "empty or missing index: $INDEX" >&2; exit 2; }

jq -rn --arg index "$INDEX" '
  def txt: ((.summary // "") + " " + (.verdict // ""));
  def is_class:
    (txt | test("prettier"; "i"))
    or (txt | test("format[- ](glob|script)"; "i"))
    or ((txt | test("npm run format"; "i")) and (txt | test("no-op|drift|tracked-file|silently|reflow"; "i")));
  def is_viol:
    (txt | test("prettier --check fail|fails prettier|failed prettier --check|still failed prettier|silently no-op"; "i"));

  ([inputs]) as $rows
  | ($rows | length)                          as $n
  | ($rows | map(select(is_class)))           as $class
  | ($class | map(select(is_viol)))           as $viol
  | ($class | map(.repo + "/" + .branch) | unique) as $branches

  | "format-scope-replay — over \($index)",
    "  \($n) records · format-scope class \($class | length) · would-have-caught \($viol | length) · branches \($branches | length)",
    "",
    "format-scope class records (recurring correction, memory-only baseline):",
    ($class[] | "  \(.cite)  [\(.repo)/\(.branch) w\(.wave // "?")]  \((.summary // .verdict // "")[0:66])"),
    "",
    "  distinct branches: \($branches | join(", "))",
    "",
    "would-have-caught by the gate (format-scope failures caught LATE by crew recall,",
    "not by any executable check — exactly the memory-only gap C1/C25 measured):",
    ($viol[] | "  \(.cite)  \((.summary // .verdict // "")[0:74])"),
    "",
    "baseline: memory-only recall caught \($viol | length) format-scope violation(s) late (post-",
    "  build, by crew); the scoped prettier gate catches them at verify time, so a",
    "  wave cannot re-violate. issue #40 hand-count was 5 records / 3 branches",
    "  (unpublished predicate); this reproducible predicate: \($class | length) / \($branches | length)."
' "$INDEX"
