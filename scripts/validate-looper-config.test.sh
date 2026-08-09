#!/usr/bin/env bash
# validate-looper-config.test.sh — both-directions test for the config
# validator: its CI-wiring check, its frontmatter checks, and its
# reference-integrity warnings.
#
# The wiring check is why this file exists. It has been wrong in BOTH
# directions and reddened nothing either time. Matching only lines that
# start `run:` missed a suite invoked inside a `run: |` block scalar and
# called a wired suite unwired. Widening the match to the whole YAML body
# then accepted any MENTION: with the real step deleted, a suite named in a
# step `name:`, in an `on: push: paths:` filter, or in a trailing `# TODO`
# comment all read as wired. So both directions are pinned here — the
# spellings CI never executes must ERROR, and the three it does execute
# must not.
#
# Self-contained: builds a fixture repo in a temp dir carrying its own copy
# of the validator, which resolves its repo root from its own path. No git,
# no network. Needs a writable temp dir, so it must run sandbox-off
# locally; it aborts rather than degrade when it cannot get one.
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

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
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
  out=$(cd "$fix" && ./scripts/validate-looper-config.sh 2>&1); rc=$?
}

# `wired` = the validator must not complain about alpha.test.sh (it may
# still exit 0 for other reasons, so the absence of THAT error is the
# assertion). `unwired` = it must complain, by name, and exit nonzero.
wiring() { # label, wired|unwired  — workflow body arrives on stdin
  cat > "$wf"
  run_fixture
  if [ "$2" = wired ]; then
    [ "$rc" -eq 0 ] \
      && ! printf '%s\n' "$out" | grep -q 'alpha.test.sh is not invoked'
  else
    [ "$rc" -ne 0 ] \
      && printf '%s\n' "$out" | grep -q 'alpha.test.sh is not invoked'
  fi
  check "$1 ($2, exit $rc)" $?
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

echo
if [ "$fails" -eq 0 ]; then echo "all validate-looper-config tests passed"; exit 0
else echo "$fails validate-looper-config test(s) FAILED"; exit 1; fi
