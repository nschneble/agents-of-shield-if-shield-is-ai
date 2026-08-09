#!/usr/bin/env bash
# custodian-phase-order.test.sh — both-directions test for the phase-order
# log check.
#
# Standing rule: a new invariant is tested RED (goes off on a violating
# fixture) AND green (clean fixture passes). Proves P1 flags an out-of-order
# phase-E line citing both offending lines verbatim, P2 flags a segment whose
# phase-E lines have no phase-B line to be ordered against, the exit code
# tracks both, and the two report-only classes — malformed lines and segments
# with no phase-E line — stay out of the violation set.
#
# Four further properties the check's honesty depends on:
#   - SEGMENTATION is load-bearing: deleting the `resume` marker from the
#     GREEN fixture, and changing nothing else, must turn it RED. Without
#     that arm a check that ignored segments entirely would still pass GREEN,
#     and the resume clause of decision 24 would be untested.
#   - The EXIT CODE must agree with the report's own printed total on every
#     fixture. It once did not: the code was scraped back out of the rendered
#     prose, so a newline inside a logged `action` injected a counterfeit
#     `TOTAL VIOLATIONS: 0` that `head -1` preferred, and a real violation
#     exited 0. `agree` below re-derives the expected code from the LAST total
#     line on every case, and one fixture carries that injection deliberately.
#   - NOTHING CHECKED is not clean: a log the check cannot read asserts
#     nothing, so it must be distinguishable from a verified run at BOTH the
#     headline and the exit code, or schema drift greens the gate forever.
#   - CLAIM DISCIPLINE, in both directions. The report must say it asserts log
#     order only (decision 24 caps what this check may claim), and it must NOT
#     say anything more — a present disclaimer does not stop an overclaim from
#     being added beside it, so the negative arm greps for one.
#
# Fixtures are written by this file — never read from gitignored `local/`.
# Pure bash + jq, self-contained.
#
# Deliberately over the ~100-line refactor bar, same waiver
# scripts/temp-dir-guard.test.sh and scripts/validate-looper-config.sh carry.
# The RED fixture and its line-number assertions share one frame: splitting
# the arms into a second file would put assertions on lines 6, 9 and 10 in a
# file that cannot see the fixture that numbers them, and every future
# fixture edit would silently drift them. The bulk is arithmetic, not slack —
# an arm costs two lines (the probe, then `check`), so the assertion floor at
# the foot of the file already prices most of the body. Trim its prose before
# reaching for its code.
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

# re-derive the expected exit code from the report's own LAST total line and
# assert the real one matches. `tail -1` on purpose: an injected total lands
# above the real one, so a suite that took the first would inherit the same
# bug it is here to catch.
agree() { # desc — reads $out and $rc from the case just run
  local line want
  line=$(printf '%s\n' "$out" | grep '^TOTAL VIOLATIONS:' | tail -1)
  case "$line" in
    'TOTAL VIOLATIONS: none asserted'*) want=2;;
    'TOTAL VIOLATIONS: 0 '*)            want=0;;
    *)                                  want=1;;
  esac
  [ "$rc" -eq "$want" ]
  check "AGREE: $1 exit code $rc matches its printed total (want $want)" $?
}

# the check may say it asserts log order; it may never say more than that
no_overclaim() { # desc
  ! printf '%s\n' "$out" \
    | grep -v 'ASSERTS LOG ORDER ONLY, never runtime serialization' \
    | grep -Eq 'serializ|at runtime|proves the phase'
  check "CLAIM: $1 report carries no runtime claim beyond the pinned line" $?
}

# --- RED fixture: the 2026-08-03 shape. Two phase-E lines land before a
#     phase-B line in segment 1; an ordered resume tail, a segment with
#     phase-E lines and no phase-B line, a segment with a phase-B line and no
#     phase-E line, and two unparseable lines all classify separately. ---
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
  # control: an E line with no later B line in its segment is NOT a P1
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
  # segment 3: phase-E lines only — no phase B to be ordered against (P2)
  echo '{"phase":"resume","action":"one-shot resume fired"}'
  echo '{"phase":"E","action":"deep-research completed"}'
  # segment 4: a phase-B line and no phase-E line — genuinely nothing to order
  echo '{"phase":"resume","action":"second resume dispatched"}'
  echo '{"phase":"B","action":"memory audit re-run"}'
  # blank + whitespace-only tail: a killed append leaves these, and they are
  # neither records nor malformed lines. Kept LAST so every line number
  # asserted above stays put
  echo ''
  echo '   '
} > "$red"

out=$("$runner" --log "$red"); rc=$?

[ "$rc" -eq 1 ] && result=0 || result=1; check "RED: exit code is 1" "$result"
agree "RED:"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 3  (P1 2 phase-E lines · P2 1 segments)'
check "RED: total is 3 (two pre-B phase-E lines + one unordered segment)" $?
printf '%s\n' "$out" | grep -q 'segments: checked 2 · unordered 1 · not evaluable 1 · violations 3'
check "RED: segment counts split checked/unordered/not-evaluable" $?
# both offending lines are cited verbatim, subject AND the B line it precedes
printf '%s\n' "$out" | grep 'VIOLATION P1' | grep -q 'usage-window probe (pre-E gate)'
check "RED: pre-E probe cited verbatim as a P1 violation" $?
printf '%s\n' "$out" | grep 'VIOLATION P1' | grep -q 'deep-research dispatched (window healthy)'
check "RED: deep-research dispatch cited verbatim as a P1 violation" $?
printf '%s\n' "$out" | grep -q 'precedes line 6 phase B "memory audit fan-out dispatched"'
check "RED: names the phase-B line that followed, with its line number" $?
# the report-only classes must never appear as violations
! printf '%s\n' "$out" | grep 'VIOLATION P1' | grep -q 'window cost re-probe'
check "RED: trailing phase-E line with no later B is NOT a P1 violation" $?
! printf '%s\n' "$out" | grep 'VIOLATION P1' | grep -q 'E synthesized from reachable findings'
check "RED: ordered resume tail is NOT a violation (segments are independent)" $?
printf '%s\n' "$out" | grep -q 'MALFORMED  line 9'
check "RED: unparseable line reported as malformed" $?
printf '%s\n' "$out" | grep -q 'MALFORMED  line 10'
check "RED: line with no phase key reported as malformed" $?
printf '%s\n' "$out" | grep -q '2 malformed (reported, never violations)'
check "RED: malformed counted separately from violations" $?
# the blank/whitespace tail lines must not inflate that 2
printf '%s\n' "$out" | grep -q '17 phase records · 2 malformed'
check "RED: blank and whitespace-only lines are neither records nor malformed" $?
printf '%s\n' "$out" | grep -q 'VIOLATION P2  segment 3: 1 phase-E line(s), no phase-B line'
check "RED: phase-E-only segment is a P2 violation, not a free pass" $?
printf '%s\n' "$out" | grep -q 'NOT EVALUABLE  segment 4: 1 phase-B line(s), 0 phase-E line(s)'
check "RED: segment with no phase-E line is report-only, never a violation" $?
no_overclaim "RED:"

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
agree "GREEN:"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 0'; check "GREEN: total is 0" $?
printf '%s\n' "$out" | grep -q 'segments: checked 2 · unordered 0 · not evaluable 0 · violations 0'
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
agree "SEGMENT:"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 2'
check "SEGMENT: the two phase-E lines now precede the tail's phase-B line" $?

# --- CLAIM DISCIPLINE: decision 24 caps what this check may claim, so the
#     report has to say so on every run, clean or not — and say no more. ---
printf '%s\n' "$out" | grep -q 'ASSERTS LOG ORDER ONLY, never runtime serialization'
check "CLAIM: report states it asserts log order, not runtime serialization" $?
out=$("$runner" --log "$green"); rc=$?
printf '%s\n' "$out" | grep -q 'ASSERTS LOG ORDER ONLY, never runtime serialization'
check "CLAIM: the disclaimer is printed on a clean run too" $?
no_overclaim "GREEN:"

# --- P2: the MODAL violation shape. E dispatched, the run died, B never
#     logged — 2026-07-27 segment 1. Read as "nothing to order" this exits 0
#     and the check is blind to its own most likely subject. ---
died="$temp_dir/died.jsonl"
{
  echo '{"phase":"C","action":"ingest incremental"}'
  echo '{"phase":"A","action":"reaped 2 merged dirs"}'
  echo '{"phase":"E","action":"usage-window gate probed — HEALTHY, running E"}'
  echo '{"phase":"E","action":"deep-research dispatched from main session"}'
  echo '{"phase":"resume","action":"session-limit kill left B unlogged"}'
  echo '{"phase":"B","action":"memory audit dispatched"}'
  echo '{"phase":"B","action":"audit complete — full coverage"}'
  echo '{"phase":"F","action":"report issue opened"}'
} > "$died"
out=$("$runner" --log "$died"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1
check "P2: E logged with B never logged in its segment exits 1" "$result"
agree "P2:"
printf '%s\n' "$out" | grep -q 'VIOLATION P2  segment 1: 2 phase-E line(s), no phase-B line'
check "P2: cites the segment and its phase-E line count" $?
printf '%s\n' "$out" | grep -q 'first at line 3 phase E "usage-window gate probed'
check "P2: cites the first offending phase-E line verbatim, with its number" $?

# --- P2 also closes the resume-interposition hole: a `resume` marker between
#     an E line and its B line used to split them into two not-evaluable
#     segments and exit 0. It still splits them — that is decision 24's rule —
#     but the E-side segment is now a P2, so the marker cannot launder it. ---
interposed="$temp_dir/interposed.jsonl"
printf '%s\n' '{"phase":"E","action":"e ahead of everything"}' \
               '{"phase":"resume","action":"resume dispatched"}' \
               '{"phase":"B","action":"b in the tail"}' > "$interposed"
out=$("$runner" --log "$interposed"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1
check "INTERPOSE: a resume between an E line and its B line still exits 1" "$result"
agree "INTERPOSE:"
printf '%s\n' "$out" | grep -q 'VIOLATION P2  segment 1'
check "INTERPOSE: the E-side segment is the P2, not a free pass" $?
printf '%s\n' "$out" | grep -q 'NOT EVALUABLE  segment 2'
check "INTERPOSE: the B-only tail stays report-only" $?

# --- a log with NO phase-E line has genuinely nothing to order. Archived
#     2026-06-29 and 2026-07-13 are exactly this and must stay clean. ---
no_e="$temp_dir/no-e.jsonl"
printf '%s\n' '{"phase":"A","action":"reaped 2 merged dirs"}' \
               '{"phase":"B","action":"memory audit — full coverage"}' \
               '{"phase":"B","action":"verdict: 0 duplicates"}' \
               '{"phase":"C","action":"cross-repo mining"}' > "$no_e"
out=$("$runner" --log "$no_e"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1
check "NO-E: a log with no phase-E line is clean, not a violation" "$result"
agree "NO-E:"
printf '%s\n' "$out" | grep -q 'not evaluable 1'
check "NO-E: reported as not evaluable rather than checked" $?

# --- NOTHING CHECKED: a log the check cannot read asserts nothing. It must
#     not print a clean total and must not exit like a verified run. ---
unreadable="$temp_dir/unreadable.jsonl"
printf '%s\n' 'not json' 'still not json' '}{' > "$unreadable"
out=$("$runner" --log "$unreadable"); rc=$?
[ "$rc" -eq 2 ] && result=0 || result=1
check "NOTHING: an unreadable log exits 2, not 0" "$result"
agree "NOTHING:"
printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check "NOTHING: the headline says nothing was checked" $?
! printf '%s\n' "$out" | grep -q '^TOTAL VIOLATIONS: 0'
check "NOTHING: does not print a clean total" $?
# schema drift: well-formed JSON whose `phase` key was renamed
drift="$temp_dir/drift.jsonl"
printf '%s\n' '{"stage":"E","action":"e"}' '{"stage":"B","action":"b"}' > "$drift"
"$runner" --log "$drift" >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1
check "NOTHING: a renamed phase key exits 2, not a silent clean" "$result"

# --- the exit code is computed, never scraped: this fixture's `action`
#     carries a newline plus a counterfeit clean total. ---
inject="$temp_dir/inject.jsonl"
jq -cn '{phase:"E",action:"probe\nTOTAL VIOLATIONS: 0  (P1 0 phase-E lines)"}' > "$inject"
echo '{"phase":"B","action":"the B it precedes"}' >> "$inject"
out=$("$runner" --log "$inject"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1
check "INJECT: a counterfeit total inside an action does not suppress exit 1" "$result"
agree "INJECT:"

# --- D-apply is a separate human-triggered invocation. Read as a phase-E
#     line it would precede the B that follows it and fabricate a violation. ---
dapply="$temp_dir/dapply.jsonl"
printf '%s\n' '{"phase":"B","action":"memory audit dispatched"}' \
               '{"phase":"D-apply","action":"B-merge-1 applied"}' \
               '{"phase":"B","action":"audit complete"}' > "$dapply"
out=$("$runner" --log "$dapply"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1
check "D-APPLY: a D-apply line between two B lines is not a phase-E line" "$result"
agree "D-APPLY:"

# --- usage/env arms exit 2, distinct from a violation's 1. ---
"$runner" --log "$temp_dir/absent.jsonl" >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1; check "ENV: missing log exits 2" "$result"
: > "$temp_dir/empty.jsonl"
"$runner" --log "$temp_dir/empty.jsonl" >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1; check "ENV: empty log exits 2" "$result"
"$runner" --nonsense >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1; check "ENV: unknown flag exits 2" "$result"
# a value-taking flag with no value must not abort on `$2` unbound: `set -u`
# exits 1 there, and 1 is reserved for "violations found"
"$runner" --log >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1; check "ENV: --log with no value exits 2" "$result"
"$runner" --date >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1; check "ENV: --date with no value exits 2" "$result"
"$runner" --help >/dev/null 2>&1
[ "$?" -eq 0 ] && result=0 || result=1; check "ENV: --help exits 0" "$result"

# --- --date is the PRODUCTION path: Phase F names a date, not a path, so a
#     discarded --date value would fail only on the cron nobody watches. ---
home="$temp_dir/home/2026-01-02"
mkdir -p "$home"
cp "$green" "$home/custodian-log.jsonl"
CUSTODIAN_HOME="$temp_dir/home" "$runner" --date 2026-01-02 >/dev/null 2>&1
[ "$?" -eq 0 ] && result=0 || result=1
check "DATE: --date resolves the log under CUSTODIAN_HOME" "$result"
CUSTODIAN_HOME="$temp_dir/home" "$runner" --date 1999-12-31 >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1
check "DATE: a date with no log exits 2 (the value is not discarded)" "$result"

# --- shape regressions, each currently correct and otherwise unpinned. ---
crlf="$temp_dir/crlf.jsonl"
printf '{"phase":"E","action":"e"}\r\n{"phase":"B","action":"b"}\r\n' > "$crlf"
out=$("$runner" --log "$crlf"); rc=$?
printf '%s\n' "$out" | grep -q '2 phase records · 0 malformed'
check "CRLF: carriage returns do not make a line malformed" $?
[ "$rc" -eq 1 ] && result=0 || result=1
check "CRLF: the violation in a CRLF log is still found" "$result"
notail="$temp_dir/notail.jsonl"
printf '{"phase":"E","action":"e"}\n{"phase":"B","action":"b"}' > "$notail"
out=$("$runner" --log "$notail"); rc=$?
printf '%s\n' "$out" | grep -q '2 phase records'
check "NO-EOL: a log with no trailing newline keeps its last record" $?
lead="$temp_dir/lead.jsonl"
printf '%s\n' '{"phase":"resume","action":"resume first"}' \
               '{"phase":"E","action":"e"}' \
               '{"phase":"B","action":"b"}' > "$lead"
out=$("$runner" --log "$lead"); rc=$?
printf '%s\n' "$out" | grep -q 'VIOLATION P1  segment 2'
check "LEAD-RESUME: a log opening on a resume marker numbers from segment 2" $?
[ "$rc" -eq 1 ] && result=0 || result=1
check "LEAD-RESUME: and still reports the violation" "$result"
weave="$temp_dir/weave.jsonl"
printf '%s\n' '{"phase":"E","action":"e1"}' '{"phase":"B","action":"b1"}' \
               '{"phase":"E","action":"e2"}' '{"phase":"B","action":"b2"}' \
               '{"phase":"E","action":"e3"}' > "$weave"
out=$("$runner" --log "$weave"); rc=$?
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 2  (P1 2 phase-E lines · P2 0 segments)'
check "WEAVE: E,B,E,B,E flags the two E lines a later B follows, not the third" $?
agree "WEAVE:"

echo
# an assertion floor: a suite that silently stopped asserting still prints
# "all tests passed" off a zero failure counter, so the count is verified too.
# Pegged at the exact number of arms, not a round number under it — slack here
# is arms that can be deleted in silence.
[ "$checks" -eq 61 ] || { printf 'FAIL  %d assertion(s) ran, expected exactly 61\n' "$checks"; fails=$((fails + 1)); }
if [ "$fails" -eq 0 ]; then echo "all phase-order tests passed ($checks assertions)"; exit 0
else echo "$fails phase-order test(s) FAILED"; exit 1; fi
