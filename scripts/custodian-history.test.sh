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
has "CHANGED $(cite a 2)" && has "CHANGED $(cite a 3)"
check "DELETION: both shifted cites report CHANGED" $?
[ "$(summary_of "$(cite b 1)")" = "b1|b1x" ] && has "CHANGED $(cite b 1)"
check "REWRITE: a rewritten line reports CHANGED and adds the new record beside the old" $?
! printf '%s\n' "$out" | grep -qE "^(CHANGED|VANISHED) $(cite b '[23]')$"
check "REWRITE: the untouched lines of that file report nothing" $?
has "VANISHED $(cite c 2)" && has "VANISHED $(cite c 3)" && ! printf '%s\n' "$out" | grep -q "^CHANGED $(cite c 1)$"
check "TRUNCATE: a shorter file reports its lost lines VANISHED" $?
[ "$(summary_of "$(cite c 2)")" = "c2" ]
check "TRUNCATE: a vanished line keeps its record and gains none" $?
printf '%s\n' "$out" | grep -q '^ingested 3 new record(s); 3 changed, 2 vanished; '
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
check "REVERT: a line restored to older content is re-appended as newest" $?
ingest
! printf '%s\n' "$out" | grep -q "^CHANGED $(cite b 1)$"
check "REVERT: and then reads as indexed" $?

mkdir -p "$loops/.archive/2026-10-01" && mv "$loops/c" "$loops/.archive/2026-10-01/c" && rm -rf "$loops/d"
ingest
! printf '%s\n' "$out" | grep -qE "^(CHANGED|VANISHED) linklater/local/loops/[cd]/"
check "GONE: an archived or deleted source reports nothing" $?
printf '%s\n' "$out" | grep -q '^ingested 0 new record(s); 0 changed, 0 vanished; '
check "GONE: and the summary counts nothing" $?

# --- readers see one record per cite: the newest ---
q=$(REPOS_ROOT="$root" CUSTODIAN_HOME="$home" "$hist" query --repo linklater --limit 99)
[ "$(printf '%s\n' "$q" | grep -c "^$(cite a 3)$")" -eq 1 ] \
  && [ "$(printf '%s\n' "$q" | grep -A2 -x "$(cite a 3)" | tail -1)" = '  a4' ]
check "QUERY: a rewritten cite is listed once, with its newest content" $?

g1='{"wave":1,"kind":"crew","agent":"x","verdict":"ok","ran":false,"task_tool_available":false,"verified_by":null,"blockers":0,"summary":"%s"}\n'
g1ok='{"wave":1,"kind":"crew","agent":"x","verdict":"ok","ran":true,"task_tool_available":true,"verified_by":"executable","blockers":0,"summary":"%s"}\n'
gin="$temp_dir/g"; mkdir -p "$gin/linklater/local/loops/g" "$gin/home"
gidx="$gin/home/history-index.jsonl"
gingest() { REPOS_ROOT="$gin" CUSTODIAN_HOME="$gin/home" "$hist" ingest >/dev/null 2>&1; }
g1count() { "$guard" --index "$gidx" 2>/dev/null | sed -n 's/^TOTAL VIOLATIONS: .*(G1 \([0-9]*\) lines.*/\1/p'; }
printf "$g1" bad > "$gin/linklater/local/loops/g/gates.jsonl"; gingest
printf "$g1" bad2 > "$gin/linklater/local/loops/g/gates.jsonl"; gingest
[ "$(grep -c . "$gidx")" -eq 2 ] && [ "$(g1count)" = 1 ]
check "GUARDRAILS: a violating line rewritten twice counts once" $?
printf "$g1ok" fixed > "$gin/linklater/local/loops/g/gates.jsonl"; gingest
[ "$(g1count)" = 0 ]
check "GUARDRAILS: a violation rewritten clean no longer counts" $?

# --- one projection: ingest's key is the reap guard's, byte for byte ---
proj() { grep -oE '\[\.wave, \.kind.*\] \| tojson' "$1" | sort -u; }
ik=$(proj "$here/custodian-index.jq"); rk=$(proj "$here/custodian-reap.sh")
[ -n "$ik" ] && [ "$ik" = "$rk" ]
check "KEY: custodian-index.jq's gate_key projection is the reap guard's" $?

echo
if [ "$fails" -eq 0 ]; then echo "all $checks custodian-history test(s) passed"; exit 0
else echo "$fails of $checks custodian-history test(s) FAILED"; exit 1; fi
