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
  origin_head=$(git -C "$REPO_ROOT" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
  # a dangling origin/HEAD, left by a rename and prune, names nothing
  if [ -n "$origin_head" ] && git -C "$REPO_ROOT" show-ref --verify --quiet "$origin_head"; then
    DEFAULT=${origin_head#refs/remotes/origin/}
  fi
fi
if [ -z "$DEFAULT" ] && git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/main; then
  DEFAULT=main
fi
[ -n "$DEFAULT" ] || { echo "cannot resolve the default branch; pass --default" >&2; exit 2; }
case "$(printf '%s' "$DEFAULT" | tr '[:upper:]' '[:lower:]')" in
  head|@) echo "--default $DEFAULT names the checkout, not the default branch" >&2; exit 2;;
esac
given=$DEFAULT
git -C "$REPO_ROOT" rev-parse --verify --quiet "$DEFAULT^{commit}" >/dev/null \
  || { echo "default branch does not resolve: $DEFAULT" >&2; exit 2; }
DEFAULT_REF=$(git -C "$REPO_ROOT" rev-parse --symbolic-full-name "$DEFAULT" 2>/dev/null)
case "$DEFAULT_REF" in
  refs/heads/?*)          DEFAULT=${DEFAULT_REF#refs/heads/};;
  refs/remotes/?*/?*)
    remote=$(git -C "$REPO_ROOT" remote | awk -v r="${DEFAULT_REF#refs/remotes/}" \
      'index(r, $0 "/") == 1 && length($0) > length(best) { best = $0 } END { print best }')
    [ -n "$remote" ] || { echo "--default $DEFAULT names no configured remote" >&2; exit 2; }
    DEFAULT=${DEFAULT_REF#refs/remotes/"$remote"/};;
  *) echo "--default $DEFAULT does not name a branch" >&2; exit 2;;
esac
# case-blind filesystems resolve a misspelled ref; only git's own spelling counts
refnames=$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)')
printf '%s\n' "$refnames" | grep -qxF -e "$DEFAULT_REF" \
  && printf '%s\n' "$refnames" | grep -qxF -e "$given" -e "refs/heads/$given" -e "refs/remotes/$given" \
  || { echo "--default $given does not match a ref's exact spelling" >&2; exit 2; }

mode=plan
[ "$APPLY" -eq 1 ] && mode=apply
repo_name=$(basename "$REPO_ROOT")
loops="$REPO_ROOT/local/loops"
if [ ! -d "$loops" ]; then
  printf 'summary\t%s\treap=0 keep=0 clear=0 failed=0 mode=%s (no local/loops)\n' "$repo_name" "$mode"
  exit 0
fi

merged_branches=$(git -C "$REPO_ROOT" branch --merged "$DEFAULT_REF" --format='%(refname:short)') \
  || { echo "git branch --merged $DEFAULT_REF failed" >&2; exit 2; }

# unreadable index reads as empty, so the guard keeps rather than reaps
indexed=""
if [ -s "$INDEX" ]; then
  indexed=$(jq -r '.cite // empty' "$INDEX" 2>/dev/null) || indexed=""
fi

gh_prs() { # branch, state, tip ('' = any) -> PR numbers; fails if gh can't
  local raw
  command -v "$GH_BIN" >/dev/null 2>&1 || return 1
  raw=$(cd "$REPO_ROOT" && "$GH_BIN" pr list --state "$2" --head "$1" --json number,headRefOid 2>/dev/null) \
    || return 1
  printf '%s' "$raw" | jq -er --arg tip "$3" 'if type == "array"
    then map(select($tip == "" or .headRefOid == $tip) | .number | tostring) | join(",")
    else error end' 2>/dev/null
}

merged_behind() { # branch, tip -> merged PRs whose head the tip has moved past
  local raw n oid found=""
  [ -n "$2" ] || return 0
  raw=$(cd "$REPO_ROOT" && "$GH_BIN" pr list --state merged --head "$1" --json number,headRefOid 2>/dev/null) \
    || return 1
  while IFS=$'\t' read -r n oid; do
    [ -n "$n" ] || continue
    git -C "$REPO_ROOT" merge-base --is-ancestor "$oid" "$2" 2>/dev/null && found="$found${found:+,}$n"
  done < <(printf '%s' "$raw" | jq -r '.[]? | [.number, .headRefOid] | @tsv' 2>/dev/null)
  printf '%s' "$found"
}

terminated() { cat -- "$1" && { [ -z "$(tail -c 1 -- "$1")" ] || echo; }; }

uncited_count() { # gates path, branch -> lines whose cite is not indexed
  local cites
  cites=$(terminated "$1" | jq -r --arg cbase "$repo_name/local/loops/$2/gates.jsonl" \
    '$cbase + ":" + (input_line_number | tostring)' 2>/dev/null) || return 1
  [ -n "$cites" ] || { echo 0; return 0; }
  awk 'NR == FNR { seen[$0] = 1; next } !($0 in seen)' \
    <(printf '%s\n' "$indexed") <(printf '%s\n' "$cites") | grep -c . || true
}

recorded_commits() { # dir -> commits its records say the run shipped
  if [ -e "$1/run-state.json" ]; then
    jq -r '.queue[]? | objects | .commit | strings' "$1/run-state.json" 2>/dev/null || return 1
  fi
  if [ -e "$1/gates.jsonl" ]; then
    jq -rR 'fromjson? | objects | .commit | strings' "$1/gates.jsonl" 2>/dev/null
  fi
  return 0
}

on_default() { # commits, one per line -> 0 when every one is in the default
  local c
  while IFS= read -r c; do
    [[ "$c" =~ ^[0-9a-f]{4,40}$ ]] || return 1
    git -C "$REPO_ROOT" merge-base --is-ancestor "$c" "$DEFAULT_REF" 2>/dev/null || return 1
  done <<< "$1"
}

branch_dirs=()
while IFS= read -r -d '' dir; do
  case "$dir" in "$loops"/?*) ;; *) continue ;; esac
  branch=${dir#"$loops/"}
  if ! git check-ref-format "refs/heads/$branch"; then
    printf 'skip\t%q\tnot a branch name\n' "$branch"; continue
  fi
  branch_dirs+=("$dir")
done < <(find "$loops" -mindepth 2 -type f ! -name .DS_Store -print0 2>/dev/null \
  | while IFS= read -r -d '' f; do printf '%s\0' "${f%/*}"; done | sort -zu)

reaped=0; kept=0; cleared=0; failed=0
for dir in ${branch_dirs[@]+"${branch_dirs[@]}"}; do
  branch=${dir#"$loops/"}

  if [ -e "$dir/run-state.json.tmp" ]; then
    printf 'clear\t%s\trun-state.json.tmp\n' "$branch"
    cleared=$((cleared + 1))
    if [ "$APPLY" -eq 1 ]; then
      rm -f -- "$dir/run-state.json.tmp"
      [ ! -e "$dir/run-state.json.tmp" ] || failed=$((failed + 1))
    fi
  fi

  nested=""
  for other in "${branch_dirs[@]}"; do
    case "$other" in "$dir"/*) nested=$other; break ;; esac
  done
  verdict=keep
  if [ "$branch" = "$DEFAULT" ]; then
    reason="kept (default branch)"
  elif [ -n "$nested" ]; then
    reason="kept (nests branch dir ${nested#"$loops/"})"
  else
    tip=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$branch") || tip=""
    gh_ok=1; open=""; merged_pr=""
    open=$(gh_prs "$branch" open "") || gh_ok=0
    if [ "$gh_ok" -eq 1 ]; then merged_pr=$(gh_prs "$branch" merged "$tip") || gh_ok=0; fi
    ancestry=0; tip_note=""
    if printf '%s\n' "$merged_branches" | grep -qxF -- "$branch"; then
      if ! recorded=$(recorded_commits "$dir"); then
        tip_note="kept (run-state.json unreadable)"
      elif [ -z "$recorded" ]; then
        tip_note="kept (merged tip, no recorded commit)"
      elif on_default "$recorded"; then
        ancestry=1
      else
        tip_note="kept (recorded commit off $DEFAULT)"
      fi
    fi
    if [ "$gh_ok" -eq 1 ] && [ -n "$open" ]; then
      reason="kept (open PR #$open)"
    elif [ "$ancestry" -eq 1 ]; then
      verdict=reap; reason="merged (ancestry)"
    elif [ "$gh_ok" -eq 1 ] && [ -n "$merged_pr" ]; then
      verdict=reap; reason="merged (PR #$merged_pr)"
    elif [ "$gh_ok" -eq 1 ] && behind=$(merged_behind "$branch" "$tip") && [ -n "$behind" ]; then
      reason="kept (merged PR #$behind, local tip ahead)"
    elif [ -n "$tip_note" ]; then
      reason=$tip_note
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
done

printf 'summary\t%s\treap=%d keep=%d clear=%d failed=%d mode=%s\n' \
  "$repo_name" "$reaped" "$kept" "$cleared" "$failed" "$mode"
[ "$failed" -eq 0 ] || exit 1
