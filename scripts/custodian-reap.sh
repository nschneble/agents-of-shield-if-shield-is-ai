#!/usr/bin/env bash
# custodian-reap — Phase A verdict per local/loops dir; --apply deletes
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
INDEX="$CUSTODIAN_HOME/history-index.jsonl"
GH_BIN="${GH_BIN:-gh}"
DEFAULT=""
APPLY=0

usage() {
  echo "usage: REPO_ROOT=<repo> $0 [--default BRANCH] [--apply]" >&2
  echo "  prints reap/keep/clear per local/loops dir; --apply deletes" >&2
}
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --default) needs_value --default "$#"; DEFAULT="$2"; shift 2;;
    --apply)   APPLY=1; shift;;
    -h|--help) usage; exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "not a git repo: $REPO_ROOT" >&2; exit 2; }
if [ -z "$DEFAULT" ]; then
  DEFAULT=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  DEFAULT=${DEFAULT#origin/}
fi
if [ -z "$DEFAULT" ] && git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/main; then
  DEFAULT=main
fi
[ -n "$DEFAULT" ] || { echo "cannot resolve the default branch; pass --default" >&2; exit 2; }
git -C "$REPO_ROOT" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null \
  || { echo "default branch does not resolve: $DEFAULT" >&2; exit 2; }

mode=plan
[ "$APPLY" -eq 1 ] && mode=apply
repo_name=$(basename "$REPO_ROOT")
loops="$REPO_ROOT/local/loops"
if [ ! -d "$loops" ]; then
  printf 'summary\t%s\treap=0 keep=0 clear=0 failed=0 mode=%s (no local/loops)\n' "$repo_name" "$mode"
  exit 0
fi

merged_branches=$(git -C "$REPO_ROOT" branch --merged "$DEFAULT" --format='%(refname:short)') \
  || { echo "git branch --merged $DEFAULT failed" >&2; exit 2; }

# unreadable index reads as empty, so the guard keeps rather than reaps
indexed=""
if [ -s "$INDEX" ]; then
  indexed=$(jq -r '.cite // empty' "$INDEX" 2>/dev/null) || indexed=""
fi

gh_prs() { # branch, state -> comma-joined PR numbers; fails if gh can't say
  local raw
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  raw=$(cd "$REPO_ROOT" && "$GH_BIN" pr list --state "$2" --head "$1" --json number 2>/dev/null) \
    || return 1
  printf '%s' "$raw" | jq -er 'if type == "array" then map(.number | tostring) | join(",") else error end' \
    2>/dev/null
}

uncited_count() { # gates path, branch -> lines whose cite is not indexed
  local cites
  cites=$(jq -r --arg cbase "$repo_name/local/loops/$2/gates.jsonl" \
    '$cbase + ":" + (input_line_number | tostring)' "$1" 2>/dev/null) || return 1
  [ -n "$cites" ] || { echo 0; return 0; }
  awk 'NR == FNR { seen[$0] = 1; next } !($0 in seen)' \
    <(printf '%s\n' "$indexed") <(printf '%s\n' "$cites") | grep -c . || true
}

branch_dirs=$(find "$loops" -mindepth 2 -type f ! -name .DS_Store 2>/dev/null \
  | sed 's|/[^/]*$||' | sort -u)

reaped=0; kept=0; cleared=0; failed=0
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  branch=${dir#"$loops/"}

  if [ -e "$dir/run-state.json.tmp" ]; then
    printf 'clear\t%s\trun-state.json.tmp\n' "$branch"
    cleared=$((cleared + 1))
    if [ "$APPLY" -eq 1 ]; then
      rm -f -- "$dir/run-state.json.tmp"
      [ ! -e "$dir/run-state.json.tmp" ] || failed=$((failed + 1))
    fi
  fi

  nested=$(printf '%s\n' "$branch_dirs" | awk -v p="$dir/" 'index($0, p) == 1 { print; exit }')
  verdict=keep
  if [ "$branch" = "$DEFAULT" ]; then
    reason="kept (default branch)"
  elif [ -n "$nested" ]; then
    reason="kept (nests branch dir ${nested#"$loops/"})"
  else
    gh_ok=1; open=""; merged_pr=""
    open=$(gh_prs "$branch" open) || gh_ok=0
    if [ "$gh_ok" -eq 1 ]; then merged_pr=$(gh_prs "$branch" merged) || gh_ok=0; fi
    ancestry=0
    printf '%s\n' "$merged_branches" | grep -qxF -- "$branch" && ancestry=1
    if [ "$gh_ok" -eq 1 ] && [ -n "$open" ]; then
      reason="kept (open PR #$open)"
    elif [ "$ancestry" -eq 1 ]; then
      verdict=reap; reason="merged (ancestry)"
    elif [ "$gh_ok" -eq 1 ] && [ -n "$merged_pr" ]; then
      verdict=reap; reason="merged (PR #$merged_pr)"
    elif [ "$gh_ok" -eq 0 ]; then
      reason="kept (merge unverifiable — gh absent)"
    else
      reason="kept (unmerged)"
    fi
  fi

  if [ "$verdict" = reap ] && [ -e "$dir/gates.jsonl" ]; then
    missing=$(uncited_count "$dir/gates.jsonl" "$branch") || missing=unreadable
    if [ "$missing" != 0 ]; then
      verdict=keep; reason="kept (unindexed — ingest gap)"
    fi
  fi

  printf '%s\t%s\t%s\n' "$verdict" "$branch" "$reason"
  if [ "$verdict" = keep ]; then kept=$((kept + 1)); continue; fi
  reaped=$((reaped + 1))
  [ "$APPLY" -eq 1 ] || continue
  rm -rf -- "$dir"
  if [ -e "$dir" ]; then
    echo "could not delete $dir" >&2; failed=$((failed + 1)); continue
  fi
  parent=$(dirname "$dir")
  while [ "$parent" != "$loops" ] && rmdir "$parent" 2>/dev/null; do
    parent=$(dirname "$parent")
  done
done <<EOF
$branch_dirs
EOF

printf 'summary\t%s\treap=%d keep=%d clear=%d failed=%d mode=%s\n' \
  "$repo_name" "$reaped" "$kept" "$cleared" "$failed" "$mode"
[ "$failed" -eq 0 ] || exit 1
