#!/usr/bin/env bash
# record-execution-receipt — PostToolUse hook. Appends one receipt per
# Bash execution to a per-branch log the executing agent never writes.
#
# Every other rail in this repo rests on something the agent cannot
# author. `verified_by` does not: it is free text the audited agent
# types, G3 compares it to the string "executable", and across the
# indexed history it holds 17 distinct values (re-derive with
# `jq -r '.verified_by // "ABSENT"' local/custodian/history-index.jsonl
# | sort | uniq -c`). A wave that types "executable" clears G3 whether a
# command ran or not.
#
# THERE IS NO EXIT CODE TO RECORD. The PostToolUse payload's
# `tool_response` carries only `interrupted`, `isImage`,
# `noOutputExpected`, `stderr`, `stdout` — verified by dumping the live
# payload. An earlier version read `.tool_response.exit_code`, wrote
# null on all 159 real receipts, and made the checking side's clean arm
# unreachable; its test passed only because the fixture hand-wrote the
# key it then asserted on.
#
# What IS observable: this event fires on tool SUCCESS — a failure goes
# to PostToolUseFailure, which nothing here subscribes to. So the
# receipt's EXISTENCE is the success signal, and `interrupted` is the
# one recorded qualifier. Record that, and nothing more.
#
# NO SIGNING. A single-user local loop has no forger to defend against;
# the value is existence, not authenticity.
#
# Never blocks a tool call and never fails one: a receipt writer that
# could break the session it observes would be traded away the first
# time it misfired. Every arm exits 0.
exec 2>/dev/null

payload=$(cat)
[ -n "$payload" ] || exit 0

command -v jq >/dev/null || exit 0

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
[ "$tool" = "Bash" ] || exit 0

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
[ -n "$cwd" ] || cwd=$PWD
repo_root=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$repo_root" ] || exit 0

branch=$(cd "$repo_root" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -n "$branch" ] || branch=detached

# `local/` is gitignored scratch, beside the run artifacts a wave
# already writes. A receipt is evidence about a run, not a deliverable.
dir="$repo_root/local/loops/$branch"
mkdir -p "$dir" || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
[ -n "$cmd" ] || exit 0

# absent reads as false rather than null: the payload omits the key on
# some shapes, and "not interrupted" is what absence means here
interrupted=$(printf '%s' "$payload" | jq -r '(.tool_response.interrupted // false) | tostring')
case "$interrupted" in true|false) : ;; *) interrupted=false ;; esac

sha_of() {
  if command -v shasum >/dev/null; then
    printf '%s' "$1" | shasum -a 256 | cut -d" " -f1
  else
    printf ''
  fi
}
out=$(printf '%s' "$payload" | jq -r '(.tool_response.stdout // "") | tostring')
err=$(printf '%s' "$payload" | jq -r '(.tool_response.stderr // "") | tostring')

jq -cn \
  --arg cmd "$cmd" \
  --arg sha "$(sha_of "$out")" \
  --arg errsha "$(sha_of "$err")" \
  --argjson interrupted "$interrupted" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{command: $cmd, interrupted: $interrupted, stdout_sha: $sha, stderr_sha: $errsha, ts: $ts}' \
  >> "$dir/receipts.jsonl" || exit 0

exit 0
