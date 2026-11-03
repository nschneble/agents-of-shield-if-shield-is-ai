#!/usr/bin/env bash
# custodian-cite-check — Phase B citation resolver over an explicit list
# of memory files: RESOLVED / MOVED / GONE / UNRESOLVED per citation, plus
# a summary. Report-only; --pairs feeds custodian-fingerprint-cache.sh.
set -uo pipefail

HOME_DIR=""
REPOS_DIR=""
REPO_ARGS=()
PAIRS=0
MEM_FILES=()

usage() {
  echo "usage: $0 [--home DIR] [--repos-dir DIR] [--repo NAME|PATH]... [--pairs] [memory_file...]" >&2
  echo "  memory files come from args, else one path per line on stdin" >&2
  echo "  prints VERDICT<TAB>memory_file<TAB>line<TAB>kind<TAB>citation<TAB>detail" >&2
  echo "  then summary<TAB>citations_total=N<TAB>citations_resolved=M<TAB>per-verdict counts" >&2
  echo "  --pairs prints memory_file<TAB>cited_abs_path for RESOLVED/MOVED only," >&2
  echo "  summary on stderr; exit 0 all RESOLVED, 1 any other verdict, 2 bad input" >&2
}
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --home)      needs_value --home "$#"; HOME_DIR="$2"; shift 2;;
    --repos-dir) needs_value --repos-dir "$#"; REPOS_DIR="$2"; shift 2;;
    --repo)      needs_value --repo "$#"; REPO_ARGS+=( "$2" ); shift 2;;
    --pairs)     PAIRS=1; shift;;
    -h|--help)   usage; exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   MEM_FILES+=( "$1" ); shift;;
  esac
done
HOME_DIR="${HOME_DIR:-$HOME}"
REPOS_DIR="${REPOS_DIR:-${REPOS_ROOT:-$HOME_DIR/Developer/Repos}}"
CLAUDE_DIR="$HOME_DIR/.claude"

if [ "${#MEM_FILES[@]}" -eq 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && MEM_FILES+=( "$f" )
  done
fi
[ "${#MEM_FILES[@]}" -gt 0 ] || { echo "no memory files given" >&2; exit 2; }
for f in "${MEM_FILES[@]}"; do
  [ -f "$f" ] && [ -r "$f" ] || { echo "memory file missing or unreadable: $f" >&2; exit 2; }
done

REPOS=()
if [ "${#REPO_ARGS[@]}" -gt 0 ]; then
  for r in "${REPO_ARGS[@]}"; do
    case "$r" in */*) REPOS+=( "${r%/}" );; *) REPOS+=( "$REPOS_DIR/$r" );; esac
  done
elif [ -d "$REPOS_DIR" ]; then
  for d in "$REPOS_DIR"/*/; do
    [ -e "$d.git" ] && REPOS+=( "${d%/}" )
  done
fi
[ "${#REPOS[@]}" -gt 0 ] || { echo "no git repos under $REPOS_DIR; pass --repo or --repos-dir" >&2; exit 2; }

encode() { printf '%s' "$1" | sed 's/[^A-Za-z0-9-]/-/g'; }

repo_names=""
for r in "${REPOS[@]+"${REPOS[@]}"}"; do repo_names+="$(basename "$r"),"; done
top_dirs=""
for d in /*; do top_dirs+="${d#/},"; done

HOME_PRUNE=( file-history shell-snapshots debug paste-cache session-env todos cache seed-admin bridge-spawn ide )
CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cite-check.XXXXXX") && [ -d "$CACHE_DIR" ] \
  || { echo "mktemp -d gave no usable dir (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
trap 'rm -rf "$CACHE_DIR"' EXIT

# a gitignored hit is a backup or scratch copy, not where the target went
drop_ignored() { # root, hits
  local ignored
  [ -n "$2" ] || return 0
  if git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
    ignored=$(printf '%s\n' "$2" | git -C "$1" check-ignore --stdin 2>/dev/null)
    if [ -n "$ignored" ]; then
      printf '%s\n' "$2" | grep -vxF -e "$ignored" | sort
      return 0
    fi
  fi
  printf '%s\n' "$2" | sort
}

glob_escape() { printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'; }

# runs in command substitutions, so the cache lives on disk, keyed by root
walk() { # root; sets WALK to its cached listing, returns 1 if the walk errored
  local rc files prune=( -name .git ) p skip=()
  local memory=( -path '*/.claude/projects/*/memory' -o -path '*/.claude/agent-memory' )
  WALK="$CACHE_DIR/$(printf '%s' "$1" | cksum | tr ' ' '-')"
  if [ ! -e "$WALK.rc" ]; then
    if [ "$1" = "$CLAUDE_DIR" ]; then
      for p in "${HOME_PRUNE[@]}"; do prune+=( -o -path "$(glob_escape "$1")/$p" ); done
      skip=( ! -name '*.jsonl' )
    fi
    find -L "$1" \( "${prune[@]}" \) -prune -o -name node_modules -print -prune -o -print >"$WALK.all" 2>/dev/null \
      && find -L "$1" \( "${prune[@]}" -o -name node_modules -o "${memory[@]}" \) -prune \
        -o -type f "${skip[@]+"${skip[@]}"}" -print >"$WALK.files" 2>/dev/null
    rc=$?
    files=$(drop_ignored "$1" "$(cat "$WALK.files" 2>/dev/null)")
    if [ -n "$files" ]; then printf '%s\n' "$files"; fi >"$WALK.files"
    echo "$rc" >"$WALK.rc"
  fi
  [ "$(cat "$WALK.rc")" -eq 0 ]
}

# prints matches one per line; returns 2 when the walk errored, no hits
search_find() { # root, suffix|name, value, [keep-ignored]
  local out rc=0
  walk "$1" || rc=2
  out=$(MODE=$2 VALUE=$3 SELF=${mem_abs:-} awk '
    BEGIN { m = ENVIRON["MODE"]; v = ENVIRON["VALUE"]; sfx = "/" v }
    $0 == ENVIRON["SELF"] || $0 ~ /\/node_modules$/ { next }
    m == "name" { n = split($0, s, "/"); if (s[n] == v) print; next }
    length($0) > length(sfx) && substr($0, length($0) - length(sfx) + 1) == sfx
  ' "$WALK.all")
  [ -n "${4:-}" ] || out=$(drop_ignored "$1" "$out")
  [ -n "$out" ] && printf '%s\n' "$out"
  [ -n "$out" ] || return "$rc"
}

search_grep() { # root, symbol
  local out rc=0
  walk "$1" || rc=2
  if [ -s "$WALK.files" ]; then
    out=$(tr '\n' '\0' <"$WALK.files" | xargs -0 sh -c 'grep -lIF -D skip -e "$0" -- "$@" 2>/dev/null; [ $? -le 1 ]' "$2") || rc=2
  fi
  out=$(drop_ignored "$1" "${out:-}")
  [ -n "$out" ] && printf '%s\n' "$out"
  [ -n "$out" ] || return "$rc"
}

installed_dependency() { # rel, roots... -> the rel under a node_modules dir
  local rel=$1 r d
  shift
  for r in "$@"; do
    walk "$r"
    while IFS= read -r d; do
      [ -e "$d/$rel" ] && { printf '%s' "$d/$rel"; return 0; }
    done < <(awk '/\/node_modules$/' "$WALK.all")
  done
  return 1
}

ignored_copy() { # rel, roots... -> a gitignored file the rel is a suffix of
  local rel=$1 r hit
  shift
  for r in "$@"; do
    hit=$(search_find "$r" suffix "$rel" keep) && [ -n "$hit" ] && { printf '%s' "${hit%%$'\n'*}"; return 0; }
  done
  return 1
}

every_root() { # preferred roots... -> each candidate root once, preferred first
  printf '%s\n' "$@" "$CLAUDE_DIR" "${REPOS[@]+"${REPOS[@]}"}" | awk 'NF && !seen[$0]++'
}

reloc_root_for() { # abs path -> the root its relocation searches
  local abs=$1 r best=""
  case "$abs" in "$CLAUDE_DIR"/*|"$CLAUDE_DIR") best=$CLAUDE_DIR;; esac
  for r in "${REPOS[@]+"${REPOS[@]}"}"; do
    case "$abs" in "$r"/*|"$r") [ "${#r}" -gt "${#best}" ] && best=$r;; esac
  done
  printf '%s' "$best"
}

is_dependency_path() { # root, rel
  case "/$2/" in */.git/*|*/node_modules/*|*/vendor/*|*/.venv/*|*/bower_components/*) return 0;; esac
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 && git -C "$1" check-ignore -q -- "$2" 2>/dev/null
}

extract() { # memory file -> line, kind, token, verbatim, named repos
  awk -v names="$repo_names" -v tops="$top_dirs" '
    BEGIN {
      nn = split(names, rn, ",")
      nt = split(tops, tl, ","); for (i = 1; i <= nt; i++) if (tl[i] != "") top[tl[i]] = 1
      ext = "^(sh|bash|zsh|md|json|jsonl|yml|yaml|ts|tsx|js|jsx|mjs|cjs|py|rb|erb|tsv|csv|toml|plist|txt|css|scss|html|go|rs|sql|lock|vue|svelte)$"
    }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    {
      named = ""; lline = tolower($0)
      for (i = 1; i <= nn; i++) {
        if (rn[i] == "") continue
        off = 0
        while ((p = index(substr(lline, off + 1), tolower(rn[i]))) > 0) {
          pos = off + p
          before = pos > 1 ? substr(lline, pos - 1, 1) : ""
          after = substr(lline, pos + length(rn[i]), 1)
          if (before !~ /[A-Za-z0-9_.-]/ && after !~ /[A-Za-z0-9_-]/) { named = named rn[i] ","; break }
          off = pos
        }
      }
      np = 0; ns = 0
      n = split($0, part, "`")
      for (i = 2; i < n; i += 2) {
        span = part[i]
        if (span ~ /[ \t]/) {
          nw = split(span, word, /[ \t]+/)
          for (w = 1; w <= nw; w++) {
            tok = word[w]; sub(/[,;:)]+$/, "", tok)
            if (tok ~ /\//) consider(tok, 1)
          }
        } else consider(span, 0)
      }
      for (k = 1; k <= np; k++) printf "%d\tpath\t%s\t%s\t%s\n", NR, paths[k], praw[k], named
      if (np > 0) for (k = 1; k <= ns; k++) printf "%d\tsymbol\t%s\t%s\t%s\n", NR, syms[k], syms[k], named
    }
    function consider(tok, inword,    last, segs, raw) {
      if (tok == "") return
      raw = tok
      sub(/^\$\{HOME\}\//, "~/", tok); sub(/^\$HOME\//, "~/", tok)
      if (placeholder(tok)) return
      if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && (tok ~ /_/ && tok ~ /[A-Za-z]/ || tok ~ /[a-z][A-Z]/)) { addsym(tok); return }
      if (!inword && tok ~ /^--[a-z][a-z0-9-]+$/) { addsym(tok); return }
      sub(/:[0-9]+(-[0-9]+)?$/, "", tok); sub(/#L[0-9]+(-L?[0-9]+)?$/, "", tok)
      if (tok ~ /[<>*?{}$|]/ || tok ~ /\.\.\./ || tok ~ /…/ || tok ~ /:\/\// || tok ~ /^[@-]/) return
      if (tok ~ /^\/[^\/.]*$/) return
      if (tok ~ /^\// && !((segs = split(tok, seg, "/")) > 1 && seg[2] in top)) return
      if (tok ~ /\//) {
        segs = split(tok, seg, "/"); last = seg[segs]
        if (tok !~ /[A-Za-z]/) return
        if (last ~ /\.[A-Za-z0-9]+$/ || tok ~ /\/$/ || tok ~ /^(~\/|\/)/) addpath(tok, raw)
        return
      }
      if (tok ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*\.[A-Za-z0-9]+$/) {
        last = tok; sub(/^.*\./, "", last)
        if (last ~ ext) addpath(tok, raw)
      }
    }
    function placeholder(t) {
      return t ~ /(^|[\/.-])[A-Za-z]([\/.-]|$)/ || t ~ /(^|[\/_.-])(foo|bar|baz|qux|some)([\/_.-]|$)/
    }
    function addpath(t, r,   k) { for (k = 1; k <= np; k++) if (praw[k] == r) return; paths[++np] = t; praw[np] = r }
    function addsym(t,   k) { for (k = 1; k <= ns; k++) if (syms[k] == t) return; syms[++ns] = t }
  ' "$1"
}

total=0; resolved=0; moved=0; gone=0; unresolved=0
emit() { # verdict, memory_file, line, kind, citation, detail
  total=$((total + 1))
  case "$1" in
    RESOLVED) resolved=$((resolved + 1));;
    MOVED) moved=$((moved + 1));;
    GONE) gone=$((gone + 1));;
    UNRESOLVED) unresolved=$((unresolved + 1));;
  esac
  if [ "$PAIRS" -eq 1 ]; then
    case "$1" in RESOLVED|MOVED) [ "$4" = path ] && [ -f "$6" ] && printf '%s\t%s\n' "$2" "$6";; esac
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
  fi
}

check_path() { # mem, line, token, verbatim, named, owner, in_agent_memory
  local mem=$1 line=$2 tok=$3 cite=$4 named=$5 owner=$6 agent=$7
  local roots=() named_list=() wide=() r rel abs base sym verdict k i npref note
  local searched="" errored=0 located=0 bare=0 hit=""
  tok=${tok#./}
  case "$tok" in
    "~/"*|/*)
      case "$tok" in "~/"*) abs="$HOME_DIR/${tok#\~/}";; *) abs=$tok;; esac
      abs=${abs%/}
      r=$(reloc_root_for "$abs")
      [ -n "$r" ] || { emit UNRESOLVED "$mem" "$line" path "$cite" "no search root covers $abs"; return; }
      if [ -e "$abs" ]; then
        line_files+=( "$abs" ); line_roots+=( "$r" ); line_anchored=1
        emit RESOLVED "$mem" "$line" path "$cite" "$abs"; return
      fi
      roots=( "$r" ); rel=${abs#"$r"/}; located=1
      ;;
    *)
      rel=${tok%/}
      [ "$owner" = "-" ] && { emit UNRESOLVED "$mem" "$line" path "$cite" "owning repo is not a configured repo"; return; }
      [ -n "$owner" ] && roots=( "$owner" )
      if [ -n "$owner" ] || [ "$agent" -eq 1 ]; then
        if [ -n "$named" ]; then
          IFS=',' read -r -a named_list <<< "$named"
          for k in "${named_list[@]}"; do
            for r in "${REPOS[@]+"${REPOS[@]}"}"; do [ "$(basename "$r")" = "$k" ] && roots+=( "$r" ); done
          done
        elif [ "$agent" -eq 1 ]; then
          roots=( "${REPOS[@]+"${REPOS[@]}"}" "$CLAUDE_DIR" )
        fi
      fi
      [ "${#roots[@]}" -gt 0 ] || { emit UNRESOLVED "$mem" "$line" path "$cite" "no root for a repo-relative citation"; return; }
      [[ "$rel" == */* ]] || bare=1
      ;;
  esac

  if [ "$agent" -eq 1 ] && [ -z "$named" ] && [ "$located" -eq 0 ]; then
    for k in "${!roots[@]}"; do [ -d "${roots[$k]}" ] || unset "roots[$k]"; done
    [ "${#roots[@]}" -gt 0 ] || { emit UNRESOLVED "$mem" "$line" path "$cite" "no configured repo exists"; return; }
    roots=( "${roots[@]}" )
  fi
  for r in "${roots[@]}"; do
    [ -d "$r" ] || { emit UNRESOLVED "$mem" "$line" path "$cite" "root missing: $r"; return; }
  done
  base=$(basename "$rel")
  line_roots+=( "${roots[@]}" )

  if [ "$bare" -eq 1 ]; then
    roots+=( "$CLAUDE_DIR" )
    for r in "${roots[@]}"; do
      [ -d "$r" ] || continue
      hit=""
      [ -e "$r/$base" ] && hit="$r/$base"
      [ -n "$hit" ] || hit=$(search_find "$r" name "$base" keep) || errored=1
      if [ -n "$hit" ]; then
        abs=$(printf '%s\n' "$hit" | head -1)
        line_files+=( "$abs" ); emit RESOLVED "$mem" "$line" path "$cite" "$abs"; return
      fi
      searched+="find $r -name $base; "
    done
    if [ "$errored" -eq 1 ]; then
      emit UNRESOLVED "$mem" "$line" path "$cite" "bare name, search errored: ${searched%; }"
    else
      emit UNRESOLVED "$mem" "$line" path "$cite" "bare name, no location to prove gone: ${searched%; }: 0 hits"
    fi
    return
  fi

  for r in "${roots[@]}"; do
    if [ -e "$r/$rel" ]; then
      line_files+=( "$r/$rel" ); line_anchored=1; emit RESOLVED "$mem" "$line" path "$cite" "$r/$rel"; return
    fi
  done
  for r in "${roots[@]}"; do
    if is_dependency_path "$r" "$rel"; then
      emit UNRESOLVED "$mem" "$line" path "$cite" "dependency or gitignored path absent: $rel"; return
    fi
  done

  while IFS= read -r r; do wide+=( "$r" ); done < <(every_root "${roots[@]}")
  npref=$(printf '%s\n' "${roots[@]}" | awk '!seen[$0]++' | wc -l | tr -d ' ')
  verdict=MOVED
  for i in "${!wide[@]}"; do
    r=${wide[$i]}
    [ -d "$r" ] || { errored=1; searched+="root missing: $r; "; continue; }
    note="0 hits"
    hit=$(search_find "$r" suffix "$rel") || note=errored
    if [ -n "$hit" ]; then
      [ "$located" -eq 0 ] && [ "$i" -lt "$npref" ] && verdict=RESOLVED
      break
    fi
    hit=$(search_find "$r" name "$base") || note=errored
    [ -n "$hit" ] && break
    [ "$note" = errored ] && errored=1
    searched+="find $r -path '*/$rel' -o -name $base: $note; "
  done
  if [ -z "$hit" ]; then
    for sym in "${line_syms[@]+"${line_syms[@]}"}"; do
      for r in "${wide[@]}"; do
        [ -d "$r" ] || continue
        note="0 hits"
        hit=$(search_grep "$r" "$sym") || { note=errored; errored=1; }
        [ -n "$hit" ] && break 2
        searched+="grep -rlF -e $sym $r: $note; "
      done
    done
  fi
  if [ -n "$hit" ]; then
    abs=$(printf '%s\n' "$hit" | head -1)
    line_files+=( "$abs" ); [ "$verdict" = RESOLVED ] && line_anchored=1
    emit "$verdict" "$mem" "$line" path "$cite" "$abs"
  elif [ "$errored" -eq 1 ]; then
    emit UNRESOLVED "$mem" "$line" path "$cite" "relocation search errored: ${searched%; }"
  elif abs=$(installed_dependency "$rel" "${wide[@]}"); then
    emit UNRESOLVED "$mem" "$line" path "$cite" "dependency path present: $abs"
  elif abs=$(ignored_copy "$rel" "${wide[@]}"); then
    emit UNRESOLVED "$mem" "$line" path "$cite" "gitignored copy present: $abs"
  else
    emit GONE "$mem" "$line" path "$cite" "${searched%; }"
  fi
}

check_symbol() { # mem, line, symbol
  local mem=$1 line=$2 sym=$3 f r hit errored=0 searched="" note
  for f in "${line_files[@]+"${line_files[@]}"}"; do
    if [ -d "$f" ]; then
      hit=$(search_grep "$f" "$sym" | head -1)
    else
      hit=""; [ -f "$f" ] && grep -qF -e "$sym" "$f" 2>/dev/null && hit=$f
    fi
    [ -n "$hit" ] && { emit RESOLVED "$mem" "$line" symbol "$sym" "$hit"; return; }
  done
  [ "${#line_roots[@]}" -gt 0 ] || { emit UNRESOLVED "$mem" "$line" symbol "$sym" "no search root on this line"; return; }
  while IFS= read -r r; do
    [ -d "$r" ] || { errored=1; searched+="root missing: $r; "; continue; }
    note="0 hits"
    hit=$(search_grep "$r" "$sym") || { note=errored; errored=1; }
    [ -n "$hit" ] && { emit MOVED "$mem" "$line" symbol "$sym" "$(printf '%s\n' "$hit" | head -1)"; return; }
    searched+="grep -rlF -e $sym $r: $note; "
  done < <(every_root "${line_roots[@]}")
  if [ "$errored" -eq 1 ]; then
    emit UNRESOLVED "$mem" "$line" symbol "$sym" "relocation search errored: ${searched%; }"
  elif [ "$line_anchored" -eq 0 ]; then
    emit UNRESOLVED "$mem" "$line" symbol "$sym" "no located path on this line to anchor it: ${searched%; }"
  else
    emit GONE "$mem" "$line" symbol "$sym" "${searched%; }"
  fi
}

reset_line() { line_files=(); line_roots=(); line_syms=(); line_anchored=0; }

for mem in "${MEM_FILES[@]}"; do
  mem_abs="$(cd "$(dirname "$mem")" && pwd)/$(basename "$mem")"
  owner=""; agent=0
  case "$mem_abs" in
    "$CLAUDE_DIR"/projects/*/memory/*)
      proj=${mem_abs#"$CLAUDE_DIR"/projects/}; proj=${proj%%/*}
      owner="-"
      for r in "${REPOS[@]+"${REPOS[@]}"}"; do
        [ "$(encode "$r")" = "$proj" ] && owner=$r
      done
      ;;
    "$CLAUDE_DIR"/agent-memory/*) agent=1;;
  esac
  records=$(extract "$mem") || { echo "extraction failed: $mem" >&2; exit 2; }
  cur=""
  while IFS=$'\t' read -r ln kind tok raw named; do
    [ -n "$ln" ] || continue
    if [ "$ln" != "$cur" ]; then
      cur=$ln; reset_line
      while IFS=$'\t' read -r _ k2 t2 _ _; do
        [ "$k2" = symbol ] && line_syms+=( "$t2" )
      done < <(printf '%s\n' "$records" | awk -F'\t' -v l="$ln" '$1 == l')
    fi
    case "$kind" in
      path)   check_path "$mem" "$ln" "$tok" "$raw" "${named%,}" "$owner" "$agent";;
      symbol) check_symbol "$mem" "$ln" "$tok";;
    esac
  done <<< "$records"
done

summary=$(printf 'summary\tcitations_total=%d\tcitations_resolved=%d\tresolved=%d\tmoved=%d\tgone=%d\tunresolved=%d' \
  "$total" "$((resolved + moved))" "$resolved" "$moved" "$gone" "$unresolved")
if [ "$PAIRS" -eq 1 ]; then echo "$summary" >&2; else echo "$summary"; fi
[ "$resolved" -eq "$total" ] || exit 1
