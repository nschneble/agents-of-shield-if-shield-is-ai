#!/usr/bin/env bash
# guard-pr-template.test.sh — both-directions test for the PR-template guard.
#
# Fail-open arms tested as carefully as the bite. Fixture repos in a temp
# dir, fed the same PreToolUse JSON Claude Code sends.
# Background: docs/test-suites.md#guard-pr-template
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hook="$here/guard-pr-template.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-template-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] || die_temp "mktemp -d exited 0 with no path"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

# Verdict and assertion count both derive from a log, never from a shell
# counter — same reason validate-looper-config.test.sh does it: deleting
# the FAIL append must shorten the log and trip the count, not false-green.
results="$temp_dir/results.log"
: > "$results" || die_temp "cannot open the results log"
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; printf 'ok\n' >> "$results"
  else printf 'FAIL  %s\n' "$1"; printf 'FAIL\n' >> "$results"; fi
}

# a repo with the house template
repo="$temp_dir/repo"
mkdir -p "$repo/.github" || die_temp "cannot build $repo"
( cd "$repo" && git init -q . && git config user.email t@t && git config user.name t ) \
  || die_temp "cannot git init the fixture"
cat > "$repo/.github/PULL_REQUEST_TEMPLATE.md" <<'TPL'
<!-- What's the point of this PR? 1-2 sentences. -->

**Added:**

- **Changed:**

- **Fixed:**

-
TPL

# a repo with no template at all
bare="$temp_dir/bare"
mkdir -p "$bare" && ( cd "$bare" && git init -q . ) || die_temp "cannot build $bare"

run() { # $1 = command string, $2 = cwd — sets $out
  out=$(jq -cn --arg c "$1" --arg d "$2" '{cwd:$d,tool_input:{command:$c}}' \
        | "$hook" 2>/dev/null)
}
denied() { printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; }

# --- BITES: a body that uses none of the template's sections ------------
run 'gh pr create --title "T" --body "## Summary

Did a thing. Here are my own headings."' "$repo"
denied; check "own-headings body is denied" $?

printf '%s' "$out" | grep -q 'PULL_REQUEST_TEMPLATE.md'
check "the denial names the template path" $?

run 'gh pr edit 55 --body "Rewrote it my way."' "$repo"
denied; check "gh pr edit with an off-template body is denied" $?

# --- PASSES: the body engages with the template -------------------------
run 'gh pr create --body "Why. **Added:** a thing."' "$repo"
! denied; check "a body using one section marker passes" $?

# one marker is the whole bar — partial fills are the reviewer's call
run 'gh pr create --body "Why.

**Fixed:** the bug."' "$repo"
! denied; check "a partial fill passes (bar is one marker, not all)" $?

# --- --body-file: the contents are what count, not the flag -------------
good="$temp_dir/good.md"; printf '%s\n' 'Why it exists.' '' '**Changed:** things.' > "$good"
bad="$temp_dir/bad.md";  printf '%s\n' '## My Own Shape' '' 'Prose.' > "$bad"

run "gh pr create --body-file $good" "$repo"
! denied; check "--body-file following the template passes" $?

run "gh pr create --body-file $bad" "$repo"
denied; check "--body-file ignoring the template is denied" $?

# an unexpanded \$VAR is the shape the orchestrator actually writes, and
# reading it as a literal path would fail open on every real call
export PRT_FIXTURE_DIR="$temp_dir"
run 'gh pr create --body-file $PRT_FIXTURE_DIR/bad.md' "$repo"
denied; check "an unexpanded \$VAR path still resolves and is denied" $?

run 'gh pr create --body-file ${PRT_FIXTURE_DIR}/good.md' "$repo"
! denied; check "a \${VAR} path resolves and passes" $?

# command substitution in the path is never expanded — that would run it
run 'gh pr create --body-file $(cat /tmp/whatever)' "$repo"
! denied; check "a \$(...) path is not expanded, and fails open" $?

# --- FAILS OPEN: everywhere it cannot see clearly -----------------------
run 'gh pr create --title "T" --body "Anything at all."' "$bare"
! denied; check "no template in the repo means no verdict" $?

run 'gh pr edit 55 --add-label bug' "$repo"
denied && r=1 || r=0; check "a body-less gh pr edit is untouched" $r

run 'gh pr create --repo other/elsewhere --body "Free-form."' "$repo"
! denied; check "--repo targeting another tree fails open" $?

run 'gh pr create --body-file -' "$repo"
! denied; check "a body on stdin fails open" $?

run "gh pr create --body-file $temp_dir/does-not-exist.md" "$repo"
! denied; check "an unreadable body file fails open" $?

# a template with nothing extractable yields no bar to hold anyone to
comment_only="$temp_dir/commentonly"
mkdir -p "$comment_only/.github" && ( cd "$comment_only" && git init -q . )
printf '%s\n' '<!-- just say what changed -->' > "$comment_only/.github/PULL_REQUEST_TEMPLATE.md"
run 'gh pr create --body "Whatever I like."' "$comment_only"
! denied; check "a marker-less template yields no verdict" $?

# a PULL_REQUEST_TEMPLATE/ DIRECTORY holds several and auto-applies none
multi="$temp_dir/multi"
mkdir -p "$multi/.github/PULL_REQUEST_TEMPLATE" && ( cd "$multi" && git init -q . )
printf '%s\n' '**Added:**' > "$multi/.github/PULL_REQUEST_TEMPLATE/feature.md"
run 'gh pr create --body "No sections here."' "$multi"
! denied; check "a multi-template directory fails open" $?

# --- unrelated commands are never touched -------------------------------
run 'gh pr view 55 --json body' "$repo"
! denied; check "gh pr view is untouched" $?

run 'git commit -m "**Added:** nothing"' "$repo"
! denied; check "a non-gh command is untouched" $?

# --- the tally, derived from the log rather than from a counter ---------
# EXPECTED_CHECKS is the floor. Add or drop a block and this moves with
# it: a block deleted on its own reads as silence, which is what a
# both-directions suite exists to stop.
EXPECTED_CHECKS=19
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran guard-pr-template tests passed"; exit 0
else echo "guard-pr-template FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1; fi
