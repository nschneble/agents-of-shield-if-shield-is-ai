#!/usr/bin/env bash
# spec-load.test.sh — both-directions test for the spec-load instrument.
#
# Fixture repo in a temp dir; verdict from a results log, with the
# assertion count asserted beside it, same shape as
# scripts/validate-looper-config.test.sh.
#
# The arm that matters most is the MISSING one. This instrument exists to
# prove later waves cut what they claim, so its own failure mode is
# reporting a saving it did not measure: a renamed file silently leaving
# the sum. That arm is asserted in both directions — the row present and
# resolving, and the row present and dangling.
# Background: docs/test-suites.md#spec-load
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/spec-load.sh"

# a failing mktemp returns empty, which makes every derived path absolute
# (/fixture). The mkdir below then fails while silenced and the fixture
# writes land in the CALLER's repo. Refuse to run instead. The explicit
# template is what makes TMPDIR the input the message names: a bare
# `mktemp -d` ignores TMPDIR on BSD, allocating under /var/folders.
die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/spec-load-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

# Both the verdict and the assertion count are DERIVED from a log this
# function appends to, never from a shell counter it increments. A counter
# can be deleted in one token and leave the suite printing FAIL lines while
# exiting 0; a log cannot shorten without tripping the count below.
results="$temp_dir/results.log"
: > "$results" || die_temp "cannot open the results log at $results"
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; printf 'ok\n' >> "$results"
  else printf 'FAIL  %s\n' "$1"; printf 'FAIL\n' >> "$results"; fi
}

fix="$temp_dir/fixture"
mkdir -p "$fix/agents" "$fix/skills/alpha" || die_temp "cannot build the fixture"

# 400 chars -> 100 tokens on the chars/4 proxy, so the sums below are
# hand-checkable rather than whatever the real corpus happens to weigh
printf '%0.sx' $(seq 1 400) > "$fix/agents/one.md"
printf '%0.sx' $(seq 1 800) > "$fix/skills/alpha/SKILL.md"

man="$temp_dir/manifest.tsv"
cat > "$man" <<'EOF'
# entry	path	condition
demo	agents/one.md	always
demo	skills/alpha/SKILL.md	sometimes
EOF

# --- clean run: exit 0, and the always/conditional split is not merged ---
out=$("$script" --root "$fix" --manifest "$man" 2>&1); rc=$?
check "clean manifest exits 0" "$([ "$rc" -eq 0 ]; echo $?)"
check "reports the always subtotal (100)" \
  "$(grep -qE '\b100 always' <<< "$out"; echo $?)"
check "reports the conditional tail separately (200)" \
  "$(grep -qE 'up to +200 conditional' <<< "$out"; echo $?)"
check "reports the combined total (300)" \
  "$(grep -q '= 300' <<< "$out"; echo $?)"

# --- the arm this instrument exists for: a row whose file is gone ---
man_missing="$temp_dir/manifest-missing.tsv"
cat > "$man_missing" <<'EOF'
demo	agents/one.md	always
demo	agents/vanished.md	always
EOF
out=$("$script" --root "$fix" --manifest "$man_missing" 2>&1); rc=$?
check "a row naming a missing file exits 2" "$([ "$rc" -eq 2 ]; echo $?)"
check "names the missing path" "$(grep -q 'vanished.md' <<< "$out"; echo $?)"
# `grep -qv PATTERN` succeeds whenever ANY line differs, so it can never
# fail here — the negation has to be on grep's own verdict, not its -v flag
check "does NOT report a total for the entry it could not measure" \
  "$(! grep -q 'always' <<< "$out"; echo $?)"

# --- unusable input ---
: > "$temp_dir/empty.tsv"
"$script" --root "$fix" --manifest "$temp_dir/empty.tsv" >/dev/null 2>&1
check "empty manifest exits 2" "$([ $? -eq 2 ]; echo $?)"

"$script" --root "$fix" --manifest "$temp_dir/nope.tsv" >/dev/null 2>&1
check "absent manifest exits 2" "$([ $? -eq 2 ]; echo $?)"

printf '# only a comment\n' > "$temp_dir/comments.tsv"
"$script" --root "$fix" --manifest "$temp_dir/comments.tsv" >/dev/null 2>&1
check "comment-only manifest exits 2, not a clean sweep" "$([ $? -eq 2 ]; echo $?)"

printf 'demo\tagents/one.md\n' > "$temp_dir/short.tsv"
"$script" --root "$fix" --manifest "$temp_dir/short.tsv" >/dev/null 2>&1
check "row missing its condition exits 2" "$([ $? -eq 2 ]; echo $?)"

"$script" --root "$fix" --manifest "$man" --bogus >/dev/null 2>&1
check "unknown flag exits 2" "$([ $? -eq 2 ]; echo $?)"

"$script" --root "$fix" --entry >/dev/null 2>&1
check "flag with no value exits 2" "$([ $? -eq 2 ]; echo $?)"

# --- baseline: unchanged, grown, and dropped ---
base="$temp_dir/baseline.tsv"
"$script" --root "$fix" --manifest "$man" --write-baseline "$base" >/dev/null 2>&1
check "--write-baseline produces a non-empty file" "$([ -s "$base" ]; echo $?)"

"$script" --root "$fix" --manifest "$man" --baseline "$base" >/dev/null 2>&1
check "unchanged corpus passes its baseline" "$([ $? -eq 0 ]; echo $?)"

# grow the always-file past its recorded figure
printf '%0.sx' $(seq 1 800) > "$fix/agents/one.md"
out=$("$script" --root "$fix" --manifest "$man" --baseline "$base" 2>&1); rc=$?
check "growth past baseline exits 1" "$([ "$rc" -eq 1 ]; echo $?)"
check "growth names the entry and the delta" \
  "$(grep -q 'GREW .*demo' <<< "$out"; echo $?)"
printf '%0.sx' $(seq 1 400) > "$fix/agents/one.md"

# a baseline entry the manifest no longer measures must not read as a pass
printf 'ghost\t500\t0\n' >> "$base"
"$script" --root "$fix" --manifest "$man" --baseline "$base" >/dev/null 2>&1
check "an entry dropped from the manifest exits 2" "$([ $? -eq 2 ]; echo $?)"

printf 'demo\tnot-a-number\t0\n' > "$temp_dir/bad-base.tsv"
"$script" --root "$fix" --manifest "$man" --baseline "$temp_dir/bad-base.tsv" >/dev/null 2>&1
check "malformed baseline exits 2" "$([ $? -eq 2 ]; echo $?)"

: > "$temp_dir/empty-base.tsv"
"$script" --root "$fix" --manifest "$man" --baseline "$temp_dir/empty-base.tsv" >/dev/null 2>&1
check "empty baseline exits 2" "$([ $? -eq 2 ]; echo $?)"

# --- the real manifest resolves, every row ---
"$script" >/dev/null 2>&1
check "the repo's own manifest resolves every row" "$([ $? -eq 0 ]; echo $?)"

# --- verdict, derived from the log ---
total=$(grep -c . "$results")
failed=$(grep -c '^FAIL$' "$results")
expected=21
echo
if [ "$total" -ne "$expected" ]; then
  echo "SUITE BROKEN: logged $total assertions, expected $expected" >&2
  echo "  An assertion was added or removed without updating the count." >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "$failed of $total spec-load assertions FAILED" >&2
  exit 1
fi
echo "all $total spec-load tests passed"
