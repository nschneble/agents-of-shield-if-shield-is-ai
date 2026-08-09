#!/usr/bin/env bash
# custodian-history — cited, incremental index over gates.jsonl across the looper repos.
#
# Grafts the ctx (ctxrs/ctx) pattern onto looper's own structured log: one
# canonical store, queried for ranked cited matches, ingested incrementally
# rather than re-scanned. Substrate is JSONL + jq — no SQLite, no binary.
#
# Subcommands:
#   ingest            append only gates.jsonl lines not already indexed
#   rebuild           wipe + re-derive the whole index from source (safe anytime)
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

# Portable file mtime in epoch seconds. macOS/BSD stat speaks `-f %m`; GNU
# coreutils speaks `-c %Y`. Trap (this broke CI on ubuntu): under GNU, `stat -f`
# selects FILESYSTEM status and `%m` is the MOUNT POINT, so `stat -f %m` SUCCEEDS
# with a non-epoch ("/") — a plain `stat -f %m || stat -c %Y` fallback never
# reaches the GNU form. So probe which flavor this host speaks once, up front.
if stat -c %Y / >/dev/null 2>&1; then
  file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }   # GNU coreutils
else
  file_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }   # BSD / macOS
fi

# Resolve the files a run touched, from commit SHAs named in its summaries.
# SHA-based (not branch-ref) so it still resolves after the branch is merged +
# deleted. Best-effort: no git, no repo, or no resolvable SHA ⇒ [] (never invented).
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

ingest() {
  mkdir -p "$CUSTODIAN_HOME"; touch "$INDEX"
  local cand new gates branch mtime files_json repo rr n
  # `|| cand=""` so set -e cannot abort ahead of the check below: it did,
  # and the terminal got mktemp's own line with no script name, no refusal
  # word, and rc=1 where the empty shape gives 2 for the same failure.
  # Both shapes land here because "no temp file" is true of both, and a
  # nonzero mktemp explains itself on stderr. The explicit template is what
  # makes TMPDIR the input the message names: a bare `mktemp` ignores
  # TMPDIR on BSD and allocates under /var/folders.
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
      mtime=$(file_mtime "$gates"); [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
      # ^ numeric guard: mtime feeds `jq --argjson`, which aborts the script under
      #   set -euo pipefail on any non-integer (the exact GNU-stat failure above).
      files_json=$(resolve_files "$rr" "$gates")
      jq -c \
        --arg repo "$repo" --arg branch "$branch" \
        --argjson files "$files_json" --argjson mtime "$mtime" \
        --arg cbase "$repo/local/loops/$branch/gates.jsonl" '
        {
          repo:$repo, branch:$branch,
          wave, kind, agent, verdict,
          blockers: (.blockers // 0),
          ran: (.ran // null),
          task_tool_available: (.task_tool_available // null),
          summary: (.summary // ""),
          files: $files,
          mtime: $mtime,
          cite: ($cbase + ":" + (input_line_number|tostring))
        }
        # Era-detection keys: copy verified_by/outcome into the record ONLY when the
        # SOURCE line carried them, so key-absence in the index faithfully mirrors
        # key-absence in source. This is load-bearing: the guardrail replays legacy
        # exemption (custodian-guardrails.sh) keys on the ABSENCE of verified_by, so a
        # blanket `// null` default would forge the key onto pre-schema lines and flip
        # them modern on the next `rebuild` — flooding false G2/G3 violations. Keep it
        # conditional so the exemption survives rebuild (custodian-guardrails.test.sh
        # proves this with a rebuild-simulation case).
        + (if has("verified_by") then {verified_by} else {} end)
        + (if has("outcome")     then {outcome}     else {} end)' "$gates" >> "$cand"
    done < <(find "$rr/local/loops" -name gates.jsonl 2>/dev/null)
  done
  # anti-join by cite: keep only candidates not already in the index
  jq -c -n --slurpfile idx "$INDEX" --slurpfile cand "$cand" '
    ($idx | map({key:.cite, value:true}) | from_entries) as $seen
    | $cand[] | select(($seen[.cite] // false) | not)
  ' > "$new"
  n=$(grep -c . "$new" || true)
  cat "$new" >> "$INDEX"
  echo "ingested ${n:-0} new record(s); index now $(grep -c . "$INDEX" || echo 0) line(s) at $INDEX"
  rm -f "$cand" "$new"
}

rebuild() { rm -f "$INDEX"; ingest; }

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
  ingest)  ingest "$@";;
  rebuild) rebuild "$@";;
  query)   query "$@";;
  *) echo "usage: $0 {ingest|rebuild|query <q> [--agent|--verdict|--kind|--repo|--file S] [--blocked] [--limit N]}" >&2; exit 2;;
esac
