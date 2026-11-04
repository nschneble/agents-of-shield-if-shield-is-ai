#!/usr/bin/env bash
# record-execution-receipt — PostToolUse/PostToolUseFailure hook: appends
# one receipt per Bash run, unlike verified_by (text the agent types).
# Command text capped at 4096 chars, 99.8% of observed commands whole.
# No signing, no blocking: every arm exits 0, always.
exec 2>/dev/null

payload=$(cat)
[ -n "$payload" ] || exit 0

command -v jq >/dev/null || exit 0

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
[ "$tool" = "Bash" ] || exit 0

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty')
case "$event" in
  PostToolUseFailure) outcome=failed ;;
  PostToolUse|"") outcome=ok ;;
  *) exit 0 ;;
esac

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
[ -n "$cwd" ] || cwd=$PWD
repo_root=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$repo_root" ] || exit 0

branch=$(cd "$repo_root" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -n "$branch" ] || branch=detached
head=$(cd "$repo_root" && git rev-parse --verify -q HEAD 2>/dev/null)
tree=$(cd "$repo_root" && git rev-parse --verify -q 'HEAD^{tree}' 2>/dev/null)

# local/ is gitignored scratch; a receipt is evidence, not a deliverable
dir="$repo_root/local/loops/$branch"
mkdir -p "$dir" || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
[ -n "$cmd" ] || exit 0

default_keep=4096
CMD_KEEP="${RECEIPT_CMD_KEEP:-$default_keep}"
case "$CMD_KEEP" in ''|*[!0-9]*) CMD_KEEP=$default_keep ;; esac
[ "$CMD_KEEP" -gt 0 ] || CMD_KEEP=$default_keep

# absent reads as false, not null: some shapes omit the key entirely
interrupted=$(printf '%s' "$payload" | jq -r '(.tool_response.interrupted // .is_interrupt // false) | tostring')
case "$interrupted" in true|false) : ;; *) interrupted=false ;; esac

cmd_sha=""
cmd_len=${#cmd}
sha_of() {
  if command -v shasum >/dev/null; then
    printf '%s' "$1" | shasum -a 256 | cut -d" " -f1
  else
    printf ''
  fi
}
cmd_sha=$(sha_of "$cmd")
if [ "$cmd_len" -gt "$CMD_KEEP" ]; then
  cmd=$(printf '%s' "$cmd" | cut -c "1-$CMD_KEEP")
fi

out=$(printf '%s' "$payload" | jq -r '(.tool_response.stdout // "") | tostring')
err=$(printf '%s' "$payload" | jq -r '(.tool_response.stderr // "") | tostring')
error_sha=""
if [ "$outcome" = failed ]; then
  error_sha=$(sha_of "$(printf '%s' "$payload" | jq -r '(.error // "") | tostring')")
fi

printf '%s' "$payload" | jq -c \
  --arg cmd "$cmd" \
  --arg cmdsha "$cmd_sha" \
  --argjson cmdlen "$cmd_len" \
  --arg sha "$(sha_of "$out")" \
  --arg errsha "$(sha_of "$err")" \
  --arg errorsha "$error_sha" \
  --arg outcome "$outcome" \
  --argjson interrupted "$interrupted" \
  --arg cwd "$cwd" \
  --arg head "$head" \
  --arg tree "$tree" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  'def str_or_null: if type == "string" and . != "" then . else null end;
   def ok_only($v): if $outcome == "ok" then $v else null end;
   {command: $cmd, command_sha: $cmdsha, command_len: $cmdlen,
    outcome: $outcome, interrupted: $interrupted,
    stdout_sha: ok_only($sha), stderr_sha: ok_only($errsha),
    error_sha: ($errorsha | str_or_null),
    session_id: (.session_id | str_or_null),
    agent_id: (.agent_id | str_or_null),
    cwd: $cwd, head: ($head | str_or_null), tree: ($tree | str_or_null),
    ts: $ts}' \
  >> "$dir/receipts.jsonl" || exit 0

exit 0
