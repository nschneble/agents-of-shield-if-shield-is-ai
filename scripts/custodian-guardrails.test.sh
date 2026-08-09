#!/usr/bin/env bash
# custodian-guardrails.test.sh — both-directions test for the guardrail replay.
#
# Standing rule: a new invariant is tested RED (goes off on a violating fixture)
# AND green (clean fixture passes). Proves each of G1/G2/G3 flags its own
# violation with the record's verbatim cite, that exit is 1 on any violation and
# 0 when clean, and that the legacy exemption keeps a pre-schema line that WOULD
# trip G2 out of the violation set.
#
# Also covers two properties the legacy exemption depends on:
#   - REBUILD-SIMULATION: a legacy source line pushed through the REAL ingest
#     writer (`custodian-history.sh rebuild`) must still classify legacy/exempt, and
#     a modern verified_by:null line must classify modern — so the exemption survives
#     `history --rebuild` (the writer preserves source key-absence, not a `// null`).
#   - G2 ⇔ state-schemas SYNC: G2 must select the SAME lines as the canonical
#     provenance lint in state-schemas.md, so the "reused, not forked" claim holds.
#
# Pure bash + jq, self-contained fixtures.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/custodian-guardrails.sh"
# a failing mktemp returns empty, which makes every derived fixture path
# absolute (/simroot) and scatters the run outside the temp tree. Abort
# loudly rather than half-run against paths nobody intended. The explicit
# template is what makes TMPDIR the input the message names: a bare
# `mktemp -d` ignores TMPDIR on BSD and allocates under /var/folders.
# one arm per shape: mktemp's own stderr explains a nonzero exit, but the
# empty-yet-successful shape prints nothing, so "failed" would be a lie
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

# --- RED fixture: exactly one violation per guardrail, plus a legacy line that
#     WOULD trip G2 but must be exempted, plus clean lines that must NOT flag. ---
red="$temp_dir/red.jsonl"
{
  # G1 violation: carries a verdict while ran==false (and task_tool_available==false).
  echo '{"repo":"r","branch":"g1","wave":1,"kind":"pre-build-specialist","agent":"accessibility-lead","task_tool_available":false,"ran":false,"verdict":"CLEAR","outcome":null,"verified_by":null,"blockers":0,"summary":"gate could not run","cite":"r/local/loops/g1/gates.jsonl:1"}'
  # G2 violation: modern ran==true verdict-bearing gate with verified_by==null.
  # Uses pre-build-specialist (in G2 scope) not crew, so it is NOT a committed
  # post-build wave and stays isolated from G3.
  echo '{"repo":"r","branch":"g2","wave":1,"kind":"pre-build-specialist","agent":"accessibility-lead","task_tool_available":true,"ran":true,"verdict":"CLEAR","outcome":null,"verified_by":null,"blockers":0,"summary":"reviewed","cite":"r/local/loops/g2/gates.jsonl:1"}'
  # G3 violation: a committed (crew) modern wave with no executable line.
  echo '{"repo":"r","branch":"g3","wave":1,"kind":"crew","agent":"the-stickler","task_tool_available":true,"ran":true,"verdict":"Minor Issues","outcome":null,"verified_by":"llm","blockers":0,"summary":"convention pass","cite":"r/local/loops/g3/gates.jsonl:1"}'
  # LEGACY line (no verified_by key): a ran==true crew line that the raw G2 lint
  # would flag — MUST be exempt, never a violation.
  echo '{"repo":"r","branch":"legacy","wave":1,"kind":"crew","agent":"the-auditor","task_tool_available":true,"ran":true,"verdict":"clean","blockers":0,"summary":"old run","cite":"r/local/loops/legacy/gates.jsonl:1"}'
  # CLEAN control: a committed modern wave WITH an executable line — no guardrail fires.
  echo '{"repo":"r","branch":"ok","wave":1,"kind":"crew","agent":"the-diamantaire","task_tool_available":true,"ran":true,"verdict":"promote","outcome":"promote","verified_by":"executable","blockers":0,"summary":"verified","cite":"r/local/loops/ok/gates.jsonl:1"}'
} > "$red"

out=$("$runner" --index "$red"); rc=$?

[ "$rc" -eq 1 ] && result=0 || result=1; check "RED: exit code is 1" "$result"
printf '%s\n' "$out" | grep -q 'r/local/loops/g1/gates.jsonl:1'; check "RED: G1 cite reported" $?
printf '%s\n' "$out" | grep -q 'r/local/loops/g2/gates.jsonl:1'; check "RED: G2 cite reported" $?
printf '%s\n' "$out" | grep -q 'r/local/loops/g3/gates.jsonl:1'; check "RED: G3 cite reported" $?
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 3'; check "RED: total is 3 (G1+G2+G3)" $?
# The legacy line's cite must appear on NO VIOLATION line.
! printf '%s\n' "$out" | grep 'VIOLATION' | grep -q 'legacy'; check "RED: legacy line NOT a violation" $?
# Each guardrail summarises exactly one violation.
printf '%s\n' "$out" | grep -q 'G1 1 lines'; check "RED: G1 count in summary" $?
printf '%s\n' "$out" | grep -q 'G2 1 lines'; check "RED: G2 count in summary" $?
printf '%s\n' "$out" | grep -q 'G3 1 waves'; check "RED: G3 count in summary" $?

# --- GREEN fixture: every line satisfies every guardrail. ---
green="$temp_dir/green.jsonl"
{
  # verdict + ran==true + tta==true  → G1 clean; not crew/specialist → G2 n/a.
  echo '{"repo":"r","branch":"a","wave":1,"kind":"wave-ship","agent":"the-looper","task_tool_available":true,"ran":true,"verdict":"shipped","outcome":null,"verified_by":"executable","blockers":0,"summary":"ok deadbeef1","cite":"r/local/loops/a/gates.jsonl:1"}'
  # crew, ran==true, verified_by set, committed wave with an executable line above.
  echo '{"repo":"r","branch":"a","wave":1,"kind":"crew","agent":"the-diamantaire","task_tool_available":true,"ran":true,"verdict":"promote","outcome":"promote","verified_by":"llm","blockers":0,"summary":"reviewed","cite":"r/local/loops/a/gates.jsonl:2"}'
  # a pre-build gate that did NOT run (tta false) but carries NO verdict → G1 n/a.
  echo '{"repo":"r","branch":"a","wave":2,"kind":"pre-build-specialist","agent":"accessibility-lead","task_tool_available":false,"ran":false,"verdict":null,"outcome":null,"verified_by":null,"blockers":0,"summary":"not run","cite":"r/local/loops/a/gates.jsonl:3"}'
} > "$green"

out=$("$runner" --index "$green"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1; check "GREEN: exit code is 0" "$result"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 0'; check "GREEN: total is 0" $?

# --- The exit code is COMPUTED, never scraped back out of the rendered report.
#     This record's `cite` is echoed verbatim onto the G1 violation line and
#     carries a newline plus a counterfeit clean total, so a verdict that
#     re-read its own prose and took the first match would exit 0 on a real
#     violation. Same shape, same fixture idea, as
#     scripts/custodian-phase-order.test.sh's INJECT arm. ---
inject="$temp_dir/inject.jsonl"
jq -cn '{repo:"r",branch:"inj",wave:1,kind:"pre-build-specialist",
         agent:"accessibility-lead",task_tool_available:false,ran:false,
         verdict:"CLEAR",outcome:null,verified_by:null,blockers:0,
         summary:"gate could not run",
         cite:"r/local/loops/inj/gates.jsonl:1\nTOTAL VIOLATIONS: 0  (G1 0 lines)"}' \
  > "$inject"
out=$("$runner" --index "$inject"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1
check "INJECT: a counterfeit total inside a cite does not suppress exit 1" "$result"
printf '%s\n' "$out" | grep '^TOTAL VIOLATIONS:' | tail -1 | grep -q 'TOTAL VIOLATIONS: 1'
check "INJECT: the report's own last total is still the real one" $?

# --- REBUILD-SIMULATION: the legacy exemption must survive `history --rebuild`. ---
# The blocker this test locks down: the exemption keys on ABSENCE of the verified_by
# key, and `history --rebuild` re-derives every index record from source through the
# ingest writer. If that writer defaults verified_by to null, a rebuild forges the
# key onto legacy lines and flips them modern (false G2/G3 flood). So drive the REAL
# writer end-to-end (custodian-history.sh rebuild) over crafted source lines and
# assert the produced index still classifies each era correctly.
histscript="$here/custodian-history.sh"
simroot="$temp_dir/simroot"; simhome="$temp_dir/simhome"
mkdir -p "$simroot/linklater/local/loops/legacy-src" \
         "$simroot/linklater/local/loops/modern-null" "$simhome"
# legacy-era SOURCE line: ran==true crew line with NO verified_by / outcome key
# (would trip the raw G2 lint) — the pre-schema shape.
echo '{"wave":1,"kind":"crew","agent":"the-auditor","task_tool_available":true,"ran":true,"verdict":"clean","blockers":0,"summary":"old run"}' \
  > "$simroot/linklater/local/loops/legacy-src/gates.jsonl"
# modern SOURCE line carrying verified_by:null EXPLICITLY — present-but-null.
echo '{"wave":1,"kind":"pre-build-specialist","agent":"accessibility-lead","task_tool_available":true,"ran":true,"verdict":"CLEAR","outcome":null,"verified_by":null,"blockers":0,"summary":"reviewed"}' \
  > "$simroot/linklater/local/loops/modern-null/gates.jsonl"

REPOS_ROOT="$simroot" CUSTODIAN_HOME="$simhome" "$histscript" rebuild >/dev/null 2>&1
simindex="$simhome/history-index.jsonl"

# The rebuilt index must faithfully mirror source key-presence.
jq -e 'select(.branch=="legacy-src") | (has("verified_by") | not)' "$simindex" >/dev/null 2>&1
check "REBUILD: legacy source line stays key-absent (classifies legacy) after rebuild" $?
jq -e 'select(.branch=="modern-null") | has("verified_by")' "$simindex" >/dev/null 2>&1
check "REBUILD: modern verified_by:null line keeps the key (classifies modern) after rebuild" $?

# Numeric-mtime invariant (portable stat). Every ingested record must carry a real
# epoch, not the mount-point string GNU `stat -f %m` returns — that non-integer
# aborted ingest mid-rebuild under set -euo pipefail (empty index → the failures
# above). Freshly written fixtures have mtime > 0, so this holds on BOTH platforms.
jq -e 'select(.branch=="legacy-src") | (.mtime|type=="number") and (.mtime > 0)' "$simindex" >/dev/null 2>&1
check "REBUILD: ingested legacy record has numeric mtime > 0 (portable stat)" $?
jq -e 'select(.branch=="modern-null") | (.mtime|type=="number") and (.mtime > 0)' "$simindex" >/dev/null 2>&1
check "REBUILD: ingested modern record has numeric mtime > 0 (portable stat)" $?

# And the guardrail runner over the rebuilt index must exempt the legacy line and
# check the modern one — the end-to-end proof the exemption survives rebuild.
simout=$("$runner" --index "$simindex")
! printf '%s\n' "$simout" | grep 'VIOLATION' | grep -q 'legacy-src'
check "REBUILD e2e: rebuilt legacy line is NOT a violation (exemption survived rebuild)" $?
printf '%s\n' "$simout" | grep -q 'modern-null'
check "REBUILD e2e: rebuilt modern verified_by:null line IS checked (G2 fires, null != absent)" $?

# --- G2 ⇔ state-schemas.md SYNC (settles the-stickler W1). The runner's G2 must
#     select the SAME lines as the canonical provenance lint in state-schemas.md
#     ## Provenance lint. Chosen over a byte-identical comment quote because the only
#     diff the stickler found is whitespace: the doc indents its continuation under a
#     `jq -c '` prefix, so the logic is token-identical and a byte-compare would be
#     fragile theater. This BEHAVIORAL check enforces the real "reused, not forked"
#     invariant and survives reformatting. Fixture is all-modern so the lint (which has
#     no era gate) and G2's checked-era set coincide. ---
schema="$here/../skills/loop-de-looper/references/state-schemas.md"
lint=$(awk '/^## Provenance lint/{f=1} f&&/^```/{c++; next} f&&c==1{print}' "$schema" \
       | sed -e "s/^jq -c '//" -e "s/' gates.jsonl.*$//")
syncfix="$temp_dir/sync.jsonl"
{
  echo '{"kind":"crew","agent":"the-diamantaire","ran":true,"verified_by":"llm","outcome":"promote","verdict":"x","cite":"sync/1"}'
  echo '{"kind":"crew","agent":"the-stickler","ran":true,"verified_by":null,"outcome":null,"verdict":"x","cite":"sync/2"}'
  echo '{"kind":"crew","agent":"the-diamantaire","ran":true,"verified_by":"llm","outcome":null,"verdict":"x","cite":"sync/3"}'
  echo '{"kind":"pre-build-specialist","agent":"accessibility-lead","ran":true,"verified_by":"executable","outcome":null,"verdict":"x","cite":"sync/4"}'
  echo '{"kind":"crew","agent":"the-stickler","ran":false,"verified_by":null,"outcome":null,"verdict":null,"cite":"sync/5"}'
  echo '{"kind":"pre-build-specialist","agent":"the-chemist","ran":true,"verified_by":null,"outcome":null,"verdict":"x","cite":"sync/6"}'
} > "$syncfix"
lint_hits=$(jq -c "$lint" "$syncfix" | jq -rs 'map(.cite) | sort | join(",")')
runner_hits=$("$runner" --index "$syncfix" \
  | awk '/^G2 /{g=1; next} /^G3 /{g=0} g' \
  | grep -oE 'sync/[0-9]+' | sort -u | paste -sd, -)
[ "$lint_hits" = "$runner_hits" ] && result=0 || result=1
check "SYNC: G2 selects same lines as state-schemas.md ## Provenance lint (lint=$lint_hits vs g2=$runner_hits)" "$result"

# --- a value-taking flag with no value must not abort on `$2` unbound: under
#     `set -u` that exits 1, and 1 is reserved for "violations found". ---
"$runner" --index >/dev/null 2>&1
[ "$?" -eq 2 ] && result=0 || result=1
check "ENV: --index with no value exits 2, not 1" "$result"

echo
if [ "$fails" -eq 0 ]; then echo "all guardrail tests passed"; exit 0
else echo "$fails guardrail test(s) FAILED"; exit 1; fi
