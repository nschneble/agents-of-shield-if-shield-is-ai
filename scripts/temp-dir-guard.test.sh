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
# RED: mktemp is broken all THREE ways it breaks in the wild — a non-zero
# exit; a success that yields an empty string, which is the failure the
# guard's `-n` arm exists for and the one an exit-status-only guard
# survives; and a success handing back a real path that is a regular FILE,
# which is what `mktemp -d` degraded to a plain `mktemp` produces and what
# the guard's `-d` arm exists for. Under each, a suite must exit 2, print
# its own refusal in words true of THAT shape, and leave a victim repo
# byte-identical. GREEN: with a working mktemp each suite still passes and
# still leaves the victim untouched, so the guard costs the healthy path
# nothing.
#
# One shim per fault SHAPE, never per message. The guard grew from one arm
# to three while this loop still iterated two shims, so the third arm was
# decoration: deleting it from every roster suite, or corrupting its
# wording, left this file printing "all temp-dir guard tests passed".
#
# The roster is DERIVED, never hand-listed: every `*.test.sh` in the repo
# that mentions mktemp, minus this file. A hardcoded list covers the
# suites someone remembered; the seventh suite would be covered by
# nothing and fail nothing. Derivation has its own three failure modes,
# all of which used to pass: narrowing it to a subset (pinned by a second
# count spelled with find rather than a recursive grep); emptying it
# altogether (pinned by running a copy of this suite alone in a bare tree,
# because an empty array under `set -u` is legal on the bash CI runs); and
# WIDENING it back over `local/` (pinned by a planted scratch suite that
# must be neither counted nor executed).
#
# scripts/custodian-history.sh is checked by name at the end. It carries
# the same guard but is not a suite, so no derivation over `*.test.sh` can
# ever reach it.
#
# Deliberately over the ~100-line refactor bar. Splitting it would put the
# derivation, the shims and the drift oracle in separate files, and a
# roster that cannot see its own shims is the exact failure this file was
# written to catch. Trim its prose before reaching for its code.
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
# fd 3 is this suite's own stderr, saved before any fixture runs, so a
# refusal spoken from inside the silenced victim subshell below still
# reaches an operator. Forced with a failing victim `git init`, this file
# printed 238 lines, no FATAL, 104 ok and 62 FAIL, and told a CI reader
# their repo had been clobbered — quoting the operator's real global git
# identity as the drift — by a suite that never ran.
exec 3>&2
die_temp() { echo "FATAL: $1; refusing to run" >&3; exit 2; }
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
# and fixable, a silent gap is what put this file here.
# `local/` and `.git/` are excluded for the same reason
# validate-looper-config excludes them: local/ is gitignored scratch, not
# CI's business. Without the exclusion — which the `expected` cross-check
# below already carried — planting `local/scratch/fake.test.sh` did two
# things, and the miscount was the lesser: this loop EXECUTED that
# unreviewed file three times, with a poisoned PATH, from inside the
# victim repo. Both halves are now pinned by the planted-scratch fixture
# near the end of this file.
suites=()
while IFS= read -r suite; do
  case "$suite" in "$here/temp-dir-guard.test.sh") continue ;; esac
  suites+=( "$suite" )
done < <(cd "$repo_root" \
  && grep -rl --include='*.test.sh' --exclude-dir=local --exclude-dir=.git \
       mktemp . 2>/dev/null \
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

# the three shapes of a broken mktemp. Each defeats the guard arm before
# it: a `$?`-only guard passes the empty shape, and an `-n`-only guard
# passes the non-directory shape, which is a real path of the right form
shim_fail="$temp_dir/bin-fail"
mkdir -p "$shim_fail" || die_temp "cannot create $shim_fail"
printf '#!/usr/bin/env bash\necho "mktemp: mkdtemp failed" >&2\nexit 1\n' \
  > "$shim_fail/mktemp"
shim_empty="$temp_dir/bin-empty"
mkdir -p "$shim_empty" || die_temp "cannot create $shim_empty"
printf '#!/usr/bin/env bash\nexit 0\n' > "$shim_empty/mktemp"
# a `mktemp -d` that lost its -d — a stale wrapper, a busybox applet —
# still exits 0 and still prints a path. The file lands under this run's
# own temp dir so the EXIT trap reaps it
shim_notdir="$temp_dir/bin-notdir"
mkdir -p "$shim_notdir" || die_temp "cannot create $shim_notdir"
cat > "$shim_notdir/mktemp" <<SHIM
#!/usr/bin/env bash
f=\$(/usr/bin/mktemp "$temp_dir/notdir.XXXXXX") || exit 1
printf '%s\n' "\$f"
exit 0
SHIM
chmod +x "$shim_fail/mktemp" "$shim_empty/mktemp" "$shim_notdir/mktemp"

# the victim stands in for whatever repo the caller happens to be sitting
# in: a commit to count, a distinct identity to clobber, and an uncommitted
# file a stray `git add -A` would sweep in
victim="$temp_dir/victim"
mkdir -p "$victim" || die_temp "cannot create $victim"
# chained with `&&`, because a subshell reports only its LAST command:
# with a failing `git init` the trailing `echo` still succeeded, so an
# `||` on the group alone never fired. `set -e` inside does NOT fix that
# — errexit is suppressed in a subshell that is the left operand of an
# AND-OR list, which is exactly the position this one is in, so the
# chain is the only spelling that reports.
(
  cd "$victim" \
    && git init -q -b main \
    && git config user.email victim@caller.test \
    && git config user.name  victim \
    && echo seed > seed.txt && git add seed.txt && git commit -q -m seed \
    && echo wip > uncommitted.txt \
    || die_temp "victim fixture setup failed in $victim"
# the refusal is spoken from INSIDE the silence, over fd 3, and the exit
# out here carries no second message: one fault, one line. `exit` in a
# subshell ends only the subshell, so the parent still needs this arm or
# every assertion below runs against a fixture that was never built.
) >/dev/null 2>&1 || exit 2
head0=$(cd "$victim" && git rev-parse HEAD 2>/dev/null)
# a baseline the fixture never produced is not a passing assertion: with
# head0 empty every drift() HEAD comparison matched empty against empty
# and printed `no commit landed in the caller repo (HEAD , want )`
[ -n "$head0" ] || die_temp "victim fixture produced no HEAD baseline in $victim"

# both the observed AND the baseline value go in the label: `trap rm -rf`
# deletes the victim on exit, so a FAIL line naming only what was seen
# leaves nobody able to say what it should have been
drift() { # label — the victim must be byte-identical after every run
  local head email tree
  head=$(cd "$victim" && git rev-parse HEAD)
  email=$(cd "$victim" && git config user.email)
  tree=$(cd "$victim" && git status --porcelain | tr '\n' ';')
  # an EMPTY porcelain is the maximal-damage case, not the quiet one: it
  # means a suite committed the victim's uncommitted file away. Rendered
  # bare it read `intact ()`, less informative than the healthy run's
  # `intact (?? uncommitted.txt;)` — informativeness exactly inverted
  [ -n "$tree" ] || tree='empty — uncommitted.txt was swept into a commit'
  [ "$head" = "$head0" ]
  check "$1: no commit landed in the caller repo (HEAD $head, want $head0)" $?
  [ "$email" = victim@caller.test ]
  check "$1: caller user.email intact ($email, want victim@caller.test)" $?
  [ "$tree" = '?? uncommitted.txt;' ]
  check "$1: caller working tree intact ($tree, want '?? uncommitted.txt;')" $?
}

for suite in "${suites[@]}"; do
  name=${suite#"$repo_root/"}   # path-qualified; two suites share a basename

  # --- RED: mktemp broken, so the suite must refuse, not degrade. ---
  # the qualifier names the SHIM, not the suite: read one line at a time,
  # `(fails)` first parses as the suite failing
  for broken in \
    "mktemp fails:$shim_fail:exited nonzero" \
    "mktemp returns empty:$shim_empty:exited 0 with no path" \
    "mktemp returns a file:$shim_notdir:gave a non-directory"
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

# --- fixtures that run a COPY of this suite ------------------------------
# Both sections below stand this file up in a synthetic tree and run it.
# A copy that discovers a suite reaches these sections itself and stands
# up another tree, so the nesting is bounded by an env marker rather than
# by luck: today the planted copy bails at the roster guard before it
# gets here, but that is the very property one of them is testing, and
# the failing direction is unbounded recursion.
nested_run() { # tree-root — run a copy of this suite from another tree
  mkdir -p "$1/scripts" || die_temp "cannot create $1/scripts"
  cp "$here/temp-dir-guard.test.sh" "$1/scripts/" \
    || die_temp "cannot copy this suite into $1/scripts"
  chmod +x "$1/scripts/temp-dir-guard.test.sh"
  LOOPER_SUITE_NESTED=1 "$1/scripts/temp-dir-guard.test.sh" 2>&1
}

if [ -n "${LOOPER_SUITE_NESTED:-}" ]; then
  echo "(nested run: skipping the copy-of-this-suite fixtures)"
else

# --- the empty-roster bail-out has to be reachable -----------------------
# a copy of this suite alone in a bare tree discovers nothing but itself,
# which it skips. On bash >= 4.4 — CI is ubuntu-latest — `"${arr[@]}"` on
# an empty array is legal under `set -u`, so without the bail-out the loop
# above sails through asserting nothing and exits 0. Only bash 3.2 dies
# loudly on it, which is the environment CI does not have.
out=$(nested_run "$temp_dir/solo"); rc=$?
[ "$rc" -eq 1 ] \
  && printf '%s\n' "$out" | grep -q 'discovery found no suite'
check "empty roster bails out loudly (exit $rc, want 1)" $?

# --- the `local/` exclusion has to survive a revert ----------------------
# The roster's `--exclude-dir` and the `expected` cross-check's
# `-not -path './local/*'` are a copy-paste pair, so reverting both
# widens them in lockstep and the cross-check cannot see it. With no
# scratch file present the revert is silent, and when it does fire the
# red reads "your scratch file lacks a temp-dir guard" — which invites
# guarding the scratch file rather than restoring the exclusion, after
# the unreviewed file has already been EXECUTED with a poisoned PATH
# from inside the victim repo. So the fixture pins both halves: not
# counted, and not run.
planted="$temp_dir/planted"
mkdir -p "$planted/local/scratch" || die_temp "cannot create $planted/local/scratch"
marker="$planted/local/scratch/EXECUTED"
# mentions mktemp so a widened roster WILL discover it, and leaves proof
# on disk if anything ever runs it
printf '#!/usr/bin/env bash\ntouch "%s"\n: mktemp\nexit 0\n' "$marker" \
  > "$planted/local/scratch/fake.test.sh"
chmod +x "$planted/local/scratch/fake.test.sh"
out=$(nested_run "$planted"); rc=$?
[ "$rc" -eq 1 ] \
  && printf '%s\n' "$out" | grep -q 'discovery found no suite'
check "planted local/ suite is not counted (exit $rc, want 1)" $?
# the observation is resolved into a variable first: a `$(…)` spliced
# into the label runs before the `$?` beside it expands, and would hand
# check() the substitution's own status
[ -e "$marker" ] && seen=present || seen=absent
[ "$seen" = absent ]
check "planted local/ suite is never executed (marker $seen, want absent)" $?

fi   # end of the copy-of-this-suite fixtures

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
