#!/usr/bin/env bash
# temp-dir-guard.test.sh — both-directions test for the temp-dir guard that
# every self-contained suite carries.
#
# The defect this locks down, observed live: an unchecked
# `temp_dir=$(mktemp -d)` returns empty when the temp dir is denied or full.
# Every path derived from it then resolves absolute (/repo), the mkdir and
# cd that follow fail while silenced, and the suite's git fixture commands
# execute with the CWD still on the INVOKING repo — committing its working
# tree via `git add -A` and overwriting its user.email.
#
# RED: with mktemp forced to fail, each suite must exit non-zero, name the
# cause, and leave a victim repo byte-identical. GREEN: with a working
# mktemp each suite still passes and still leaves the victim untouched, so
# the guard costs the healthy path nothing.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# this test carries the guard it tests: without a real temp dir the victim
# repo below would resolve to /victim and the caller's repo would take the
# damage this very test exists to detect
temp_dir=$(mktemp -d) && [ -n "$temp_dir" ] && [ -d "$temp_dir" ] || {
  echo "FATAL: mktemp -d failed (TMPDIR=${TMPDIR:-unset}); refusing to run" >&2
  exit 2
}
trap 'rm -rf "$temp_dir"' EXIT

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

suites=(
  "$here/custodian-guardrails.test.sh"
  "$here/custodian-skill-lint.test.sh"
  "$here/doc-bloat-scan.test.sh"
  "$here/correction-gates/run-correction-gates.test.sh"
  "$here/correction-gates/format-scope/gate.test.sh"
  "$here/correction-gates/no-ai-attribution/gate.test.sh"
)

# a mktemp that always fails, standing in for a denied or full temp dir
shim="$temp_dir/bin"; mkdir -p "$shim" || exit 2
printf '#!/usr/bin/env bash\necho "mktemp: mkdtemp failed" >&2\nexit 1\n' \
  > "$shim/mktemp"
chmod +x "$shim/mktemp"

# the victim stands in for whatever repo the caller happens to be sitting
# in: a commit to count, a distinct identity to clobber, and an uncommitted
# file a stray `git add -A` would sweep in
victim="$temp_dir/victim"; mkdir -p "$victim" || exit 2
(
  cd "$victim" || exit 2
  git init -q -b main
  git config user.email victim@caller.test
  git config user.name  victim
  echo seed > seed.txt && git add seed.txt && git commit -q -m seed
  echo wip > uncommitted.txt
) >/dev/null 2>&1
head0=$(cd "$victim" && git rev-parse HEAD)

drift() { # label — the victim must be byte-identical after every run
  [ "$(cd "$victim" && git rev-parse HEAD)" = "$head0" ]
  check "$1: no commit landed in the caller repo" $?
  [ "$(cd "$victim" && git config user.email)" = victim@caller.test ]
  check "$1: caller user.email intact" $?
  [ "$(cd "$victim" && git status --porcelain)" = '?? uncommitted.txt' ]
  check "$1: caller working tree intact" $?
}

for suite in "${suites[@]}"; do
  name=${suite#"$here/"}   # path-qualified; two suites share a basename

  # --- RED: mktemp fails, so the suite must refuse rather than degrade. ---
  out=$(cd "$victim" && PATH="$shim:$PATH" "$suite" 2>&1); rc=$?
  # exit 2 is refusal; a bare non-zero would also match a suite that ran
  # anyway and merely failed its own assertions, which is the defect
  [ "$rc" -eq 2 ] && r=0 || r=1
  check "RED $name: refuses when mktemp fails (exit $rc, want 2)" "$r"
  printf '%s\n' "$out" | grep -qi 'mktemp'
  check "RED $name: names mktemp as the cause" $?
  drift "RED $name"

  # --- GREEN: a working mktemp, so the guard must stay out of the way. ---
  out=$(cd "$victim" && "$suite" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && r=0 || r=1
  check "GREEN $name: passes normally (exit $rc)" "$r"
  drift "GREEN $name"
done

echo
if [ "$fails" -eq 0 ]; then echo "all temp-dir guard tests passed"; exit 0
else echo "$fails temp-dir guard test(s) FAILED"; exit 1; fi
