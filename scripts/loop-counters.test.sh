#!/usr/bin/env bash
# loop-counters.test.sh — see docs/test-suites.md#loop-counters
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/loop-counters.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

fails=0
checks=0
check() { # desc, status
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

no_md="$temp_dir/no-budget.md"
printf '# a project with no loop overrides\n' > "$no_md"

zeros='{"waves_shipped":0,"waves_since_crew":0,"cumulative_files_changed":0,
  "last_review_verdict":"none","total_waves":0,"corrective_waves":0,
  "correctives_this_wave":0,"consecutive_no_progress":0,"wave_retries":0,
  "scaffolding_only_correctives":0,"batched_findings":0}'

case_n=0
# state: counter overrides merged over zeros; writes $d, $out, $rc
run() { # counter-overrides-json, outcome-json, extra args...
  case_n=$((case_n + 1))
  d="$temp_dir/case-$case_n"
  mkdir -p "$d"
  jq -n --argjson z "$zeros" --argjson over "$1" \
    '{goal: "fixture", counters: ($z + $over), last_crew_wave: 0,
      cleanup_batch: [{wave: 1}, {wave: 1}]}' > "$d/run-state.json"
  printf '%s\n' "$2" > "$d/outcome.json"
  shift 2
  out=$("$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" \
        --claude-md "$no_md" "$@" 2>&1)
  rc=$?
}
# the pre-dispatch query: writes $d, $out, $rc and leaves the snapshot alone
query() { # counter-overrides-json, next-kind, [cleanup-batch-json], extra args...
  case_n=$((case_n + 1))
  d="$temp_dir/case-$case_n"
  mkdir -p "$d"
  local over=$1 next=$2 batch='[]' pristine
  shift 2
  case "${1:-}" in '['*) batch=$1; shift;; esac
  jq -n --argjson z "$zeros" --argjson over "$over" --argjson b "$batch" \
    '{counters: ($z + $over), cleanup_batch: $b}' > "$d/run-state.json"
  pristine=$(cat "$d/run-state.json")
  out=$("$runner" --state "$d/run-state.json" --next "$next" \
        --claude-md "$no_md" "$@" 2>&1)
  rc=$?
  [ "$(cat "$d/run-state.json")" = "$pristine" ] && [ ! -e "$d/run-state.json.tmp" ]
  check "QUERY --next $next: the snapshot is left byte-identical" $?
}
ctr() { jq -r ".counters.$1" "$d/run-state.json"; }
is() { # desc, counter, want
  local got; got=$(ctr "$2")
  [ "$got" = "$3" ]
  check "$1 ($2 = $got, want $3)" $?
}

# exit code re-derived from the headline, never restated per case
agree() { # desc
  local want
  case "$(printf '%s\n' "$out" | grep -E '^(GOVERNOR|NOTHING WRITTEN)' | tail -1)" in
    'GOVERNOR: clear'*) want=0;;
    'GOVERNOR: '*)      want=1;;
    *)                  want=2;;
  esac
  [ "$rc" -eq "$want" ]
  check "AGREE: $1 exit $rc matches its headline (want $want)" $?
}

shipped_q='{"kind":"queue","shipped":true,"files_changed":3,"touched_product":true,"net_new":true,"review_verdict":"ship"}'

# --- increments and resets, one outcome kind at a time ---
run '{"consecutive_no_progress":2,"correctives_this_wave":1,"waves_since_crew":1,"cumulative_files_changed":4,"scaffolding_only_correctives":1}' "$shipped_q"
is "QUEUE shipped: counts the ship" waves_shipped 1
is "QUEUE shipped: counts the wave since crew" waves_since_crew 2
is "QUEUE shipped: adds its files" cumulative_files_changed 7
is "QUEUE shipped: records the review verdict" last_review_verdict ship
is "QUEUE shipped: counts the dispatch" total_waves 1
is "QUEUE shipped: net-new work resets no-progress" consecutive_no_progress 0
is "QUEUE: a new wave resets its correctives" correctives_this_wave 0
is "QUEUE: a product file resets scaffolding-only" scaffolding_only_correctives 0
is "QUEUE: is not a corrective" corrective_waves 0
is "QUEUE: is not a retry" wave_retries 0
is "ANY: batched_findings is the cleanup_batch length" batched_findings 2
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "QUEUE shipped: governor is clear" $?
agree "QUEUE shipped:"
[ ! -e "$d/run-state.json.tmp" ]
check "ATOMIC: no .tmp is left beside a written snapshot" $?

run '{"consecutive_no_progress":1}' '{"kind":"queue","shipped":false}'
is "QUEUE unshipped: no ship counted" waves_shipped 0
is "QUEUE unshipped: still a dispatch" total_waves 1
is "QUEUE unshipped: shipping nothing counts as no progress" consecutive_no_progress 2
is "QUEUE unshipped: no files added" cumulative_files_changed 0
is "QUEUE unshipped: verdict untouched when absent" last_review_verdict none

run '{"consecutive_no_progress":1}' '{"kind":"queue","shipped":true,"files_changed":1,"touched_product":true,"reopened":true}'
is "REOPENED: re-opening the same blocker counts as no progress" consecutive_no_progress 2

run '{"consecutive_no_progress":1}' '{"kind":"queue","shipped":true,"files_changed":1,"touched_product":true}'
is "SHIPPED, not net-new: no-progress neither grows nor resets" consecutive_no_progress 1

run '{"total_waves":2,"correctives_this_wave":0}' '{"kind":"corrective","shipped":true,"files_changed":2,"touched_product":false}'
is "CORRECTIVE: counts toward corrective_waves" corrective_waves 1
is "CORRECTIVE: counts toward this wave's correctives" correctives_this_wave 1
is "CORRECTIVE: is a dispatched wave" total_waves 3
is "CORRECTIVE: its commit is a shipped wave" waves_shipped 1
is "CORRECTIVE: no product file grows scaffolding-only" scaffolding_only_correctives 1

run '{"total_waves":2,"waves_since_crew":1}' '{"kind":"direct-fix","shipped":true,"files_changed":1,"touched_product":false}'
is "DIRECT FIX: counts toward corrective_waves" corrective_waves 1
is "DIRECT FIX: counts toward this wave's correctives" correctives_this_wave 1
is "DIRECT FIX: no product file grows scaffolding-only" scaffolding_only_correctives 1
is "DIRECT FIX: is not a dispatched wave" total_waves 2
is "DIRECT FIX: is not a shipped wave" waves_shipped 0
is "DIRECT FIX: is not a wave since crew" waves_since_crew 1
is "DIRECT FIX: adds no wave files" cumulative_files_changed 0

run '{"correctives_this_wave":1,"total_waves":3}' '{"kind":"retry","shipped":true,"files_changed":2,"touched_product":true,"net_new":true}'
is "RETRY: counts toward wave_retries" wave_retries 1
is "RETRY: is a dispatched wave" total_waves 4
is "RETRY: is not a corrective" corrective_waves 0
is "RETRY: the same wave keeps its correctives" correctives_this_wave 1

run '{"waves_since_crew":3,"cumulative_files_changed":9,"total_waves":3}' '{"kind":"crew-pass","wave":3}'
is "CREW PASS: resets waves_since_crew" waves_since_crew 0
is "CREW PASS: resets cumulative_files_changed" cumulative_files_changed 0
is "CREW PASS: is not a dispatch" total_waves 3
[ "$(jq -r .last_crew_wave "$d/run-state.json")" = 3 ]
check "CREW PASS: records last_crew_wave" $?

# --- each rail, at its limit and one short of it ---
skill_md="$here/../skills/loop-de-looper/SKILL.md"
# the action the script prints must be the action the governor table names
mirrored() { # rail
  local action row
  action=$(printf '%s\n' "$out" | grep "TRIPPED  $1 " | sed 's/^.* — //')
  row=$(grep "^| \`$1\` " "$skill_md" | tr -d '`')
  [ -n "$action" ] && case "$row" in *"$action"*) true;; *) false;; esac
  check "MIRROR $1: SKILL.md's governor row carries '$action'" $?
}
rail() { # desc, rail, overrides-at, overrides-short, outcome
  run "$3" "$5"
  printf '%s\n' "$out" | grep -q "TRIPPED  $2 "
  check "RAIL $1: trips on reaching its limit" $?
  agree "RAIL $1 at limit:"
  mirrored "$2"
  run "$4" "$5"
  ! printf '%s\n' "$out" | grep -q "TRIPPED  $2 "
  check "RAIL $1: stays quiet one short of it" $?
}
next_rail() { # desc, rail, overrides-at, overrides-short, next-kind
  query "$3" "$5"
  printf '%s\n' "$out" | grep -q "TRIPPED  $2 "
  check "RAIL $1: trips before a $5 dispatch at its limit" $?
  agree "RAIL $1 at limit:"
  mirrored "$2"
  query "$4" "$5"
  ! printf '%s\n' "$out" | grep -q "TRIPPED  $2 "
  check "RAIL $1: stays quiet one short of it" $?
  agree "RAIL $1 short of limit:"
}
next_rail "max_total_waves" max_total_waves '{"total_waves":25}' '{"total_waves":24}' queue
rail "max_corrective_waves" max_corrective_waves '{"corrective_waves":5}' '{"corrective_waves":4}' \
  '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":true,"gating":true}'
rail "consecutive_no_progress" consecutive_no_progress '{"consecutive_no_progress":2}' '{"consecutive_no_progress":1}' \
  '{"kind":"queue","shipped":false}'
next_rail "max_wave_retries" max_wave_retries '{"wave_retries":4}' '{"wave_retries":3}' retry
rail "scaffolding_only_correctives" scaffolding_only_correctives '{"scaffolding_only_correctives":1}' '{"scaffolding_only_correctives":0}' \
  '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":false,"gating":true}'

# --- a rail never halts the run on a unit that succeeded ---
run '{"corrective_waves":5}' '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":true}'
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "SUCCEEDED: the 6th corrective, nothing gating after it, is clear" $?
run '{"wave_retries":3}' '{"kind":"retry","shipped":true,"files_changed":1,"touched_product":true,"net_new":true}'
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "SUCCEEDED: the 4th retry shipping net-new work is clear" $?
run '{"total_waves":24}' "$shipped_q"
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "SUCCEEDED: the 25th wave, shipped, is clear" $?
run '{"scaffolding_only_correctives":1}' '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":false,"net_new":false,"gating":false}'
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "SUCCEEDED: a 2nd scaffolding-only corrective, nothing gating after it, is clear" $?
is "SUCCEEDED: the scaffolding-only corrective is still counted" scaffolding_only_correctives 2

# --- the dispatch rails gate the next dispatch of their kind only ---
query '{"total_waves":25}' cleanup '[{"wave":1}]'
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "NEXT: the cleanup batch wave is not gated by max_total_waves" $?
agree "NEXT cleanup at the ceiling:"
query '{}' cleanup
printf '%s\n' "$out" | grep -q '^GOVERNOR: skip' && printf '%s\n' "$out" | grep -q 'SKIP  cleanup_batch is empty'
check "CLEANUP: an empty cleanup_batch has no cleanup wave to dispatch" $?
agree "CLEANUP empty batch:"
query '{"cleanup_waves":1}' cleanup '[{"wave":1}]'
printf '%s\n' "$out" | grep -q '^GOVERNOR: skip' && printf '%s\n' "$out" | grep -q "SKIP  the run's one cleanup wave already ran"
check "CLEANUP: a second cleanup wave is never dispatched" $?
agree "CLEANUP second wave:"
query '{"cleanup_waves":1}' queue
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "CLEANUP: the cleanup marker gates only a cleanup dispatch" $?
run '{"total_waves":25,"correctives_this_wave":1,"retries_this_wave":1}' '{"kind":"cleanup","shipped":true,"files_changed":4,"touched_product":true}'
is "CLEANUP: the cleanup wave marks the run's one cleanup" cleanup_waves 1
is "CLEANUP: the cleanup wave counts in total_waves" total_waves 26
is "CLEANUP: the cleanup wave counts as shipped" waves_shipped 1
is "CLEANUP: the cleanup wave resets the wave's correctives" correctives_this_wave 0
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "CLEANUP: the cleanup wave itself reads clear" $?
query '{"total_waves":25}' corrective
printf '%s\n' "$out" | grep -q 'TRIPPED  max_total_waves 25/25'
check "NEXT: a corrective dispatch at the ceiling trips max_total_waves" $?
query '{"total_waves":25}' retry
printf '%s\n' "$out" | grep -q 'TRIPPED  max_total_waves 25/25'
check "NEXT: a retry dispatch at the ceiling trips max_total_waves" $?
query '{"wave_retries":4}' queue
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "NEXT: a queue dispatch is not gated by max_wave_retries" $?

gating_fix='{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":true,"gating":true}'
run '{}' "$gating_fix"
printf '%s\n' "$out" | grep -q 'TRIPPED  max_correctives_per_wave 1/1 — rethink'
check "PER-WAVE: a gating finding after the wave's corrective is a rethink" $?
printf '%s\n' "$out" | grep -q '^GOVERNOR: rethink'
check "PER-WAVE: the headline says rethink, not STOP" $?
agree "PER-WAVE rethink:"
mirrored max_correctives_per_wave
is "PER-WAVE: the snapshot is written before the rail is reported" corrective_waves 1

run '{}' '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":true}'
! printf '%s\n' "$out" | grep -q 'max_correctives_per_wave'
check "PER-WAVE: the wave's one corrective, with nothing gating after it, is clear" $?

run '{"correctives_this_wave":1}' '{"kind":"queue","shipped":true,"files_changed":1,"touched_product":true,"gating":true}'
! printf '%s\n' "$out" | grep -q 'max_correctives_per_wave'
check "PER-WAVE: a gating finding on a NEW wave is its first, not a rethink" $?

run '{"corrective_waves":5}' "$gating_fix"
printf '%s\n' "$out" | grep -q '^GOVERNOR: STOP'
check "OUTRANK: a STOP rail outranks a rethink tripped beside it" $?

# --- one wave, several outcomes in a row, on the same snapshot ---
fresh() {
  case_n=$((case_n + 1))
  d="$temp_dir/case-$case_n"
  mkdir -p "$d"
  jq -n --argjson z "$zeros" '{counters: $z, cleanup_batch: []}' > "$d/run-state.json"
}
step() { # outcome-json, extra args...
  printf '%s\n' "$1" > "$d/outcome.json"
  shift
  out=$("$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" \
        --claude-md "$no_md" "$@" 2>&1)
  rc=$?
}
headline() { printf '%s\n' "$out" | grep '^GOVERNOR' | sed 's/^GOVERNOR: \([a-zA-Z]*\).*/\1/'; }
gating_crew='{"kind":"crew-pass","wave":1,"gating":true}'
gating_retry='{"kind":"retry","shipped":true,"files_changed":1,"touched_product":true,"gating":true}'
clean_retry='{"kind":"retry","shipped":true,"files_changed":1,"touched_product":true,"net_new":true}'

fresh
step "$shipped_q"; step "$gating_crew"; step "$gating_fix"
h=$(headline); [ "$h" = rethink ]
check "RETRY SPENT: the wave's first rethink earns its retry (got $h)" $?
step "$gating_retry"
h=$(headline); [ "$h" = STOP ]
check "RETRY SPENT: a rethink after the wave's one retry is a STOP (got $h)" $?
printf '%s\n' "$out" | grep -q 'TRIPPED  max_correctives_per_wave 1/1 — STOP + escalate'
check "RETRY SPENT: the per-wave rail names STOP, not another retry" $?
agree "RETRY SPENT:"
is "RETRY SPENT: the retry is counted against its wave" retries_this_wave 1
step "$gating_retry"
h=$(headline); [ "$h" = STOP ]
check "RETRY SPENT: a second retry's rethink is a STOP too (got $h)" $?

fresh
step "$shipped_q"; step "$gating_fix"; step "$clean_retry"
h=$(headline); [ "$h" = clear ]
check "RETRY SPENT: a retry that clears the finding is clear (got $h)" $?
step "$gating_crew"
h=$(headline); [ "$h" = STOP ]
check "RETRY SPENT: a gating re-crew after a clean retry is a STOP (got $h)" $?

fresh
step "$shipped_q"; step "$gating_fix"; step "$clean_retry"; step "$shipped_q"
is "RETRY SPENT: a new queue wave resets the wave's retries" retries_this_wave 0
step "$gating_fix"
h=$(headline); [ "$h" = rethink ]
check "RETRY SPENT: the next wave's rethink earns its own retry (got $h)" $?

# --- no progress earns the wave its one retry, then stops ---
unshipped_q='{"kind":"queue","shipped":false}'
fresh
step "$unshipped_q"; step "$unshipped_q"; step "$unshipped_q"
h=$(headline); [ "$h" = rethink ]
check "NO PROGRESS: the wave's first trip earns its retry (got $h)" $?
mirrored consecutive_no_progress
step '{"kind":"retry","shipped":false}'
h=$(headline); [ "$h" = STOP ]
check "NO PROGRESS: still no progress after the wave's one retry is a STOP (got $h)" $?
mirrored consecutive_no_progress
agree "NO PROGRESS spent:"
fresh
step "$unshipped_q"; step "$unshipped_q"; step "$unshipped_q"; step "$clean_retry"
h=$(headline); [ "$h" = clear ]
check "NO PROGRESS: a retry shipping net-new work clears it (got $h)" $?

# --- the run dispatches one cleanup wave, however often it asks ---
fresh
jq '.cleanup_batch = [{wave: 1}, {wave: 2}]' "$d/run-state.json" > "$d/batch.json" \
  && mv "$d/batch.json" "$d/run-state.json"
rounds=""
for i in 1 2 3; do
  out=$("$runner" --state "$d/run-state.json" --next cleanup --claude-md "$no_md" 2>&1); rc=$?
  rounds="$rounds$(headline) "
  [ "$rc" -ne 0 ] || step '{"kind":"cleanup","shipped":true,"files_changed":1,"touched_product":true}'
done
total=$(ctr total_waves)
[ "$rounds" = "clear skip skip " ] && [ "$total" = 1 ]
check "CLEANUP: three cleanup rounds dispatch one wave (got $rounds, total $total)" $?

# --- overrides, from the project CLAUDE.md ---
md="$temp_dir/override.md"
cat > "$md" <<'MD'
# project

## Other
- budget: max-waves=99

## Loop de Looper
- crew-agents: interim=3
- budget: max-waves=30, max-corrective=7, per-wave-corrective=2, no-progress=4, max-retries=5, scaffolding-only=3   # tuned
MD
query '{"total_waves":25}' queue --claude-md "$md"
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "OVERRIDE: a raised max-waves lets the 26th dispatch through" $?
printf '%s\n' "$out" | grep -q "limits from $md: per-wave 2 · total 30 · corrective 7 · no-progress 4 · retries 5 · scaffolding 3"
check "OVERRIDE: every budget key lands on its own rail" $?

run '{}' "$gating_fix" --claude-md "$md"
! printf '%s\n' "$out" | grep -q 'max_correctives_per_wave'
check "OVERRIDE: per-wave-corrective=2 allows a second corrective" $?

run '{}' "$shipped_q"
printf '%s\n' "$out" | grep -q "limits from defaults: per-wave 1 · total 25 · corrective 6 · no-progress 3 · retries 4 · scaffolding 2"
check "DEFAULTS: no budget line means the skill's rail table" $?

proj="$temp_dir/project"
mkdir -p "$proj/local/loops/b"
git -C "$proj" init -q 2>/dev/null
cp "$md" "$proj/CLAUDE.md"
jq -n --argjson z "$zeros" '{counters: ($z + {total_waves: 24})}' > "$proj/local/loops/b/run-state.json"
printf '%s\n' "$shipped_q" > "$proj/outcome.json"
out=$("$runner" --state "$proj/local/loops/b/run-state.json" --outcome "$proj/outcome.json" 2>&1); rc=$?
printf '%s\n' "$out" | grep -q "limits from .*/project/CLAUDE.md: per-wave 2"
check "OVERRIDE: with no flag, the snapshot's own repo CLAUDE.md is read" $?

# --- refusals: nothing written, the existing snapshot byte-identical ---
refused() { # desc, outcome-text
  case_n=$((case_n + 1))
  d="$temp_dir/case-$case_n"
  mkdir -p "$d"
  jq -n --argjson z "$zeros" '{counters: $z, cleanup_batch: []}' > "$d/run-state.json"
  printf '%s' "$2" > "$d/outcome.json"
  local pristine; pristine=$(cat "$d/run-state.json")
  out=$("$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" --claude-md "$no_md" 2>&1); rc=$?
  [ "$rc" -eq 2 ]
  check "REFUSE $1: exits 2 (got $rc)" $?
  [ "$(cat "$d/run-state.json")" = "$pristine" ]
  check "REFUSE $1: the existing run-state.json is untouched" $?
  [ ! -e "$d/run-state.json.tmp" ]
  check "REFUSE $1: no .tmp left behind" $?
  agree "REFUSE $1:"
}
refused "truncated JSON" '{"kind":"queue","shipped":tr'
refused "two objects" '{"kind":"queue","shipped":false}{"kind":"queue","shipped":false}'
refused "an array" '[{"kind":"queue","shipped":false}]'
refused "unknown key" '{"kind":"queue","shipped":false,"shiped":true}'
refused "unknown kind" '{"kind":"polish","shipped":false}'
refused "missing shipped" '{"kind":"queue"}'
refused "non-boolean shipped" '{"kind":"queue","shipped":"yes"}'
refused "shipped without files" '{"kind":"queue","shipped":true,"touched_product":true}'
refused "shipped without touched_product" '{"kind":"queue","shipped":true,"files_changed":1}'
refused "fractional files" '{"kind":"queue","shipped":true,"files_changed":1.5,"touched_product":true}'
refused "net-new on an unshipped wave" '{"kind":"queue","shipped":false,"net_new":true}'
refused "crew pass without a wave" '{"kind":"crew-pass"}'
refused "crew pass carrying wave fields" '{"kind":"crew-pass","wave":2,"shipped":true}'

case_n=$((case_n + 1)); d="$temp_dir/case-$case_n"; mkdir -p "$d"
printf '{"counters":{"total_waves":"three"}}' > "$d/run-state.json"
printf '%s\n' "$shipped_q" > "$d/outcome.json"
out=$("$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" --claude-md "$no_md" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = '{"counters":{"total_waves":"three"}}' ] && [ ! -e "$d/run-state.json.tmp" ]
check "REFUSE a non-count counter: jq fails mid-apply, snapshot untouched, no .tmp" $?

# every counter is checked, not only the ones this outcome moves
bad_counter() { # desc, counter-overrides-json, outcome-json
  case_n=$((case_n + 1))
  d="$temp_dir/case-$case_n"
  mkdir -p "$d"
  jq -n --argjson z "$zeros" --argjson over "$2" \
    '{counters: ($z + $over), cleanup_batch: []}' > "$d/run-state.json"
  printf '%s\n' "$3" > "$d/outcome.json"
  local pristine; pristine=$(cat "$d/run-state.json")
  out=$("$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" --claude-md "$no_md" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = "$pristine" ] && [ ! -e "$d/run-state.json.tmp" ]
  check "REFUSE counter $1: exits 2, snapshot byte-identical (got $rc)" $?
}
bad_counter "total_waves 2.5" '{"total_waves":2.5}' "$shipped_q"
bad_counter "total_waves -30" '{"total_waves":-30}' "$shipped_q"
bad_counter "total_waves false" '{"total_waves":false}' "$shipped_q"
bad_counter "total_waves null" '{"total_waves":null}' "$shipped_q"
bad_counter "wave_retries true" '{"wave_retries":true}' "$shipped_q"
bad_counter "wave_retries \"9\"" '{"wave_retries":"9"}' "$shipped_q"
bad_counter "corrective_waves [1]" '{"corrective_waves":[1]}' "$shipped_q"
bad_counter "retries_this_wave 0.5" '{"retries_this_wave":0.5}' "$shipped_q"
bad_counter "batched_findings -1" '{"batched_findings":-1}' "$shipped_q"
bad_counter "cleanup_waves true" '{"cleanup_waves":true}' "$shipped_q"

# cleanup_batch must be an array, or its length is a key or char count
for batch in '{"a":1}' '"abc"' '7'; do
  case_n=$((case_n + 1)); d="$temp_dir/case-$case_n"; mkdir -p "$d"
  jq -n --argjson z "$zeros" --argjson b "$batch" '{counters: $z, cleanup_batch: $b}' > "$d/run-state.json"
  pristine=$(cat "$d/run-state.json")
  out=$("$runner" --state "$d/run-state.json" --next cleanup --claude-md "$no_md" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = "$pristine" ]
  check "REFUSE cleanup_batch $batch: --next cleanup exits 2 (got $rc)" $?
done

printf '{"counters":{"total_waves":1},' > "$d/run-state.json"
out=$("$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" --claude-md "$no_md" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = '{"counters":{"total_waves":1},' ]
check "REFUSE an unparseable run-state: exits 2 and is not rewritten" $?

for bad in 'max-waves=ten' 'max-wavez=30'; do
  printf '## Loop de Looper\n- budget: %s\n' "$bad" > "$temp_dir/bad.md"
  jq -n --argjson z "$zeros" '{counters: $z}' > "$d/run-state.json"
  pristine=$(cat "$d/run-state.json")
  out=$("$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" --claude-md "$temp_dir/bad.md" 2>&1); rc=$?
  [ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = "$pristine" ]
  check "REFUSE budget '$bad': exits 2 and writes nothing" $?
done

budget_run() { # claude-md-text
  printf '%s' "$1" > "$temp_dir/budget.md"
  case_n=$((case_n + 1))
  d="$temp_dir/case-$case_n"
  mkdir -p "$d"
  jq -n --argjson z "$zeros" '{counters: $z, cleanup_batch: []}' > "$d/run-state.json"
  printf '%s\n' "$shipped_q" > "$d/outcome.json"
  pristine=$(cat "$d/run-state.json")
  out=$("$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" --claude-md "$temp_dir/budget.md" 2>&1); rc=$?
}
defaults_line="limits from defaults: per-wave 1 · total 25 · corrective 6 · no-progress 3 · retries 4 · scaffolding 2"

budget_run '# project

How to tune the loop:

```md
## Loop de Looper
- budget: max-waves=N
```
'
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "$defaults_line"
check "FENCE: a budget template quoted in a code fence is not read (exit $rc)" $?

budget_run '# project

~~~~
## Loop de Looper
- budget: max-waves=N
```
~~~
~~~~

## Loop de Looper
- budget: max-waves=30
'
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "limits from .*: per-wave 1 · total 30 "
check "FENCE: a longer fence closes only on its own run; the real line lands (exit $rc)" $?

budget_run "$(printf '# project\r\n\r\n```md\r\n## Loop de Looper\r\n- budget: max-waves=N\r\n```\r\n\r\n## Loop de Looper\r\n- budget: max-waves=2\r\n')"
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "limits from .*: per-wave 1 · total 2 "
check "CRLF: a CRLF fence closes, so the real budget line lands (exit $rc)" $?

budget_run '# project

## loop de looper
- budget: max-waves=30
'
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "$defaults_line"
check "CASE: a lowercase heading is not the section; the defaults line prints (exit $rc)" $?

budget_run '## Loop de Looper
- budget: max-waves=30
- crew-agents: interim=3
- budget: max-corrective=7
'
[ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = "$pristine" ] \
  && printf '%s\n' "$out" | grep -q 'line 2' && printf '%s\n' "$out" | grep -q 'line 4'
check "REFUSE a second budget line: exits 2, names both lines, writes nothing (exit $rc)" $?

budget_run '## Loop de Looper
- budget: max-waves=0
'
[ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = "$pristine" ]
check "REFUSE budget 'max-waves=0': exits 2 and writes nothing (exit $rc)" $?

budget_run '## Loop de Looper
- budget: max-retries=00
'
[ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = "$pristine" ]
check "REFUSE budget 'max-retries=00': a zero is a zero however it is spelled (exit $rc)" $?

# a jq shim failing only the rail call: the one passing $SHIM_ARG
shim="$temp_dir/shim"
mkdir -p "$shim"
real_jq=$(command -v jq)
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = "$SHIM_ARG" ] && exit 5; done\nexec %q "$@"\n' "$real_jq" > "$shim/jq"
chmod +x "$shim/jq"
fresh
printf '%s\n' "$shipped_q" > "$d/outcome.json"
pristine=$(cat "$d/run-state.json")
out=$(SHIM_ARG=per PATH="$shim:$PATH" "$runner" --state "$d/run-state.json" --outcome "$d/outcome.json" --claude-md "$no_md" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = "$pristine" ] && [ ! -e "$d/run-state.json.tmp" ]
check "FAIL CLOSED: a rail evaluation that errors exits 2 and writes nothing (exit $rc)" $?
! printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "FAIL CLOSED: an unevaluated governor never reads clear" $?
out=$(SHIM_ARG=next PATH="$shim:$PATH" "$runner" --state "$d/run-state.json" --next queue --claude-md "$no_md" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ! printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "FAIL CLOSED: a dispatch-rail evaluation that errors exits 2, never clear (exit $rc)" $?

out=$("$runner" --outcome "$d/outcome.json" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "USAGE: a missing --state exits 2" $?
out=$("$runner" --state "$d/run-state.json" --next queue --outcome "$d/outcome.json" --claude-md "$no_md" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ "$(cat "$d/run-state.json")" = "$pristine" ]
check "USAGE: --next and --outcome together exit 2 and write nothing (exit $rc)" $?
out=$("$runner" --state "$d/run-state.json" --next crew --claude-md "$no_md" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ! printf '%s\n' "$out" | grep -q '^GOVERNOR'
check "USAGE: an unknown --next kind exits 2 with no verdict (exit $rc)" $?

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails of $checks loop-counters check(s) FAILED"
  exit 1
fi
echo "all $checks loop-counters checks passed"
