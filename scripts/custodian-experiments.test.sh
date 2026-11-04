#!/usr/bin/env bash
# custodian-experiments.test — record and status validate and append, list
# shows the newest verdict. Hermetic: CUSTODIAN_HOME points at a temp dir.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/custodian-experiments.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT
export CUSTODIAN_HOME="$temp_dir/custodian"
log="$CUSTODIAN_HOME/experiments.jsonl"
report="$temp_dir/report.md"
echo "result" > "$report"

fails=0; checks=0
check() {
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
rec() { "$runner" record "$@" >/dev/null 2>"$temp_dir/err"; rc=$?; }

rec --issue 101 --item E-1 --verdict follow-up --report "$report" \
  --summary "tamper goes unseen" --follow-up "compare indexed cites" \
  --follow-up "hash the gate log" --comment "https://example.test/c1" --date 2026-11-04
[ "$rc" -eq 0 ]; check "RECORD: a valid record exits 0 (got $rc)" $?
[ "$(wc -l < "$log" | tr -d ' ')" -eq 1 ]; check "RECORD: appends exactly one line" $?
jq -e '.issue == 101 and .item == "E-1" and .verdict == "follow-up" and .date == "2026-11-04"' "$log" >/dev/null
check "RECORD: issue is a number, item, verdict and date kept" $?
jq -e '.follow_ups == ["compare indexed cites", "hash the gate log"]' "$log" >/dev/null
check "RECORD: every --follow-up kept, in order" $?

rec --issue 101 --item E-2 --verdict rejected --report "$report" --summary "no gain"
[ "$rc" -eq 0 ]; check "RECORD: follow-ups and comment are optional (got $rc)" $?
jq -se '.[1].follow_ups == [] and .[1].comment == null' "$log" >/dev/null
check "RECORD: missing optionals are an empty list and null" $?

before=$(wc -l < "$log" | tr -d ' ')
rec --issue 101 --item E-1 --verdict adopted --report "$report" --summary "again"
[ "$rc" -eq 2 ]; check "DUPLICATE: the same issue and item exits 2 (got $rc)" $?
grep -q 'already recorded' "$temp_dir/err"; check "DUPLICATE: says why" $?
[ "$(wc -l < "$log" | tr -d ' ')" -eq "$before" ]; check "DUPLICATE: nothing appended" $?

rec --issue 102 --item E-1 --verdict adopted --report "$report" --summary "other issue"
[ "$rc" -eq 0 ]; check "DUPLICATE near miss: same item on another issue records (got $rc)" $?

rec --issue 101 --item E-9 --verdict maybe --report "$report" --summary "x"
[ "$rc" -eq 2 ]; check "VERDICT: a value outside the enum exits 2 (got $rc)" $?
rec --issue 101 --item E-9 --verdict inconclusive --report "$report" --summary "x"
[ "$rc" -eq 0 ]; check "VERDICT near miss: inconclusive is in the enum (got $rc)" $?

rec --issue 101 --item B-3 --verdict adopted --report "$report" --summary "x"
[ "$rc" -eq 2 ]; check "ITEM: a non-E tag exits 2 (got $rc)" $?
rec --issue x101 --item E-8 --verdict adopted --report "$report" --summary "x"
[ "$rc" -eq 2 ]; check "ISSUE: a non-number exits 2 (got $rc)" $?
rec --issue 101 --item E-8 --verdict adopted --report "$temp_dir/missing.md" --summary "x"
[ "$rc" -eq 2 ]; check "REPORT: a missing report file exits 2 (got $rc)" $?
rec --issue 101 --item E-8 --verdict adopted --report "$report" --summary ""
[ "$rc" -eq 2 ]; check "SUMMARY: an empty summary exits 2 (got $rc)" $?
rec --issue 101 --item E-8 --verdict adopted --report "$report" --summary "x" --date 11/04/2026
[ "$rc" -eq 2 ]; check "DATE: a non-ISO date exits 2 (got $rc)" $?
rec --issue 101 --item E-8 --verdict adopted --report "$report" --summary
[ "$rc" -eq 2 ]; check "USAGE: a flag with no value exits 2 (got $rc)" $?

out=$("$runner" list --issue 102); rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ]
check "LIST: --issue keeps only that issue's lines" $?
printf '%s\n' "$out" | grep -q '^#102 E-1  2026-[0-9-]*  adopted  other issue$'
check "LIST: one readable line per experiment" $?
[ "$("$runner" list | wc -l | tr -d ' ')" -eq 4 ]; check "LIST: no filter prints every line" $?

CUSTODIAN_HOME="$temp_dir/empty" "$runner" list >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ]; check "LIST: an empty record exits 0 (got $rc)" $?

export CUSTODIAN_HOME="$temp_dir/status"
log="$CUSTODIAN_HOME/experiments.jsonl"
st() { "$runner" status "$@" >/dev/null 2>"$temp_dir/err"; rc=$?; }
lines() { wc -l < "$log" | tr -d ' '; }
rec --issue 101 --item E-6 --verdict follow-up --report "$report" --summary "reaper gap"
rec --issue 102 --item E-6 --verdict rejected --report "$report" --summary "other issue"

st --issue 101 --item E-7 --verdict adopted --note "PR #1"
[ "$rc" -eq 2 ]; check "STATUS: an unrecorded item exits 2 (got $rc)" $?
grep -q 'not recorded: #101 E-7' "$temp_dir/err"; check "STATUS: says why" $?
[ "$(lines)" -eq 2 ]; check "STATUS: nothing appended for an unrecorded item" $?
st --issue 103 --item E-6 --verdict adopted --note "PR #1"
[ "$rc" -eq 2 ]; check "STATUS: the same item on an unrecorded issue exits 2 (got $rc)" $?

st --issue 101 --item E-6 --verdict maybe --note "PR #1"
[ "$rc" -eq 2 ]; check "STATUS: a verdict outside the enum exits 2 (got $rc)" $?
st --issue 101 --item E-6 --verdict adopted --note ""
[ "$rc" -eq 2 ]; check "STATUS: an empty note exits 2 (got $rc)" $?
[ "$(lines)" -eq 2 ]; check "STATUS: nothing appended on bad input" $?

st --issue 101 --item E-6 --verdict inconclusive --note "first" --date 2026-11-05
[ "$rc" -eq 0 ]; check "STATUS: a recorded item exits 0 (got $rc)" $?
st --issue 101 --item E-6 --verdict adopted --note "PR #107" --date 2026-11-06
[ "$(lines)" -eq 4 ]; check "STATUS: each status appends one line, none rewritten" $?
jq -se '.[0].verdict == "follow-up" and .[3].type == "status"' "$log" >/dev/null
check "STATUS: the record line is left as it was" $?

out=$("$runner" list)
printf '%s\n' "$out" | grep -qx '#101 E-6  2026-11-06  adopted  reaper gap  (was follow-up: PR #107)'
check "LIST: the newest status gives the verdict, date and note" $?
printf '%s\n' "$out" | grep -qx '#102 E-6  2026-[0-9-]*  rejected  other issue'
check "LIST: a status on one issue leaves another issue's item alone" $?
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ]
check "LIST: a status line is not listed as an experiment" $?

rec --issue 101 --item E-6 --verdict adopted --report "$report" --summary "again"
[ "$rc" -eq 2 ]; check "DUPLICATE: still refused after a status (got $rc)" $?

echo
if [ "$fails" -eq 0 ]; then echo "all $checks custodian-experiments test(s) passed"; exit 0
else echo "$fails of $checks custodian-experiments test(s) FAILED"; exit 1; fi
