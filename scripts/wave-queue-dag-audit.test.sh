#!/usr/bin/env bash
# wave-queue-dag-audit.test.sh — both-directions test for the wave-queue
# DAG invariant audit.
#
# Pins the two ways it could go quiet: an arm that stops firing, and a
# schema era declining as SKIP where it should VIOLATE, or the reverse.
# Background: docs/test-suites.md#wave-queue-dag-audit
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check="$here/wave-queue-dag-audit.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-dag.XXXXXX") \
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

state="$temp_dir/run-state.json"
snap() { printf '%s' "$1" > "$state"; }
run()  { out=$("$check" "$@" "$state" 2>&1); rc=$?; }
saw()  { printf '%s\n' "$out" | grep -q "$1"; }
exited() { [ "$rc" -eq "$1" ]; }

modern='{"goal_contract":{"asks":[{"id":"A1"},{"id":"A2"}]},
 "queue":[{"wave":1,"closes":["A1"]},{"wave":2,"closes":["A2"]}]}'

# --- the clean case, and the arm count that proves the arms fired -------
snap "$modern"
run
[ "$rc" -eq 0 ] && saw '0 of 5 arm(s) violated'
check_that "a conforming queue passes all five arms, exit 0 (got $rc)" $?

# --- arm 1: an entry with no wave number --------------------------------
snap '{"goal_contract":{"asks":[{"id":"A1"}]},
 "queue":[{"wave":1,"closes":["A1"]},{"candidate":"unnumbered"}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION every entry has a wave number'
check_that "an entry with no wave number violates, exit 1 (got $rc)" $?

# --- arm 2: a wave number used twice ------------------------------------
snap '{"goal_contract":{"asks":[{"id":"A1"}]},
 "queue":[{"wave":1,"closes":["A1"]},{"wave":1}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION no wave number used twice'
check_that "a duplicate wave number violates (got $rc)" $?

# --- arm 3: a gap in the numbering --------------------------------------
snap '{"goal_contract":{"asks":[{"id":"A1"}]},
 "queue":[{"wave":1,"closes":["A1"]},{"wave":3}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION waves are 1..N with no gaps'
check_that "a gap in the wave numbering violates (got $rc)" $?

# a queue starting at 2 is a gap at 1, not a shifted-but-contiguous pass
snap '{"queue":[{"wave":2},{"wave":3}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION waves are 1..N with no gaps'
check_that "a queue starting at 2 violates contiguity (got $rc)" $?

# --- arm 4: an ask no wave claims ---------------------------------------
snap '{"goal_contract":{"asks":[{"id":"A1"},{"id":"A2"}]},
 "queue":[{"wave":1,"closes":["A1"]}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION every ask is claimed by a wave'
check_that "an unclaimed ask violates (got $rc)" $?

# one wave closing two asks is normal, not a violation
snap '{"goal_contract":{"asks":[{"id":"A1"},{"id":"A2"}]},
 "queue":[{"wave":1,"closes":["A1","A2"]}]}'
run
exited 0
check_that "one wave closing two asks passes (got $rc)" $?

# --- arm 5: a closes id naming no declared ask --------------------------
snap '{"goal_contract":{"asks":[{"id":"A1"}]},
 "queue":[{"wave":1,"closes":["A1","A9"]}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION every closes id is a declared ask'
check_that "a dangling closes id violates (got $rc)" $?

# --- arm 6: absent edges are n/a, present edges are really evaluated -----
snap "$modern"
run
saw 'n/a    dependency edges ordered' && saw 'NOT EVALUABLE'
check_that "absent dependency edges report NOT EVALUABLE, not a pass" $?

# and NOT EVALUABLE must not be counted as an arm that ran
snap "$modern"
run
saw '0 of 5 arm(s) violated' && ! saw 'INCOMPLETE'
check_that "the standing edge gap is not counted as a declined arm" $?

snap '{"goal_contract":{"asks":[{"id":"A1"},{"id":"A2"}]},
 "queue":[{"wave":1,"closes":["A1"]},{"wave":2,"closes":["A2"],"depends_on":[1]}]}'
run
[ "$rc" -eq 0 ] && saw 'ok     dependency edges ordered'
check_that "an edge pointing at an earlier wave passes (got $rc)" $?

snap '{"queue":[{"wave":1,"depends_on":[2]},{"wave":2}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION dependency edges ordered'
check_that "an edge pointing at a LATER wave violates (got $rc)" $?

# a self-edge is a cycle of one, and strict ordering is what catches it
snap '{"queue":[{"wave":1,"dependsOn":[1]}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION dependency edges ordered'
check_that "a self-edge violates strict ordering (got $rc)" $?

# the shape carn/phase/1a persists: several entries, multi-edge, one empty
snap '{"queue":[{"wave":1,"depends_on":[]},{"wave":2,"depends_on":[1]},
 {"wave":3,"depends_on":[1]},{"wave":4,"depends_on":[1,2]},
 {"wave":5,"depends_on":[2,3,4]}]}'
run
[ "$rc" -eq 2 ] && saw 'ok     dependency edges ordered' && ! saw 'VIOLATION'
check_that "a real multi-edge array graph evaluates and passes (got $rc)" $?

snap '{"queue":[{"wave":1,"depends_on":"none"},{"wave":2,"depends_on":"wave 1"}]}'
run
[ "$rc" -eq 2 ] && saw 'SKIP   dependency edges ordered' && saw '2 entry(s)' \
  && ! saw 'VIOLATION' && ! saw 'jq: error'
check_that "a string-valued depends_on declines, never crashes (got $rc)" $?

# the crash's real cost was the batch: everything after it vanished
prose="$temp_dir/prose.json"
printf '%s' '{"queue":[{"wave":1,"depends_on":"none"}]}' > "$prose"
snap "$modern"
out=$("$check" "$prose" "$state" 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'QUEUE INVARIANT' \
  && printf '%s\n' "$out" | grep -q 'ok     every ask is claimed by a wave'
check_that "a snapshot after a prose-edge one is still read (got $rc)" $?

# --- schema eras decline, they do not fail ------------------------------
snap '{"queue":[],"goal_contract":[{"id":1}]}'
run
[ "$rc" -eq 2 ] && saw 'SKIP   wave numbering' && saw 'queue\[\] is empty' \
  && ! saw 'VIOLATION'
check_that "an empty queue declines, exit 2, never violates (got $rc)" $?

snap '{"queue":[{"n":1},{"n":"8a"},{"n":"1c"}]}'
run
[ "$rc" -eq 2 ] && saw 'pre-queue-shape snapshot' && ! saw 'VIOLATION'
check_that "an n-keyed legacy queue declines, never violates (got $rc)" $?

snap '{"queue":[{"wave":1}]}'
run
[ "$rc" -eq 2 ] && saw 'declares no goal-contract asks' && ! saw 'VIOLATION'
check_that "no goal contract declines the ask arms (got $rc)" $?

snap '{"goal_contract":{"asks":[{"id":"A1"}]},"queue":[{"wave":1}]}'
run
[ "$rc" -eq 2 ] && saw 'no queue entry carries'
check_that "asks with no closes anywhere declines (got $rc)" $?

# the bare-array contract shape real tuffgal runs carry, with integer ids
snap '{"goal_contract":[{"id":1,"ask":"x"}],"queue":[{"wave":1,"closes":[1]}]}'
run
[ "$rc" -eq 0 ] && saw 'ok     every ask is claimed by a wave'
check_that "a bare-array contract with integer ids is read, not skipped (got $rc)" $?

# --- arm 7: the git execution-order proxy -------------------------------
repo="$temp_dir/repo"
mkdir -p "$repo" || die_temp "cannot build $repo"
git -C "$repo" init -q -b main >/dev/null 2>&1 || die_temp "git init failed"
git -C "$repo" config user.email t@t; git -C "$repo" config user.name t
: > "$repo/a"; git -C "$repo" add -A; git -C "$repo" commit -qm a
first=$(git -C "$repo" rev-parse HEAD)
: > "$repo/b"; git -C "$repo" add -A; git -C "$repo" commit -qm b
second=$(git -C "$repo" rev-parse HEAD)

printf '{"queue":[{"wave":1,"status":"shipped","commit":"%s"},
 {"wave":2,"status":"shipped","commit":"%s"}]}' "$first" "$second" > "$state"
run --git "$repo"
saw 'ok     execution realizes wave order'
check_that "wave 1's commit being an ancestor of wave 2's passes" $?

printf '{"queue":[{"wave":1,"status":"shipped","commit":"%s"},
 {"wave":2,"status":"shipped","commit":"%s"}]}' "$second" "$first" > "$state"
run --git "$repo"
[ "$rc" -eq 1 ] && saw 'VIOLATION execution realizes wave order'
check_that "waves landing out of order violates, exit 1 (got $rc)" $?

printf '{"queue":[{"wave":1,"status":"shipped","commit":"%s"}]}' "$first" > "$state"
run --git "$repo"
saw 'SKIP   execution realizes wave order' && ! saw 'VIOLATION'
check_that "one shipped wave declines the order arm, never passes it" $?

# an unresolvable sha must not be silently treated as in-order
printf '{"queue":[{"wave":1,"status":"shipped","commit":"%s"},
 {"wave":2,"status":"shipped","commit":"deadbee"}]}' "$first" > "$state"
run --git "$repo"
saw 'SKIP   execution realizes wave order' && saw '1 shipped wave'
check_that "an unresolvable sha drops out and the arm declines" $?

snap "$modern"
run --git "$temp_dir"
saw 'SKIP   execution realizes wave order' && saw 'is not a git repo'
check_that "a --git target that is not a repo declines" $?

# --- a violation outranks incompleteness in the exit code ---------------
snap '{"queue":[{"wave":1},{"wave":3}]}'
run
[ "$rc" -eq 1 ] && saw 'VIOLATION' && saw 'SKIP'
check_that "a snapshot both violating and incomplete exits 1 (got $rc)" $?

# --- unreadable inputs --------------------------------------------------
printf 'not json' > "$state"
run
[ "$rc" -eq 2 ] && saw 'NOTHING CHECKED'
check_that "an unparseable snapshot exits 2 with NOTHING CHECKED (got $rc)" $?

out=$("$check" "$temp_dir/absent.json" 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check_that "a missing snapshot exits 2, not clean (got $rc)" $?

snap "$modern"
out=$("$check" --git 2>&1); rc=$?
exited 2
check_that "a value-taking flag with no value exits 2 (got $rc)" $?

out=$("$check" --nope "$state" 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'unknown flag'
check_that "an unknown flag exits 2 (got $rc)" $?

# --- --census: the corpus is discovered, never named ---------------------
census="$temp_dir/census"
mkdir -p "$census/repo-a/local/loops/main" "$census/repo-b/local/loops/phase/1a" \
  "$census/repo-c/elsewhere" || die_temp "cannot build $census"
for d in repo-a/local/loops/main repo-b/local/loops/phase/1a repo-c/elsewhere; do
  printf '%s' "$modern" > "$census/$d/run-state.json"
done
out=$("$check" --census "$census" 2>&1); rc=$?
[ "$rc" -eq 0 ] && saw '2 snapshot(s)' && saw 'repo-b/local/loops/phase/1a'
check_that "--census finds nested local/loops snapshots (got $rc)" $?

saw 'repo-a/local/loops/main' && ! saw 'repo-c/elsewhere'
check_that "--census ignores a run-state.json outside local/loops" $?

out=$("$check" --census "$temp_dir/repo" 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'found no local/loops snapshot'
check_that "a census root with no snapshot exits 2, not clean (got $rc)" $?

# --- a clean snapshot beside a declining one still reports both ---------
good="$temp_dir/good.json"; printf '%s' "$modern" > "$good"
snap '{"queue":[]}'
out=$("$check" "$good" "$state" 2>&1); rc=$?
[ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q '2 snapshot(s)' \
  && printf '%s\n' "$out" | grep -q '0 of 5 arm(s) violated'
check_that "a batch reports every snapshot and the whole arm count (got $rc)" $?

EXPECTED_CHECKS=35
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran wave-queue-dag-audit tests passed"; exit 0
else
  echo "wave-queue-dag-audit FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1
fi
