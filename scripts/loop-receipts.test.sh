#!/usr/bin/env bash
# loop-receipts.test.sh — both-directions test for the receipt check, and
# for the hook that writes what it reads.
#
# The hook half matters as much as the check half: a hook that silently
# writes nothing makes every branch NOT EVALUABLE, which is a clean exit
# forever. So the writer is exercised against real payload shapes, not
# assumed.
#
# THE FIXTURES BELOW ARE THE PAYLOAD THE RUNTIME ACTUALLY SENDS, dumped
# from a live PostToolUse call: tool_response carries interrupted,
# isImage, noOutputExpected, stderr, stdout — and no exit code, under any
# spelling. An earlier version of this file hand-wrote `exit_code: 0`,
# asserted on it, and passed green while the check it covers could not
# reach its own clean arm on a single real branch. A fixture that
# manufactures the schema it validates proves nothing.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
check_sh="$here/loop-receipts.sh"
hook="$here/../hooks/record-execution-receipt.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-receipts.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] || die_temp "mktemp -d exited 0 with no path"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

results="$temp_dir/results.log"
: > "$results" || die_temp "cannot open the results log at $results"
check() {
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
out=$("$check_sh" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'NOT EVALUABLE'
check "no receipts log = NOT EVALUABLE, exit 0 (got $rc)" $?

# and it must not read as a pass — the class has to be printed
! printf '%s\n' "$out" | grep -q 'every executable claim has runtime evidence'
check "an unevaluable branch is not reported as verified" $?

# --strict turns the same state into a failure
out=$("$check_sh" --dir "$dir" --strict 2>&1); rc=$?
[ "$rc" -eq 1 ]
check "--strict makes a missing receipts log a failure (got $rc)" $?

# --- VIOLATION: claims executable, runtime recorded no success ----------
printf '{"command":"false","interrupted":true,"stdout_sha":"x","stderr_sha":"z","ts":"t"}\n' > "$receipts"
out=$("$check_sh" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'VIOLATION'
check "an executable claim with only interrupted receipts = exit 1 (got $rc)" $?

# --- clean: a successful command backs the claim ------------------------
printf '{"command":"npm test","interrupted":false,"stdout_sha":"y","stderr_sha":"z","ts":"t"}\n' >> "$receipts"
out=$("$check_sh" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'runtime evidence'
check "an executable claim with an uninterrupted receipt passes (got $rc)" $?

# --- no claim, no obligation -------------------------------------------
printf '{"wave":1,"kind":"crew","ran":true,"verified_by":"llm","verdict":"x"}\n' > "$gates"
printf '{"command":"false","interrupted":true,"stdout_sha":"x","stderr_sha":"z","ts":"t"}\n' > "$receipts"
out=$("$check_sh" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'nothing claimed'
check "a wave claiming nothing executable is not a violation (got $rc)" $?

# --- unusable inputs ----------------------------------------------------
out=$("$check_sh" --dir "$temp_dir/absent" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a missing dir exits 2 (got $rc)" $?

mkdir -p "$temp_dir/empty"
out=$("$check_sh" --dir "$temp_dir/empty" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a dir with no gate lines exits 2 (got $rc)" $?

out=$("$check_sh" --dir 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a value-taking flag with no value exits 2 (got $rc)" $?

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
{"tool_name":"Bash","cwd":"$repo","tool_input":{"command":"echo hi"},"tool_response":{"interrupted":false,"isImage":false,"noOutputExpected":false,"stdout":"hi","stderr":""}}
JSON
bash "$hook" < "$payload"
written="$repo/local/loops/testbranch/receipts.jsonl"
[ -s "$written" ] && [ "$(jq -r '.interrupted' "$written")" = "false" ] \
  && [ -n "$(jq -r '.stdout_sha' "$written")" ]
check "the hook records a Bash call from a real-shaped payload" $?

cat > "$payload" <<JSON
{"tool_name":"Read","cwd":"$repo","tool_input":{"file_path":"x"}}
JSON
before=$(grep -c . "$written")
bash "$hook" < "$payload"
[ "$(grep -c . "$written")" -eq "$before" ]
check "a non-Bash call writes no receipt" $?

# no exit code is recorded at all, in either direction: the runtime does
# not expose one, so a field claiming to carry it could only ever be a
# fabrication or a permanent null
[ "$(tail -1 "$written" | jq -r 'has("exit_code")')" = "false" ]
check "no exit_code field is invented" $?

# an absent `interrupted` reads as false, not null — absence means the
# call was not interrupted, and null would make the check's own
# `!= true` test pass for the wrong reason
cat > "$payload" <<JSON
{"tool_name":"Bash","cwd":"$repo","tool_input":{"command":"true"},"tool_response":{"stdout":""}}
JSON
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.interrupted')" = "false" ]
check "an absent interrupted flag records false, never null" $?

# a non-boolean value must normalize to false rather than reach the log
# as-is: the check tests `!= true`, so a string or null would pass it for
# the wrong reason
cat > "$payload" <<JSON
{"tool_name":"Bash","cwd":"$repo","tool_input":{"command":"true"},"tool_response":{"interrupted":"maybe","stdout":""}}
JSON
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.interrupted')" = "false" ]
check "a non-boolean interrupted value normalizes to false" $?

# an interrupted call is recorded as such, and the check counts it out
cat > "$payload" <<JSON
{"tool_name":"Bash","cwd":"$repo","tool_input":{"command":"sleep 99"},"tool_response":{"interrupted":true,"stdout":""}}
JSON
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.interrupted')" = "true" ]
check "an interrupted call is recorded interrupted" $?

# the non-Bash gate must hold ALONE: a tool whose input also carries a
# `command` (a slash command, say) must not mint a receipt naming it as
# an executed shell command
cat > "$payload" <<JSON
{"tool_name":"SlashCommand","cwd":"$repo","tool_input":{"command":"/looper go"},"tool_response":{"stdout":""}}
JSON
before=$(grep -c . "$written")
bash "$hook" < "$payload"
[ "$(grep -c . "$written")" -eq "$before" ]
check "a non-Bash tool carrying a command writes no receipt" $?

# a cwd outside any git repo has nowhere to write and must stay silent
cat > "$payload" <<JSON
{"tool_name":"Bash","cwd":"$temp_dir","tool_input":{"command":"echo x"},"tool_response":{"stdout":"x"}}
JSON
bash "$hook" < "$payload"
[ ! -e "$temp_dir/local/loops" ]
check "a cwd outside any git repo writes nothing" $?

# a long command is truncated, and its full identity survives as a digest
long=$(python3 -c "print('echo ' + 'y'*900)")
python3 - "$repo" "$long" > "$payload" <<'PY2'
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],
                  "tool_input":{"command":sys.argv[2]},
                  "tool_response":{"interrupted":False,"stdout":"","stderr":""}}))
PY2
bash "$hook" < "$payload"
last=$(tail -1 "$written")
[ "$(printf '%s' "$last" | jq -r '.command | length')" -le 200 ] \
  && [ "$(printf '%s' "$last" | jq -r '.command_len')" -gt 200 ] \
  && [ -n "$(printf '%s' "$last" | jq -r '.command_sha')" ]
check "a long command is truncated but keeps its length and digest" $?

# a short command is stored whole — truncation must not be unconditional
cat > "$payload" <<JSON
{"tool_name":"Bash","cwd":"$repo","tool_input":{"command":"git status"},"tool_response":{"interrupted":false,"stdout":"","stderr":""}}
JSON
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.command')" = "git status" ]
check "a short command is stored verbatim" $?

# the hook must never break the call it observes
cat > "$payload" <<'JSON'
not json at all
JSON
bash "$hook" < "$payload"; rc=$?
[ "$rc" -eq 0 ]
check "a malformed payload still exits 0 (got $rc)" $?

# one bad line at the head of gates.jsonl must not retire every claim
# behind it — the abort-on-first-error shape this check used to have
printf 'not json at all\n' > "$gates"
printf '%s\n' "$claim" >> "$gates"
printf '{"command":"x","interrupted":true,"ts":"t"}\n' > "$receipts"
out=$("$check_sh" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'claims:   1'
check "a malformed gate line does not hide the claims behind it (got $rc)" $?

# a gates file with nothing parseable at all is unusable input, not clean
printf 'not json\nstill not json\n' > "$gates"
out=$("$check_sh" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 2 ]
check "a wholly unparseable gates file exits 2 (got $rc)" $?

EXPECTED_CHECKS=22
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran loop-receipts tests passed"; exit 0
else
  echo "loop-receipts FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1
fi
