#!/usr/bin/env bash
# skill-body-ceiling — fails when a skill's body grows past the size last
# DELIBERATELY agreed to (skill-body-ceilings.tsv), not a fixed budget.
# Raising the ceiling in the growing commit is the point; rationale:
# docs/decisions/looper-custodian.md. Usage: [--ceilings P] [--root P]
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CEILINGS=""

needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --ceilings) needs_value --ceilings "$#"; CEILINGS="$2"; shift 2;;
    --root)     needs_value --root "$#";     repo_root="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--ceilings PATH] [--root PATH]" >&2
      echo "  fails when a skill body grows past its recorded ceiling" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -n "$CEILINGS" ] || CEILINGS="$repo_root/scripts/skill-body-ceilings.tsv"
# -s tests size, not readability; mode-000 would pass, yielding no rows
if [ ! -s "$CEILINGS" ] || ! head -c 1 "$CEILINGS" >/dev/null 2>&1; then
  echo "empty or unreadable ceilings file: $CEILINGS" >&2; exit 2
fi

est_tokens() { # file -> approx tokens, the lint's proxy
  local c; c=$(wc -c < "$1" 2>/dev/null | tr -d ' '); echo $(( ${c:-0} / 4 ));
}

echo "skill-body-ceiling — recorded ceilings from $CEILINGS"
echo

over=0
checked=0
while IFS=$'\t' read -r skill ceiling note; do
  case "${skill:-}" in ''|\#*) continue ;; esac
  case "$ceiling" in
    ''|*[!0-9]*) echo "  MALFORMED  $skill: ceiling \"$ceiling\" is not a number" >&2; exit 2 ;;
  esac
  # a bare name is a skill; a slash is a repo-relative path (agents/*.md)
  case "$skill" in
    */*) f="$repo_root/$skill";                 label="$skill" ;;
    *)   f="$repo_root/skills/$skill/SKILL.md"; label="skills/$skill/SKILL.md" ;;
  esac
  if [ ! -e "$f" ]; then
    echo "  MISSING    $skill: no $label to measure" >&2
    exit 2
  fi
  actual=$(est_tokens "$f")
  checked=$((checked + 1))
  if [ "$actual" -gt "$ceiling" ]; then
    echo "  OVER       $skill: ~$actual tokens > recorded $ceiling (+$((actual - ceiling)))"
    echo "             Extract a section into references/, or raise the ceiling in"
    echo "             the same commit so the diff shows what the growth bought."
    [ -n "${note:-}" ] && echo "             last agreed: $note"
    over=$((over + 1))
  else
    slack=$((ceiling - actual))
    printf '  ok         %s: ~%s tokens, %s under\n' "$skill" "$actual" "$slack"
    # a ceiling far above the file has stopped constraining anything
    if [ "$ceiling" -gt 0 ] && [ "$slack" -gt $((ceiling / 5)) ]; then
      echo "             NOTE: $slack tokens of slack — an extraction landed and the"
      echo "             ceiling was not lowered with it, so it now guards nothing."
    fi
  fi
done < "$CEILINGS"

echo
if [ "$checked" -eq 0 ]; then
  echo "NOTHING CHECKED  the ceilings file carried no readable row, so no skill"
  echo "                 was measured — not a clean run."
  exit 2
fi
echo "checked $checked · over $over"
[ "$over" -eq 0 ]
