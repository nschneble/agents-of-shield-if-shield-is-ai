#!/usr/bin/env bash
# record-execution-receipt — PostToolUse hook. Appends one receipt per
# Bash execution to a per-branch log the executing agent never writes.
#
# Every other rail in this repo rests on something the agent cannot
# author. `verified_by` did not: it is free text the audited agent types,
# G3 compares it to the string "executable", and across 1078 indexed gate
# lines it holds 17 distinct values — 419 `executable`, 156 `llm`, and 14
# one-off strings like `orchestrator`, `main`, `npm view peerDependencies`
# and `ran seed 555 twice`. Those 14 counted as no-evidence, and a wave
# that simply types `executable` clears G3 whether a command ran or not.
#
# NO SIGNING. A single-user local loop has no forger to defend against,
# and the value here is existence, not authenticity — the source paper's
# HMAC layer is theatre at this scale and is deliberately dropped.
#
# Never blocks a tool call and never fails one: a receipt writer that can
# break the session it observes would be traded away the first time it
# misfired. Every arm exits 0.
#
# Reads the harness's PostToolUse JSON on stdin. Writes nothing when the
# payload is not a Bash call, or when no repo can be resolved.
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

# `local/` is gitignored scratch, beside the run artifacts a wave already
# writes. A receipt is evidence about a run, not a tracked deliverable.
dir="$repo_root/local/loops/$branch"
mkdir -p "$dir" || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
[ -n "$cmd" ] || exit 0
exit_code=$(printf '%s' "$payload" | jq -r '
  .tool_response.exit_code // .tool_response.exitCode // empty')
# an absent exit code is recorded as absent, never coerced to 0 — a
# receipt claiming success it never observed is the fabrication this
# whole mechanism exists to remove
[ -n "$exit_code" ] || exit_code=null

out=$(printf '%s' "$payload" | jq -r '
  (.tool_response.stdout // .tool_response.output // "") | tostring')
if command -v shasum >/dev/null; then
  stdout_sha=$(printf '%s' "$out" | shasum -a 256 | cut -d" " -f1)
else
  stdout_sha=""
fi

printf '%s' "$payload" | jq -c \
  --arg cmd "$cmd" \
  --arg sha "$stdout_sha" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson code "$exit_code" \
  '{command: $cmd, exit_code: $code, stdout_sha: $sha, ts: $ts}' \
  >> "$dir/receipts.jsonl" || exit 0

exit 0
