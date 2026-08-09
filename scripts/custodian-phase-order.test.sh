#!/usr/bin/env bash
# custodian-phase-order.test.sh — both-directions test for the phase-order
# log check.
#
# Standing rule: a new invariant is tested RED (goes off on a violating
# fixture) AND green (clean fixture passes). Proves P1 flags an out-of-order
# phase-E line citing both offending lines verbatim, exits 1 on any violation
# and 0 when clean, and keeps its two report-only classes — malformed lines
# and segments with nothing to order — out of the violation set.
#
# Two further properties the check's honesty depends on:
#   - SEGMENTATION is load-bearing: deleting the `resume` marker from the
#     GREEN fixture, and changing nothing else, must turn it RED. Without
#     that arm a check that ignored segments entirely would still pass GREEN,
#     and the resume clause of decision 24 would be untested.
#   - CLAIM DISCIPLINE: the report must say it asserts log order only. That
#     wording is the constraint decision 24 imposes on this check, so it is
#     pinned here rather than left to a reviewer to notice going missing.
#
# Fixtures are written by this file — never read from gitignored `local/`.
# Pure bash + jq, self-contained.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/custodian-phase-order.sh"
# a failing mktemp returns empty, which makes every derived fixture path
# absolute (/red.jsonl) and scatters the run outside the temp tree. Abort
# loudly rather than half-run against paths nobody intended. The explicit
# template is what makes TMPDIR the input the message names: a bare
# `mktemp -d` ignores TMPDIR on BSD and allocates under /var/folders.
# one arm per shape: mktemp's own stderr explains a nonzero exit, but the
# empty-yet-successful shape prints nothing, so "failed" would be a lie
die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

fails=0
checks=0
check() { # desc, condition-already-evaluated ($?)
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# --- RED fixture: the 2026-08-03 shape. Two phase-E lines land before a
#     phase-B line in segment 1; a resume tail that IS ordered, a segment
#     with no phase-B line, and two unparseable lines must all stay out of
#     the violation set. ---
red="$temp_dir/red.jsonl"
{
  echo '{"phase":"C","action":"ingest incremental"}'
  echo '{"phase":"A","action":"reaped 2 merged dirs"}'
  echo '{"phase":"B","action":"skill-spec lint"}'
  # the two violations: probe and dispatch, both ahead of B's fan-out
  echo '{"phase":"E","action":"usage-window probe (pre-E gate)"}'
  echo '{"phase":"E","action":"deep-research dispatched (window healthy)"}'
  echo '{"phase":"B","action":"memory audit fan-out dispatched"}'
  echo '{"phase":"B","action":"memory audit FULL COVERAGE 484/484"}'
  # control: an E line with no later B line in its segment is NOT a violation
  echo '{"phase":"E","action":"window cost re-probe"}'
  echo 'not json at all'
  echo '{"repo":"r","action":"line carries no phase key"}'
  # segment 2: an ordered resume tail must not inherit segment 1's disorder
  echo '{"phase":"resume","action":"resume dispatched"}'
  echo '{"phase":"B","action":"staleness resolved against live tree"}'
  echo '{"phase":"E","action":"E synthesized from reachable findings"}'
  echo '{"phase":"F","action":"report issue opened"}'
  # Phase D is a separate human-triggered invocation, never part of the run
  echo '{"phase":"D-apply","action":"apply #1"}'
  # segment 3: phase-E lines only — nothing to order, so not evaluable
  echo '{"phase":"resume","action":"one-shot resume fired"}'
  echo '{"phase":"E","action":"deep-research completed"}'
  # blank + whitespace-only tail: a killed append leaves these, and they are
  # neither records nor malformed lines. Kept LAST so every line number
  # asserted above stays put
  echo ''
  echo '   '
} > "$red"

out=$("$runner" --log "$red"); rc=$?

[ "$rc" -eq 1 ] && result=0 || result=1; check "RED: exit code is 1" "$result"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 2'; check "RED: total is 2 (both pre-B phase-E lines)" $?
printf '%s\n' "$out" | grep -q 'segments: checked 2 · not evaluable 1 · violations 2'
check "RED: segment counts split checked/not-evaluable" $?
# both offending lines are cited verbatim, subject AND the B line it precedes
printf '%s\n' "$out" | grep 'VIOLATION' | grep -q 'usage-window probe (pre-E gate)'
check "RED: pre-E probe cited verbatim as a violation" $?
printf '%s\n' "$out" | grep 'VIOLATION' | grep -q 'deep-research dispatched (window healthy)'
check "RED: deep-research dispatch cited verbatim as a violation" $?
printf '%s\n' "$out" | grep -q 'precedes line 6 phase B "memory audit fan-out dispatched"'
check "RED: names the phase-B line that followed, with its line number" $?
# the three report-only classes must never appear as violations
! printf '%s\n' "$out" | grep 'VIOLATION' | grep -q 'window cost re-probe'
check "RED: trailing phase-E line with no later B is NOT a violation" $?
! printf '%s\n' "$out" | grep 'VIOLATION' | grep -q 'E synthesized from reachable findings'
check "RED: ordered resume tail is NOT a violation (segments are independent)" $?
printf '%s\n' "$out" | grep -q 'MALFORMED  line 9'
check "RED: unparseable line reported as malformed" $?
printf '%s\n' "$out" | grep -q 'MALFORMED  line 10'
check "RED: line with no phase key reported as malformed" $?
printf '%s\n' "$out" | grep -q '2 malformed (reported, never violations)'
check "RED: malformed counted separately from violations" $?
# the blank/whitespace tail lines must not inflate that 2
printf '%s\n' "$out" | grep -q '15 phase records · 2 malformed'
check "RED: blank and whitespace-only lines are neither records nor malformed" $?
printf '%s\n' "$out" | grep -q 'NOT EVALUABLE  segment 3'
check "RED: phase-E-only segment reported not evaluable, not violated" $?

# --- GREEN fixture: C → A → B → E, then an ordered resume tail. ---
green="$temp_dir/green.jsonl"
{
  echo '{"phase":"C","action":"ingest incremental"}'
  echo '{"phase":"A","action":"reaped 1 merged dir"}'
  echo '{"phase":"B","action":"skill-spec lint"}'
  echo '{"phase":"B","action":"memory audit FULL COVERAGE 12/12"}'
  echo '{"phase":"E","action":"usage-window probe (pre-E gate)"}'
  echo '{"phase":"E","action":"deep-research dispatched (window healthy)"}'
  echo '{"phase":"F","action":"report issue opened"}'
  echo '{"phase":"resume","action":"resume dispatched"}'
  echo '{"phase":"B","action":"staleness resolved against live tree"}'
  echo '{"phase":"E","action":"E synthesized from reachable findings"}'
  echo '{"phase":"F","action":"report issue updated"}'
} > "$green"

out=$("$runner" --log "$green"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1; check "GREEN: exit code is 0" "$result"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 0'; check "GREEN: total is 0" $?
printf '%s\n' "$out" | grep -q 'segments: checked 2 · not evaluable 0 · violations 0'
check "GREEN: both segments evaluated, neither violated" $?

# --- SEGMENTATION is load-bearing. Delete ONLY the `resume` marker from the
#     GREEN fixture and it must redden: the tail's phase-B line now sits in
#     segment 1, behind two phase-E lines. A check that ignored segments
#     would pass GREEN identically and this arm is what separates them. ---
merged="$temp_dir/merged.jsonl"
grep -v '"phase":"resume"' "$green" > "$merged"
out=$("$runner" --log "$merged"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1
check "SEGMENT: GREEN minus its resume marker exits 1" "$result"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 2'
check "SEGMENT: the two phase-E lines now precede the tail's phase-B line" $?

# --- CLAIM DISCIPLINE: decision 24 caps what this check may claim, so the
#     report has to say so on every run, clean or not. ---
printf '%s\n' "$out" | grep -q 'ASSERTS LOG ORDER ONLY, never runtime serialization'
check "CLAIM: report states it asserts log order, not runtime serialization" $?
out=$("$runner" --log "$green")
printf '%s\n' "$out" | grep -q 'ASSERTS LOG ORDER ONLY, never runtime serialization'
check "CLAIM: the disclaimer is printed on a clean run too" $?

# --- env/usage arms exit 2, distinct from a violation's 1. ---
"$runner" --log "$temp_dir/absent.jsonl" >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1; check "ENV: missing log exits 2" "$result"
: > "$temp_dir/empty.jsonl"
"$runner" --log "$temp_dir/empty.jsonl" >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1; check "ENV: empty log exits 2" "$result"
"$runner" --nonsense >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1; check "ENV: unknown flag exits 2" "$result"

echo
# an assertion floor: a suite that silently stopped asserting still prints
# "all tests passed" off a zero failure counter, so the count is verified too
[ "$checks" -ge 20 ] || { printf 'FAIL  only %d assertion(s) ran, expected >= 20\n' "$checks"; fails=$((fails + 1)); }
if [ "$fails" -eq 0 ]; then echo "all phase-order tests passed ($checks assertions)"; exit 0
else echo "$fails phase-order test(s) FAILED"; exit 1; fi
