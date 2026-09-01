#!/usr/bin/env bash
# format-scope-replay — scores the format-scope gate against loop history
# (issue #40 E-greenlight-1); replays two predicates over the history
# index (Sefz trace-as-query pattern). Read-only report, not a gate.
# Provenance + predicate rationale: ./spec.md.
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
