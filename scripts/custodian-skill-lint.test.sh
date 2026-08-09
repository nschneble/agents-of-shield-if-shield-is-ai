#!/usr/bin/env bash
# custodian-skill-lint.test.sh — both-directions test for the skill linter.
#
# Standing rule: a new invariant is tested RED (fires on a violating fixture) AND
# green (clean fixture passes). This proves each STRUCTURAL check flags its own
# violation with the offending file cited, that exit is 1 on any structural
# violation and 0 when clean, and — crucially for the two-tier design — that an
# ADVISORY-only fixture (over the token budgets, nothing structurally wrong) still
# exits 0. Pure bash + jq-free, self-contained fixtures under a temp dir.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
linter="$here/custodian-skill-lint.sh"
# a failing mktemp returns empty, which makes every derived fixture path
# absolute (/red-unknown) and scatters the run outside the temp tree. Abort
# loudly rather than half-run against paths nobody intended. The explicit
# template is what makes TMPDIR the input the message names: a bare
# `mktemp -d` ignores TMPDIR on BSD and allocates under /var/folders.
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
check() { # desc  rc-already-evaluated($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# ── RED fixtures: one structural violation per check ───────────────────────────

# unknown frontmatter field + first-person description (advisory rides along).
d="$temp_dir/red-unknown"; mkdir -p "$d"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-unknown
description: Does a thing when the user asks.
tools: Read
---
Body.
EOF

# missing required description.
d="$temp_dir/red-nodesc"; mkdir -p "$d"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-nodesc
---
Body.
EOF

# name pattern (uppercase + consecutive hyphen) and dir mismatch.
d="$temp_dir/red-badname"; mkdir -p "$d"
cat > "$d/SKILL.md" <<'EOF'
---
name: Red--Name
description: Use this when names go wrong.
---
Body.
EOF

# no frontmatter fence at all.
d="$temp_dir/red-nofm"; mkdir -p "$d"
cat > "$d/SKILL.md" <<'EOF'
# just markdown, no frontmatter
Use this when you forgot the fence.
EOF

# broken relative link. The skill BUNDLES references/, so a references/ ref is
# in-scope; the target file is missing → flagged. A repo-relative scripts/ ref
# (no bundled scripts/ dir) must stay out of scope and NOT be flagged.
d="$temp_dir/red-brokenlink"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-brokenlink
description: Use this to test a dangling reference.
---
See [the guide](references/MISSING.md) for details.
Also runs scripts/custodian-history.sh (repo-relative, out of scope).
EOF

# reference nesting: references/a.md links to references/b.md (both exist).
d="$temp_dir/red-nesting"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-nesting
description: Use this when references chain too deep.
---
See [a](references/a.md).
EOF
cat > "$d/references/a.md" <<'EOF'
Now go read [b](references/b.md).
EOF
echo "leaf" > "$d/references/b.md"

# secret leak: a fake AWS key (documented example value, not a real credential).
d="$temp_dir/red-secret"; mkdir -p "$d"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-secret
description: Use this when a key gets pasted by mistake.
---
Example config: AKIAIOSFODNN7EXAMPLE
EOF

# intra-skill wiki-link: one slug resolves locally, a second does not → broken.
d="$temp_dir/red-wikilink"; mkdir -p "$d"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-wikilink
description: Use this when a local wiki-link dangles. See [[glossary]] and [[ghost]].
---
Body.
EOF
echo "terms" > "$d/glossary.md"

# unterminated frontmatter, prose body: opened with `---`, no closing fence, the
# body is plain prose (no `key:` lines). Without the structural check this passes
# silently clean — the fault must be named as its own violation.
d="$temp_dir/red-unterm-prose"; mkdir -p "$d"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-unterm-prose
description: Use this when the closing fence is forgotten.
Body prose with no closing fence.
EOF

# unterminated frontmatter, word:-line body: body lines (`Example:`, `Note:`) look
# like frontmatter keys. Without the structural check these cascade into misleading
# frontmatter-unknown-field findings that never name the real (missing-fence) fault.
d="$temp_dir/red-unterm-words"; mkdir -p "$d"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-unterm-words
description: Use this when body lines masquerade as keys.
Example: this line looks like a key.
Note: so does this one.
EOF

# A broken fence must NOT silence the frontmatter-independent secret scan. Each of
# the three malformed-frontmatter shapes (unterminated fence, missing opening
# fence, missing SKILL.md entirely) pairs its frontmatter violation with an AKIA
# secret planted in references/notes.md; both findings must surface in one pass.

# (1) unterminated fence + secret in references.
d="$temp_dir/red-unterm-secret"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
---
name: red-unterm-secret
description: Use this when a broken fence must not silence the secret scan.
Body prose with no closing fence.
EOF
cat > "$d/references/notes.md" <<'EOF'
Leaked example key: AKIAIOSFODNN7EXAMPLE
EOF

# (2) missing opening fence + secret in references.
d="$temp_dir/red-nofm-secret"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
# no frontmatter fence here
Use this when the fence is missing entirely.
EOF
cat > "$d/references/notes.md" <<'EOF'
Leaked example key: AKIAIOSFODNN7EXAMPLE
EOF

# (3) no SKILL.md at all + secret in references: the dir-level secret scan must
# still run with zero SKILL.md present.
d="$temp_dir/red-nofile-secret"; mkdir -p "$d/references"
cat > "$d/references/notes.md" <<'EOF'
Leaked example key: AKIAIOSFODNN7EXAMPLE
EOF

out=$("$linter" \
  "$temp_dir/red-unknown" "$temp_dir/red-nodesc" "$temp_dir/red-badname" \
  "$temp_dir/red-nofm" "$temp_dir/red-brokenlink" "$temp_dir/red-nesting" \
  "$temp_dir/red-secret" "$temp_dir/red-wikilink" \
  "$temp_dir/red-unterm-prose" "$temp_dir/red-unterm-words" \
  "$temp_dir/red-unterm-secret" "$temp_dir/red-nofm-secret" \
  "$temp_dir/red-nofile-secret")
rc=$?

[ "$rc" -eq 1 ] && result=0 || result=1;                          check "RED: exit code is 1" "$result"
printf '%s\n' "$out" | grep -q 'frontmatter-unknown-field.*red-unknown';    check "RED: unknown field flagged" $?
printf '%s\n' "$out" | grep -q 'frontmatter-required.*red-nodesc';          check "RED: missing description flagged" $?
printf '%s\n' "$out" | grep -q 'name-pattern.*red-badname';                 check "RED: bad name pattern flagged" $?
printf '%s\n' "$out" | grep -q 'name-mismatch.*red-badname';                check "RED: name/dir mismatch flagged" $?
printf '%s\n' "$out" | grep -q 'frontmatter-missing.*red-nofm';             check "RED: missing frontmatter flagged" $?
printf '%s\n' "$out" | grep -q 'broken-link.*red-brokenlink.*MISSING';       check "RED: broken relative link flagged" $?
# The repo-relative scripts/ ref in that same fixture must NOT be flagged.
! printf '%s\n' "$out" | grep -q 'broken-link.*custodian-history';           check "RED: repo-relative ref not flagged" $?
printf '%s\n' "$out" | grep -q 'reference-nesting.*red-nesting';            check "RED: reference nesting flagged" $?
printf '%s\n' "$out" | grep -q 'secret-leak.*red-secret';                    check "RED: secret leak flagged" $?
printf '%s\n' "$out" | grep -q 'broken-link.*ghost';                        check "RED: dangling wiki-link flagged" $?
# The resolving wiki-link must NOT be flagged.
! printf '%s\n' "$out" | grep -q 'glossary';                                check "RED: resolving wiki-link not flagged" $?
printf '%s\n' "$out" | grep -q 'frontmatter-unterminated.*red-unterm-prose'; check "RED: unterminated frontmatter (prose body) flagged" $?
printf '%s\n' "$out" | grep -q 'frontmatter-unterminated.*red-unterm-words'; check "RED: unterminated frontmatter (word-line body) flagged" $?
# The word:-line body must NOT cascade misleading frontmatter-unknown-field findings.
! printf '%s\n' "$out" | grep -q 'frontmatter-unknown-field.*red-unterm-words'; check "RED: unterminated body does not cascade unknown-field" $?

# A malformed frontmatter must NOT suppress the secret scan: each shape emits BOTH
# its frontmatter violation AND the references/ secret leak, in one pass.
printf '%s\n' "$out" | grep -q 'frontmatter-unterminated.*red-unterm-secret';       check "RED: unterminated+secret — fence flagged" $?
printf '%s\n' "$out" | grep -q 'secret-leak.*red-unterm-secret.*notes.md';          check "RED: unterminated+secret — secret still scanned" $?
printf '%s\n' "$out" | grep -q 'frontmatter-missing.*red-nofm-secret';              check "RED: no-fence+secret — fence flagged" $?
printf '%s\n' "$out" | grep -q 'secret-leak.*red-nofm-secret.*notes.md';            check "RED: no-fence+secret — secret still scanned" $?
printf '%s\n' "$out" | grep -q 'frontmatter-missing.*red-nofile-secret';            check "RED: no-SKILL.md+secret — missing file flagged" $?
printf '%s\n' "$out" | grep -q 'secret-leak.*red-nofile-secret.*notes.md';          check "RED: no-SKILL.md+secret — secret still scanned" $?

# ── GREEN fixture: fully spec-clean, all four optional fields, resolving refs ───
d="$temp_dir/green-skill"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
---
name: green-skill
description: Extracts and validates things. Use this when the user asks to check a thing.
license: MIT
compatibility: Requires bash and jq
metadata:
  author: looper
  version: "1.0"
allowed-tools: Read Grep
---
See [the reference](references/REFERENCE.md) for the full table.
EOF
echo "# reference, no deeper links" > "$d/references/REFERENCE.md"

out=$("$linter" "$temp_dir/green-skill"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                         check "GREEN: exit code is 0" "$result"
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 0';             check "GREEN: zero violations" $?
! printf '%s\n' "$out" | grep -q '^VIOLATION';                   check "GREEN: no VIOLATION lines" $?

# ── ADVISORY-only fixture: structurally clean but over the body budget ─────────
# Must produce an INFO advisory yet still exit 0 (advisories never fail the run).
d="$temp_dir/adv-skill"; mkdir -p "$d"
{
  echo '---'
  echo 'name: adv-skill'
  echo 'description: A big skill. Use this when the body is deliberately large.'
  echo '---'
  # ~24000 chars ≈ ~6000 tokens > 5000 budget, and > 500 lines.
  i=0; while [ "$i" -lt 700 ]; do
    echo 'This is a deliberately long body line to blow past the advisory token and line budgets.'
    i=$((i + 1))
  done
} > "$d/SKILL.md"

out=$("$linter" "$temp_dir/adv-skill"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                         check "ADVISORY: exit code is 0 (advisory never fails)" "$result"
printf '%s\n' "$out" | grep -q 'adv-body-budget.*adv-skill';     check "ADVISORY: body token budget flagged as INFO" $?
printf '%s\n' "$out" | grep -q 'adv-body-lines.*adv-skill';      check "ADVISORY: body line budget flagged as INFO" $?
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 0';            check "ADVISORY: zero structural violations" $?

# ── Context-file advisory: a >150-line CLAUDE.md, exits 0 ──────────────────────
cf="$temp_dir/CLAUDE.md"
i=0; while [ "$i" -lt 160 ]; do echo "context line $i"; i=$((i + 1)); done > "$cf"
out=$("$linter" "$cf"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                         check "CONTEXT: over-long context file exits 0" "$result"
printf '%s\n' "$out" | grep -q 'adv-context-lines.*CLAUDE.md';   check "CONTEXT: line budget flagged as INFO" $?

# ── G-a: a dangling markdown link is a violation with NO references/ dir ────────
# The link target's nonexistence is the violation; the subdir's existence is
# irrelevant. The resolving-link direction (green) is covered by the GREEN
# fixture above, whose references/REFERENCE.md link resolves cleanly.
d="$temp_dir/ga-nodir"; mkdir -p "$d"      # deliberately NO references/ subdir
cat > "$d/SKILL.md" <<'EOF'
---
name: ga-nodir
description: Use this when a markdown link dangles with no references dir.
---
See [notes](references/gone.md).
EOF
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1;                         check "G-a: dangling link without references/ dir exits 1" "$result"
printf '%s\n' "$out" | grep -q 'broken-link.*ga-nodir.*references/gone.md'; check "G-a: dangling link flagged with no references/ dir" $?
n=$(printf '%s\n' "$out" | grep -c '^VIOLATION')
[ "$n" -eq 1 ] && result=0 || result=1;                          check "G-a: exactly one violation, no spurious extras" "$result"

# ── G-c: a single broken link is counted exactly ONCE ─────────────────────────
# The target matches both the markdown-link grep and the bare-token grep on the
# same line; the two must collapse to one finding, not inflate the count.
d="$temp_dir/gc-count"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
---
name: gc-count
description: Use this when one broken link must count once.
---
See [x](references/gone.md).
EOF
out=$("$linter" "$d")
n=$(printf '%s\n' "$out" | grep -c 'broken-link')
[ "$n" -eq 1 ] && result=0 || result=1;                          check "G-c: single broken link yields exactly one broken-link finding" "$result"
printf '%s\n' "$out" | grep -q 'structural violations: 1';       check "G-c: structural count is 1, not double-counted" $?

# ── G-b: a reference file nested deeper than one level is a violation ──────────
# references/a/b/c.md (two subdir levels deep) with a link to it → nesting
# violation. The direct-child (green) direction is covered by the GREEN fixture
# (references/REFERENCE.md) and the red-nesting fixture's depth-1 files.
d="$temp_dir/gb-deep"; mkdir -p "$d/references/a/b"
cat > "$d/SKILL.md" <<'EOF'
---
name: gb-deep
description: Use this when a reference file is nested too deep.
---
See [deep](references/a/b/c.md).
EOF
echo "leaf" > "$d/references/a/b/c.md"
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1;                         check "G-b: two-level nested reference exits 1" "$result"
printf '%s\n' "$out" | grep -q 'reference-nesting.*a/b/c.md';    check "G-b: nested reference file cited in nesting violation" $?

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
