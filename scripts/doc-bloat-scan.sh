#!/usr/bin/env bash
# doc-bloat-scan — self-contained comment-bloat detector for looper-declutter.
#
# The MECHANICAL finder behind `looper-declutter`: pure bash + awk + grep, no
# third-party tools, no tokenizer deps (`[[no-third-party-hosted-tool-reliance]]`:
# mine the check, don't adopt a linter). Read-only. It emits candidates; the
# skill triages them and routes snips to their existing owners (the-chronicler
# mechanics, the-ghostwriter voice). It NEVER edits a file and NEVER gates —
# exit is always 0.
#
# ── What it flags (JSONL, one candidate per line) ───────────────────────────────
#   block-overexplained : a bare `/* … */` or `{/* … */}` block spanning
#                         multiple lines — at least one content line between
#                         opener and closer, `*`-prefixed OR free-form prose
#                         alike, so an un-starred inline essay is not invisible.
#                         The primary quarry: a multi-line block wedged
#                         mid-execution.
#   jsdoc-block         : the same shape, but a `/**` (or `{/**`) opener — a
#                         doc header. Reported, not excused: the skill keeps
#                         it only on an external-contract surface (Swagger,
#                         DTO fields, README, public API). Declaration
#                         position buys placement, not length.
#   jsdoc-oneline       : a `/** … */` (or `{/** … */}`) opening and closing on
#                         ONE line — a symbol doc, which is the shape a
#                         per-prop doc takes. Emitted because props get no
#                         docs at all, not because one line is too long. A
#                         bare one-line `/* … */` is an inline note, not a
#                         symbol doc, and is NOT flagged; nor is an empty
#                         `/**/`.
#   stacked-slashes     : two or more consecutive full-line `//` comments (a wall
#                         of `//` that wants collapsing to a single WHY line).
#   over-75             : a comment line whose length exceeds 75 chars (content
#                         should wrap; the break sits at column 76).
#   capitalized-slash   : a single-line `//` whose first word is Capitalized
#                         (`// Returns…` → `// returns…`). Conventional ALL-CAPS
#                         markers (TODO, FIXME, GOTCHA, NOTE…) are exempt.
#   unterminated-block  : an opener with no closer before end of file. Usually
#                         a FALSE opener — a `{/*` inside a template literal,
#                         which is not a comment at all — so the lines after it
#                         are re-judged as code and still reported. Exit stays
#                         0: the source is normally valid, and this is a
#                         diagnostic about the scan, not a snip to route.
#
# `text` quotes the line the candidate CITES. For a block that is the
# opener line verbatim when it carries prose, and `/* ... <first body>`
# when the opener is bare — the elision mark says the words come from
# the next line, so the quote is never read as the opener's own. An
# `unterminated-block` always quotes the opener line verbatim: it has no
# validated body to borrow a word from.
#
# ── Scope (v1) ──────────────────────────────────────────────────────────────────
# C-style `//` and `/* */` only, and only FULL-LINE comments (the trimmed line
# starts with the comment token). JSX's braced form IS that same token: `{/*`
# and `{/**` open the same blocks, `*/}` closes them — braced is the only way
# to comment in JSX children position, so a `.tsx` tree would otherwise scan as
# comment-free. The brace must abut the slash (`{ /*` is an object literal or
# an open block). Capitalization is judged on single-line `//` only; a one-line
# `/* … */` or `{/* … */}` is length-checked, not case-checked — and a one-line
# `/** … */` is additionally flagged for EXISTING, since the `/**` spelling
# declares a symbol doc rather than an inline note.
# Trailing end-of-line comments (`code(); // x`) and `#`-comment languages are
# out of scope — deliberately, so a `//` inside a string or a `https://` URL is
# never mis-read as a comment. A candidate is a suggestion, not a verdict: the
# skill's human-disposes gate is where false positives die. Extending to
# `#`-languages / trailing comments is future scope.
#
# Shares scripts/custodian-skill-lint.sh's portability rules: bash 3.2
# safe (no mapfile / associative arrays), and grep/awk that may
# legitimately return non-zero (no match) are guarded so a clean scan
# never turns fatal. Not its I/O conventions — this script has no
# env-override paths (paths are arguments) and prints usage on stdout,
# `--help` being an answer rather than an error.
#
# Usage:
#   doc-bloat-scan.sh [<path> ...]     paths default to `.`; dirs are walked,
#                                      files scanned directly. In a git work tree
#                                      the walk uses `git ls-files` (respects
#                                      .gitignore); otherwise a pruned `find`.
#   doc-bloat-scan.sh -h | --help
set -uo pipefail

# ranged to `set -`, not a line number, so editing the header can't truncate
# help mid-sentence or drop the Usage block off the end
usage() { sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

# Source extensions carrying C-style comments.
EXT_RE='\.(ts|tsx|js|jsx|mjs|cjs|c|h|cc|cpp|hpp|hh|go|java|swift|rs|kt|kts|scala|cs|m|mm)$'

# Dirs pruned in the non-git fallback walk (git mode honors .gitignore instead).
PRUNE='.git node_modules dist build out coverage vendor .next .nuxt .svelte-kit local'

# --- awk finder: each file buffered, scanned by index, flushed at file end ---
# buffered, not streamed: an opener's fate is only known at end of file
read -r -d '' AWK_PROG <<'AWK' || true
function jesc(s) {           # minimal JSON string escaping
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s)
  gsub(/\r/, "", s)
  return s
}
function emit(f, ln, kind, text,   t) {
  t = text
  if (length(t) > 200) t = substr(t, 1, 200)   # keep JSONL lines sane
  printf "{\"file\":\"%s\",\"line\":%d,\"kind\":\"%s\",\"text\":\"%s\"}\n",
         jesc(f), ln, kind, jesc(t)
}
# held, not printed: a false opener gives its lines back to the scan
function hold(ln, kind, text) {
  held++; held_line[held] = ln; held_kind[held] = kind; held_text[held] = text
}
function release(   i) {
  for (i = 1; i <= held; i++)
    emit(cur_file, held_line[i], held_kind[i], held_text[i])
  held = 0
}
function flush_slashes() {
  if (slash_run >= 2) emit(cur_file, slash_line, "stacked-slashes", slash_text)
  slash_run = 0
}
function reset() {           # per-file state
  in_block = 0; block_body = 0; block_line = 0; held = 0
  block_first = ""; block_kind = ""; block_open = ""; block_text = ""
  slash_run = 0; slash_line = 0; slash_text = ""
}
function scan_line(ln, line,   t, len, is_close, body, after, one, rest) {
  t = line
  sub(/^[ \t]+/, "", t)      # trimmed (leading whitespace removed)
  len = length(line)

  if (in_block) {
    if (len > 75) hold(ln, "over-75", t)
    is_close = (index(line, "*/") > 0)
    body = t
    sub(/[ \t]*\*\/.*$/, "", body)  # drop the closer first, so a bare `*/`…
    sub(/^\*+[ \t]*/, "", body)     # …then a leading `*` if JSDoc-style
    # count every interior CONTENT line, `*`-prefixed or free-form prose alike,
    # so a non-starred `/* … */` block is no longer invisible; a bare closer
    # strips to empty and does not count
    if (body != "") { block_body++; if (block_first == "") block_first = body }
    if (is_close) {
      release()
      # >= 1 content line means a genuine multi-line block (opener, content,
      # closer) — the-chronicler bans any multi-line block mid-execution
      if (block_body >= 1) {
        rest = block_text; sub(/^\{?\/\*+[ \t]*/, "", rest)
        emit(cur_file, block_line, block_kind,
             (rest != "") ? block_text : block_open " ... " block_first)
      }
      in_block = 0; block_body = 0; block_first = ""; block_text = ""
    }
    return
  }

  # block opener? `{/*` is the JSX braced form of the same token, so it takes
  # the same path. The brace must abut: `{ /*` is a block or object literal.
  if (t ~ /^\{?\/\*/) {
    flush_slashes()
    if (len > 75) emit(cur_file, ln, "over-75", t)
    # a `/* … */` or `{/* … */}` that closes on its own line is not a block.
    # The `/**` spelling still emits: it declares "this is documentation of a
    # symbol," which is the shape a per-prop doc takes, and props get no docs
    # (the-chronicler `## Internal code`). A bare one-line `/* … */` does NOT
    # emit — it is an inline note, the same survivor class as a one-line `//`.
    if (index(t, "*/") > 1) {
      if (t ~ /^\{?\/\*\*/ && t ~ /\*\/\}?$/) {
        one = t
        sub(/^\{?\/\*+[ \t]*/, "", one)
        sub(/[ \t]*\*+\/\}?$/, "", one)
        # an alnum is what separates real prose from an empty `/**/` husk
        if (one ~ /[A-Za-z0-9]/) emit(cur_file, ln, "jsdoc-oneline", t)
      }
      return
    }
    in_block = 1; block_body = 0; block_first = ""
    block_line = ln
    # `/**` is a doc header (keep-leaning); a bare `/*` mid-code is the quarry
    block_kind = (t ~ /^\{?\/\*\*/) ? "jsdoc-block" : "block-overexplained"
    block_open = ((t ~ /^\{/) ? "{" : "") ((block_kind == "jsdoc-block") ? "/**" : "/*")
    # the emitted text has to quote the line it CITES. When the opener
    # carries prose, that trimmed line is the quote; splicing the next
    # line's words onto this line number misleads whoever ticks it
    block_text = t
    return
  }

  # full-line `//` comment?
  if (t ~ /^\/\//) {
    if (len > 75) emit(cur_file, ln, "over-75", t)
    after = t
    sub(/^\/\/+[ \t]*/, "", after)
    # Capitalized first word = Uppercase then lowercase. ALL-CAPS markers
    # (TODO/GOTCHA/…) are [A-Z][A-Z] and correctly skipped.
    if (after ~ /^[A-Z][a-z]/) emit(cur_file, ln, "capitalized-slash", t)
    if (slash_run == 0) { slash_line = ln; slash_text = t }
    slash_run++
    return
  }

  # any non-comment line ends a `//` run
  flush_slashes()
}
# an opener still open at EOF was never a block: report it, rescan its tail
function finish_file(   i) {
  if (cur_file == "") return
  reset()
  i = 1
  while (i <= nlines) {
    scan_line(i, L[i])
    i++
    if (i > nlines && in_block) {
      emit(cur_file, block_line, "unterminated-block", block_text)
      held = 0; in_block = 0
      i = block_line + 1
    }
  }
  flush_slashes()
}
FNR == 1 { finish_file(); cur_file = FILENAME; nlines = 0; split("", L) }
{ nlines++; L[nlines] = $0 }
END { finish_file() }
AWK

scan_files() {  # scan the NUL-delimited file list on stdin
  # xargs batches large lists; the awk per-file reset makes batch boundaries
  # harmless. LC_ALL=C reads bytes not multibyte, so one stray non-UTF8 byte
  # can't abort awk mid-batch and silently drop every file after it.
  grep -zEi "$EXT_RE" 2>/dev/null | xargs -0 env LC_ALL=C awk "$AWK_PROG" 2>/dev/null || true
}

list_dir() {    # emit NUL-delimited file paths under a dir
  local root="$1"
  if ( cd "$root" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
    ( cd "$root" && git ls-files -z 2>/dev/null | while IFS= read -r -d '' f; do
        printf '%s\0' "$root/$f"; done )
  else
    local prune_expr=() d
    for d in $PRUNE; do prune_expr+=( -name "$d" -o ); done
    find "$root" -type d \( "${prune_expr[@]}" -false \) -prune -o -type f -print0 2>/dev/null
  fi
}

main() {
  local paths=( "$@" )
  [ ${#paths[@]} -eq 0 ] && paths=( "." )
  local p
  {
    for p in "${paths[@]}"; do
      if [ -f "$p" ]; then printf '%s\0' "$p"
      elif [ -d "$p" ]; then list_dir "$p"
      fi
    done
  } | scan_files
}

main "$@"
