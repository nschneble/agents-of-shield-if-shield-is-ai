#!/usr/bin/env bash
# validate-looper-config.test.sh — both-directions test for the config
# validator: CI wiring, frontmatter, reference integrity.
#
# Fixture repo in a temp dir; verdict from a results log, with the
# assertion count asserted beside it.
# Background: docs/test-suites.md#validate-looper-config
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/.." && pwd)
# a failing mktemp returns empty, which makes every derived path absolute
# (/fixture). The mkdir below then fails while silenced and the fixture
# writes land in the CALLER's repo. Refuse to run instead. The explicit
# template is what makes TMPDIR the input the message names: a bare
# `mktemp -d` ignores TMPDIR on BSD, allocating under /var/folders.
# one arm per shape: mktemp's own stderr explains a nonzero exit, the
# empty-yet-successful shape prints nothing, and a success handing back a
# regular file leaves a path that exists but is not a directory
die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

# Both the verdict and the assertion count are DERIVED from a log this
# function appends to, never from a shell counter it increments. The
# counter form had a one-token false-green: deleting `fails=$((fails+1))`
# left the suite printing five FAIL lines and exiting 0 under
# `all validate-looper-config tests passed`. It also had no floor, so
# deleting a whole fixture block was zero FAILs and zero noise. This
# file is the one that guarantees every OTHER suite is wired into CI, so
# it is the one that must not be able to lie. Deleting the FAIL append
# now shortens the log and trips the count instead.
results="$temp_dir/results.log"
: > "$results" || die_temp "cannot open the results log at $results"
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; printf 'ok\n' >> "$results"
  else printf 'FAIL  %s\n' "$1"; printf 'FAIL\n' >> "$results"; fi
}

fix="$temp_dir/fixture"
mkdir -p "$fix/scripts" "$fix/agents" "$fix/skills/beta" \
         "$fix/.github/workflows" || die_temp "cannot build $fix"
cp "$repo_root/scripts/validate-looper-config.sh" "$fix/scripts/" \
  || die_temp "cannot copy the validator into $fix"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fix/scripts/alpha.test.sh"
printf -- '---\nname: alpha\ndescription: fixture agent.\n---\n\nBody.\n' \
  > "$fix/agents/alpha.md"
printf -- '---\nname: beta\ndescription: fixture skill.\n---\n\nBody.\n' \
  > "$fix/skills/beta/SKILL.md"

wf="$fix/.github/workflows/validate.yml"
run_fixture() { # sets $out and $rc — not a subshell, so both survive
  # point the deploy-link check at an absent config dir so it skips: the
  # fixture is a throwaway tree nobody deploys, and letting the real
  # ~/.claude answer would make every assertion below depend on the dev
  # machine's link state. Its own assertions set this deliberately.
  out=$(cd "$fix" && CLAUDE_CONFIG_DIR="$temp_dir/undeployed" \
          ./scripts/validate-looper-config.sh 2>&1); rc=$?
}

# `wired` = the validator must not complain about alpha.test.sh (it may
# still exit 0 for other reasons, so the absence of THAT error is the
# assertion). `unwired` = it must complain, by name, and exit nonzero.
wiring() { # label, wired|unwired  — workflow body arrives on stdin
  local r saw want
  cat > "$wf"
  run_fixture
  # both sides of the label, not just the want: a FAIL reading only
  # `(unwired, exit 1)` names the expectation and leaves the reader
  # guessing which half of it missed
  printf '%s\n' "$out" | grep -q 'alpha.test.sh is not invoked' \
    && saw=complained || saw=silent
  if [ "$2" = wired ]; then want='exit 0 + silent'
    [ "$rc" -eq 0 ] && [ "$saw" = silent ]
  else want='nonzero + complained'
    [ "$rc" -ne 0 ] && [ "$saw" = complained ]
  fi; r=$?
  check "$1 ($2: exit $rc + $saw, want $want)" "$r"
}

# --- WIRED: the three spellings CI actually executes. ---
wiring "inline run:" wired <<'YAML'
name: validate
on: [push]
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - name: alpha
        run: ./scripts/alpha.test.sh
YAML

wiring "run: | block scalar" wired <<'YAML'
name: validate
on: [push]
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - name: alpha
        run: |
          echo starting
          ./scripts/alpha.test.sh
YAML

wiring "run: > folded scalar" wired <<'YAML'
name: validate
on: [push]
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - name: alpha
        run: >
          ./scripts/alpha.test.sh
YAML

# --- UNWIRED: five spellings that name the suite but never run it. ---
wiring "named only in a step label" unwired <<'YAML'
name: validate
on: [push]
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - name: TODO restore ./scripts/alpha.test.sh
        run: echo skipped
YAML

wiring "named only in a paths: filter" unwired <<'YAML'
name: validate
on:
  push:
    paths:
      - ./scripts/alpha.test.sh
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - name: nothing
        run: echo skipped
YAML

wiring "named only in a trailing comment" unwired <<'YAML'
name: validate
on: [push]
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - name: disabled
        run: echo skipped  # TODO re-enable ./scripts/alpha.test.sh
YAML

wiring "named only in a with: input" unwired <<'YAML'
name: validate
on: [push]
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - uses: some/action@v1
        with:
          script: ./scripts/alpha.test.sh
YAML

# a dedent ends the block scalar, so the env: value below it is not run
wiring "named in env: after a block ends" unwired <<'YAML'
name: validate
on: [push]
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - name: something
        run: |
          echo hi
        env:
          NOTE: ./scripts/alpha.test.sh
YAML

# --- back to a wired workflow: everything below tests the other checks,
# so wiring must stop being the reason the fixture is red. ---
wiring "restored wired workflow" wired <<'YAML'
name: validate
on: [push]
jobs:
  config:
    runs-on: ubuntu-latest
    steps:
      - name: alpha
        run: ./scripts/alpha.test.sh
YAML

# --- the workflow file itself missing is its own error. ---
mv "$wf" "$temp_dir/wf.bak"
run_fixture
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'no test suite runs in CI'
check "missing workflow errors (exit $rc)" $?
mv "$temp_dir/wf.bak" "$wf"

# --- frontmatter: each defect errors, and the clean tree does not. ---
run_fixture
[ "$rc" -eq 0 ]
check "GREEN: clean fixture passes (exit $rc)" $?

printf -- '---\nname: wrongname\ndescription: d.\n---\n' > "$fix/agents/alpha.md"
run_fixture
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'path implies `alpha`'
check "name/path mismatch errors" $?

printf 'no frontmatter here\n' > "$fix/agents/alpha.md"
run_fixture
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'has no frontmatter'
check "missing frontmatter errors" $?
printf -- '---\nname: alpha\ndescription: fixture agent.\n---\n' \
  > "$fix/agents/alpha.md"

printf -- '---\nname: beta\n---\n' > "$fix/skills/beta/SKILL.md"
run_fixture
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'missing or empty `description'
check "missing description errors" $?

mkdir -p "$fix/skills/gamma"
run_fixture
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'gamma` has no SKILL.md'
check "skill dir without SKILL.md errors" $?
rmdir "$fix/skills/gamma"
printf -- '---\nname: beta\ndescription: fixture skill.\n---\n' \
  > "$fix/skills/beta/SKILL.md"

# --- references: a dangling path WARNS, it never blocks a merge. ---
printf -- '---\nname: beta\ndescription: d.\n---\n\nSee `scripts/nope.sh`.\n' \
  > "$fix/skills/beta/SKILL.md"
run_fixture
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'scripts/nope.sh` which does not exist'
check "dangling reference warns without failing (exit $rc)" $?

printf -- '---\nname: beta\ndescription: d.\n---\n\nSee `scripts/alpha.test.sh`.\n' \
  > "$fix/skills/beta/SKILL.md"
run_fixture
[ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'does not exist'
check "resolving reference does not warn (exit $rc)" $?

# --- deploy links: warn on anything the tree ships but ~/.claude can't
# reach. Three arms, because the check has been able to fail as silence
# (undeployed machine) and as noise (CI) as easily as it can bite. ---
deploy_fixture() { # $1 = config dir handed to the validator
  out=$(cd "$fix" && CLAUDE_CONFIG_DIR="$1" \
          ./scripts/validate-looper-config.sh 2>&1); rc=$?
}

# an undeployed tree is silent, not 37 warnings — this is the CI case
deploy_fixture "$temp_dir/nothing-here"
[ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'is not deployed'
check "undeployed tree skips the link check entirely (exit $rc)" $?

# a deployed dir missing one file names that file and stays exit 0
dep="$temp_dir/deployed"
mkdir -p "$dep/agents" "$dep/skills/beta"
ln -s "$fix/skills/beta/SKILL.md" "$dep/skills/beta/SKILL.md"
deploy_fixture "$dep"
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'agents/alpha.md is not deployed'
check "an unlinked file warns without failing (exit $rc)" $?

# a link pointing somewhere else is a different failure than an absent one
printf 'decoy\n' > "$temp_dir/decoy.md"
ln -s "$temp_dir/decoy.md" "$dep/agents/alpha.md"
deploy_fixture "$dep"
printf '%s\n' "$out" | grep -q 'agents/alpha.md resolves to' \
  && ! printf '%s\n' "$out" | grep -q 'agents/alpha.md is not deployed'
check "a link into the wrong file warns as misresolved, not missing" $?

# and the fully-linked tree is silent
rm "$dep/agents/alpha.md"; ln -s "$fix/agents/alpha.md" "$dep/agents/alpha.md"
deploy_fixture "$dep"
[ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'alpha.md is not deployed\|alpha.md resolves to'
check "a fully linked tree is silent (exit $rc)" $?

# --- Doc mirror: a verb a skill declares must reach the family doc ------
# Both directions on the same fixture verb, because the miss this check
# exists for is silent in the tree it ships in: the skill is valid, the
# doc is valid, and only their disagreement is the defect. Asserts on the
# warning text, not the exit status — doc rot is a WARN here, so a
# verdict keyed on rc would pass in both directions.
mkdir -p "$fix/docs"
printf -- '---\nname: beta\ndescription: fixture skill.\n---\n\nRun `/beta apply #<id>` to apply it.\n' \
  > "$fix/skills/beta/SKILL.md"

printf '# Skills\n\nStructured invocations: `/beta apply #<id>`.\n' \
  > "$fix/docs/looper-skills.md"
run_fixture
! printf '%s\n' "$out" | grep -q 'omits `/beta apply`'
check "a verb the family doc carries does not warn" $?

printf '# Skills\n\nNo structured invocations listed.\n' \
  > "$fix/docs/looper-skills.md"
run_fixture
printf '%s\n' "$out" | grep -q 'omits `/beta apply`'
check "a declared verb absent from the family doc warns by name" $?

# --- the tally, derived from the log rather than from a counter ---------
# EXPECTED_CHECKS is the floor. Add or remove a fixture block and this
# number moves with it — that is the point: a block deleted on its own
# reads as silence, and silence is what this file exists to stop.
EXPECTED_CHECKS=23
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
# both conditions in ONE verdict, so there is no accumulator to delete
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran validate-looper-config tests passed"; exit 0
  # never "0 FAILED" beside a non-zero exit: on a count trip the failure
  # IS the missing assertions, so the line has to say so
else echo "validate-looper-config FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1; fi
