#!/usr/bin/env bash
# loop-receipts.test.sh — both-directions test for the receipt check, and
# for the hook that writes what it reads.
#
# Success fixtures: a live PostToolUse dump; failure: docs, live-checked.
# Background: docs/test-suites.md#loop-receipts
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

# --- a failed run is a receipt, never evidence --------------------------
printf '{"command":"npm test","outcome":"failed","interrupted":false,"error_sha":"e","ts":"t"}\n' > "$receipts"
out=$("$check_sh" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'VIOLATION'
check "an executable claim with only failed receipts = exit 1 (got $rc)" $?

printf '{"command":"npm test","outcome":"ok","interrupted":false,"ts":"t"}\n' >> "$receipts"
out=$("$check_sh" --dir "$dir" 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '2 recorded, 1 uninterrupted'
check "an ok receipt beside a failed one backs the claim (got $rc)" $?

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

# top-level keys as captured from a live PostToolUse call
repo_head=$(git -C "$repo" rev-parse HEAD)
repo_tree=$(git -C "$repo" rev-parse 'HEAD^{tree}')
cat > "$payload" <<JSON
{"session_id":"s-1","transcript_path":"/t.jsonl","cwd":"$repo","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo ok"},"tool_response":{"interrupted":false,"isImage":false,"noOutputExpected":false,"stdout":"ok","stderr":""},"tool_use_id":"toolu_1","duration_ms":5}
JSON
bash "$hook" < "$payload"
last=$(tail -1 "$written")
[ "$(printf '%s' "$last" | jq -r '.outcome')" = "ok" ] \
  && [ "$(printf '%s' "$last" | jq -r '.error_sha')" = "null" ] \
  && [ "$(printf '%s' "$last" | jq -r '.stdout_sha')" != "null" ]
check "a PostToolUse event records outcome ok and no error digest" $?

[ "$(printf '%s' "$last" | jq -r '.session_id')" = "s-1" ] \
  && [ "$(printf '%s' "$last" | jq -r '.agent_id')" = "null" ] \
  && [ "$(printf '%s' "$last" | jq -r '.cwd')" = "$repo" ]
check "a main-session call records its session, a null agent, and cwd" $?

[ "$(printf '%s' "$last" | jq -r '.head')" = "$repo_head" ] \
  && [ "$(printf '%s' "$last" | jq -r '.tree')" = "$repo_tree" ]
check "a receipt records the repo's HEAD commit and tree" $?

jq -c '.agent_id = "a-7" | .agent_type = "Explore"' "$payload" > "$payload.sub"
bash "$hook" < "$payload.sub"
[ "$(tail -1 "$written" | jq -r '.agent_id')" = "a-7" ]
check "a subagent call records its agent_id" $?

# a live failure carried error as "Exit code N" plus the output
error_text='Exit code 1
Error: Cannot find module'
python3 - "$repo" "$error_text" false > "$payload" <<'PY2'
import json,sys
print(json.dumps({"session_id":"s-1","cwd":sys.argv[1],
                  "hook_event_name":"PostToolUseFailure","tool_name":"Bash",
                  "tool_input":{"command":"npm test"},"tool_use_id":"toolu_2",
                  "error":sys.argv[2],"is_interrupt":sys.argv[3] == "true"}))
PY2
bash "$hook" < "$payload"
last=$(tail -1 "$written")
want_sha=$(printf '%s' "$error_text" | shasum -a 256 | cut -d' ' -f1)
[ "$(printf '%s' "$last" | jq -r '.outcome')" = "failed" ] \
  && [ "$(printf '%s' "$last" | jq -r '.error_sha')" = "$want_sha" ]
check "a PostToolUseFailure event records outcome failed and the error digest" $?

[ "$(printf '%s' "$last" | jq -r '.stdout_sha')" = "null" ] \
  && [ "$(printf '%s' "$last" | jq -r '.interrupted')" = "false" ]
check "a failure records no stdout digest it never saw" $?

python3 - "$repo" "aborted" true > "$payload" <<'PY2'
import json,sys
print(json.dumps({"cwd":sys.argv[1],"hook_event_name":"PostToolUseFailure",
                  "tool_name":"Bash","tool_input":{"command":"sleep 9"},
                  "error":sys.argv[2],"is_interrupt":sys.argv[3] == "true"}))
PY2
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.interrupted')" = "true" ]
check "a failure with is_interrupt records interrupted" $?

cat > "$payload" <<JSON
{"cwd":"$repo","hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_input":{"command":"false"}}
JSON
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.outcome + " " + (.error_sha | tostring)')" = "failed null" ]
check "a failure with no error text records a null error digest" $?

python3 - "$repo" > "$payload" <<'PY2'
import json,sys
print(json.dumps({"cwd":sys.argv[1],"hook_event_name":"PostToolUseFailure",
                  "tool_name":"Bash","tool_input":{"command":"make\n\n"},
                  "error":"Exit code 2\nboom\n"}))
PY2
bash "$hook" < "$payload"
last=$(tail -1 "$written")
want_cmd=$(printf 'make\n\n' | shasum -a 256 | cut -d' ' -f1)
want_err=$(printf 'Exit code 2\nboom\n' | shasum -a 256 | cut -d' ' -f1)
[ "$(printf '%s' "$last" | jq -r '.command_len')" -eq 6 ] \
  && [ "$(printf '%s' "$last" | jq -r '.command_sha')" = "$want_cmd" ] \
  && [ "$(printf '%s' "$last" | jq -r '.error_sha')" = "$want_err" ]
check "trailing newlines count toward the command and error digests" $?

cat > "$payload" <<JSON
{"cwd":"$repo","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo pre"}}
JSON
before=$(grep -c . "$written")
bash "$hook" < "$payload"
[ "$(grep -c . "$written")" -eq "$before" ]
check "an event other than PostToolUse/Failure writes no receipt" $?

bare="$temp_dir/bare"
mkdir -p "$bare" && git -C "$bare" init -q . 2>/dev/null
cat > "$payload" <<JSON
{"cwd":"$bare","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":""}}
JSON
bash "$hook" < "$payload"
bare_log=$(find "$bare/local/loops" -name receipts.jsonl 2>/dev/null | head -1)
[ -n "$bare_log" ] && [ "$(tail -1 "$bare_log" | jq -r '.head')" = "null" ] \
  && [ "$(tail -1 "$bare_log" | jq -r '.tree')" = "null" ]
check "a repo with no commit records null head and tree, still writes" $?

long_payload() { # length of the y-run
  python3 - "$repo" "$1" > "$payload" <<'PY2'
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],
                  "tool_input":{"command":"echo " + "y"*int(sys.argv[2])},
                  "tool_response":{"interrupted":False,"stdout":"","stderr":""}}))
PY2
}

long_payload 900
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.command | length')" -eq 905 ]
check "a 905-char command is stored whole" $?

long_payload 5000
bash "$hook" < "$payload"
last=$(tail -1 "$written")
full_sha=$(jq -j '.tool_input.command' "$payload" | shasum -a 256 | cut -d' ' -f1)
[ "$(printf '%s' "$last" | jq -r '.command | length')" -eq 4096 ] \
  && [ "$(printf '%s' "$last" | jq -r '.command_len')" -eq 5005 ] \
  && [ "$(printf '%s' "$last" | jq -r '.command_sha')" = "$full_sha" ]
check "a command past the cap is cut to 4096 with a full-command digest" $?

python3 - "$repo" > "$payload" <<'PY3'
import json, sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],
                  "tool_input":{"command":"\n".join(["echo " + "z"*1995]*3)},
                  "tool_response":{"interrupted":False,"stdout":"","stderr":""}}))
PY3
bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.command | length')" -eq 4096 ]
check "a multi-line command past the cap is cut to 4096 in all" $?

RECEIPT_CMD_KEEP=50 bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.command | length')" -eq 50 ]
check "RECEIPT_CMD_KEEP overrides the cap" $?

RECEIPT_CMD_KEEP=+50 bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.command | length')" -eq 4096 ]
check "a signed RECEIPT_CMD_KEEP keeps the default cap" $?

RECEIPT_CMD_KEEP=0 bash "$hook" < "$payload"
[ "$(tail -1 "$written" | jq -r '.command | length')" -eq 4096 ]
check "a zero RECEIPT_CMD_KEEP keeps the default cap" $?

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

EXPECTED_CHECKS=40
ran=$(grep -c . "$results"); fails=$(grep -c '^FAIL$' "$results")
echo
[ "$ran" -eq "$EXPECTED_CHECKS" ] \
  || echo "FAIL  assertion count ($ran, want $EXPECTED_CHECKS) — a block was dropped, or added without moving EXPECTED_CHECKS"
if [ "$fails" -eq 0 ] && [ "$ran" -eq "$EXPECTED_CHECKS" ]; then
  echo "all $ran loop-receipts tests passed"; exit 0
else
  echo "loop-receipts FAILED: $fails failing, $ran of $EXPECTED_CHECKS assertions ran"; exit 1
fi
