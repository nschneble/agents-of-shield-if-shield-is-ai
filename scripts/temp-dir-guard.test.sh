#!/usr/bin/env bash
# temp-dir-guard.test.sh — both-directions test for the temp-dir guard that
# every self-contained suite carries.
#
# The defect this locks down, observed live: an unchecked
# `temp_dir=$(mktemp -d)` returns empty when the temp dir is denied or
# full. Every path derived from it then resolves absolute (/repo), the
# mkdir and cd that follow fail while silenced, and the suite's git
# fixture commands execute with the CWD still on the INVOKING repo,
# committing its working tree via `git add -A` and overwriting its
# user.email.
#
# RED: mktemp is broken BOTH ways it breaks in the wild — a non-zero exit,
# and a success that yields an empty string, which is the failure the
# guard's `-n` arm exists for and the one an exit-status-only guard
# survives. Under each, a suite must exit 2, print its own refusal, and
# leave a victim repo byte-identical. GREEN: with a working mktemp each
# suite still passes and still leaves the victim untouched, so the guard
# costs the healthy path nothing.
#
# The roster is DERIVED, never hand-listed: every `*.test.sh` in the repo
# that mentions mktemp, minus this file. A hardcoded list covers the
# suites someone remembered; the seventh suite would be covered by
# nothing and fail nothing.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/.." && pwd)
# this test carries the guard it tests: without a real temp dir the victim
# repo below would resolve to /victim and the caller's repo would take the
# damage this very test exists to detect. The explicit template is what
# makes TMPDIR the input the message names: a bare `mktemp -d` ignores
# TMPDIR on BSD and allocates under /var/folders.
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  && [ -n "$temp_dir" ] && [ -d "$temp_dir" ] || {
  echo "FATAL: mktemp -d failed (TMPDIR=${TMPDIR:-unset}); refusing to run" >&2
  exit 2
}
trap 'rm -rf "$temp_dir"' EXIT

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# a bare `mktemp` match, not `$(mktemp`, so a suite that reaches it by some
# other spelling is over-covered rather than missed: a false red is loud
# and fixable, a silent gap is what put this file here
suites=()
while IFS= read -r suite; do
  case "$suite" in "$here/temp-dir-guard.test.sh") continue ;; esac
  suites+=( "$suite" )
done < <(cd "$repo_root" \
  && grep -rl --include='*.test.sh' mktemp . 2>/dev/null \
  | sed "s|^\./|$repo_root/|" | sort)

# an empty roster would sail through the loop below reporting nothing
if [ "${#suites[@]}" -eq 0 ]; then
  printf 'FAIL  discovery found no suite carrying mktemp under %s\n' "$repo_root"
  printf '\n1 temp-dir guard test(s) FAILED\n'
  exit 1
fi
printf 'discovered %d suite(s) carrying mktemp:\n' "${#suites[@]}"
for suite in "${suites[@]}"; do printf '  %s\n' "${suite#"$repo_root/"}"; done
echo

# the two shapes of a broken mktemp. The empty-yet-successful one is the
# discriminator: a guard that only checks `$?` passes the first and fails
# the second, and empty is the shape observed live
shim_fail="$temp_dir/bin-fail"; mkdir -p "$shim_fail" || exit 2
printf '#!/usr/bin/env bash\necho "mktemp: mkdtemp failed" >&2\nexit 1\n' \
  > "$shim_fail/mktemp"
shim_empty="$temp_dir/bin-empty"; mkdir -p "$shim_empty" || exit 2
printf '#!/usr/bin/env bash\nexit 0\n' > "$shim_empty/mktemp"
chmod +x "$shim_fail/mktemp" "$shim_empty/mktemp"

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
  name=${suite#"$repo_root/"}   # path-qualified; two suites share a basename

  # --- RED: mktemp broken, so the suite must refuse, not degrade. ---
  for broken in "fails:$shim_fail" "returns empty:$shim_empty"; do
    label=${broken%%:*}; shim=${broken#*:}
    out=$(cd "$victim" && PATH="$shim:$PATH" "$suite" 2>&1); rc=$?
    # exit 2 is refusal; a bare non-zero would also match a suite that ran
    # anyway and merely failed its own assertions, which is the defect
    [ "$rc" -eq 2 ] && r=0 || r=1
    check "RED $name ($label): refuses (exit $rc, want 2)" "$r"
    # the guard's OWN words. Grepping for `mktemp` matched the shim's
    # stderr instead, so an entirely unguarded suite passed that check
    printf '%s\n' "$out" | grep -q 'refusing to run'
    check "RED $name ($label): prints the guard's refusal" $?
    drift "RED $name ($label)"
  done

  # --- GREEN: a working mktemp, so the guard must stay out of the way. ---
  out=$(cd "$victim" && "$suite" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && r=0 || r=1
  check "GREEN $name: passes normally (exit $rc)" "$r"
  drift "GREEN $name"
done

echo
if [ "$fails" -eq 0 ]; then echo "all temp-dir guard tests passed"; exit 0
else echo "$fails temp-dir guard test(s) FAILED"; exit 1; fi
