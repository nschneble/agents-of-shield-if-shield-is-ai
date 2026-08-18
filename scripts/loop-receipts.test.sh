#!/usr/bin/env bash
# loop-receipts.test.sh — both-directions test for the receipt check, and
# for the hook that writes what it reads.
#
# The hook half matters as much as the check half: a hook that silently
# writes nothing makes every branch NOT EVALUABLE, which is a clean exit
# forever. So the writer is exercised against real payload shapes, not
# assumed.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check="$here/loop-receipts.sh"
hook="$here/../hooks/record-execution-receipt.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-receipts.XXXXXX") \
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

dir="$temp_dir/branch"
mkdir -p "$dir" || die_temp "cannot build $dir"
gates="$dir/gates.jsonl"
receipts="$dir/receipts.jsonl"

claim='{"wave":1,"kind":"crew","ran":true,"verified_by":"executable","verdict":"promote"}'

# --- NOT EVALUABLE: a branch older than the hook is never a violation ---
printf '%s\n' "$claim" > "$gates"
rm -f "$receipts"
out=$("$check" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'NOT EVALUABLE'
check_that "no receipts log = NOT EVALUABLE, exit 0 (got $rc)" $?

# and it must not read as a pass — the class has to be printed
! printf '%s\n' "$out" | grep -q 'every executable claim has runtime evidence'
check_that "an unevaluable branch is not reported as verified" $?

# --strict turns the same state into a failure
out=$("$check" --dir "$dir" --strict 2>&1); rc=$?
[ "$rc" -eq 1 ]
check_that "--strict makes a missing receipts log a failure (got $rc)" $?

# --- VIOLATION: claims executable, runtime recorded no success ----------
printf '{"command":"false","exit_code":1,"stdout_sha":"x","ts":"t"}\n' > "$receipts"
out=$("$check" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'VIOLATION'
check_that "an executable claim with no successful command = exit 1 (got $rc)" $?

# --- clean: a successful command backs the claim ------------------------
printf '{"command":"npm test","exit_code":0,"stdout_sha":"y","ts":"t"}\n' >> "$receipts"
out=$("$check" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'runtime evidence'
check_that "an executable claim with an exit-0 receipt passes (got $rc)" $?

# --- no claim, no obligation -------------------------------------------
printf '{"wave":1,"kind":"crew","ran":true,"verified_by":"llm","verdict":"x"}\n' > "$gates"
printf '{"command":"false","exit_code":1,"stdout_sha":"x","ts":"t"}\n' > "$receipts"
out=$("$check" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'nothing claimed'
check_that "a wave claiming nothing executable is not a violation (got $rc)" $?

# --- unusable inputs ----------------------------------------------------
out=$("$check" --dir "$temp_dir/absent" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check_that "a missing dir exits 2 (got $rc)" $?

mkdir -p "$temp_dir/empty"
out=$("$check" --dir "$temp_dir/empty" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check_that "a dir with no gate lines exits 2 (got $rc)" $?

out=$("$check" --dir 2>&1); rc=$?
[ "$rc" -eq 2 ]
check_that "a value-taking flag with no value exits 2 (got $rc)" $?

# --- the writer: real payload shapes ------------------------------------
repo="$temp_dir/repo"
mkdir -p "$repo"
# needs a real commit: on an unborn branch `git rev-parse --abbrev-ref
# HEAD` fails, the hook falls back to `detached`, and the receipt lands
# somewhere the assertion is not looking
( cd "$repo" && git init -q . \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git checkout -qb testbranch ) 2>/dev/null
payload="$temp_dir/payload.json"

cat > "$payload" <<JSON
{"tool_name":"Bash","cwd":"$repo","tool_input":{"command":"echo hi"},"tool_response":{"exit_code":0,"stdout":"hi"}}
JSON
bash "$hook" < "$payload"
written="$repo/local/loops/testbranch/receipts.jsonl"
[ -s "$written" ] && [ "$(jq -r '.exit_code' "$written")" = "0" ]
check_that "the hook records a Bash call with its exit code" $?

cat > "$payload" <<JSON
{"tool_name":"Read","cwd":"$repo","tool_input":{"file_path":"x"}}
JSON
before=$(grep -c . "$written")
bash "$hook" < "$payload"
[ "$(grep -c . "$written")" -eq "$before" ]
check_that "a non-Bash call writes no receipt" $?

# an absent exit code must stay absent: a receipt asserting a success it
# never saw is the fabrication this mechanism removes
cat > "$payload" <<JSON
{"tool_name":"Bash","cwd":"$repo","tool_input":{"command":"true"},"tool_response":{"stdout":""}}
JSON
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.exit_code')" = "null" ]
check_that "a missing exit code is recorded null, never coerced to 0" $?

# the hook must never break the call it observes
cat > "$payload" <<'JSON'
not json at all
JSON
bash "$hook" < "$payload"; rc=$?
[ "$rc" -eq 0 ]
check_that "a malformed payload still exits 0 (got $rc)" $?

EXPECTED_CHECKS=13
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran loop-receipts tests passed"; exit 0
else
  echo "loop-receipts FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1
fi
