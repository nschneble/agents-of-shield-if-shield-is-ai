#!/usr/bin/env bash
# loop-unanimity-audit — finds wave groups where every crew reviewer agreed
# and none claimed execution behind the verdict. G2 checks a line has
# provenance, G3 checks a committed wave has some; neither asks whether a
# UNANIMOUS crew pass rests on nothing. Usage: see --help.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
INDEX="${INDEX:-$REPO_ROOT/local/custodian/history-index.jsonl}"
CENSUS_ROOT="$REPOS_ROOT"
MIN_AGENTS=2
WANT_INDEX=1
WANT_CENSUS=1

# exit 2 for usage errors: 1 is reserved for "findings"
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --index)     needs_value --index "$#"; INDEX="$2"; shift 2;;
    --census)    needs_value --census "$#"; CENSUS_ROOT="$2"; shift 2;;
    --min-agents) needs_value --min-agents "$#"; MIN_AGENTS="$2"; shift 2;;
    --no-index)  WANT_INDEX=0; shift;;
    --no-census) WANT_CENSUS=0; shift;;
    -h|--help)
      echo "usage: $0 [--index PATH] [--census ROOT] [--min-agents N]" >&2
      echo "            [--no-index] [--no-census]" >&2
      echo "  groups crew gate lines by repo|branch|wave|pass, then reports how" >&2
      echo "  many reached a unanimous all-clean verdict with zero execution" >&2
      echo "  backing. Corpus is the custodian history index plus every live" >&2
      echo "  local/loops/*/gates.jsonl under ROOT, deduped on cite." >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

case "$MIN_AGENTS" in
  ''|*[!0-9]*) echo "--min-agents needs a non-negative integer" >&2; exit 2;;
esac
# a trailing slash survives the ${gates#ROOT/} strip and turns every repo
# name into an absolute path, which then misses the receipts lookup
while [ "$CENSUS_ROOT" != "/" ] && [ "${CENSUS_ROOT%/}" != "$CENSUS_ROOT" ]; do
  CENSUS_ROOT="${CENSUS_ROOT%/}"
done
[ "$WANT_INDEX" -eq 1 ] || [ "$WANT_CENSUS" -eq 1 ] \
  || { echo "--no-index and --no-census leave no corpus" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/loop-unanimity.XXXXXX")
trap 'rm -rf "$work"' EXIT
corpus="$work/corpus.jsonl"
: > "$corpus"

index_lines=0
if [ "$WANT_INDEX" -eq 1 ]; then
  [ -s "$INDEX" ] || { echo "empty or missing index: $INDEX" >&2; exit 2; }
  jq -cRn '[inputs | fromjson? // empty | select(type == "object")]
           | .[] | . + {source: "index"}' "$INDEX" >> "$corpus"
  index_lines=$(jq -Rn '[inputs | fromjson? // empty | select(type == "object")] | length' "$INDEX")
fi

census_files=0
census_lines=0
if [ "$WANT_CENSUS" -eq 1 ]; then
  [ -d "$CENSUS_ROOT" ] || { echo "--census needs a directory: $CENSUS_ROOT" >&2; exit 2; }
  while IFS= read -r gates; do
    [ -s "$gates" ] || continue
    rel="${gates#"$CENSUS_ROOT"/}"
    repo="${rel%%/local/loops/*}"
    tail="${rel#*/local/loops/}"
    branch="${tail%/gates.jsonl}"
    # cite is synthesized to the index's exact form so dedup can join on it
    jq -cRn --arg repo "$repo" --arg branch "$branch" --arg rel "$rel" '
      [inputs] | to_entries[]
      | (.key + 1) as $ln | (.value | fromjson? // empty)
      | select(type == "object")
      | . + {repo: $repo, branch: $branch, cite: ($rel + ":" + ($ln | tostring)),
             source: "live"}' "$gates" >> "$corpus"
    census_files=$((census_files + 1))
  done < <(find "$CENSUS_ROOT" -type d -name node_modules -prune -o \
                -path '*/local/loops/*' -name gates.jsonl -print 2>/dev/null | sort)
  census_lines=$(jq -Rn '[inputs | fromjson? // empty | select(type == "object")
                          | select(.source == "live")] | length' "$corpus")
fi

total_read=$(jq -Rn '[inputs | fromjson? // empty] | length' "$corpus")
[ "$total_read" -gt 0 ] || { echo "NOTHING CHECKED — no parseable gate line in the corpus" >&2; exit 2; }

analysis=$(jq -Rn --argjson min "$MIN_AGENTS" '
  def rollup:
    (.agent == null)
    or ((.agent | tostring) | test("^all[-_ ]"; "i"))
    or ((.agent | tostring) | test("^(crew|none)$"; "i"))
    or ((.agent | tostring) | test("/"));

  # test("crew") not == "crew": the index holds crew-final, crew-interim,
  # final-crew and ~10 more spellings that an exact match would not see
  def is_crew: ((.kind // "") | tostring | test("crew"));
  def modern:  has("verified_by");
  def vb:      (.verified_by // null);

  [inputs | fromjson? // empty | select(type == "object")]
  | (unique_by(.cite // "\(.repo)|\(.branch)|\(.kind)|\(.agent)|\(.summary)")) as $rows
  | ($rows | map(select(is_crew)))                                  as $crew
  | ($crew | map(select(.ran == true)))                             as $ran
  | ($crew | map(select(.ran != true)) | length)                    as $notran
  | ($ran  | map(select(.wave == null)) | length)                   as $nowave
  | ($ran  | map(select(.wave != null)))                            as $usable
  | ($crew | map(select(.wave != null))
           | group_by([.repo, .branch, (.wave | tostring)])
           | map({key: (.[0].repo + "|" + .[0].branch + "|" + (.[0].wave | tostring)),
                  value: length}) | from_entries)                   as $dispatched

  | ($usable
     | group_by([.repo, .branch, (.wave | tostring),
                 (if has("pass") then (.pass // "null") else "unspecified" end)])
     | map({repo: .[0].repo, branch: .[0].branch, wave: (.[0].wave | tostring),
            pass: (if (.[0] | has("pass")) then (.[0].pass // "null") else "unspecified" end),
            lines: length,
            agents: ([.[].agent] | unique | length),
            dispatched: ($dispatched[.[0].repo + "|" + .[0].branch + "|" + (.[0].wave | tostring)] // 0),
            has_rollup: any(.[]; rollup),
            source: ([.[].source] | unique | join("+")),
            all_clean: all(.[]; (.blockers // 0) == 0),
            all_flag:  all(.[]; (.blockers // 0) > 0),
            all_modern: all(.[]; modern),
            any_modern: any(.[]; modern),
            t1: all(.[]; (vb == null) or (vb == "llm")),
            t2: all(.[]; vb != "executable"),
            cites: [.[].cite],
            verdicts: ([.[].verdict] | unique)})) as $g

  | ($g | map(select(.agents >= $min and (.has_rollup | not))))     as $multi
  | ($multi | map(select(.all_clean)))                              as $unanimous
  | ($unanimous | map(select(.t1)))                                 as $t1z
  | ($unanimous | map(select(.t2)))                                 as $t2z
  | ($t1z | map(select(.all_modern)))                               as $findings

  | {corpus: {deduped: ($rows | length), crew: ($crew | length),
              dropped_not_ran: $notran, dropped_no_wave: $nowave,
              usable: ($usable | length)},
     groups: {total: ($g | length),
              single_reviewer: ($g | map(select(.agents < $min)) | length),
              rollup_excluded: ($g | map(select(.agents >= $min and .has_rollup)) | length),
              multi: ($multi | length),
              unanimous_clean: ($unanimous | length),
              unanimous_flag: ($multi | map(select(.all_flag)) | length),
              pass_resolved: ($g | map(select(.pass != "unspecified")) | length)},
     backing: {t1_zero: ($t1z | length),
               t1_zero_legacy_era: ($t1z | map(select(.any_modern | not)) | length),
               t1_zero_modern_era: ($findings | length),
               t2_zero: ($t2z | length)},
     findings: ($findings | sort_by(.repo, .branch, .wave))}
' "$corpus")

pct() { [ "$2" -eq 0 ] && printf 'n/a' || printf '%s' "$(( $1 * 100 / $2 ))%"; }

echo "loop-unanimity-audit — unanimous crew verdicts with zero execution backing"
echo "  corpus:   index $index_lines line(s) · census $census_lines line(s) from $census_files file(s) under $CENSUS_ROOT"
printf '            %s deduped · %s crew · %s usable (dropped %s not-ran, %s wave-null)\n' \
  "$(printf '%s' "$analysis" | jq -r '.corpus.deduped')" \
  "$(printf '%s' "$analysis" | jq -r '.corpus.crew')" \
  "$(printf '%s' "$analysis" | jq -r '.corpus.usable')" \
  "$(printf '%s' "$analysis" | jq -r '.corpus.dropped_not_ran')" \
  "$(printf '%s' "$analysis" | jq -r '.corpus.dropped_no_wave')"
echo

printf '%s\n' "$analysis" | jq -r '
  "  groups (repo|branch|wave|pass)",
  "    total                      \(.groups.total)",
  "    single-reviewer            \(.groups.single_reviewer)   (not a unanimity; excluded)",
  "    rollup-agent               \(.groups.rollup_excluded)   (all-six/crew/slash lines; excluded)",
  "    multi-reviewer             \(.groups.multi)",
  "    UNANIMOUS all-clean        \(.groups.unanimous_clean)",
  "    unanimous all-flagging     \(.groups.unanimous_flag)   (agree a defect exists; SAME defect NOT checkable)",
  "    carrying a real pass field \(.groups.pass_resolved)   (index records carry none)",
  "",
  "  execution backing behind the unanimous all-clean groups",
  "    T1 zero (every verified_by llm/null/absent)  \(.backing.t1_zero)",
  "      of those, all-legacy-era (field predates)  \(.backing.t1_zero_legacy_era)   unevidenced, NOT a finding",
  "      of those, modern-era                       \(.backing.t1_zero_modern_era)   <- the finding",
  "    T2 zero (no verified_by == \"executable\")      \(.backing.t2_zero)"'
echo

findings=$(printf '%s\n' "$analysis" | jq -r '.backing.t1_zero_modern_era')
if [ "$findings" -eq 0 ]; then
  echo "  no modern-era group reached a unanimous all-clean verdict with zero backing"
else
  echo "  FINDINGS — unanimous, all-clean, every reviewer's provenance llm/null:"
  while IFS=$'\t' read -r repo branch wave pass agents dispatched cites; do
    [ -n "$repo" ] || continue
    rlog="$CENSUS_ROOT/$repo/local/loops/$branch/receipts.jsonl"
    if [ ! -s "$rlog" ]; then
      corrob="NOT EVALUABLE (no receipts log on this branch)"
    else
      up=$(jq -Rn '[inputs | fromjson? // empty | select((.interrupted // false) != true)] | length' "$rlog")
      corrob="branch has $up uninterrupted receipt(s) — branch-granular only, receipts carry no wave"
    fi
    printf '    %s/%s wave %s pass %s · %s reviewer(s) ran of %s crew line(s) logged, all clean\n' \
      "$repo" "$branch" "$wave" "$pass" "$agents" "$dispatched"
    printf '      receipts: %s\n' "$corrob"
    printf '      cites: %s\n' "$cites"
  done < <(printf '%s\n' "$analysis" | jq -r '.findings[]
            | [.repo, .branch, .wave, .pass, (.agents|tostring),
               (.dispatched|tostring), (.cites|join(", "))] | @tsv')
fi

echo
unan=$(printf '%s\n' "$analysis" | jq -r '.groups.unanimous_clean')
echo "VERDICT: $findings of $unan unanimous all-clean group(s) had zero execution backing ($(pct "$findings" "$unan") of unanimous passes)"
[ "$findings" -eq 0 ]
