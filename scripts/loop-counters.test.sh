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
rail() { # desc, rail, overrides-at, overrides-short, outcome
  run "$3" "$5"
  printf '%s\n' "$out" | grep -q "TRIPPED  $2 "
  check "RAIL $1: trips on reaching its limit" $?
  agree "RAIL $1 at limit:"
  run "$4" "$5"
  ! printf '%s\n' "$out" | grep -q "TRIPPED  $2 "
  check "RAIL $1: stays quiet one short of it" $?
}
rail "max_total_waves" max_total_waves '{"total_waves":24}' '{"total_waves":23}' "$shipped_q"
rail "max_corrective_waves" max_corrective_waves '{"corrective_waves":5}' '{"corrective_waves":4}' \
  '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":true}'
rail "consecutive_no_progress" consecutive_no_progress '{"consecutive_no_progress":2}' '{"consecutive_no_progress":1}' \
  '{"kind":"queue","shipped":false}'
rail "max_wave_retries" max_wave_retries '{"wave_retries":3}' '{"wave_retries":2}' \
  '{"kind":"retry","shipped":true,"files_changed":1,"touched_product":true,"net_new":true}'
rail "scaffolding_only_correctives" scaffolding_only_correctives '{"scaffolding_only_correctives":1}' '{"scaffolding_only_correctives":0}' \
  '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":false}'

gating_fix='{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":true,"gating":true}'
run '{}' "$gating_fix"
printf '%s\n' "$out" | grep -q 'TRIPPED  max_correctives_per_wave 1/1 — rethink'
check "PER-WAVE: a gating finding after the wave's corrective is a rethink" $?
printf '%s\n' "$out" | grep -q '^GOVERNOR: rethink'
check "PER-WAVE: the headline says rethink, not STOP" $?
agree "PER-WAVE rethink:"
is "PER-WAVE: the snapshot is written before the rail is reported" corrective_waves 1

run '{}' '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":true}'
! printf '%s\n' "$out" | grep -q 'max_correctives_per_wave'
check "PER-WAVE: the wave's one corrective, with nothing gating after it, is clear" $?

run '{"correctives_this_wave":1}' '{"kind":"queue","shipped":true,"files_changed":1,"touched_product":true,"gating":true}'
! printf '%s\n' "$out" | grep -q 'max_correctives_per_wave'
check "PER-WAVE: a gating finding on a NEW wave is its first, not a rethink" $?

run '{"total_waves":24}' '{"kind":"corrective","shipped":true,"files_changed":1,"touched_product":true,"gating":true}'
printf '%s\n' "$out" | grep -q '^GOVERNOR: STOP'
check "OUTRANK: a STOP rail outranks a rethink tripped beside it" $?

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
run '{"total_waves":24}' "$shipped_q" --claude-md "$md"
printf '%s\n' "$out" | grep -q '^GOVERNOR: clear'
check "OVERRIDE: a raised max-waves lets wave 25 through" $?
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
refused "unknown kind" '{"kind":"cleanup","shipped":false}'
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

out=$("$runner" --outcome "$d/outcome.json" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "USAGE: a missing --state exits 2" $?

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails of $checks loop-counters check(s) FAILED"
  exit 1
fi
echo "all $checks loop-counters checks passed"
