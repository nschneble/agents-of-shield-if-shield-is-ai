#!/usr/bin/env bash
# loop-state-audit.test.sh — both-directions test for the run-state
# drift audit.
#
# Standing rule: a new invariant is tested RED (goes off on a violating
# fixture) AND green (clean fixture passes). Every comparison arm gets
# both, because an audit that silently stopped comparing would print
# `STATE DRIFT: 0` — the same words as a clean run. The arm count in the
# headline is what separates those two, so it is asserted too.
#
# Four properties the audit's honesty depends on:
#   - THE LIVE SEGMENT is load-bearing. A `commit` line above a later
#     `_declared` belongs to a superseded dispatch, so the wave is NOT
#     shipped. One fixture pair carries both directions: the same lines
#     with and without the trailing declaration. Without the pair, an
#     audit that grepped the whole file for `commit` and an audit that
#     read segments correctly would each pass some single arm.
#   - NOT EVALUABLE is not clean. A journal with an unparseable line
#     cannot be typed, so the four journal-derived arms are SKIPPED
#     rather than compared against a floor — and the report has to say
#     which wave and why, or a damaged journal quietly shrinks the
#     comparison to the arms that happen to still work.
#   - The EXIT CODE tracks the printed drift count on every fixture, so
#     a caller branching on `$?` and a human reading the report never
#     disagree. `agree` below re-derives it from the report's own
#     headline rather than restating an expected number.
#   - EXIT 0 MEANS FULLY CHECKED, not "nothing I compared disagreed".
#     A resume branches on this code to decide whether to trust the
#     snapshot, so a run whose position arms were skipped exits 2 even
#     with every surviving arm green — and a disagreement the audit did
#     settle outranks that, since drift is actionable and a gap is only
#     a reason to go looking. Both directions have an arm.
#
# Fixtures are written by this file — never read from gitignored
# `local/`. Pure bash + jq, self-contained.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/loop-state-audit.sh"

# a failing mktemp returns empty, which makes every derived fixture path
# absolute and scatters the run outside the temp tree. Abort loudly
# rather than half-run against paths nobody intended.
die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

fails=0
checks=0
check() { # desc, condition-already-evaluated ($?)
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# re-derive the expected exit code from the report's own headline. A
# suite that hardcoded the number would keep agreeing after the report
# and the code drifted apart, which is the pair this arm exists to hold.
agree() { # desc — reads $out and $rc from the case just run
  local line want
  line=$(printf '%s\n' "$out" | grep -E '^(STATE DRIFT|NOTHING CHECKED)' | tail -1)
  case "$line" in
    'NOTHING CHECKED'*)  want=2;;
    *INCOMPLETE*)         want=2;;
    'STATE DRIFT: 0 of'*) want=0;;
    *)                    want=1;;
  esac
  [ "$rc" -eq "$want" ]
  check "AGREE: $1 exit code $rc matches its headline (want $want)" $?
}

# a real sha so the resolve arm has something that passes; the audit
# resolves against the checkout it ships in, not the fixture dir
real_sha=$(git -C "$here/.." rev-parse --short HEAD)

# --- Fixture builder. A run dir with N shipped waves, all agreeing. ---
mkrun() { # dir, wave_count
  local d="$1" n="$2" i
  mkdir -p "$d"
  for i in $(seq 1 "$n"); do
    {
      printf '{"step":"_declared","wave":%d,"dispatch":1,"reason":"initial","steps":["build","commit"]}\n' "$i"
      echo '{"step":"build","status":"done","artifact":null}'
      echo '{"step":"commit","status":"done","artifact":null}'
    } > "$d/wave-$i.jsonl"
  done
  echo '{"wave":1,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0}' > "$d/gates.jsonl"
  jq -n --argjson n "$n" --arg sha "$real_sha" '{
    goal: "fixture",
    queue: [range(1; $n + 1) | {wave: ., status: "shipped", commit: $sha}],
    counters: {waves_shipped: $n, total_waves: $n, wave_retries: 0},
    last_crew_wave: 1
  }' > "$d/run-state.json"
}

# --- GREEN: a snapshot that matches its records exactly. ---
g="$temp_dir/green"; mkrun "$g" 2
out=$("$runner" --dir "$g" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q 'STATE DRIFT: 0 of 7 field(s)'
check "GREEN: an agreeing snapshot reports zero drift over all 7 arms" $?
agree "GREEN:"
! printf '%s\n' "$out" | grep -q 'DRIFT  '
check "GREEN: no arm prints a DRIFT line" $?
printf '%s\n' "$out" | grep -q 'ASSERTS SNAPSHOT AGAINST LOCAL RECORDS ONLY'
check "GREEN: the disclaimer is printed on a clean run too" $?

# --- RED, one arm at a time. Each mutates the GREEN fixture in exactly
#     one field, so the arm that reddens names the field that moved. ---
red_one() { # desc, jq-mutation, expected-label
  local d="$temp_dir/red-$checks"
  cp -R "$g" "$d"
  jq "$2" "$g/run-state.json" > "$d/run-state.json"
  out=$("$runner" --dir "$d" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -q "DRIFT  $3"
  check "RED: $1" $?
  agree "RED $3:"
}
red_one "an inflated waves_shipped reddens" \
  '.counters.waves_shipped = 5' 'waves_shipped'
red_one "a queue claiming more shipped entries than journals reddens" \
  '.queue += [{wave: 9, status: "shipped", commit: "'"$real_sha"'"}]' 'queue shipped entries'
red_one "a total_waves the journals do not support reddens" \
  '.counters.total_waves = 7' 'total_waves'
red_one "a wave_retries count with no retry declaration reddens" \
  '.counters.wave_retries = 2' 'wave_retries'
red_one "a last_crew_wave gates.jsonl does not support reddens" \
  '.last_crew_wave = 4' 'last_crew_wave'
red_one "a shipped entry naming an unresolvable sha reddens" \
  '.queue[0].commit = "deadbee"' 'shipped commits resolve'
red_one "a shipped entry with no sha at all reddens" \
  '.queue[0].commit = null' 'shipped entries have sha'

# --- THE OBSERVED FAILURE, end to end: two waves shipped, both journals
#     complete, snapshot still reading zeros and no PR. This is the
#     shape the audit was written for, so it gets its own arm rather
#     than living inside the generic counter cases. ---
z="$temp_dir/zeroed"; mkrun "$z" 2
jq '.counters.waves_shipped = 0 | .counters.total_waves = 0
    | .queue = [.queue[] | .status = "pending" | .commit = null]' \
  "$z/run-state.json" > "$z/tmp" && mv "$z/tmp" "$z/run-state.json"
out=$("$runner" --dir "$z" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q 'DRIFT  waves_shipped            snapshot 0 · journals 2'
check "ZEROED: the observed stale-snapshot shape reddens, citing both sides" $?
[ "$(printf '%s\n' "$out" | grep -c 'DRIFT  ')" -eq 3 ]
check "ZEROED: exactly the three position arms redden, not the sha arms" $?
agree "ZEROED:"

# --- THE LIVE SEGMENT, both directions on ONE fixture pair. A `commit`
#     above a later `_declared` is a superseded dispatch's audit trail,
#     so the wave is not shipped; append nothing else and the same lines
#     must flip. ---
s="$temp_dir/segment"; mkrun "$s" 1
printf '%s\n' '{"step":"_declared","wave":1,"dispatch":2,"reason":"retry","steps":["build","commit"]}' \
  >> "$s/wave-1.jsonl"
jq '.counters.wave_retries = 1' "$s/run-state.json" > "$s/tmp" && mv "$s/tmp" "$s/run-state.json"
out=$("$runner" --dir "$s" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q 'DRIFT  waves_shipped            snapshot 1 · journals 0'
check "SEGMENT: a commit above a later declaration does not ship the wave" $?
printf '%s\n' "$out" | grep -q 'ok     wave_retries             snapshot 1 · journals 1'
check "SEGMENT: and that declaration is counted as the retry it is" $?
agree "SEGMENT:"
printf '%s\n' '{"step":"commit","status":"done","artifact":null}' >> "$s/wave-1.jsonl"
out=$("$runner" --dir "$s" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q 'ok     waves_shipped            snapshot 1 · journals 1'
check "SEGMENT: a commit BELOW that declaration ships it again" $?
agree "SEGMENT-GREEN:"

# --- NOT EVALUABLE is not clean: a journal the audit cannot parse
#     removes the four journal arms rather than being counted as zero,
#     and the report names the wave and the reason. ---
u="$temp_dir/unevaluable"; mkrun "$u" 2
echo '{"step":"commit","status":"do' >> "$u/wave-2.jsonl"
out=$("$runner" --dir "$u" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q 'NOT EVALUABLE  wave(s) 2'
check "UNEVALUABLE: the damaged journal is named" $?
printf '%s\n' "$out" | grep -q 'SKIPPED  the four journal-derived arms'
check "UNEVALUABLE: the four journal arms are skipped, not compared" $?
printf '%s\n' "$out" | grep -q 'STATE DRIFT: 0 of 3 field(s)'
check "UNEVALUABLE: the headline counts 3 arms, not 7" $?
# exit 0 would tell a resume the snapshot is fully vouched for when the
# four arms that vouch for its POSITION never ran — the one reading of
# this report that must not be available
printf '%s\n' "$out" | grep -q 'INCOMPLETE, 4 arm(s) could not be settled'
check "UNEVALUABLE: the headline says INCOMPLETE and counts the skipped arms" $?
[ "$rc" -eq 2 ]
check "UNEVALUABLE: a skipped arm exits 2, never 0" $?
agree "UNEVALUABLE:"

# drift the audit DID settle outranks the gap around it: a caller told
# only "incomplete" would go looking for the damage and miss the
# disagreement sitting in plain sight
jq '.queue[0].commit = "deadbee"' "$u/run-state.json" > "$u/tmp" && mv "$u/tmp" "$u/run-state.json"
out=$("$runner" --dir "$u" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q 'DRIFT  shipped commits resolve'
check "PRECEDENCE: a settled disagreement still reddens beside a skipped arm" $?
[ "$rc" -eq 1 ]
check "PRECEDENCE: and drift outranks INCOMPLETE at the exit code" $?
agree "PRECEDENCE:"

# --- NOTHING CHECKED is not clean either, at both the headline and the
#     exit code, or an unreadable run dir greens the audit forever. ---
out=$("$runner" --dir "$temp_dir/absent" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check "NOTHING: a missing run dir asserts nothing" $?
agree "NOTHING-dir:"
b="$temp_dir/broken"; mkrun "$b" 1; echo 'not json' > "$b/run-state.json"
out=$("$runner" --dir "$b" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check "NOTHING: an unparseable snapshot asserts nothing" $?
agree "NOTHING-snapshot:"

# --- Usage errors exit 2, never 1: the contract reserves 1 for drift,
#     so a typo'd flag must not read as a clean-but-drifting run. ---
"$runner" --nope >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "USAGE: an unknown flag exits 2" $?
"$runner" --dir >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "USAGE: a value-taking flag with no value exits 2" $?

echo
# an assertion floor: a suite that silently stopped asserting still
# prints "all tests passed" off a zero failure counter, so the count is
# verified too. Pegged at the exact number of arms, not a round number
# under it — slack here is arms that can be deleted in silence.
[ "$checks" -eq 41 ] || { printf 'FAIL  %d assertion(s) ran, expected exactly 41\n' "$checks"; fails=$((fails + 1)); }
if [ "$fails" -eq 0 ]; then echo "all loop-state-audit tests passed ($checks assertions)"; exit 0
else echo "$fails loop-state-audit test(s) FAILED"; exit 1; fi
