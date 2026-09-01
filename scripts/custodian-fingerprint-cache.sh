#!/usr/bin/env bash
# custodian-fingerprint-cache — sha256 pre-filter for Phase B's memory audit.
# Caches a hash per (memory_file, cited_path) pair; `diff` partitions a
# citation set into new/unchanged/changed/gone so Phase B's LLM fan-out only
# re-audits the delta. Mechanism ported from capn-hook's chart/ask model
# (github.com/CyrusNuevoDia/capn-hook) — see issue #81.
set -euo pipefail

REPOS_ROOT="${REPOS_ROOT:-$HOME/Developer/Repos}"
CUSTODIAN_HOME="${CUSTODIAN_HOME:-$REPOS_ROOT/agents-of-shield-if-shield-is-ai/local/custodian}"
CACHE="${CACHE:-$CUSTODIAN_HOME/fingerprint-cache.json}"

hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }

ensure_cache() {
  mkdir -p "$(dirname "$CACHE")"
  [ -f "$CACHE" ] || echo '{}' > "$CACHE"
}

usage() {
  cat >&2 <<EOF
usage: $0 init
       $0 record <memory_file> <cited_abs_path>
       $0 diff   < pairs.tsv        # memory_file<TAB>cited_abs_path per line

diff prints one line per pair to stdout:
  NEW|UNCHANGED|CHANGED|GONE<TAB>memory_file<TAB>cited_abs_path
and a summary count to stderr.

NEW/CHANGED/GONE need Phase B's LLM audit this run; UNCHANGED can be
skipped and still counted resolved (its hash matches the last confirmed
audit). GONE never auto-retires — it's still a B-retire CANDIDATE that
needs the relocation search SKILL.md requires before it's proposed.
EOF
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
  init)
    ensure_cache
    ;;
  record)
    [ $# -eq 2 ] || { echo "record needs <memory_file> <cited_abs_path>" >&2; exit 2; }
    memory_file=$1
    cited_abs=$2
    [ -f "$cited_abs" ] || { echo "cannot record, file missing: $cited_abs" >&2; exit 2; }
    ensure_cache
    h=$(hash_file "$cited_abs")
    key="${memory_file}|${cited_abs}"
    tmp=$(mktemp "${TMPDIR:-/tmp}/fingerprint-cache.XXXXXX")
    jq --arg k "$key" --arg h "$h" --arg mf "$memory_file" --arg cp "$cited_abs" \
      '.[$k] = {hash: $h, memory_file: $mf, cited_path: $cp}' "$CACHE" > "$tmp"
    mv "$tmp" "$CACHE"
    ;;
  diff)
    ensure_cache
    new=0; unchanged=0; changed=0; gone=0
    while IFS=$'\t' read -r memory_file cited_abs; do
      [ -n "$memory_file" ] || continue
      key="${memory_file}|${cited_abs}"
      cached_hash=$(jq -r --arg k "$key" '.[$k].hash // empty' "$CACHE")
      if [ ! -f "$cited_abs" ]; then
        printf 'GONE\t%s\t%s\n' "$memory_file" "$cited_abs"
        gone=$((gone + 1))
        continue
      fi
      cur_hash=$(hash_file "$cited_abs")
      if [ -z "$cached_hash" ]; then
        printf 'NEW\t%s\t%s\n' "$memory_file" "$cited_abs"
        new=$((new + 1))
      elif [ "$cur_hash" = "$cached_hash" ]; then
        printf 'UNCHANGED\t%s\t%s\n' "$memory_file" "$cited_abs"
        unchanged=$((unchanged + 1))
      else
        printf 'CHANGED\t%s\t%s\n' "$memory_file" "$cited_abs"
        changed=$((changed + 1))
      fi
    done
    echo "new=$new unchanged=$unchanged changed=$changed gone=$gone" >&2
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
