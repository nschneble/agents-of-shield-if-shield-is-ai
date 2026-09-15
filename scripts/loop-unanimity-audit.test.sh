#!/usr/bin/env bash
# loop-unanimity-audit.test.sh — both-directions test. Every exclusion arm
# is paired with the fixture it excludes, so a finding count of 0 over real
# data is a claim the positive control has already proved falsifiable.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check_sh="$here/loop-unanimity-audit.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-unanimity.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] || die_temp "mktemp -d exited 0 with no path"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
# u+rwX first: a fixture chmods a subtree to 000 and a crash would
# strand it
trap 'chmod -R u+rwX "$temp_dir" 2>/dev/null; rm -rf "$temp_dir"' EXIT

results="$temp_dir/results.log"
: > "$results" || die_temp "cannot open the results log at $results"
check() {
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; printf 'ok\n' >> "$results"
  else printf 'FAIL  %s\n' "$1"; printf 'FAIL\n' >> "$results"; fi
}

index="$temp_dir/index.jsonl"
empty_root="$temp_dir/empty-root"
mkdir -p "$empty_root" || die_temp "cannot build $empty_root"

run() { "$check_sh" --index "$index" --census "$empty_root" "$@" 2>&1; }

# a crew line: repo, branch, wave, agent, blockers, verified_by, line no
row() {
  printf '{"repo":"%s","branch":"%s","wave":%s,"kind":"crew","agent":"%s",' "$1" "$2" "$3" "$4"
  printf '"ran":true,"blockers":%s,"verified_by":%s,"verdict":"v",' "$5" "$6"
  printf '"cite":"%s/local/loops/%s/gates.jsonl:%s"}\n' "$1" "$2" "$7"
}

# --- positive control: 3 reviewers, all clean, all llm ------------------
{ row r b 1 the-stickler 0 '"llm"' 1
  row r b 1 the-chemist  0 '"llm"' 2
  row r b 1 the-auditor  0 null    3; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'r/b wave 1'
check "a unanimous all-clean llm-only group is found, exit 1 (got $rc)" $?

printf '%s\n' "$out" | grep -q 'modern-era                       1'
check "the positive control lands in the modern-era bucket, not legacy" $?

printf '%s\n' "$out" | grep -q 'VERDICT: 1 of 1'
check "the verdict line reports 1 of 1 unanimous groups unbacked" $?

# --- the mutation: one reviewer claims execution, finding disappears ----
{ row r b 1 the-stickler 0 '"llm"'        1
  row r b 1 the-chemist  0 '"llm"'        2
  row r b 1 the-auditor  0 '"executable"' 3; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'no modern-era group'
check "one executable line clears the whole group, exit 0 (got $rc)" $?

printf '%s\n' "$out" | grep -q 'T2 zero (no verified_by == "executable")      0'
check "T2 agrees the group is backed once a line says executable" $?

# --- a prose provenance is not llm/null: T1 clears, T2 still flags ------
{ row r b 1 the-stickler 0 '"llm"'                   1
  row r b 1 the-chemist  0 '"llm"'                   2
  row r b 1 the-auditor  0 '"orchestrator, ran it"'  3; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ]
check "a prose provenance disqualifies the group from T1 (got $rc)" $?

printf '%s\n' "$out" | grep -q 'T2 zero (no verified_by == "executable")      1'
check "T2 still counts the prose group as unbacked" $?

# --- a single reviewer is not a unanimity ------------------------------
row r b 1 the-stickler 0 '"llm"' 1 > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'single-reviewer            1'
check "one reviewer alone is excluded and counted (got $rc)" $?

# --- the same agent twice is still one reviewer ------------------------
{ row r b 1 the-stickler 0 '"llm"' 1
  row r b 1 the-stickler 0 '"llm"' 2; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'single-reviewer            1'
check "two lines from one agent do not make a unanimity (got $rc)" $?

# --- a null agent is a rollup too, not an anonymous reviewer -----------
{ printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":null,"ran":true,"blockers":0,"verified_by":"llm","cite":"r/local/loops/b/gates.jsonl:1"}\n'
  row r b 1 the-chemist 0 '"llm"' 2; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'rollup-agent               1'
check "a null agent excludes the group as a rollup (got $rc)" $?

printf '%s\n' "$out" | grep -q 'modern-era                       0'
check "a null-agent group never reaches the finding bucket" $?

# --- a rollup line is not a set of reviewers ---------------------------
{ row r b 1 ALL-SIX-ENUMERATED 0 '"llm"' 1
  row r b 1 the-chemist        0 '"llm"' 2; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'rollup-agent               1'
check "an all-six rollup excludes the group and is counted (got $rc)" $?

{ row r b 1 the-chemist/the-improver 0 '"llm"' 1
  row r b 1 the-auditor              0 '"llm"' 2; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'rollup-agent               1'
check "a slash-joined multi-agent line is treated as a rollup (got $rc)" $?

# --- legacy era: the field predates the record, so it is unevidenced ---
{ printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"cite":"r/local/loops/b/gates.jsonl:1"}\n'
  printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-chemist","ran":true,"blockers":0,"cite":"r/local/loops/b/gates.jsonl:2"}\n'; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'all-legacy-era (field predates)  1'
check "a pre-schema group is legacy-era, not a finding (got $rc)" $?

printf '%s\n' "$out" | grep -q 'modern-era                       0'
check "the legacy group does not leak into the modern-era count" $?

# --- mixed era: the three sub-buckets must partition t1_zero -----------
{ row r b 1 the-stickler 0 '"llm"' 1
  row r b 1 the-chemist  0 '"llm"' 2
  printf '{"repo":"r","branch":"b","wave":2,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"cite":"r/local/loops/b/gates.jsonl:3"}\n'
  printf '{"repo":"r","branch":"b","wave":2,"kind":"crew","agent":"the-chemist","ran":true,"blockers":0,"cite":"r/local/loops/b/gates.jsonl:4"}\n'
  row r b 3 the-stickler 0 '"llm"' 5
  printf '{"repo":"r","branch":"b","wave":3,"kind":"crew","agent":"the-chemist","ran":true,"blockers":0,"cite":"r/local/loops/b/gates.jsonl:6"}\n'; } > "$index"
out=$(run); rc=$?

# read the token after the marker: a label can be reworded, the
# count cannot
num_after() {
  printf '%s\n' "$out" \
    | awk -v m="$1" '{for (i = 1; i <= NF; i++) if ($i == m) { print $(i + 1); exit }}'
}
t1z=$(num_after 'llm/null/absent)'); legacy=$(num_after 'predates)')
mixed=$(num_after 'predate)');       modern=$(num_after 'modern-era')

[ "$t1z" = "3" ]
check "all three unbacked groups land in t1_zero (got ${t1z:-none})" $?

[ "$mixed" = "1" ] && [ "$legacy" = "1" ] && [ "$modern" = "1" ]
check "the mixed-era group is its own bucket, not legacy or modern (got legacy=${legacy:-none} mixed=${mixed:-none} modern=${modern:-none})" $?

[ -n "$t1z" ] && [ $((legacy + mixed + modern)) -eq "$t1z" ]
check "the sub-buckets sum to t1_zero ($legacy+$mixed+$modern vs $t1z)" $?

# --- a blocker means the pass was not unanimously clean ----------------
{ row r b 1 the-stickler 0 '"llm"' 1
  row r b 1 the-chemist  1 '"llm"' 2; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'UNANIMOUS all-clean        0'
check "one reviewer with a blocker breaks all-clean (got $rc)" $?

# --- all flagging is its own bucket, never an all-clean unanimity ------
{ row r b 1 the-stickler 2 '"llm"' 1
  row r b 1 the-chemist  1 '"llm"' 2; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'unanimous all-flagging     1'
check "an all-flagging group is counted separately (got $rc)" $?

# --- a line that never ran carries no verdict and is dropped -----------
{ row r b 1 the-stickler 0 '"llm"' 1
  row r b 1 the-chemist  0 '"llm"' 2
  printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-auditor","ran":null,"blockers":0,"verified_by":null,"cite":"r/local/loops/b/gates.jsonl:3"}\n'; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '2 reviewer(s) ran of 3 crew line(s) logged'
check "a not-ran line is dropped but still shown as dispatched (got $rc)" $?

printf '%s\n' "$out" | grep -q 'dropped 1 not-ran'
check "the dropped not-ran line is reported, not silently swallowed" $?

# --- crew spelling variants must still count as crew -------------------
{ printf '{"repo":"r","branch":"b","wave":1,"kind":"crew-final","agent":"the-stickler","ran":true,"blockers":0,"verified_by":"llm","cite":"r/local/loops/b/gates.jsonl:1"}\n'
  printf '{"repo":"r","branch":"b","wave":1,"kind":"final-crew","agent":"the-chemist","ran":true,"blockers":0,"verified_by":"llm","cite":"r/local/loops/b/gates.jsonl:2"}\n'; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 1 ]
check "crew-final and final-crew are seen as crew lines (got $rc)" $?

# --- a non-crew kind is not a reviewer --------------------------------
{ printf '{"repo":"r","branch":"b","wave":1,"kind":"executor-handback","agent":"the-looper","ran":true,"blockers":0,"verified_by":"llm","cite":"r/local/loops/b/gates.jsonl:1"}\n'
  row r b 1 the-chemist 0 '"llm"' 2; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'single-reviewer            1'
check "an executor-handback line is not counted as a reviewer (got $rc)" $?

# --- pass splits a wave into separate groups --------------------------
{ printf '{"repo":"r","branch":"b","wave":1,"pass":"interim","kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"verified_by":"llm","cite":"r/local/loops/b/gates.jsonl:1"}\n'
  printf '{"repo":"r","branch":"b","wave":1,"pass":"final","kind":"crew","agent":"the-chemist","ran":true,"blockers":0,"verified_by":"llm","cite":"r/local/loops/b/gates.jsonl:2"}\n'; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'carrying a real pass field 2'
check "two passes of one wave are two groups, not a unanimity (got $rc)" $?

# --- --min-agents raises the bar --------------------------------------
{ row r b 1 the-stickler 0 '"llm"' 1
  row r b 1 the-chemist  0 '"llm"' 2; } > "$index"
out=$(run --min-agents 3); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'single-reviewer            1'
check "--min-agents 3 excludes a 2-reviewer group (got $rc)" $?

# --- the census arm reads a live gates.jsonl and dedups against it -----
live="$temp_dir/root/r/local/loops/b"
mkdir -p "$live" || die_temp "cannot build $live"
{ row r b 1 the-stickler 0 '"llm"' 1
  row r b 1 the-chemist  0 '"llm"' 2; } | sed 's/,"cite":"[^"]*"//' > "$live/gates.jsonl"
out=$("$check_sh" --no-index --census "$temp_dir/root" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'census 2 line(s) from 1 file(s)'
check "the census arm finds a live gates.jsonl on its own (got $rc)" $?

out=$("$check_sh" --no-index --census "$temp_dir/root//" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '    r/b wave 1'
check "a trailing slash on --census still yields repo 'r' (got $rc)" $?

out=$("$check_sh" --index "$index" --census "$temp_dir/root" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'index 2 line(s) · census 2 line(s)'
check "both arms really do carry the same 2 lines (got $rc)" $?

# the group count alone cannot see dedup — 4 dupes still make one group
printf '%s\n' "$out" | grep -q '2 deduped · 2 crew'
check "4 corpus lines collapse to 2 on cite, not 4" $?

# --- on a cite collision the live row wins, not the index snapshot -----
stale="$temp_dir/root-stale"
mkdir -p "$stale/r/local/loops/b" || die_temp "cannot build $stale"
{ printf '{"wave":1,"pass":"final","kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"verified_by":"llm"}\n'
  printf '{"wave":1,"pass":"final","kind":"crew","agent":"the-chemist","ran":true,"blockers":0,"verified_by":"llm"}\n'; } \
  > "$stale/r/local/loops/b/gates.jsonl"
{ printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"cite":"r/local/loops/b/gates.jsonl:1"}\n'
  printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-chemist","ran":true,"blockers":0,"cite":"r/local/loops/b/gates.jsonl:2"}\n'; } > "$index"
out=$("$check_sh" --index "$index" --census "$stale" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q '2 deduped · 2 crew'
check "the index and live copies of one line really do collide (got $rc)" $?

[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'carrying a real pass field 1'
check "the surviving row keeps the live pass, not the index's absent one (got $rc)" $?

printf '%s\n' "$out" | grep -q 'modern-era                       1'
check "the surviving row keeps live verified_by, so the era is modern" $?

# --- an unreadable census subtree is announced, not silently dropped ---
perms="$temp_dir/root-perms"
mkdir -p "$perms/ra/local/loops/b" "$perms/rb/local/loops/b" \
  || die_temp "cannot build $perms"
{ row ra b 1 the-stickler 0 '"llm"' 1
  row ra b 1 the-chemist  0 '"llm"' 2; } | sed 's/,"cite":"[^"]*"//' \
  > "$perms/ra/local/loops/b/gates.jsonl"
{ row rb b 1 the-stickler 0 '"llm"' 1
  row rb b 1 the-chemist  0 '"llm"' 2; } | sed 's/,"cite":"[^"]*"//' \
  > "$perms/rb/local/loops/b/gates.jsonl"
chmod 000 "$perms/rb/local"
readable=0; ls "$perms/rb/local" >/dev/null 2>&1 && readable=1
chmod 755 "$perms/rb/local"
[ "$readable" -eq 0 ] || die_temp "chmod 000 did not block this user; the fixture cannot prove anything"
chmod 000 "$perms/rb/local"
out=$("$check_sh" --no-index --census "$perms" 2>&1); rc=$?
chmod 755 "$perms/rb/local"

printf '%s\n' "$out" | grep -q 'WARNING:  census could not read 1 path(s)'
check "an unreadable census subtree raises a warning (got $rc)" $?

printf '%s\n' "$out" | grep -q 'census 2 line(s) from 1 file(s)'
check "and the warning is about real loss — rb's 2 lines are absent" $?

out=$("$check_sh" --no-index --census "$perms" 2>&1)
printf '%s\n' "$out" | grep -q 'WARNING'; warned=$?
[ "$warned" -ne 0 ]
check "a fully readable census raises no warning" $?

# --- with no cite, dedup falls back to repo|branch|kind|agent|summary --
{ printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"verified_by":"llm","summary":"same"}\n'
  printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-chemist","ran":true,"blockers":0,"verified_by":"llm","summary":"other"}\n'
  printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"verified_by":"llm","summary":"same"}\n'; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '2 deduped · 2 crew'
check "3 cite-less rows collapse to 2 on the fallback key (got $rc)" $?

printf '%s\n' "$out" | grep -q '2 reviewer(s) ran of 2 crew line(s) logged'
check "the fallback key still keeps the two distinct agents apart" $?

{ printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"verified_by":"llm","summary":"same"}\n'
  printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-chemist","ran":true,"blockers":0,"verified_by":"llm","summary":"other"}\n'
  printf '{"repo":"r","branch":"b","wave":1,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0,"verified_by":"llm","summary":"third"}\n'; } > "$index"
out=$(run); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q '3 deduped · 3 crew'
check "a differing summary is not deduped away by the fallback key (got $rc)" $?

# --- usage errors are exit 2, never a silent clean run ----------------
"$check_sh" --index "$temp_dir/nope.jsonl" --census "$empty_root" >/dev/null 2>&1
[ $? -eq 2 ]
check "a missing index exits 2"  $?

"$check_sh" --bogus >/dev/null 2>&1
[ $? -eq 2 ]
check "an unknown flag exits 2" $?

"$check_sh" --index "$index" --min-agents x >/dev/null 2>&1
[ $? -eq 2 ]
check "a non-numeric --min-agents exits 2" $?

"$check_sh" --no-index --no-census >/dev/null 2>&1
[ $? -eq 2 ]
check "dropping both corpus arms exits 2" $?

"$check_sh" --index >/dev/null 2>&1
[ $? -eq 2 ]
check "a flag missing its value exits 2" $?

# a corpus that parses to nothing is unusable input, not a clean result
printf 'not json\nstill not json\n' > "$index"
out=$("$check_sh" --index "$index" --census "$empty_root" 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check "a wholly unparseable corpus exits 2 (got $rc)" $?

EXPECTED_CHECKS=45
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran loop-unanimity-audit tests passed"; exit 0
else
  echo "loop-unanimity-audit FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1
fi
