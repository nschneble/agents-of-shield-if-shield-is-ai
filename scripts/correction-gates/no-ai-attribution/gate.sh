#!/usr/bin/env bash
# no-ai-attribution gate — the no-AI-attribution-markers correction,
# compiled to an executable check. Provenance + marker list: ./spec.md.
# Runs at commit/PR time (looper-commit), reading git history + a staged
# body — a different surface + position than format-scope, deliberately.
#
# Usage:
#   gate.sh [--dir DIR] [--range REF] [--body FILE]
#
#   --dir DIR    repo working root (default .)
#   --range REF  commit-message scope. A..B scans the range; a bare ref
#                scans that one commit (default HEAD, the commit a wave is
#                about to add).
#   --body FILE  also scan FILE (a staged PR body) for markers
#
# Exit: 0 clean · 1 a marker was found · 2 usage/env error.
set -euo pipefail

DIR="."
RANGE="HEAD"
BODY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="$2"; shift 2;;
    --range) RANGE="$2"; shift 2;;
    --body)  BODY="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--dir DIR] [--range REF] [--body FILE]" >&2
      echo "  fails if an AI-attribution marker is in the commit(s) or body" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

abspath() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$(pwd)" "$1";; esac; }
[ -n "$BODY" ] && BODY="$(abspath "$BODY")"
[ -d "$DIR" ] || { echo "no such dir: $DIR" >&2; exit 2; }
cd "$DIR"

# the banned tells, matched case-insensitively
RE='co-authored-by:.*(claude|anthropic)'
RE="$RE"'|generated with \[?claude'
RE="$RE"'|🤖 generated with'
RE="$RE"'|claude\.ai/code'

report=()
scan() { # label, text — append a report line per marker hit
  local label="$1" text="$2" hit
  hit=$(printf '%s\n' "$text" | grep -inE "$RE" || true)
  [ -n "$hit" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] && report+=("VIOLATION  AI-attribution marker in $label: $line")
  done <<< "$hit"
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  case "$RANGE" in
    *..*) msgs=$(git log --format='%B' "$RANGE");;
    *)    msgs=$(git log --format='%B' -1 "$RANGE");;
  esac
  scan "commit message(s) [$RANGE]" "$msgs"
elif [ -z "$BODY" ]; then
  echo "not a git work tree and no --body to scan" >&2; exit 2
fi

if [ -n "$BODY" ]; then
  [ -f "$BODY" ] || { echo "no such body file: $BODY" >&2; exit 2; }
  scan "PR body" "$(cat "$BODY")"
fi

if [ "${#report[@]}" -eq 0 ]; then
  echo "no-ai-attribution-gate: clean"
  exit 0
fi
printf 'no-ai-attribution-gate: %d marker(s)\n' "${#report[@]}"
for line in "${report[@]}"; do printf '  %s\n' "$line"; done
exit 1
