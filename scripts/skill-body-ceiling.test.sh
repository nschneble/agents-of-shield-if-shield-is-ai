#!/usr/bin/env bash
# skill-body-ceiling.test.sh — both-directions test for the body-ceiling
# check.
#
# Pins the shapes where the check stops checking — unreadable ceilings
# file, skipped row, comparison that never fires.
# Background: docs/test-suites.md#skill-body-ceiling
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check="$here/skill-body-ceiling.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-ceiling.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] || die_temp "mktemp -d exited 0 with no path"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

results="$temp_dir/results.log"
: > "$results" || die_temp "cannot open the results log at $results"
check_that() {
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; printf 'ok\n' >> "$results"
  else printf 'FAIL  %s\n' "$1"; printf 'FAIL\n' >> "$results"; fi
}

root="$temp_dir/root"
mkdir -p "$root/skills/alpha" || die_temp "cannot build $root"
ceilings="$temp_dir/ceilings.tsv"

# 400 bytes -> ~100 tokens under the chars/4 proxy
body() { head -c "$1" /dev/zero | tr '\0' 'x' > "$root/skills/alpha/SKILL.md"; }
row()  { printf '%s\t%s\t%s\n' "alpha" "$1" "fixture" > "$ceilings"; }
run()  { out=$("$check" --ceilings "$ceilings" --root "$root" 2>&1); rc=$?; }

# --- under the ceiling ---------------------------------------------------
body 400; row 200
run
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'ok         alpha'
check_that "a body under its ceiling passes, exit 0 (got $rc)" $?

# --- exactly at the ceiling is not over ----------------------------------
body 400; row 100
run
[ "$rc" -eq 0 ]
check_that "a body exactly at its ceiling passes (got $rc)" $?

# --- over the ceiling ----------------------------------------------------
body 800; row 100
run
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'OVER       alpha' \
  && printf '%s\n' "$out" | grep -q '+100'
check_that "a body over its ceiling fails with the overage, exit 1 (got $rc)" $?

# the remedy has to be in the output, or the failure is a riddle
printf '%s\n' "$out" | grep -q 'raise the ceiling in'
check_that "the failure names both remedies" $?

# --- slack note: a ceiling that has stopped constraining anything --------
body 400; row 1000
run
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'tokens of slack'
check_that "a ceiling far above the file reports slack (got $rc)" $?

# and a snug ceiling does NOT cry slack
body 400; row 110
run
! printf '%s\n' "$out" | grep -q 'tokens of slack'
check_that "a snug ceiling reports no slack" $?

# --- comments and blank lines are skipped, not measured ------------------
body 400
printf '# a comment\n\n%s\t%s\t%s\n' "alpha" "200" "fixture" > "$ceilings"
run
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'checked 1'
check_that "comments and blanks are skipped, the real row is checked (got $rc)" $?

# --- a file with only comments is NOT a clean run ------------------------
printf '# nothing but a comment\n' > "$ceilings"
run
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check_that "a ceilings file with no row exits 2 (got $rc)" $?

# --- unusable inputs -----------------------------------------------------
row 100
printf 'alpha\tnotanumber\tfixture\n' > "$ceilings"
run
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'MALFORMED'
check_that "a non-numeric ceiling exits 2 (got $rc)" $?

printf 'ghost\t100\tfixture\n' > "$ceilings"
run
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'MISSING'
check_that "a row naming a skill with no SKILL.md exits 2 (got $rc)" $?

out=$("$check" --ceilings "$temp_dir/absent.tsv" --root "$root" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check_that "a missing ceilings file exits 2 (got $rc)" $?

row 100; chmod 000 "$ceilings"
run; chmod 644 "$ceilings"
[ "$rc" -eq 2 ]
check_that "an unreadable ceilings file exits 2, not clean (got $rc)" $?

out=$("$check" --ceilings 2>&1); rc=$?
[ "$rc" -eq 2 ]
check_that "a value-taking flag with no value exits 2 (got $rc)" $?

# --- a slash-carrying row is a repo-relative path, not a skill name ------
mkdir -p "$root/agents"
head -c 400 /dev/zero | tr '\0' 'x' > "$root/agents/solo.md"
printf '%s\t%s\t%s\n' "agents/solo.md" "200" "fixture" > "$ceilings"
run
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'ok         agents/solo.md'
check_that "an agent row measures the path it names (got $rc)" $?

printf '%s\t%s\t%s\n' "agents/gone.md" "200" "fixture" > "$ceilings"
run
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'no agents/gone.md'
check_that "a slash row naming a missing file exits 2 (got $rc)" $?

# --- the real file is honest about the real tree -------------------------
out=$("$check" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'looper-custodian'
check_that "the committed ceilings file passes against the real tree (got $rc)" $?

EXPECTED_CHECKS=16
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran skill-body-ceiling tests passed"; exit 0
else
  echo "skill-body-ceiling FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1
fi
