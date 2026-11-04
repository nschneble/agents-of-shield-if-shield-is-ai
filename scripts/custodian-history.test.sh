#!/usr/bin/env bash
# both-directions test; background: docs/test-suites.md#custodian-history
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hist="$here/custodian-history.sh"
guard="$here/custodian-guardrails.sh"

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
has() { printf '%s\n' "$out" | grep -qxF -- "$1"; }

root="$temp_dir/root"; home="$temp_dir/home"; index="$home/history-index.jsonl"
loops="$root/linklater/local/loops"
mkdir -p "$loops/a" "$loops/b" "$loops/c" "$loops/d" "$home" || die_temp "cannot build fixture"
cite() { echo "linklater/local/loops/$1/gates.jsonl:$2"; }
line() { printf '{"wave":1,"kind":"crew","agent":"the-stickler","blockers":0,"summary":"%s"}\n' "$1"; }
ingest() { out=$(REPOS_ROOT="$root" CUSTODIAN_HOME="$home" "$hist" ingest 2>/dev/null); rc=$?; }
records() { grep -c . "$index" || true; }
summary_of() { jq -r --arg c "$1" 'select(.cite == $c) | .summary' "$index" | paste -sd'|' -; }

for d in a b c d; do { line "${d}1"; line "${d}2"; line "${d}3"; } > "$loops/$d/gates.jsonl"; done
ingest
[ "$rc" -eq 0 ] && [ "$(records)" -eq 12 ]; check "BASE: first ingest indexes every line" $?

ingest
[ "$(records)" -eq 12 ] && ! printf '%s\n' "$out" | grep -qE '^(CHANGED|VANISHED) '
check "STEADY: an unchanged re-ingest adds nothing and reports nothing" $?
printf '%s\n' "$out" | grep -q '^ingested 0 new record(s); 0 changed, 0 vanished; '
check "STEADY: the summary counts zero of each" $?

head -12 "$index" > "$temp_dir/prefix"
{ line a1; line a3; line a4; } > "$loops/a/gates.jsonl"
line b1x > "$temp_dir/b"; sed -n 2,3p "$loops/b/gates.jsonl" >> "$temp_dir/b"; mv "$temp_dir/b" "$loops/b/gates.jsonl"
line c1 > "$loops/c/gates.jsonl"
ingest
[ "$rc" -eq 0 ]; check "MISMATCH: ingest still exits 0 when lines changed (got $rc)" $?
[ "$(summary_of "$(cite a 3)")" = "a3|a4" ]
check "DELETION: an append landing on an indexed cite after a deletion is indexed" $?
has "VANISHED $(cite a 2)" && ! printf '%s\n' "$out" | grep -qE "^(CHANGED|VANISHED) $(cite a '[13]')$"
check "DELETION: the deleted line reports VANISHED, the shifted line nothing" $?
[ "$(summary_of "$(cite b 1)")" = "b1|b1x" ] && has "CHANGED $(cite b 1)"
check "REWRITE: a rewritten line reports CHANGED and adds the new record beside the old" $?
! printf '%s\n' "$out" | grep -qE "^(CHANGED|VANISHED) $(cite b '[23]')$"
check "REWRITE: the untouched lines of that file report nothing" $?
has "VANISHED $(cite c 2)" && has "VANISHED $(cite c 3)" && ! printf '%s\n' "$out" | grep -q "^CHANGED $(cite c 1)$"
check "TRUNCATE: a shorter file reports its lost lines VANISHED" $?
[ "$(summary_of "$(cite c 2)")" = "c2" ]
check "TRUNCATE: a vanished line keeps its record and gains none" $?
printf '%s\n' "$out" | grep -q '^ingested 3 new record(s); 1 changed, 3 vanished; '
check "MISMATCH: the summary counts new, changed and vanished" $?
head -12 "$index" | cmp -s - "$temp_dir/prefix"
check "APPEND-ONLY: every earlier record is byte-identical" $?

ingest
[ "$(records)" -eq 15 ] && ! printf '%s\n' "$out" | grep -q '^CHANGED '
check "ONE-SHOT: a CHANGED line reports once, then reads as indexed" $?
has "VANISHED $(cite c 2)"
check "VANISHED: a truncated live file reports again on the next run" $?

line b1 > "$temp_dir/b"; sed -n 2,3p "$loops/b/gates.jsonl" >> "$temp_dir/b"; mv "$temp_dir/b" "$loops/b/gates.jsonl"
ingest
[ "$(summary_of "$(cite b 1)")" = "b1|b1x|b1" ] && has "CHANGED $(cite b 1)"
check "REVERT: a line restored to older content is re-appended under its cite" $?
ingest
! printf '%s\n' "$out" | grep -q "^CHANGED $(cite b 1)$"
check "REVERT: and then reads as indexed" $?

mkdir -p "$loops/.archive/2026-10-01" && mv "$loops/c" "$loops/.archive/2026-10-01/c" && rm -rf "$loops/d"
ingest
! printf '%s\n' "$out" | grep -qE "^(CHANGED|VANISHED) linklater/local/loops/[cd]/"
check "GONE: an archived or deleted source reports nothing" $?
printf '%s\n' "$out" | grep -q '^ingested 0 new record(s); 0 changed, 0 vanished; '
check "GONE: and the summary counts nothing" $?

# --- readers count each distinct line a log has ever held, once ---
rin="$temp_dir/r"; rlog="$rin/linklater/local/loops/r/gates.jsonl"; ridx="$rin/home/history-index.jsonl"
mkdir -p "${rlog%/*}" "$rin/home" || die_temp "cannot build reader fixture"
rline() { printf '{"wave":1,"kind":"crew","agent":"x","verdict":"ok","ran":%s,"task_tool_available":true,"verified_by":"executable","blockers":0,"summary":"%s"}\n' "$2" "$1"; }
ringest() { rout=$(REPOS_ROOT="$rin" CUSTODIAN_HOME="$rin/home" "$hist" ingest 2>/dev/null); }
total_of() { "$guard" --index "$1" 2>/dev/null | sed -n 's/^  \([0-9]*\) records · .*/\1/p'; }
g1_of() { "$guard" --index "$1" 2>/dev/null | sed -n 's/^TOTAL VIOLATIONS: .*(G1 \([0-9]*\) lines.*/\1/p'; }
summaries_of() { # root -> the summary of every query row, sorted
  REPOS_ROOT="$1" CUSTODIAN_HOME="$1/home" "$hist" query --limit 99 \
    | sed -n 's/^  \([^[ ].*\)$/\1/p' | sort | paste -sd' ' -
}
{ rline s1 true; rline s2 false; rline s3 true; rline s4 true; rline s5 true; } > "$rlog"
ringest
[ "$(total_of "$ridx")" = 5 ] && [ "$(g1_of "$ridx")" = 1 ]
check "READERS: five lines and one violation before any edit" $?
sed -n '1p;3,5p' "$rlog" > "$rin/shifted" && mv "$rin/shifted" "$rlog"
ringest
[ "$(printf '%s\n' "$rout" | grep -E '^(CHANGED|VANISHED) ')" = "VANISHED linklater/local/loops/r/gates.jsonl:2" ]
check "SHIFT: a mid-file deletion reports the deleted line alone" $?
[ "$(summaries_of "$rin")" = "s1 s2 s3 s4 s5" ]
check "SHIFT: query lists every line the log held once, the deleted one included" $?
[ "$(total_of "$ridx")" = 5 ] && [ "$(g1_of "$ridx")" = 1 ]
check "SHIFT: guardrails count the tail once and keep the deleted line's violation" $?
before=$(grep -c . "$ridx"); ringest
[ "$(grep -c . "$ridx")" -eq "$before" ] \
  && printf '%s\n' "$rout" | grep -q '^ingested 0 new record(s); 0 changed, 0 vanished; '
check "SHIFT: a re-ingest after the shift adds and reports nothing" $?

g1='{"wave":1,"kind":"crew","agent":"x","verdict":"ok","ran":false,"task_tool_available":false,"verified_by":null,"blockers":0,"summary":"%s"}\n'
g1ok='{"wave":1,"kind":"crew","agent":"x","verdict":"ok","ran":true,"task_tool_available":true,"verified_by":"executable","blockers":0,"summary":"%s"}\n'
gin="$temp_dir/g"; gloops="$gin/linklater/local/loops"; gidx="$gin/home/history-index.jsonl"
mkdir -p "$gloops/g" "$gloops/h" "$gloops/i" "$gin/home" || die_temp "cannot build guardrail fixture"
gingest() { REPOS_ROOT="$gin" CUSTODIAN_HOME="$gin/home" "$hist" ingest >/dev/null 2>&1; }
printf "$g1" bad > "$gloops/g/gates.jsonl"; gingest
printf "$g1" bad2 > "$gloops/g/gates.jsonl"; gingest
[ "$(grep -c . "$gidx")" -eq 2 ] && [ "$(g1_of "$gidx")" = 2 ]
check "HISTORY: a violating line rewritten counts both versions" $?
printf "$g1ok" fixed > "$gloops/g/gates.jsonl"; gingest
[ "$(g1_of "$gidx")" = 2 ] && [ "$(summaries_of "$gin")" = "bad bad2 fixed" ]
check "HISTORY: a violation rewritten clean still counts and is still listed" $?
printf "$g1" bad2 > "$gloops/g/gates.jsonl"; gingest
[ "$(grep -c . "$gidx")" -eq 4 ] && [ "$(g1_of "$gidx")" = 2 ] && [ "$(total_of "$gidx")" = 3 ]
check "HISTORY: a revert to a counted version counts it once" $?
{ printf "$g1ok" twin; printf "$g1ok" twin; } > "$gloops/h/gates.jsonl"; gingest
[ "$(total_of "$gidx")" = 4 ]
check "TWINS: two identical lines in one log collapse to one" $?
printf "$g1ok" twin > "$gloops/i/gates.jsonl"; gingest
[ "$(total_of "$gidx")" = 5 ]
check "TWINS: the same line in another log counts on its own" $?

# --- ingest indexes a rewrite that only flips false, null or presence ---
kbase='{"wave":1,"kind":"crew","agent":"x","verdict":"ok","verified_by":"executable","blockers":0,"summary":"s"}'
kin="$temp_dir/k"; mkdir -p "$kin/home" || die_temp "cannot build key fixture"
kingest() { kout=$(REPOS_ROOT="$kin" CUSTODIAN_HOME="$kin/home" "$hist" ingest 2>/dev/null); }
k=0
for pair in '.|.ran = false' '.ran = null|.ran = false' \
  '.|.task_tool_available = false' '.task_tool_available = null|.task_tool_available = false' \
  'del(.verified_by)|.verified_by = null' '.|.outcome = null'; do
  k=$((k + 1)); klog="$kin/linklater/local/loops/k$k/gates.jsonl"; mkdir -p "${klog%/*}"
  from=${pair%%|*}; to=${pair#*|}
  jq -c "$from" <<< "$kbase" > "$klog"; kingest
  jq -c "$to" <<< "$kbase" > "$klog"; kingest
  printf '%s\n' "$kout" | grep -q '^ingested 1 new record(s); 1 changed, 0 vanished; '
  check "EXACT: a rewrite from $from to $to is indexed and reported" $?
  jq -c "$from" <<< "$kbase" > "$klog"; kingest
  printf '%s\n' "$kout" | grep -q '^ingested 1 new record(s); 1 changed, 0 vanished; '
  check "EXACT: and the rewrite back to $from is too" $?
done

xin="$temp_dir/x"; xlog="$xin/linklater/local/loops/x/gates.jsonl"
mkdir -p "${xlog%/*}" "$xin/home" || die_temp "cannot build G1 fixture"
printf '%s\n' "$kbase" > "$xlog"
REPOS_ROOT="$xin" CUSTODIAN_HOME="$xin/home" "$hist" ingest >/dev/null 2>&1
jq -c '.ran = false | .task_tool_available = false' <<< "$kbase" > "$xlog"
REPOS_ROOT="$xin" CUSTODIAN_HOME="$xin/home" "$hist" ingest >/dev/null 2>&1
[ "$(g1_of "$xin/home/history-index.jsonl")" = 1 ]
check "EXACT: a line rewritten to ran false reaches G1 without a rebuild" $?

# --- ingest's key is at least as fine as the reap guard's ---
rk=$(grep -oE '\[\.wave, \.kind.*\] \| tojson' "$here/custodian-reap.sh" | sort -u)
records_jq='
  {wave: 1, kind: "crew", agent: "a", verdict: "ok", blockers: 0, ran: true,
   task_tool_available: true, summary: "s", verified_by: "e", outcome: "o"} as $b
  | [$b] + [($b | keys_unsorted[]) as $f
      | ((null, false, true, 0, 2, "", "s") as $v | $b | .[$f] = $v), ($b | del(.[$f]))]'
coarser=$(jq -n -L "$here" 'include "custodian-index"; def guard: '"$rk"';'"$records_jq"'
  | [.[] as $x | .[] as $y
      | select(($x | exact_key) == ($y | exact_key) and ($x | guard) != ($y | guard))]
  | length' 2>/dev/null)
[ "$(printf '%s\n' "$rk" | grep -c .)" -eq 1 ] && [ "$coarser" = 0 ]
check "KEY: every pair of records the reap guard tells apart, ingest's key does too" $?
finer=$(jq -n -L "$here" 'include "custodian-index"; def guard: '"$rk"';
  {ran: false} as $f | {ran: null} as $n
  | ($f | exact_key) != ($n | exact_key) and ($f | guard) == ($n | guard)' 2>/dev/null)
[ "$finer" = true ]
check "KEY: ingest's key tells ran false from null, which the guard folds" $?

# --- a failed ingest leaves no temp file behind ---
tin="$temp_dir/t"
mkdir -p "$tin/tmp" "$tin/home" "$tin/linklater/local/loops/t" || die_temp "cannot build temp fixture"
line t1 > "$tin/linklater/local/loops/t/gates.jsonl"
TMPDIR="$tin/tmp" REPOS_ROOT="$tin" CUSTODIAN_HOME="$tin/home" "$hist" ingest >/dev/null 2>&1
[ -s "$tin/home/history-index.jsonl" ] && [ -z "$(ls -A "$tin/tmp")" ]
check "TEMP: a clean ingest leaves no temp file" $?
echo 'not json' > "$tin/home/history-index.jsonl"
TMPDIR="$tin/tmp" REPOS_ROOT="$tin" CUSTODIAN_HOME="$tin/home" "$hist" ingest >/dev/null 2>&1; trc=$?
[ "$trc" -ne 0 ] && [ -z "$(ls -A "$tin/tmp")" ]
check "TEMP: an ingest failing on a corrupt index leaves none either (got $trc)" $?

echo
if [ "$fails" -eq 0 ]; then echo "all $checks custodian-history test(s) passed"; exit 0
else echo "$fails of $checks custodian-history test(s) FAILED"; exit 1; fi
