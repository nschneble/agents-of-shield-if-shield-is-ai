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
# survives. Under each, a suite must exit 2, print its own refusal in
# words true of THAT shape, and leave a victim repo byte-identical. GREEN:
# with a working mktemp each suite still passes and still leaves the victim
# untouched, so the guard costs the healthy path nothing.
#
# The roster is DERIVED, never hand-listed: every `*.test.sh` in the repo
# that mentions mktemp, minus this file. A hardcoded list covers the
# suites someone remembered; the seventh suite would be covered by
# nothing and fail nothing. Derivation has its own two failure modes, both
# of which used to pass: narrowing it to a subset (pinned by a second
# count spelled with find rather than a recursive grep) and emptying it
# altogether (pinned by running a copy of this suite alone in a bare tree,
# because an empty array under `set -u` is legal on the bash CI runs).
#
# scripts/custodian-history.sh is checked by name at the end. It carries
# the same guard but is not a suite, so no derivation over `*.test.sh` can
# ever reach it.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/.." && pwd)
# this test carries the guard it tests: without a real temp dir the victim
# repo below would resolve to /victim and the caller's repo would take the
# damage this very test exists to detect. The explicit template is what
# makes TMPDIR the input the message names: a bare `mktemp -d` ignores
# TMPDIR on BSD and allocates under /var/folders.
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

# a second count, spelled with find rather than a recursive grep, so
# narrowing the derivation above cannot pass unremarked: truncating it to a
# strict subset used to print `discovered 2 suite(s)` and exit 0
expected=$(cd "$repo_root" \
  && find . -name '*.test.sh' -not -path './.git/*' \
       -not -path './local/*' -exec grep -l mktemp {} + 2>/dev/null \
  | grep -vc 'temp-dir-guard\.test\.sh')
[ "${#suites[@]}" -eq "$expected" ]
check "roster covers every mktemp suite (${#suites[@]} of $expected)" $?

# the two shapes of a broken mktemp. The empty-yet-successful one is the
# discriminator: a guard that only checks `$?` passes the first and fails
# the second, and empty is the shape observed live
shim_fail="$temp_dir/bin-fail"
mkdir -p "$shim_fail" || die_temp "cannot create $shim_fail"
printf '#!/usr/bin/env bash\necho "mktemp: mkdtemp failed" >&2\nexit 1\n' \
  > "$shim_fail/mktemp"
shim_empty="$temp_dir/bin-empty"
mkdir -p "$shim_empty" || die_temp "cannot create $shim_empty"
printf '#!/usr/bin/env bash\nexit 0\n' > "$shim_empty/mktemp"
chmod +x "$shim_fail/mktemp" "$shim_empty/mktemp"

# the victim stands in for whatever repo the caller happens to be sitting
# in: a commit to count, a distinct identity to clobber, and an uncommitted
# file a stray `git add -A` would sweep in
victim="$temp_dir/victim"
mkdir -p "$victim" || die_temp "cannot create $victim"
(
  cd "$victim" || die_temp "cannot cd into $victim"
  git init -q -b main
  git config user.email victim@caller.test
  git config user.name  victim
  echo seed > seed.txt && git add seed.txt && git commit -q -m seed
  echo wip > uncommitted.txt
) >/dev/null 2>&1
head0=$(cd "$victim" && git rev-parse HEAD)

# the observed value goes in the label: `trap rm -rf` deletes the victim on
# exit, so a bare FAIL line is the only record left of what a suite did to
# somebody's working tree
drift() { # label — the victim must be byte-identical after every run
  local head email tree
  head=$(cd "$victim" && git rev-parse HEAD)
  email=$(cd "$victim" && git config user.email)
  tree=$(cd "$victim" && git status --porcelain | tr '\n' ';')
  [ "$head" = "$head0" ]
  check "$1: no commit landed in the caller repo (HEAD $head)" $?
  [ "$email" = victim@caller.test ]
  check "$1: caller user.email intact ($email)" $?
  [ "$tree" = '?? uncommitted.txt;' ]
  check "$1: caller working tree intact ($tree)" $?
}

for suite in "${suites[@]}"; do
  name=${suite#"$repo_root/"}   # path-qualified; two suites share a basename

  # --- RED: mktemp broken, so the suite must refuse, not degrade. ---
  # the qualifier names the SHIM, not the suite: read one line at a time,
  # `(fails)` first parses as the suite failing
  for broken in \
    "mktemp fails:$shim_fail:exited nonzero" \
    "mktemp returns empty:$shim_empty:exited 0 with no path"
  do
    label=${broken%%:*}; rest=${broken#*:}
    shim=${rest%%:*}; want=${rest#*:}
    out=$(cd "$victim" && PATH="$shim:$PATH" "$suite" 2>&1); rc=$?
    # exit 2 is refusal; a bare non-zero would also match a suite that ran
    # anyway and merely failed its own assertions, which is the defect
    [ "$rc" -eq 2 ] && r=0 || r=1
    check "RED $name ($label): refuses (exit $rc, want 2)" "$r"
    # the guard's OWN words. Grepping for `mktemp` matched the shim's
    # stderr instead, so an entirely unguarded suite passed that check
    printf '%s\n' "$out" | grep -q 'refusing to run'
    check "RED $name ($label): prints the guard's refusal" $?
    # and the words have to be TRUE of this shape. On the empty shape the
    # shim prints nothing at all, so a message that says mktemp failed is
    # the only line an operator gets — and it sends them to test a TMPDIR
    # that works
    printf '%s\n' "$out" | grep -q "$want"
    check "RED $name ($label): says \"$want\"" $?
    drift "RED $name ($label)"
  done

  # --- GREEN: a working mktemp, so the guard must stay out of the way. ---
  out=$(cd "$victim" && "$suite" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && r=0 || r=1
  check "GREEN $name: passes normally (exit $rc)" "$r"
  drift "GREEN $name"
done

# --- the empty-roster bail-out has to be reachable -----------------------
# a copy of this suite alone in a bare tree discovers nothing but itself,
# which it skips. On bash >= 4.4 — CI is ubuntu-latest — `"${arr[@]}"` on
# an empty array is legal under `set -u`, so without the bail-out the loop
# above sails through asserting nothing and exits 0. Only bash 3.2 dies
# loudly on it, which is the environment CI does not have.
solo="$temp_dir/solo/scripts"
mkdir -p "$solo" || die_temp "cannot create $solo"
cp "$here/temp-dir-guard.test.sh" "$solo/" \
  || die_temp "cannot copy this suite into $solo"
chmod +x "$solo/temp-dir-guard.test.sh"
out=$("$solo/temp-dir-guard.test.sh" 2>&1); rc=$?
[ "$rc" -eq 1 ] \
  && printf '%s\n' "$out" | grep -q 'discovery found no suite'
check "empty roster bails out loudly (exit $rc, want 1)" $?

# --- the production script carrying the same guard -----------------------
# custodian-history.sh is not a suite, so the derived roster structurally
# cannot see it, and deleting its guard outright reddened nothing. Named
# explicitly rather than folded into the roster: it says `cannot ingest`,
# not `refusing to run`, and its healthy path walks five repos, so it has
# no GREEN direction worth running here.
hist="$repo_root/scripts/custodian-history.sh"
if [ ! -x "$hist" ]; then
  check "custodian-history.sh is present and executable" 1
else
  for broken in \
    "mktemp fails:$shim_fail" "mktemp returns empty:$shim_empty"
  do
    label=${broken%%:*}; shim=${broken#*:}
    out=$(cd "$victim" && CUSTODIAN_HOME="$temp_dir/hist" \
      PATH="$shim:$PATH" "$hist" ingest 2>&1); rc=$?
    [ "$rc" -eq 2 ] && r=0 || r=1
    check "RED custodian-history ($label): refuses (exit $rc, want 2)" "$r"
    # `set -euo pipefail` aborted on the nonzero shape before the guard
    # could speak, leaving mktemp's own line, no script name, and rc=1
    printf '%s\n' "$out" | grep -q 'custodian-history.*cannot ingest'
    check "RED custodian-history ($label): names itself, refuses" $?
    drift "RED custodian-history ($label)"
  done
fi

echo
if [ "$fails" -eq 0 ]; then echo "all temp-dir guard tests passed"; exit 0
else echo "$fails temp-dir guard test(s) FAILED"; exit 1; fi
