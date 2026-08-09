#!/usr/bin/env bash
# gate.test.sh — both-directions test for the no-ai-attribution gate.
#
# Standing rule: RED (fires on a marker) AND green (clean surface passes).
# Covers every scanned surface — commit-message trailer, a commit range,
# and a PR-body file — in both footer forms (with and without the emoji),
# so the gate proves it catches the tells the correction bans and does not
# flag clean commits/bodies.
#
# Self-contained: builds a throwaway git repo in a temp dir, so the test
# needs no network and runs in CI (git only). Needs a writable temp dir, so
# it must run sandbox-off locally; it aborts rather than degrade when it
# cannot get one.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gate="$here/gate.sh"
# a failing mktemp returns empty, which makes every derived path absolute
# (/repo). The mkdir and cd below then fail while silenced, leaving the git
# fixture commands running in the CALLER's repo, where they commit its
# working tree and overwrite its user.email. Refuse to run instead.
temp_dir=$(mktemp -d) && [ -n "$temp_dir" ] && [ -d "$temp_dir" ] || {
  echo "FATAL: mktemp -d failed (TMPDIR=${TMPDIR:-unset}); refusing to run" >&2
  exit 2
}
trap 'rm -rf "$temp_dir"' EXIT

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

repo="$temp_dir/repo"; mkdir -p "$repo" || exit 2
(
  # never let the git fixture run in whatever the caller's CWD happens to be
  cd "$repo" || exit 2
  git init -q -b main
  git config user.email t@example.com
  git config user.name  t
  echo one > f.txt && git add -A && git commit -q -m "clean commit, no markers"
) >/dev/null 2>&1
c1=$( cd "$repo" && git rev-parse HEAD )

# body fixtures
printf 'Summary: an ordinary PR body, nothing to see.\n' > "$temp_dir/clean.txt"
printf '🤖 Generated with [Claude Code](https://claude.ai/code)\n' > "$temp_dir/robot.txt"
printf 'Generated with Claude Code\n' > "$temp_dir/genwith.txt"

# --- GREEN: a markerless tip commit passes. ---
out=$("$gate" --dir "$repo" --range HEAD); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "GREEN: markerless commit passes (exit 0)" "$r"
printf '%s\n' "$out" | grep -q 'no-ai-attribution-gate: clean'; check "GREEN: reports clean" $?

# --- GREEN: a clean PR body alongside a clean commit passes. ---
out=$("$gate" --dir "$repo" --range HEAD --body "$temp_dir/clean.txt"); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "GREEN: clean body passes (exit 0)" "$r"

# --- RED: the emoji footer in a PR body fires (commit still clean). ---
out=$("$gate" --dir "$repo" --range HEAD --body "$temp_dir/robot.txt"); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "RED: emoji 'Generated with' footer in body fails (exit 1)" "$r"
printf '%s\n' "$out" | grep -q 'marker in PR body'; check "RED: names the PR body as the source" $?

# --- RED: the no-emoji footer form also fires (proves emoji-optional). ---
out=$("$gate" --dir "$repo" --range HEAD --body "$temp_dir/genwith.txt"); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "RED: no-emoji 'Generated with Claude' footer fails (exit 1)" "$r"

# --- RED: a Co-Authored-By: Claude trailer in the tip commit fires. ---
printf 'feat: a change\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$temp_dir/msg"
( cd "$repo" && echo two > f.txt && git add -A && git commit -q -F "$temp_dir/msg" ) >/dev/null 2>&1
out=$("$gate" --dir "$repo" --range HEAD); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "RED: Co-Authored-By Claude trailer fails (exit 1)" "$r"
printf '%s\n' "$out" | grep -qi 'co-authored-by'; check "RED: cites the trailer line" $?

# --- RED: a range that spans the tainted commit fires. ---
out=$("$gate" --dir "$repo" --range "$c1..HEAD"); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "RED: range spanning the tainted commit fails (exit 1)" "$r"

echo
if [ "$fails" -eq 0 ]; then echo "all no-ai-attribution gate tests passed"; exit 0
else echo "$fails no-ai-attribution gate test(s) FAILED"; exit 1; fi
