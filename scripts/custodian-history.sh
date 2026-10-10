#!/usr/bin/env bash
# custodian-history — cited, incremental index over gates.jsonl, all repos.
# One canonical JSONL store (no SQLite), queried for ranked cited matches,
# grafting the ctx pattern onto looper structured log.
#
# Subcommands:
#   ingest            append only gates.jsonl lines not already indexed
#   rebuild           wipe + re-derive from live dirs; loses reaped dirs' records
#   rebuild --include-archive
#                     same, then local/loops/.archive/<date>/<dir>; keeps them
#   query <q> [flags]  read-only ranked cited lookup
#
# query flags (all substring, case-insensitive):
#   --agent S  --verdict S  --kind S  --repo S  --file S
#   --blocked  (only records with blockers>0)
#   --limit N  (default 20)
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
REPOS=(linklater tuffgal tuffgal-action agents-of-shield-if-shield-is-ai rss-reader)
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
INDEX="$CUSTODIAN_HOME/history-index.jsonl"

# probe stat flavor once: GNU stat -f wrongly reads fs status, not mtime
if stat -c %Y / >/dev/null 2>&1; then
  file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }   # GNU coreutils
else
  file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }   # BSD / macOS
fi

# SHA-based, not branch-ref, so it resolves after the branch is deleted
resolve_files() {  # repo_root gates_path -> JSON array on stdout
  local rr="$1" gp="$2"
  command -v git >/dev/null 2>&1 || { echo '[]'; return; }
  git -C "$rr" rev-parse --git-dir >/dev/null 2>&1 || { echo '[]'; return; }
  local shas sha verified=() f files=()
  shas=$(jq -r '.summary // ""' "$gp" 2>/dev/null | grep -oiE '[0-9a-f]{7,40}' | sort -u || true)
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$rr" cat-file -e "${sha}^{commit}" 2>/dev/null && verified+=("$sha") || true
  done <<< "$shas"
  [ ${#verified[@]} -gt 0 ] || { echo '[]'; return; }
  for sha in "${verified[@]}"; do
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done \
      < <(git -C "$rr" show --name-only --pretty=format: "$sha" 2>/dev/null || true)
  done
  [ ${#files[@]} -gt 0 ] || { echo '[]'; return; }
  printf '%s\n' "${files[@]}" | sort -u | jq -R . | jq -cs .
}

terminated() { cat -- "$1" && { [ -z "$(tail -c 1 -- "$1")" ] || echo; }; }

index_gates() {  # repo_root repo gates_path branch cite_base >> stdout
  local mtime files_json
  # numeric guard: a non-integer here aborts jq --argjson under set -e
  mtime=$(file_mtime "$3"); [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  files_json=$(resolve_files "$1" "$3")
  terminated "$3" | jq -c \
    --arg repo "$2" --arg branch "$4" \
    --argjson files "$files_json" --argjson mtime "$mtime" \
    --arg cbase "$5" '
    {
      repo:$repo, branch:$branch,
      wave, kind, agent, verdict,
      blockers: (.blockers // 0),
      ran: .ran,
      task_tool_available: .task_tool_available,
      summary: (.summary // ""),
      files: $files,
      mtime: $mtime,
      cite: ($cbase + ":" + (input_line_number|tostring))
    }
    # copied only if source has the key: feeds the legacy exemption
    + (if has("verified_by") then {verified_by} else {} end)
    + (if has("outcome")     then {outcome}     else {} end)'
}

# reap names a same-day repeat <branch>.<n> only beside an existing <branch>
archived_branch() {  # archived_dir name_under_date -> branch on stdout
  local suffix=${2##*.}
  if [ "$suffix" != "$2" ] && [[ "$suffix" =~ ^[0-9]+$ ]] && [ -d "${1%.*}" ]; then
    echo "${2%.*}"
  else
    echo "$2"
  fi
}

ingest() {
  local include_archive="${1:-0}"
  mkdir -p "$CUSTODIAN_HOME"; touch "$INDEX"
  local cand new gates branch rel dir repo rr n
  # || cand="" so set -e cannot abort before the named-failure check below
  cand=$(mktemp "${TMPDIR:-/tmp}/custodian-history.XXXXXX") || cand=""
  new=$(mktemp "${TMPDIR:-/tmp}/custodian-history.XXXXXX") || new=""
  [ -n "$cand" ] && [ -n "$new" ] || {
    echo "FATAL: custodian-history: mktemp gave no temp file" \
         "(TMPDIR=${TMPDIR:-unset}); cannot ingest" >&2
    exit 2
  }
  for repo in "${REPOS[@]}"; do
    rr="$REPOS_ROOT/$repo"
    [ -d "$rr/local/loops" ] || { echo "skip $repo (no local/loops)" >&2; continue; }
    while IFS= read -r gates; do
      branch=${gates#"$rr/local/loops/"}; branch=${branch%/gates.jsonl}
      index_gates "$rr" "$repo" "$gates" "$branch" \
        "$repo/local/loops/$branch/gates.jsonl" >> "$cand"
    done < <(find "$rr/local/loops" -type d -name .archive -prune -o -name gates.jsonl -print 2>/dev/null)
    [ "$include_archive" -eq 1 ] || continue
    while IFS= read -r gates; do
      dir=${gates%/gates.jsonl}; rel=${dir#"$rr/local/loops/"}
      [[ "$rel" =~ ^\.archive/[0-9]{4}-[0-9]{2}-[0-9]{2}/. ]] || continue
      branch=$(archived_branch "$dir" "${rel#.archive/*/}")
      index_gates "$rr" "$repo" "$gates" "$branch" \
        "$repo/local/loops/$rel/gates.jsonl" >> "$cand"
    done < <(find "$rr/local/loops/.archive" -mindepth 3 -name gates.jsonl -print 2>/dev/null | sort)
  done
  # anti-join by cite: keep only candidates not already in the index
  jq -c -n --slurpfile idx "$INDEX" --slurpfile cand "$cand" '
    ($idx | map({key:.cite, value:true}) | from_entries) as $seen
    | $cand[] | select(($seen[.cite] // false) | not)
  ' > "$new"
  n=$(grep -c . "$new" || true)
  cat "$new" >> "$INDEX"
  # || true, not || echo 0: grep -c already prints 0 before exiting 1
  echo "ingested ${n:-0} new record(s); index now $(grep -c . "$INDEX" || true) line(s) at $INDEX"
  rm -f "$cand" "$new"
}

rebuild() {
  local include_archive=0
  case "$#:${1:-}" in
    0:) ;;
    1:--include-archive) include_archive=1 ;;
    *) echo "rebuild takes only --include-archive" >&2; exit 2 ;;
  esac
  rm -f "$INDEX"; ingest "$include_archive"
}

query() {
  local q="" agent="" verdict="" kind="" repo="" file="" blocked=0 limit=20
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) agent="$2"; shift 2;;
      --verdict) verdict="$2"; shift 2;;
      --kind) kind="$2"; shift 2;;
      --repo) repo="$2"; shift 2;;
      --file) file="$2"; shift 2;;
      --blocked) blocked=1; shift;;
      --limit) limit="$2"; shift 2;;
      --*) echo "unknown flag: $1" >&2; return 2;;
      *) q="$1"; shift;;
    esac
  done
  [ -s "$INDEX" ] || { echo "empty index — run: $0 ingest" >&2; return 0; }
  jq -rn \
    --arg q "$q" --arg agent "$agent" --arg verdict "$verdict" \
    --arg kind "$kind" --arg repo "$repo" --arg file "$file" \
    --argjson blocked "$blocked" --argjson limit "$limit" '
    def ci($s): ($s // "") | ascii_downcase;
    [ inputs
      | select($q=="" or (ci(.summary+" "+(.agent//"")+" "+(.verdict//"")+" "+(.kind//"")) | contains(ci($q))))
      | select($agent==""   or (ci(.agent)   | contains(ci($agent))))
      | select($verdict=="" or (ci(.verdict) | contains(ci($verdict))))
      | select($kind==""    or (ci(.kind)    | contains(ci($kind))))
      | select($repo==""    or (ci(.repo)    | contains(ci($repo))))
      | select($file==""    or (any((.files//[])[]; ci(.) | contains(ci($file)))))
      | select($blocked==0  or ((.blockers // 0) > 0))
    ]
    | sort_by(.mtime, .cite) | reverse                       # most-recent run first
    | . as $rows
    | ($rows[:$limit][]
        | "\(.cite)\n  [\(.repo) · w\(.wave) · \(.kind) · \(.agent) · \(.verdict // "-") · blockers=\(.blockers)]\n  \(.summary)\n"),
      (if ($rows|length) > $limit
         then "… \(($rows|length) - $limit) more match(es) — raise --limit"
         else empty end)
  ' "$INDEX"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  ingest)
    for arg in "$@"; do
      [ "$arg" != --include-archive ] || { echo "--include-archive is a rebuild flag" >&2; exit 2; }
    done
    ingest;;
  rebuild) rebuild "$@";;
  query)   query "$@";;
  *) echo "usage: $0 {ingest|rebuild [--include-archive]|query <q> [--agent|--verdict|--kind|--repo|--file S] [--blocked] [--limit N]}" >&2; exit 2;;
esac
