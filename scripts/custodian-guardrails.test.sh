#!/usr/bin/env bash
# custodian-guardrails.test.sh — both-directions test for the guardrail replay.
#
# Standing rule: a new invariant is tested RED (goes off on a violating fixture)
# AND green (clean fixture passes). Proves each of G1/G2/G3 flags its own
# violation with the record's verbatim cite, that exit is 1 on any violation and
# 0 when clean, and that the legacy exemption keeps a pre-schema line that WOULD
# trip G2 out of the violation set. Pure bash + jq, self-contained fixtures.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/custodian-guardrails.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# --- RED fixture: exactly one violation per guardrail, plus a legacy line that
#     WOULD trip G2 but must be exempted, plus clean lines that must NOT flag. ---
red="$tmp/red.jsonl"
{
  # G1 violation: carries a verdict while ran==false (and task_tool_available==false).
  echo '{"repo":"r","branch":"g1","wave":1,"kind":"pre-build-specialist","agent":"accessibility-lead","task_tool_available":false,"ran":false,"verdict":"CLEAR","outcome":null,"verified_by":null,"blockers":0,"summary":"gate could not run","cite":"r/local/loops/g1/gates.jsonl:1"}'
  # G2 violation: modern ran==true verdict-bearing gate with verified_by==null.
  # Uses pre-build-specialist (in G2 scope) not crew, so it is NOT a committed
  # post-build wave and stays isolated from G3.
  echo '{"repo":"r","branch":"g2","wave":1,"kind":"pre-build-specialist","agent":"accessibility-lead","task_tool_available":true,"ran":true,"verdict":"CLEAR","outcome":null,"verified_by":null,"blockers":0,"summary":"reviewed","cite":"r/local/loops/g2/gates.jsonl:1"}'
  # G3 violation: a committed (crew) modern wave with no executable line.
  echo '{"repo":"r","branch":"g3","wave":1,"kind":"crew","agent":"the-stickler","task_tool_available":true,"ran":true,"verdict":"Minor Issues","outcome":null,"verified_by":"llm","blockers":0,"summary":"convention pass","cite":"r/local/loops/g3/gates.jsonl:1"}'
  # LEGACY line (no verified_by key): a ran==true crew line that the raw G2 lint
  # would flag — MUST be exempt, never a violation.
  echo '{"repo":"r","branch":"legacy","wave":1,"kind":"crew","agent":"the-auditor","task_tool_available":true,"ran":true,"verdict":"clean","blockers":0,"summary":"old run","cite":"r/local/loops/legacy/gates.jsonl:1"}'
  # CLEAN control: a committed modern wave WITH an executable line — no guardrail fires.
  echo '{"repo":"r","branch":"ok","wave":1,"kind":"crew","agent":"the-diamantaire","task_tool_available":true,"ran":true,"verdict":"promote","outcome":"promote","verified_by":"executable","blockers":0,"summary":"verified","cite":"r/local/loops/ok/gates.jsonl:1"}'
} > "$red"

out=$("$runner" --index "$red"); rc=$?

[ "$rc" -eq 1 ] && r=0 || r=1; check "RED: exit code is 1" "$r"
printf '%s\n' "$out" | grep -q 'r/local/loops/g1/gates.jsonl:1'; check "RED: G1 cite reported" $?
printf '%s\n' "$out" | grep -q 'r/local/loops/g2/gates.jsonl:1'; check "RED: G2 cite reported" $?
printf '%s\n' "$out" | grep -q 'r/local/loops/g3/gates.jsonl:1'; check "RED: G3 cite reported" $?
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 3'; check "RED: total is 3 (G1+G2+G3)" $?
# The legacy line's cite must appear on NO VIOLATION line.
! printf '%s\n' "$out" | grep 'VIOLATION' | grep -q 'legacy'; check "RED: legacy line NOT a violation" $?
# Each guardrail summarises exactly one violation.
printf '%s\n' "$out" | grep -q 'G1 1 lines'; check "RED: G1 count in summary" $?
printf '%s\n' "$out" | grep -q 'G2 1 lines'; check "RED: G2 count in summary" $?
printf '%s\n' "$out" | grep -q 'G3 1 waves'; check "RED: G3 count in summary" $?

# --- GREEN fixture: every line satisfies every guardrail. ---
green="$tmp/green.jsonl"
{
  # verdict + ran==true + tta==true  → G1 clean; not crew/specialist → G2 n/a.
  echo '{"repo":"r","branch":"a","wave":1,"kind":"wave-ship","agent":"the-looper","task_tool_available":true,"ran":true,"verdict":"shipped","outcome":null,"verified_by":"executable","blockers":0,"summary":"ok deadbeef1","cite":"r/local/loops/a/gates.jsonl:1"}'
  # crew, ran==true, verified_by set, committed wave with an executable line above.
  echo '{"repo":"r","branch":"a","wave":1,"kind":"crew","agent":"the-diamantaire","task_tool_available":true,"ran":true,"verdict":"promote","outcome":"promote","verified_by":"llm","blockers":0,"summary":"reviewed","cite":"r/local/loops/a/gates.jsonl:2"}'
  # a pre-build gate that did NOT run (tta false) but carries NO verdict → G1 n/a.
  echo '{"repo":"r","branch":"a","wave":2,"kind":"pre-build-specialist","agent":"accessibility-lead","task_tool_available":false,"ran":false,"verdict":null,"outcome":null,"verified_by":null,"blockers":0,"summary":"not run","cite":"r/local/loops/a/gates.jsonl:3"}'
} > "$green"

out=$("$runner" --index "$green"); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "GREEN: exit code is 0" "$r"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 0'; check "GREEN: total is 0" $?

echo
if [ "$fails" -eq 0 ]; then echo "all guardrail tests passed"; exit 0
else echo "$fails guardrail test(s) FAILED"; exit 1; fi
