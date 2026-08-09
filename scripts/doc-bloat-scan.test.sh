#!/usr/bin/env bash
# doc-bloat-scan.test.sh — both-directions test for the comment-bloat detector.
#
# Every kind fires on a violating fixture (RED) AND the clean fixtures produce
# ZERO output (green), in both the C-style and the JSX braced (`{/* … */}`)
# spelling. The green side proves no false positive on: a lowercase single-line
# comment, a single-line `/** … */`, consecutive braced one-liners (a `{/*` read
# as an unconditional block opener would swallow the code between them into a
# phantom block), a `// TODO:` marker, a braced token inside a string, a
# `https://` URL (the `//` must not read as a comment), and a ≤75-char comment.
# Exit is always 0 — the scanner reports, it never gates. Pure bash, jq-free.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scanner="$here/doc-bloat-scan.sh"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/doc-bloat-scan.XXXXXX")
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

echo "$out" | grep -q '"file":"[^"]*bloat.ts".*"kind":"jsdoc-block"'
check "jsdoc-block fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*bloat.ts".*"kind":"stacked-slashes"'
check "stacked-slashes fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*bloat.ts".*"kind":"over-75"'
check "over-75 fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*bloat.ts".*"kind":"capitalized-slash"'
check "capitalized-slash fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# RED: the braced spelling reaches the same kinds
echo "$out" | grep -q '"file":"[^"]*braced.tsx","line":3,"kind":"block-overexplained"'
check "braced multi-line block fires block-overexplained" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*braced.tsx","line":8,"kind":"jsdoc-block"'
check "braced multi-line doc block fires jsdoc-block" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q '"file":"[^"]*braced.tsx","line":12,"kind":"over-75"'
check "braced one-liner reaches the over-75 check" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# a one-line `{/* … */}` closes itself, so exactly the two real blocks emit —
# any extra means a braced one-liner opened a phantom block
braced_blocks=$(echo "$out" | grep -c 'braced.tsx.*"kind":"\(block-overexplained\|jsdoc-block\)"')
check "braced one-liners open no block" "$([ "$braced_blocks" -eq 2 ] && echo 0 || echo 1)"

# green: neither clean fixture appears in any candidate
echo "$out" | grep -q 'clean\.ts"'
check "clean.ts produces no candidate" "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q 'clean\.tsx"'
check "clean.tsx produces no candidate" "$([ $? -ne 0 ] && echo 0 || echo 1)"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
