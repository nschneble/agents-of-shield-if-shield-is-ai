#!/usr/bin/env bash
# custodian-log-recall.test.sh — both-directions test for the recall check.
#
# Both directions matter more here than in most suites, because the
# failure this check exists to catch is an ABSENCE. A check that reports
# a missing line is easy; a check that stays quiet when the line is
# present, and that refuses to call an unfired rule clean, is the part
# that can silently rot into "always green" or "always red".
#
# So four verdict classes are pinned, not two: SATISFIED, VIOLATION,
# NOT EVALUABLE, and the UNDECLARED exit that fires when the spec grows
# a requirement nobody taught the check to time.
#
# Self-contained: fixture spec + fixture logs in a temp dir. No git, no
# network, and it never reads the real local/custodian corpus.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check="$here/custodian-log-recall.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-recall.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] || die_temp "mktemp -d exited 0 with no path"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

# verdict and assertion count both derived from a log, never from a shell
# counter — the false-green shape scripts/validate-looper-config.test.sh
# documents.
results="$temp_dir/results.log"
: > "$results" || die_temp "cannot open the results log at $results"
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; printf 'ok\n' >> "$results"
  else printf 'FAIL  %s\n' "$1"; printf 'FAIL\n' >> "$results"; fi
}

spec="$temp_dir/SKILL.md"
# BOTH prescribed strings, because the second trigger arm is otherwise
# unreachable from the suite: with only one string prescribed, the
# usage-window predicate could be deleted outright and nothing reddened
write_spec() {
  printf 'Spec fixture.\n\nRe-probe once and log `action "window cost"`.\nDefer and log `action "deferred (usage-window)"` when hot.\n' \
    > "$spec"
}
write_spec

logs_root="$temp_dir/logs"
mkdir -p "$logs_root/2026-01-01" || die_temp "cannot build $logs_root"
log="$logs_root/2026-01-01/custodian-log.jsonl"

run() { out=$("$check" --spec "$spec" --logs-root "$logs_root" 2>&1); rc=$?; }

# --- VIOLATION: trigger fired, prescribed line never written ------------
cat > "$log" <<'JSON'
{"phase":"E","ran":true,"action":"deep-research completed","detail":"ok"}
{"phase":"E","ran":false,"action":"deferred (usage-window)","detail":"five_hour 0.97"}
{"phase":"F","ran":true,"action":"issue opened","detail":"ok"}
JSON
run
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'VIOLATION.*window cost'
check "trigger fired + line absent = VIOLATION, exit 1 (got $rc)" $?

# --- SATISFIED: the same corpus, with the prescribed line written -------
cat > "$log" <<'JSON'
{"phase":"E","ran":true,"action":"deep-research completed","detail":"ok"}
{"phase":"E","ran":true,"action":"window cost","detail":"0.31 -> 0.44"}
{"phase":"E","ran":false,"action":"deferred (usage-window)","detail":"five_hour 0.97"}
JSON
run
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'SATISFIED.*window cost'
check "line present = SATISFIED, exit 0 (got $rc)" $?

# The direction a rotted check fails silently: it must not still be
# shouting VIOLATION once the line exists.
! printf '%s\n' "$out" | grep -q 'VIOLATION.*window cost'
check "a satisfied rule is not also reported as a violation" $?

# --- NOT EVALUABLE: no line, and no trigger either ----------------------
cat > "$log" <<'JSON'
{"phase":"B","ran":true,"action":"memory audit","detail":"ok"}
{"phase":"E","ran":false,"action":"NOT RUN — deep-research not invokable","detail":"n/a"}
{"phase":"E","ran":false,"action":"deferred (usage-window)","detail":"five_hour 0.97"}
JSON
run
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'NOT EVALUABLE.*window cost'
check "no line + no trigger = NOT EVALUABLE, exit 0 (got $rc)" $?

# and it must not read as clean silence — the class has to be printed
printf '%s\n' "$out" | grep -q 'not evaluable'
check "the tally names the not-evaluable count rather than implying clean" $?

# an excluded phrasing is what makes that arm work: the record mentions
# deep-research while saying it never ran, so it owes no re-probe
# matches the verdict CLASS, not the bare word: the tally line always
# reads `TOTAL VIOLATIONS: n`, so grepping for VIOLATION alone is true
# even on a clean run and asserts nothing.
! printf '%s\n' "$out" | grep -q 'VIOLATION  '
check "a deep-research mention that says it never ran is not a trigger" $?

# --- UNDECLARED: spec grows a requirement with no declared trigger ------
printf 'Spec fixture.\n\nAlways log `action "teleport the log"` afterwards.\n' > "$spec"
run
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'UNDECLARED'
check "a prescribed action with no declared trigger exits 2 (got $rc)" $?

# --- unusable inputs are exit 2, never a clean pass ---------------------
write_spec
out=$("$check" --spec "$temp_dir/absent.md" --logs-root "$logs_root" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a missing spec exits 2 (got $rc)" $?

out=$("$check" --spec "$spec" --logs-root "$temp_dir/no-such-root" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "no logs anywhere exits 2 (got $rc)" $?

printf 'No requirements here.\n' > "$temp_dir/bare.md"
out=$("$check" --spec "$temp_dir/bare.md" --logs-root "$logs_root" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a spec prescribing nothing exits 2 rather than passing (got $rc)" $?

out=$("$check" --spec 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a value-taking flag with no value exits 2 (got $rc)" $?

# --- a malformed log line must not abort the sweep ----------------------
write_spec
cat > "$log" <<'JSON'
not json at all
{"phase":"E","ran":true,"action":"deep-research completed","detail":"ok"}
{"phase":"E","ran":false,"action":"deferred (usage-window)","detail":"five_hour 0.97"}
JSON
run
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'VIOLATION.*window cost'
check "a malformed line does not stop the sweep (got $rc)" $?

# --- the exclusion list, ONE ALTERNATIVE AT A TIME ---------------------
# The trigger excludes six phrasings that all mean deep-research never
# ran. A single record tripping several at once cannot tell a working
# exclusion list from one missing an alternative — the same
# trips-every-condition-at-once defect the G1 fixtures had.
excl_case() { # label, action text
  cat > "$log" <<JSON
{"phase":"E","ran":false,"action":"$2","detail":"n/a"}
{"phase":"E","ran":false,"action":"deferred (usage-window)","detail":"five_hour 0.97"}
JSON
  run
  [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'NOT EVALUABLE.*window cost'
  check "$1 alone is not a deep-research trigger (got $rc)" $?
}
excl_case "not installed"  "DEGRADED MODE — deep-research skill not installed"
excl_case "not nestable"   "deep-research not nestable from a subagent"
# no other alternative in this text: "bars deep-research" would also
# exclude it, and then dropping the lowercase arm changes nothing
excl_case "lowercase not run" "deep-research did not run this week"
excl_case "not invokable"  "deep-research was not invokable here"

# the phase gate holds on its own: the same text on a non-E line owes
# nothing, so a predicate that dropped `.phase == "E"` would over-fire
cat > "$log" <<'JSON'
{"phase":"C","ran":true,"action":"deep-research completed","detail":"ok"}
{"phase":"E","ran":false,"action":"deferred (usage-window)","detail":"five_hour 0.97"}
JSON
run
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'NOT EVALUABLE.*window cost'
check "a deep-research line outside phase E is not a trigger (got $rc)" $?

# a prescribed string living ONLY in references/ still counts. This
# branch moved spec sections into references/, so a harvest that skipped
# them would silently shrink the denominator.
mkdir -p "$temp_dir/references"
printf 'Only here.\n\nAlways log `action "window cost"` after research.\n' \
  > "$temp_dir/references/extracted.md"
printf 'Spec fixture with the string only in references.\n\nDefer and log `action "deferred (usage-window)"`.\n' > "$spec"
cat > "$log" <<'JSON'
{"phase":"E","ran":true,"action":"deep-research completed","detail":"ok"}
{"phase":"E","ran":false,"action":"deferred (usage-window)","detail":"five_hour 0.97"}
JSON
run
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'VIOLATION.*window cost'
check "a string prescribed only in references/ is still harvested (got $rc)" $?
rm -rf "$temp_dir/references"
write_spec

# --- a corpus with nothing parseable is unusable, not clean ------------
cat > "$log" <<'JSON'
not json
still not json
JSON
run
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check "a corpus with no parseable record exits 2 (got $rc)" $?

EXPECTED_CHECKS=19
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran custodian-log-recall tests passed"; exit 0
else
  echo "custodian-log-recall FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1
fi
