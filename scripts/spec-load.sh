#!/usr/bin/env bash
# spec-load — what each entry point pays in spec tokens per dispatch,
# not per file (skill-body-ceiling.sh's blind spot). Same chars/4 proxy
# as skill-body-ceiling.sh + custodian-skill-lint.sh, so all three agree.
# Usage: spec-load.sh [--manifest P] [--baseline P] [--write-baseline P]
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST=""
BASELINE=""
WRITE_BASELINE=""
ONLY_ENTRY=""

needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest)       needs_value --manifest "$#";       MANIFEST="$2"; shift 2;;
    --root)           needs_value --root "$#";           repo_root="$2"; shift 2;;
    --entry)          needs_value --entry "$#";          ONLY_ENTRY="$2"; shift 2;;
    --baseline)       needs_value --baseline "$#";       BASELINE="$2"; shift 2;;
    --write-baseline) needs_value --write-baseline "$#"; WRITE_BASELINE="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--manifest PATH] [--root PATH] [--entry NAME]" >&2
      echo "          [--baseline PATH] [--write-baseline PATH]" >&2
      echo "  reports spec tokens loaded per entry point" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -n "$MANIFEST" ] || MANIFEST="$repo_root/scripts/spec-load-manifest.tsv"
# -s tests size, not readability; mode-000 would pass, yielding no rows
if [ ! -s "$MANIFEST" ] || ! head -c 1 "$MANIFEST" >/dev/null 2>&1; then
  echo "empty or unreadable manifest: $MANIFEST" >&2; exit 2
fi

est_tokens() { # file -> approx tokens, the lint's proxy
  local c; c=$(wc -c < "$1" 2>/dev/null | tr -d ' '); echo $(( ${c:-0} / 4 ));
}

# entry order is manifest order, so the report matches how a run pays these
entries=()
declare -a always_total cond_total row_count
declare -a crew_costs

seen_entry() { # name -> index, or -1
  local i=0
  for e in ${entries[@]+"${entries[@]}"}; do
    [ "$e" = "$1" ] && { echo "$i"; return; }
    i=$((i + 1))
  done
  echo -1
}

rows=0
while IFS=$'\t' read -r entry path condition; do
  case "${entry:-}" in ''|\#*) continue ;; esac
  if [ -z "${path:-}" ] || [ -z "${condition:-}" ]; then
    echo "MALFORMED  $entry: row needs entry, path and condition" >&2; exit 2
  fi
  f="$repo_root/$path"
  if [ ! -e "$f" ]; then
    echo "MISSING    $entry: no $path" >&2
    echo "           A manifest row must name a real file. Fix the path or drop" >&2
    echo "           the row; a vanished file must never read as a saving." >&2
    exit 2
  fi
  rows=$((rows + 1))
  tok=$(est_tokens "$f")

  idx=$(seen_entry "$entry")
  if [ "$idx" -lt 0 ]; then
    entries+=("$entry"); idx=$(( ${#entries[@]} - 1 ))
    always_total[$idx]=0; cond_total[$idx]=0; row_count[$idx]=0
  fi
  row_count[$idx]=$(( ${row_count[$idx]} + 1 ))
  if [ "$condition" = "always" ]; then
    always_total[$idx]=$(( ${always_total[$idx]} + tok ))
  else
    cond_total[$idx]=$(( ${cond_total[$idx]} + tok ))
  fi
  [ "$entry" = "crew-agent" ] && crew_costs+=("$tok")
done < "$MANIFEST"

if [ "$rows" -eq 0 ]; then
  echo "NOTHING MEASURED  the manifest carried no readable row, so no entry" >&2
  echo "                  point was measured — not a clean run." >&2
  exit 2
fi

echo "spec-load — tokens loaded per dispatch, from $(basename "$MANIFEST")"
echo

measured=""
i=0
for e in "${entries[@]}"; do
  if [ -n "$ONLY_ENTRY" ] && [ "$e" != "$ONLY_ENTRY" ]; then i=$((i + 1)); continue; fi
  a=${always_total[$i]}; c=${cond_total[$i]}
  printf '  %-20s %6d always' "$e" "$a"
  [ "$c" -gt 0 ] && printf '  + up to %5d conditional  (= %d)' "$c" "$((a + c))"
  printf '   · %d files\n' "${row_count[$i]}"
  measured="${measured}${e}	${a}	${c}
"
  i=$((i + 1))
done

# crew cost is a RANGE: domain matching decides which reviewers fire
if [ -z "$ONLY_ENTRY" ] && [ "${#crew_costs[@]}" -gt 0 ]; then
  sorted=$(printf '%s\n' "${crew_costs[@]}" | sort -n)
  n=${#crew_costs[@]}
  full=0; for t in "${crew_costs[@]}"; do full=$((full + t)); done
  lo=0; hi=0; k=0
  while IFS= read -r t; do
    k=$((k + 1))
    [ "$k" -le 3 ] && lo=$((lo + t))
    [ "$k" -gt $((n - 3)) ] && hi=$((hi + t))
  done <<< "$sorted"
  echo
  echo "  crew pass, all $n reviewers:      $full"
  echo "  crew pass, any 3 (domain-matched): $lo to $hi"
  echo "  Multiply by the diff each reviewer reads; this is definitions only."
fi

if [ -n "$WRITE_BASELINE" ]; then
  { echo "# spec-load baseline — entry, always-tokens, conditional-tokens"
    printf '%s' "$measured"; } > "$WRITE_BASELINE" || {
    echo "cannot write baseline to $WRITE_BASELINE" >&2; exit 2; }
  echo
  echo "baseline written to $WRITE_BASELINE"
fi

if [ -n "$BASELINE" ]; then
  if [ ! -s "$BASELINE" ] || ! head -c 1 "$BASELINE" >/dev/null 2>&1; then
    echo "empty or unreadable baseline: $BASELINE" >&2; exit 2
  fi
  echo
  grew=0; compared=0
  while IFS=$'\t' read -r b_entry b_always b_cond; do
    case "${b_entry:-}" in ''|\#*) continue ;; esac
    case "${b_always:-}" in ''|*[!0-9]*) echo "MALFORMED baseline row for $b_entry" >&2; exit 2;; esac
    idx=$(seen_entry "$b_entry")
    if [ "$idx" -lt 0 ]; then
      echo "  DROPPED    $b_entry: in the baseline, absent from the manifest" >&2
      echo "             An entry point that stopped being measured is not a saving." >&2
      exit 2
    fi
    compared=$((compared + 1))
    now=${always_total[$idx]}
    if [ "$now" -gt "$b_always" ]; then
      printf '  GREW       %s: %d always > baseline %d (+%d)\n' \
        "$b_entry" "$now" "$b_always" "$((now - b_always))"
      grew=$((grew + 1))
    else
      printf '  ok         %s: %d always, %d under baseline\n' \
        "$b_entry" "$now" "$((b_always - now))"
    fi
  done < "$BASELINE"
  if [ "$compared" -eq 0 ]; then
    echo "NOTHING COMPARED  the baseline carried no readable row" >&2; exit 2
  fi
  echo
  echo "compared $compared · grew $grew"
  [ "$grew" -eq 0 ] || exit 1
fi

exit 0
