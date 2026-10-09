#!/usr/bin/env bash
# custodian-backup — Phase D pre-apply snapshot and one-level undo
set -uo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"

usage() {
  echo "usage: $0 snapshot --issue N [--date YYYY-MM-DD] [--tag TAG FILE...]..." >&2
  echo "       $0 undo --issue N" >&2
  echo "  snapshot copies every file before an apply edits it; undo restores the latest" >&2
}
die() { echo "$1" >&2; exit 2; }
needs_value() { [ "$2" -ge 2 ] || die "$1 needs a value"; }

same() { # copy, original -> 0 when they match; a symlink matches by target
  if [ -L "$1" ] || [ -L "$2" ]; then
    [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
  else
    cmp -s "$1" "$2"
  fi
}

snapshot() {
  local issue="" day="" tag="" f pairs=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) needs_value --issue "$#"; issue="$2"; shift 2;;
      --date)  needs_value --date "$#";  day="$2";   shift 2;;
      --tag)   needs_value --tag "$#";   tag="$2";   shift 2;;
      --*) die "unknown flag: $1";;
      *)
        [ -n "$tag" ] || die "$1 has no --tag before it"
        [ -L "$1" ] || [ -f "$1" ] || die "not a regular file or symlink: $1"
        f="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
        pairs="$pairs$f	$tag
"
        shift;;
    esac
  done
  [[ "$issue" =~ ^[0-9]+$ ]] || die "--issue needs a number"
  [ -n "$day" ] || day=$(date +%Y-%m-%d)
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date needs YYYY-MM-DD"

  local dir="$CUSTODIAN_HOME/$day" seq bdir manifest
  mkdir -p "$dir" || die "cannot create $dir"
  seq=$(find "$dir" -mindepth 1 -maxdepth 1 -type d -name 'backup-*' 2>/dev/null \
    | sed -nE 's|.*/backup-[0-9]+-([0-9]+)$|\1|p' | sort -n | tail -1)
  seq=$(( ${seq:-0} + 1 ))
  bdir="$dir/backup-$issue-$seq"

  manifest=$(printf '%s' "$pairs" | jq -R -s --argjson issue "$issue" --arg date "$day" \
    --argjson seq "$seq" '
      split("\n") | map(select(length > 0) | split("\t") | {original: .[0], tag: .[1]})
      | group_by(.original)
      | map({original: .[0].original, backup: ("files" + .[0].original),
             tags: (map(.tag) | unique)})
      | {issue: $issue, date: $date, seq: $seq, entries: .}') \
    || die "cannot build manifest"
  mkdir "$bdir" || die "cannot create $bdir"

  local original backup failed=0 count=0
  while IFS='	' read -r original backup; do
    count=$((count + 1))
    mkdir -p "$(dirname "$bdir/$backup")" \
      && cp -P -p "$original" "$bdir/$backup" 2>/dev/null \
      && same "$bdir/$backup" "$original" \
      || { echo "copy failed: $original" >&2; failed=$((failed + 1)); }
  done < <(printf '%s' "$manifest" | jq -r '.entries[] | [.original, .backup] | @tsv')

  if [ "$failed" -gt 0 ]; then
    echo "PARTIAL  $failed of $count file(s) did not copy; no manifest written" >&2
    echo "         do not edit anything: $bdir is not a snapshot" >&2
    exit 1
  fi
  printf '%s\n' "$manifest" > "$bdir/manifest.json.tmp" \
    && mv "$bdir/manifest.json.tmp" "$bdir/manifest.json" \
    || { echo "PARTIAL  manifest write failed in $bdir" >&2; exit 1; }
  printf 'snapshot\t%s\t%d file(s)\n' "$bdir" "$count"
}

undo() {
  local issue=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) needs_value --issue "$#"; issue="$2"; shift 2;;
      *) die "unexpected arg: $1";;
    esac
  done
  [[ "$issue" =~ ^[0-9]+$ ]] || die "undo needs --issue N"
  local latest bdir manifest newest
  latest=$(find "$CUSTODIAN_HOME" -mindepth 2 -maxdepth 2 -type d -name 'backup-*' 2>/dev/null \
    | sed -nE 's|^(.*/([0-9]{4}-[0-9]{2}-[0-9]{2})/backup-[0-9]+-([0-9]+))$|\2	\3	\1|p' \
    | sort -t '	' -k1,1 -k2,2n | tail -1)
  [ -n "$latest" ] || die "no snapshot under $CUSTODIAN_HOME"
  bdir=${latest##*	}
  newest=${bdir##*/backup-}; newest=${newest%-*}
  [ "$newest" = "$issue" ] || die "newest snapshot is for issue $newest, not $issue: $bdir"
  manifest="$bdir/manifest.json"
  [ -s "$manifest" ] || die "newest snapshot is incomplete, no manifest: $bdir"
  jq -e '(.entries | type == "array")
         and all(.entries[]; (.original | type == "string") and (.backup | type == "string"))' \
    "$manifest" >/dev/null 2>&1 \
    || die "manifest is not in the shape this script writes; restore by hand: $manifest"

  local original backup tags tmp restored=0 unchanged=0 failed=0
  while IFS='	' read -r original backup _; do
    [ -L "$bdir/$backup" ] || [ -f "$bdir/$backup" ] || die "snapshot is missing $backup; nothing restored"
  done < <(jq -r '.entries[] | [.original, .backup] | @tsv' "$manifest")

  while IFS='	' read -r original backup tags; do
    if ! parent_unmoved "$original"; then
      printf 'failed\t%s\t%s\n' "$original" "$tags"
      failed=$((failed + 1)); continue
    fi
    if same "$bdir/$backup" "$original"; then
      printf 'unchanged\t%s\t%s\n' "$original" "$tags"
      unchanged=$((unchanged + 1)); continue
    fi
    tmp="$original.undo-$$"
    if { [ -L "$original" ] || [ ! -d "$original" ]; } \
        && mkdir -p "$(dirname "$original")" && cp -P -p "$bdir/$backup" "$tmp" 2>/dev/null \
        && { [ ! -L "$original" ] || rm -f -- "$original"; } \
        && mv -f "$tmp" "$original" && same "$bdir/$backup" "$original"; then
      printf 'restored\t%s\t%s\n' "$original" "$tags"
      restored=$((restored + 1))
    else
      rm -f "$tmp"
      printf 'failed\t%s\t%s\n' "$original" "$tags"
      failed=$((failed + 1))
    fi
  done < <(jq -r '.entries[] | [.original, .backup, (.tags // [] | join(","))] | @tsv' "$manifest")

  if [ "$restored" -eq 0 ] && [ "$failed" -eq 0 ]; then
    printf 'no-op\t%s\tevery file already matches the snapshot\n' "$bdir"
  fi
  printf 'undo\t%s\trestored=%d unchanged=%d failed=%d\n' "$bdir" "$restored" "$unchanged" "$failed"
  [ "$failed" -eq 0 ] || exit 1
}

# a parent swapped for a symlink would land the restore somewhere else
parent_unmoved() {
  local p
  p=$(dirname "$1")
  while [ ! -e "$p" ] && [ ! -L "$p" ]; do p=$(dirname "$p"); done
  [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$p" ]
}

cmd="${1:-}"; shift || true
case "$cmd" in
  snapshot) snapshot "$@";;
  undo)     undo "$@";;
  -h|--help) usage;;
  *) usage; exit 2;;
esac
