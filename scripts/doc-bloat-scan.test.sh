#!/usr/bin/env bash
# doc-bloat-scan.test.sh — both-directions test for the comment-bloat detector.
#
# Each of the four kinds fires on a violating fixture (RED) AND a clean fixture
# produces ZERO output (green), proving no false positive on: a lowercase
# single-line comment, a one-`*`-line block, a `// TODO:` marker, a `https://`
# URL (the `//` must not read as a comment), and a ≤75-char comment. Exit is
# always 0 — the scanner reports, it never gates. Pure bash, jq-free.
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

# ── RED fixture: one hit of every kind ─────────────────────────────────────────
cat > "$temp_dir/bloat.ts" <<'EOF'
/**
 * this block over-narrates
 * across several star lines
 */
export const a = 1

// first stacked line
// second stacked line
export const b = 2

// this single comment runs well past the seventy-five character wrap ceiling here
export const c = 3

// Returns the widget
export const d = 4
EOF

# ── green fixture: nothing should fire ─────────────────────────────────────────
cat > "$temp_dir/clean.ts" <<'EOF'
/**
 * one star line only
 */
export const e = 1

// lowercase single comment
export const f = 2

// TODO: a capitalized marker is exempt
export const g = 3

const url = "https://example.com/a//b"
export const h = 4
EOF

out=$("$scanner" "$temp_dir")
rc=$?

# exit is always 0
check "exit 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# RED: every kind present, anchored to bloat.ts
echo "$out" | grep -q '"kind":"block-overexplained".*bloat.ts\|"file":"[^"]*bloat.ts".*block-overexplained'
check "block-overexplained fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q 'bloat.ts.*stacked-slashes\|stacked-slashes.*bloat.ts'
check "stacked-slashes fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q 'bloat.ts.*over-75\|over-75.*bloat.ts'
check "over-75 fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

echo "$out" | grep -q 'bloat.ts.*capitalized-slash\|capitalized-slash.*bloat.ts'
check "capitalized-slash fires" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# green: clean.ts never appears in any candidate
echo "$out" | grep -q 'clean.ts'
check "clean.ts produces no candidate" "$([ $? -ne 0 ] && echo 0 || echo 1)"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
