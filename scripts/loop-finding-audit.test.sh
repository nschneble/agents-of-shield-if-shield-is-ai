#!/usr/bin/env bash
# loop-finding-audit.test.sh — both-directions test for the finding
# admissibility audit.
#
# Every arm both ways, plus the arm count in the headline. Fixtures
# written by this suite; pure bash + jq.
# Background: docs/test-suites.md#loop-finding-audit
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/loop-finding-audit.sh"

# a failing mktemp returns empty, which makes every derived fixture path
# absolute and scatters the run outside the temp tree. Abort loudly
# rather than half-run against paths nobody intended.
die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-finding.XXXXXX") \
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

# re-derive the expected exit code from the report's own headline, so a
# report and a code that drifted apart cannot both keep passing.
agree() { # desc — reads $out and $rc from the case just run
  local line want
  line=$(printf '%s\n' "$out" | grep -E '^(FINDING AUDIT|NOTHING CHECKED)' | tail -1)
  case "$line" in
    'NOTHING CHECKED'*)            want=2;;
    *INCOMPLETE*)                  want=2;;
    'FINDING AUDIT: 0 violations'*) want=0;;
    *)                             want=1;;
  esac
  [ "$rc" -eq "$want" ]
  check "AGREE: $1 exit code $rc matches its headline (want $want)" $?
}

# --- Fixture builder: a run that spent one corrective and can say why.
gate() { # wave, agent, gates, gated_by, contract_ref
  jq -nc --arg w "$1" --arg a "$2" --argjson g "$3" \
         --arg gb "$4" --arg cr "$5" '{
    wave: $w, kind: "crew", agent: $a, task_tool_available: true, ran: true,
    verdict: "fixture", outcome: null, verified_by: "executable",
    gates: $g,
    gated_by: (if $gb == "" then null else $gb end),
    contract_ref: (if $cr == "" then null else $cr end),
    blockers: 0, summary: "fixture"
  }'
}

mkrun() { # dir
  local d="$1"
  mkdir -p "$d"
  {
    gate 1 the-diamantaire true correctness-regression A1
    gate 1 the-chemist false "" ""
    gate 1 the-auditor false "" ""
    gate 1-corrective-1 the-diamantaire false "" ""
    gate 1-corrective-1 the-chemist false "" ""
  } > "$d/gates.jsonl"
  jq -n '{
    goal: "fixture",
    goal_contract: { asks: [
      { id: "A1", ask: "the first ask", done_when: "it is done" },
      { id: "A2", ask: "the second ask", done_when: "it is done" }
    ], fixed_at: "step-1" },
    queue: [ { wave: 1, status: "shipped", closes: ["A1"] } ],
    cleanup_batch: [],
    counters: { corrective_waves: 1, correctives_this_wave: 0 }
  }' > "$d/run-state.json"
}

run() { out=$("$runner" --dir "$1" 2>&1); rc=$?; }

# --- GREEN: one corrective, one justified gating finding. -------------
g="$temp_dir/green"; mkrun "$g"
run "$g"
printf '%s\n' "$out" | grep -q 'FINDING AUDIT: 0 violations across 6 check(s)'
check "GREEN: a justified run reports zero violations over all 6 arms" $?
agree "GREEN:"
! printf '%s\n' "$out" | grep -q 'VIOLATION'
check "GREEN: no arm prints a VIOLATION line" $?
! printf '%s\n' "$out" | grep -q 'NOT EVALUABLE'
check "GREEN: no arm is skipped when both records are present" $?
printf '%s\n' "$out" | grep -q "ASSERTS THE RUN'S OWN RECORDS ONLY"
check "GREEN: the disclaimer is printed on a clean run too" $?

# --- RED, one arm at a time. Each mutates GREEN in exactly one place. --
red() { # desc, expected-substring, mutator-fn
  local d="$temp_dir/red-$checks"
  cp -R "$g" "$d"
  "$3" "$d"
  run "$d"
  printf '%s\n' "$out" | grep -q "$2"
  check "RED: $1" $?
  agree "RED: $1 —"
}

# arm 1 — a gating claim with no contract_ref
m_no_ref() { jq -c 'if .gates == true then .contract_ref = null else . end' "$1/gates.jsonl" > "$1/g" && mv "$1/g" "$1/gates.jsonl"; }
red "a gating claim with no contract_ref is unjustified" 'unjustified gating claim' m_no_ref

# arm 1 — a gating claim in a class the floor does not carry
m_bad_class() { jq -c 'if .gates == true then .gated_by = "test-hygiene" else . end' "$1/gates.jsonl" > "$1/g" && mv "$1/g" "$1/gates.jsonl"; }
red "a gating claim outside the five classes is unjustified" 'unjustified gating claim' m_bad_class

# arm 2 — an ask id the contract never declared
m_phantom_ask() { jq -c 'if .gates == true then .contract_ref = "A7" else . end' "$1/gates.jsonl" > "$1/g" && mv "$1/g" "$1/gates.jsonl"; }
red "an ask id absent from the goal contract is caught" 'does not declare' m_phantom_ask

# arm 2 — a contract_ref that is neither shape
m_junk_ref() { jq -c 'if .gates == true then .contract_ref = "looked wrong to me" else . end' "$1/gates.jsonl" > "$1/g" && mv "$1/g" "$1/gates.jsonl"; }
red "a contract_ref of neither shape is caught" 'neither an ask id nor a path' m_junk_ref

# arm 3 — more correctives spent than justified
m_overspend() { jq '.counters.corrective_waves = 4' "$1/run-state.json" > "$1/s" && mv "$1/s" "$1/run-state.json"; }
red "correctives spent beyond the justified findings are caught" '4 corrective wave(s) spent, 1 justified' m_overspend

# arm 3 — the legacy shape: a log with no justification fields at all
m_legacy() { jq -c 'del(.gates, .gated_by, .contract_ref)' "$1/gates.jsonl" > "$1/g" && mv "$1/g" "$1/gates.jsonl"; }
red "a legacy log cannot account for its correctives" '1 corrective wave(s) spent, 0 justified' m_legacy

# arm 3 — an under-reported counter. The snapshot says nothing was
# spent while the log carries three labelled correctives; trusting the
# counter alone made this the cheapest way around the whole check.
m_underreport() {
  { gate 2-corrective-1 the-diamantaire false "" ""
    gate 3-corrective-1 the-diamantaire false "" ""; } >> "$1/gates.jsonl"
  jq '.counters.corrective_waves = 0' "$1/run-state.json" > "$1/s" && mv "$1/s" "$1/run-state.json"
}
red "an under-reported counter loses to the log's labels" '3 corrective wave(s) spent, 1 justified' m_underreport

# arm 3 — a counter that is not a count. Must skip the snapshot side
# loudly and keep auditing on the log, never fall through silently.
m_junk_counter() { jq '.counters.corrective_waves = "ten"' "$1/run-state.json" > "$1/s" && mv "$1/s" "$1/run-state.json"; }
red "a non-numeric counter is named, not silently trusted" "counter 'ten' is not a count" m_junk_counter

# arm 4 — two correctives on one parent wave
m_two_correctives() { gate 1-corrective-2 the-diamantaire false "" "" >> "$1/gates.jsonl"; }
red "a second corrective on the same wave breaches the cap" 'wave 1 spent 2 correctives, cap is 1' m_two_correctives

# arm 5 — an interim pass wider than the cap
m_wide_interim() {
  { gate 1 the-stickler false "" ""; gate 1 the-improver false "" ""; } >> "$1/gates.jsonl"
  gate 2 the-chemist false "" "" >> "$1/gates.jsonl"   # a later label, so wave 1 is not final
}
red "an interim crew wider than the cap is caught" 'interim crew on wave 1 ran 5 agents' m_wide_interim

# --- GREEN counterparts for the arms whose RED is a threshold. --------
# A cap check that fired on everything would pass every RED above while
# being useless, so each threshold arm needs its permissive direction.
w="$temp_dir/wide-final"; mkrun "$w"
{ gate 9 the-diamantaire false "" ""; gate 9 the-chemist false "" ""
  gate 9 the-auditor false "" ""; gate 9 the-chronicler false "" ""
  gate 9 the-stickler false "" ""; gate 9 the-improver false "" ""
  gate 9 the-ghostwriter false "" ""; } >> "$w/gates.jsonl"
run "$w"
! printf '%s\n' "$out" | grep -q 'interim crew'
check "GREEN: the final pass may run all seven" $?
agree "GREEN-final:"

c="$temp_dir/cleanup"; mkrun "$c"
{ gate cleanup the-diamantaire false "" ""; gate cleanup the-chemist false "" ""
  gate cleanup the-auditor false "" ""; gate cleanup the-stickler false "" ""
  gate 99 the-chemist false "" ""; } >> "$c/gates.jsonl"
run "$c"
! printf '%s\n' "$out" | grep -q 'interim crew on wave cleanup'
check "GREEN: a cleanup pass is terminal, not interim" $?

l="$temp_dir/line-ref"; mkrun "$l"
jq -c 'if .gates == true then .contract_ref = "apps/web/src/auth/core.ts:L40-L52" else . end' \
  "$l/gates.jsonl" > "$l/g" && mv "$l/g" "$l/gates.jsonl"
run "$l"
printf '%s\n' "$out" | grep -q 'FINDING AUDIT: 0 violations'
check "GREEN: a path:Lstart-Lend citation justifies a gating finding" $?
agree "GREEN-line-ref:"

o="$temp_dir/override"; mkrun "$o"
gate 1-corrective-2 the-diamantaire false "" "" >> "$o/gates.jsonl"
out=$("$runner" --dir "$o" --max-per-wave 2 2>&1); rc=$?
! printf '%s\n' "$out" | grep -q 'spent 2 correctives'
check "GREEN: --max-per-wave raises the cap it is given" $?

# --- INCOMPLETE: a missing snapshot skips arms, so exit 2, not 0. -----
i="$temp_dir/no-state"; mkrun "$i"; rm "$i/run-state.json"
run "$i"
printf '%s\n' "$out" | grep -q 'INCOMPLETE, 2 arm(s)'
check "INCOMPLETE: a missing snapshot skips both snapshot-fed arms" $?
agree "INCOMPLETE:"
printf '%s\n' "$out" | grep -q 'NOT EVALUABLE'
check "INCOMPLETE: the skipped arms are named, not silently dropped" $?

# --- NOTHING CHECKED: nothing to read asserts nothing. ---------------
run "$temp_dir/absent"
printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check "NOTHING: a missing run dir asserts nothing" $?
agree "NOTHING-dir:"

e="$temp_dir/empty"; mkdir -p "$e"; : > "$e/gates.jsonl"
run "$e"
printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check "NOTHING: an empty gate log asserts nothing" $?
agree "NOTHING-empty:"

b="$temp_dir/broken"; mkrun "$b"; echo 'not json' > "$b/gates.jsonl"
run "$b"
printf '%s\n' "$out" | grep -q 'NOTHING CHECKED'
check "NOTHING: an unparseable gate log asserts nothing" $?
agree "NOTHING-broken:"

# --- Usage errors exit 2, never 1: the contract reserves 1 for a real
#     violation, so a typo'd flag must not read as a failing audit. ----
"$runner" --nope >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "USAGE: an unknown flag exits 2" $?
"$runner" --dir >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "USAGE: a value-taking flag with no value exits 2" $?
"$runner" --max-per-wave abc >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "USAGE: a non-numeric cap exits 2" $?

echo
# an assertion floor: a suite that silently stopped asserting still
# prints "all tests passed" off a zero failure counter. Pegged at the
# exact arm count, not a round number under it.
[ "$checks" -eq 43 ] || { printf 'FAIL  %d assertion(s) ran, expected exactly 43\n' "$checks"; fails=$((fails + 1)); }
if [ "$fails" -eq 0 ]; then echo "all loop-finding-audit tests passed ($checks assertions)"; exit 0
else echo "$fails loop-finding-audit test(s) FAILED"; exit 1; fi
