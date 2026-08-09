#!/usr/bin/env bash
# doc-bloat-scan.test.sh — both-directions test for the comment-bloat
# detector.
#
# Every kind fires on a violating fixture (RED) AND the clean fixtures
# produce ZERO output (green), in both the C-style and the JSX braced
# (`{/* … */}`) spelling. The green side proves no false positive on: a
# lowercase single-line comment, a single-line `/** … */`, consecutive
# braced one-liners (a `{/*` read as an unconditional block opener would
# swallow the code between them into a phantom block), a `// TODO:`
# marker, a braced token inside a string, a `https://` URL (the `//` must
# not read as a comment), and a comment of exactly 75 chars — the boundary
# itself, paired with an exactly-76 line on the red side so the comparison
# is pinned from both directions rather than somewhere in the middle.
# Three more green shapes carry the block bookkeeping: a block with NO
# content line at all, in both the bare and the `*`-only spelling, so that
# miscounting an empty body emits a candidate quoting nothing; the braced
# zero-content form, whose `*/}` closer has to strip to empty like a plain
# `*/` does; and a `{ /*` block scope, which is not a comment opener
# because the brace does not abut — the one rule the scanner states twice.
# Exit is always 0 — the scanner reports, it never gates. Pure bash,
# jq-free.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scanner="$here/doc-bloat-scan.sh"
# a failing mktemp returns empty, which makes every derived fixture path
# absolute (/bloat.ts) and scatters the run outside the temp tree. Abort
# loudly rather than half-run against paths nobody intended. The explicit
# template is what makes TMPDIR the input the message names: a bare
# `mktemp -d` ignores TMPDIR on BSD and allocates under /var/folders.
# GOTCHA: a TMPDIR inside a git work tree reds this suite: the walk takes
# its `git ls-files` branch and lists no untracked fixture.
# one arm per shape: mktemp's own stderr explains a nonzero exit, but the
# empty-yet-successful shape prints nothing, so "failed" would be a lie
die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

fails=0
check() { # desc  condition-rc
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# ── RED fixture: one hit of every C-style kind ─────────────────────────────────
cat > "$temp_dir/bloat.ts" <<'EOF'
/**
 * this block over-narrates
 * across several star lines
 */
export const a = 1

/*
  this free-form block over-narrates too
*/
export const b = 2

// first stacked line
// second stacked line
export const c = 3

// this single comment runs well past the seventy-five character wrap ceiling here
export const d = 4

// Returns the widget
export const e = 5

/* this opener carries its own prose
   and one more body line follows
*/
export const j = 6

// a comment running exactly one character past the seventy-five column wrap
export const k = 7
EOF

# ── RED fixture: the JSX braced spelling of the same shapes ────────────────────
cat > "$temp_dir/braced.tsx" <<'EOF'
export const Panel = () => (
  <div>
    {/*
      this braced block over-narrates
      across two lines of prose
    */}
    <span>a</span>
    {/** a braced doc opener
      with one body line
    */}
    <span>b</span>
    {/* one braced line running well past the seventy-five character wrap ceiling */}
    <span>c</span>
    {/* short braced note */}
    <span>d</span>
    {/* this braced opener carries prose
      and continues on a second line
    */}
    <span>e</span>
  </div>
)
EOF

# ── green fixtures: nothing should fire ────────────────────────────────────────
cat > "$temp_dir/clean.ts" <<'EOF'
/** a single-line doc comment stays put */
export const f = 1

// lowercase single comment
export const g = 2

// TODO: a capitalized marker is exempt
export const h = 3

const url = "https://example.com/a//b"
export const i = 4

/*
*/
export const j = 5

/*
 *
 */
export const k = 6

{ /*
  a block scope, not a comment: the brace has to abut the slash
*/ }

// a comment measured to stop exactly at the seventy-fifth column, no wider
export const l = 7
EOF

cat > "$temp_dir/clean.tsx" <<'EOF'
export const Ok = () => (
  <div>
    {/* a braced one-liner */}
    <span>a</span>
    {/* another braced one-liner */}
    <span>b</span>
    {/** a braced doc one-liner */}
    <span>c</span>
    {/*
    */}
    <span>{"{/* not a comment, just a string */}"}</span>
  </div>
)
EOF

out=$("$scanner" "$temp_dir")
rc=$?

# exit is always 0
check "exit 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# RED: every kind present, anchored to bloat.ts
echo "$out" | grep -q '"file":"[^"]*bloat.ts".*"kind":"block-overexplained"'
check "block-overexplained fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# pinned through to the text: a bare `/**` opener has no prose of its own,
# and the quote is the only part of a jsdoc candidate that can silently
# empty out while the kind and the line number stay right
echo "$out" | grep -q '"file":"[^"]*bloat.ts","line":1,"kind":"jsdoc-block","text":"/\*\* \.\.\. this block over-narrates"'
check "jsdoc-block fires, quoting the elided body line" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*bloat.ts".*"kind":"stacked-slashes"'
check "stacked-slashes fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*bloat.ts".*"kind":"over-75"'
check "over-75 fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# the boundary itself, both sides of it. `len > 75` had nothing pinning
# the comparison: `>= 75`, `> 74` and `> 76` all survived. bloat.ts:27 is
# exactly 76 chars and must fire (kills `> 76`); the clean fixture's
# exactly-75 line must not (kills `>= 75` and `> 74`).
echo "$out" | grep -q '"file":"[^"]*bloat.ts","line":27,"kind":"over-75"'
check "a 76-char comment fires over-75" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q 'clean\.ts".*"kind":"over-75"'
check "a 75-char comment does not fire over-75" "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*bloat.ts".*"kind":"capitalized-slash"'
check "capitalized-slash fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# RED: the braced spelling reaches the same kinds
echo "$out" | grep -q '"file":"[^"]*braced.tsx","line":3,"kind":"block-overexplained"'
check "braced multi-line block fires block-overexplained" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*braced.tsx","line":8,"kind":"jsdoc-block","text":"{/\*\* a braced doc opener"'
check "braced multi-line doc block fires jsdoc-block" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*braced.tsx","line":12,"kind":"over-75"'
check "braced one-liner reaches the over-75 check" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# a one-line `{/* … */}` closes itself, so exactly the three real blocks
# emit — any extra means a braced one-liner opened a phantom block
braced_blocks=$(echo "$out" | grep -c 'braced.tsx.*"kind":"\(block-overexplained\|jsdoc-block\)"')
check "braced one-liners open no block" "$([ "$braced_blocks" -eq 3 ] && echo 0 || echo 1)"

# ── the quote must belong to the line it cites ─────────────────────────────────
# The defect: the opener's line number was emitted with the FIRST BODY
# LINE's text, so prose on the opener line was silently dropped and the
# report showed a quote that is not on the line it points at.
echo "$out" | grep -q '"file":"[^"]*bloat.ts","line":22,"kind":"block-overexplained","text":"/\* this opener carries its own prose"'
check "opener prose is the quote, not the body line" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*braced.tsx","line":16,"kind":"block-overexplained","text":"{/\* this braced opener carries prose"'
check "braced opener prose is the quote" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# a bare opener has no prose of its own, so the body line stands in behind
# an explicit elision mark rather than posing as the opener's words
echo "$out" | grep -q '"file":"[^"]*bloat.ts","line":7,"kind":"block-overexplained","text":"/\* \.\.\. this free-form block over-narrates too"'
check "bare opener marks the borrowed line as elided" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*braced.tsx","line":3,"kind":"block-overexplained","text":"{/\* \.\.\. this braced block over-narrates"'
check "bare braced opener marks the borrowed line as elided" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# green: neither clean fixture appears in any candidate
echo "$out" | grep -q 'clean\.ts"'
check "clean.ts produces no candidate" "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q 'clean\.tsx"'
check "clean.tsx produces no candidate" "$([ $? -ne 0 ] && echo 0 || echo 1)"

# ── --help ───────────────────────────────────────────────────────────────
# usage() prints the file header back, ranged to `set -` rather than to a
# line number so editing the header cannot truncate help mid-sentence. That
# range was pinned by nothing: reverting it to the old `sed -n '2,40p'`
# dropped the last 20 lines including the Usage block, and reddened
# nothing. Four assertions, because each catches a different regression —
# a non-zero exit, an empty body, stderr noise leaking into a help screen
# piped to a pager, and truncation at EITHER end.
help_out=$("$scanner" --help 2>"$temp_dir/help.err"); help_rc=$?
[ "$help_rc" -eq 0 ]
check "--help exits 0 (got $help_rc)" $?
[ -n "$help_out" ]
check "--help writes to stdout" $?
[ ! -s "$temp_dir/help.err" ]
check "--help writes nothing to stderr" $?
# the LAST line of the header, so a range that stops short cannot pass
printf '%s\n' "$help_out" | grep -q -- '-h | --help'
check "--help reaches the end of the header (no truncation)" $?
# and the FIRST, because only the tail was pinned: moving the range start
# to `sed -n '30,/^set -/p'` dropped 28 of 61 help lines and stayed green
printf '%s\n' "$help_out" | grep -q 'doc-bloat-scan — self-contained comment-bloat detector'
check "--help starts at the top of the header (no head truncation)" $?

# the header documents `-h | --help`, so the alias is part of the contract:
# narrowing the case to `--help)` silently turned `-h` into a scan of `.`
h_out=$("$scanner" -h 2>"$temp_dir/h.err"); h_rc=$?
[ "$h_rc" -eq 0 ] && [ "$h_out" = "$help_out" ] && [ ! -s "$temp_dir/h.err" ]
check "-h is the same answer as --help (exit $h_rc)" $?

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
