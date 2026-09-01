#!/usr/bin/env bash
# custodian-fingerprint-cache.test.sh — both-directions test for the sha256
# pre-filter: each of new/unchanged/changed/gone must be reported correctly,
# and record must refuse to fingerprint a citation that doesn't resolve.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/custodian-fingerprint-cache.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

export CACHE="$temp_dir/fingerprint-cache.json"

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

stable="$temp_dir/stable.md"
mover="$temp_dir/mover.md"
ghost="$temp_dir/ghost.md"
echo "unchanged content" > "$stable"
echo "will change" > "$mover"
echo "about to vanish" > "$ghost"

# --- record refuses a citation that doesn't resolve yet ---
"$runner" record memory-a.md "$temp_dir/never-existed.md" >/dev/null 2>&1
refuse_rc=$?
[ "$refuse_rc" -ne 0 ]
check "record refuses a missing file (exit $refuse_rc)" $?
[ ! -f "$CACHE" ] || jq -e '. == {}' "$CACHE" >/dev/null 2>&1
check "record left no entry for the refused citation" $?

# --- seed the cache with three confirmed-resolved citations ---
"$runner" record memory-a.md "$stable" >/dev/null
"$runner" record memory-a.md "$mover" >/dev/null
"$runner" record memory-a.md "$ghost" >/dev/null

# now mutate the world: one file edited, one deleted, one left alone,
# plus a citation the cache has never seen
echo "changed content" > "$mover"
rm -f "$ghost"
fresh="$temp_dir/fresh.md"
echo "brand new" > "$fresh"

pairs="$temp_dir/pairs.tsv"
{
  printf 'memory-a.md\t%s\n' "$stable"
  printf 'memory-a.md\t%s\n' "$mover"
  printf 'memory-a.md\t%s\n' "$ghost"
  printf 'memory-a.md\t%s\n' "$fresh"
} > "$pairs"

out="$temp_dir/out.tsv"
err="$temp_dir/out.err"
"$runner" diff < "$pairs" > "$out" 2> "$err"
check "diff exits clean" $?

grep -qF "$(printf 'UNCHANGED\tmemory-a.md\t%s' "$stable")" "$out"
check "unchanged file reported UNCHANGED" $?

grep -qF "$(printf 'CHANGED\tmemory-a.md\t%s' "$mover")" "$out"
check "edited file reported CHANGED" $?

grep -qF "$(printf 'GONE\tmemory-a.md\t%s' "$ghost")" "$out"
check "deleted file reported GONE" $?

grep -qF "$(printf 'NEW\tmemory-a.md\t%s' "$fresh")" "$out"
check "never-cached file reported NEW" $?

grep -q 'new=1 unchanged=1 changed=1 gone=1' "$err"
check "summary counts match all four states" $?

# --- a bare `init` is idempotent and never clobbers existing entries ---
"$runner" init
"$runner" init
still_there=$(jq -r --arg k "memory-a.md|$stable" '.[$k].hash // empty' "$CACHE")
[ -n "$still_there" ]
check "init does not clobber an existing cache" $?

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS ($0)"
else
  echo "FAIL: $fails check(s) failed ($0)"
fi
exit "$fails"
