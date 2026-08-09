#!/usr/bin/env bash
# run-correction-gates.test.sh — both-directions test for the registry
# runner. Proves it is a REGISTRY (discovers and aggregates N entries
# generically), not format-scope hardcoded: it runs multiple stub entries,
# aggregates their verdicts, keeps running after one fails, honors the
# enabled flag, maps exit codes to PASS/FAIL/ERROR, and threads the
# wave-context contract (CG_*) through to each entry's exec.
#
# Self-contained: entries are stub gates that just exit a chosen code, so
# the test needs no prettier/node/git and runs in CI. It exercises the
# runner's dispatch logic, not any real correction — each real gate has its
# own both-directions test.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/run-correction-gates.sh"
# a failing mktemp returns empty, which makes every derived fixture path
# absolute (/green) and scatters the run outside the temp tree. Abort
# loudly rather than half-run against paths nobody intended. The explicit
# template is what makes TMPDIR the input the message names: a bare
# `mktemp -d` ignores TMPDIR on BSD and allocates under /var/folders.
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  && [ -n "$temp_dir" ] && [ -d "$temp_dir" ] || {
  echo "FATAL: mktemp -d failed (TMPDIR=${TMPDIR:-unset}); refusing to run" >&2
  exit 2
}
trap 'rm -rf "$temp_dir"' EXIT

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# mk_entry REGDIR ID EXITCODE [ENABLED] — stub entry; gate just exits.
mk_entry() {
  local d="$1/$2"; mkdir -p "$d"
  {
    echo '---'
    echo "id: $2"
    echo "enabled: ${4:-true}"
    echo 'exec: ./gate.sh'
    echo '---'
    echo 'stub'
  } > "$d/spec.md"
  printf '#!/usr/bin/env bash\nexit %s\n' "$3" > "$d/gate.sh"
  chmod +x "$d/gate.sh"
}

# --- GREEN: two passing entries -> exit 0, both ran (multi-entry). ---
reg="$temp_dir/green"
mk_entry "$reg" alpha 0
mk_entry "$reg" beta  0
out=$("$runner" --registry "$reg"); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "GREEN: all-clean registry passes (exit 0)" "$r"
printf '%s\n' "$out" | grep -q 'PASS  alpha'; check "GREEN: ran first entry" $?
printf '%s\n' "$out" | grep -q 'PASS  beta';  check "GREEN: ran second entry (registry, not one gate)" $?
printf '%s\n' "$out" | grep -q '2 ran · 0 fail'; check "GREEN: summary counts both" $?

# --- RED: one entry fails -> exit 1, and the sibling STILL ran. ---
reg="$temp_dir/red"
mk_entry "$reg" alpha 0
mk_entry "$reg" bad   1
out=$("$runner" --registry "$reg"); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "RED: a violating entry fails the run (exit 1)" "$r"
printf '%s\n' "$out" | grep -q 'FAIL  bad';   check "RED: names the failing entry" $?
printf '%s\n' "$out" | grep -q 'PASS  alpha'; check "RED: keeps running siblings after a failure" $?

# --- ERROR: a gate that cannot run (exit 2) -> runner exit 2, not 1. ---
reg="$temp_dir/err"
mk_entry "$reg" broken 2
out=$("$runner" --registry "$reg"); rc=$?
[ "$rc" -eq 2 ] && r=0 || r=1; check "ERROR: an env/usage-error gate exits 2 (distinct from a violation)" "$r"
printf '%s\n' "$out" | grep -q 'ERROR broken (exit 2)'; check "ERROR: reports it as an error, not a fail" $?

# --- SKIP: enabled:false is not run, even though its gate would fail. ---
reg="$temp_dir/skip"
mk_entry "$reg" off 1 false
out=$("$runner" --registry "$reg"); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "SKIP: disabled entry is not run (would-fail gate stays green)" "$r"
printf '%s\n' "$out" | grep -q 'SKIP  off (disabled)'; check "SKIP: reports the skip" $?

# --- CONTEXT: the wave-context contract (CG_*) reaches the exec. A gate
# that greps CG_TOUCHED_FILE for a sentinel passes only when the runner
# actually threaded the value through; absent it fails. Both ways. ---
reg="$temp_dir/ctx"; d="$reg/ctx"; mkdir -p "$d"
{
  echo '---'; echo 'id: ctx'; echo 'enabled: true'
  echo 'exec: ./gate.sh "$CG_TOUCHED_FILE"'; echo '---'
} > "$d/spec.md"
printf '#!/usr/bin/env bash\ngrep -q SENTINEL "$1" 2>/dev/null && exit 0 || exit 1\n' > "$d/gate.sh"
chmod +x "$d/gate.sh"
printf 'SENTINEL\n' > "$temp_dir/touched.txt"
out=$("$runner" --registry "$reg" --touched-from "$temp_dir/touched.txt"); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "CONTEXT: exec reads the threaded CG_TOUCHED_FILE (exit 0)" "$r"
out=$("$runner" --registry "$reg"); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "CONTEXT: same gate fails when context absent (proves it was threaded)" "$r"

echo
if [ "$fails" -eq 0 ]; then echo "all run-correction-gates tests passed"; exit 0
else echo "$fails run-correction-gates test(s) FAILED"; exit 1; fi
