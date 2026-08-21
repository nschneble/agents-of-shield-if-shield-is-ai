#!/usr/bin/env bash
# custodian-mutation-kill.test.sh — both-directions test for the mutation
# harness.
#
# killed, SURVIVED, and DID NOT APPLY, pinned against fixtures.
# Background: docs/test-suites.md#custodian-mutation-kill
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
harness="$here/custodian-mutation-kill.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-mutkill-t.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] || die_temp "mktemp -d exited 0 with no path"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

results="$temp_dir/results.log"
: > "$results" || die_temp "cannot open the results log at $results"
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; printf 'ok\n' >> "$results"
  else printf 'FAIL  %s\n' "$1"; printf 'FAIL\n' >> "$results"; fi
}

root="$temp_dir/root"
mkdir -p "$root/scripts" || die_temp "cannot build $root"

# subject: a check whose rule is a two-condition `or`, the shape that
# started this
# the rule is written without shell sigils on the mutated line, because
# \Q interpolates and a `$1` in a pattern silently matches nothing — the
# trap the harness itself documents
cat > "$root/scripts/subject.sh" <<'SH'
#!/usr/bin/env bash
case "$1:$2" in
  bad:*|*:bad) exit 0;;
esac
exit 1
SH

# a suite that exercises BOTH conditions separately — it can tell a
# working predicate from a broken one
cat > "$root/scripts/subject.test.sh" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$here/subject.sh" bad good || exit 1
bash "$here/subject.sh" good bad || exit 1
bash "$here/subject.sh" good good && exit 1
exit 0
SH

# a suite that only ever tries the both-bad case — blind to either
# disjunct being dropped, the exact gap this harness was written to find
cat > "$root/scripts/blind.test.sh" <<'SH'
#!/usr/bin/env bash
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$here/subject.sh" bad bad || exit 1
exit 0
SH
chmod +x "$root/scripts/"*.sh

table="$temp_dir/table"
run() { out=$("$harness" --root "$root" --table "$table" 2>&1); rc=$?; }

# --- killed: the suite separates the conditions -------------------------
printf 'drop-second|subject.sh|subject.test.sh|%s\n' \
  's/\Qbad:*|*:bad\E/bad:*/' > "$table"
run
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '  killed          drop-second'
check "a suite that separates the conditions kills the mutant, exit 0 (got $rc)" $?

# --- SURVIVED: the blind suite cannot ----------------------------------
printf 'drop-second|subject.sh|blind.test.sh|%s\n' \
  's/\Qbad:*|*:bad\E/bad:*/' > "$table"
run
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'SURVIVED        drop-second'
check "a blind suite lets the mutant survive, exit 1 (got $rc)" $?

# --- DID NOT APPLY: a pattern matching nothing is never a kill ----------
printf 'ghost|subject.sh|subject.test.sh|%s\n' \
  's/\Qthis text is not in the file\E/replacement/' > "$table"
run
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'DID NOT APPLY   ghost'
check "a non-matching pattern reports DID NOT APPLY, exit 1 (got $rc)" $?

! printf '%s\n' "$out" | grep -q '  killed          ghost'
check "a mutant that never applied is not scored as killed" $?

# --- a red baseline stops the run rather than scoring against it --------
cat > "$root/scripts/broken.test.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$root/scripts/broken.test.sh"
printf 'x|subject.sh|broken.test.sh|%s\n' \
  's/\Qbad:*|*:bad\E/bad:*/' > "$table"
run
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'BASELINE RED'
check "a suite already failing exits 2 before any mutant (got $rc)" $?

# --- unusable inputs ----------------------------------------------------
out=$("$harness" --root "$root" --table "$temp_dir/absent" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a missing table exits 2 (got $rc)" $?

printf 'x|nosuch.sh|subject.test.sh|s/a/b/\n' > "$table"
run
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'MISSING'
check "a mutant naming an absent script exits 2 (got $rc)" $?

out=$("$harness" --target 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a value-taking flag with no value exits 2 (got $rc)" $?

# --- --list names every declared mutant without running anything --------
out=$("$harness" --list 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'g1-or-to-and' \
  && ! printf '%s\n' "$out" | grep -q 'killed'
check "--list prints the real table and runs nothing (got $rc)" $?

EXPECTED_CHECKS=9
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran custodian-mutation-kill tests passed"; exit 0
else
  echo "custodian-mutation-kill FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1
fi
