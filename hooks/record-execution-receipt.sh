#!/usr/bin/env bash
# record-execution-receipt — PostToolUse hook: appends one receipt per
# Bash execution, unlike verified_by (free text the audited agent types).
# No exit code exists in the payload; existence + interrupted is all it
# records. No signing, no blocking: every arm exits 0, always.
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

# local/ is gitignored scratch; a receipt is evidence, not a deliverable
dir="$repo_root/local/loops/$branch"
mkdir -p "$dir" || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
[ -n "$cmd" ] || exit 0

# truncated: loop-receipts.sh reads only existence + interrupted, not this
CMD_KEEP="${RECEIPT_CMD_KEEP:-200}"

# absent reads as false, not null: some shapes omit the key entirely
interrupted=$(printf '%s' "$payload" | jq -r '(.tool_response.interrupted // false) | tostring')
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

jq -cn \
  --arg cmd "$cmd" \
  --arg cmdsha "$cmd_sha" \
  --argjson cmdlen "$cmd_len" \
  --arg sha "$(sha_of "$out")" \
  --arg errsha "$(sha_of "$err")" \
  --argjson interrupted "$interrupted" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{command: $cmd, command_sha: $cmdsha, command_len: $cmdlen,
    interrupted: $interrupted, stdout_sha: $sha, stderr_sha: $errsha, ts: $ts}' \
  >> "$dir/receipts.jsonl" || exit 0

exit 0
