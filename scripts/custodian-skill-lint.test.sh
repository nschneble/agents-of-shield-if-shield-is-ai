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
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

fails=0
check() { # desc  rc-already-evaluated($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# Small helper to write a skill fixture: mkskill <dir> <SKILL.md-body-file-content>
mkskill() { mkdir -p "$1"; }

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

out=$("$linter" \
  "$temp_dir/red-unknown" "$temp_dir/red-nodesc" "$temp_dir/red-badname" \
  "$temp_dir/red-nofm" "$temp_dir/red-brokenlink" "$temp_dir/red-nesting" \
  "$temp_dir/red-secret" "$temp_dir/red-wikilink")
rc=$?

[ "$rc" -eq 1 ] && r=0 || r=1;                                     check "RED: exit code is 1" "$r"
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
[ "$rc" -eq 0 ] && r=0 || r=1;                                    check "GREEN: exit code is 0" "$r"
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
[ "$rc" -eq 0 ] && r=0 || r=1;                                    check "ADVISORY: exit code is 0 (advisory never fails)" "$r"
printf '%s\n' "$out" | grep -q 'adv-body-budget.*adv-skill';     check "ADVISORY: body token budget flagged as INFO" $?
printf '%s\n' "$out" | grep -q 'adv-body-lines.*adv-skill';      check "ADVISORY: body line budget flagged as INFO" $?
printf '%s\n' "$out" | grep -q 'TOTAL VIOLATIONS: 0';            check "ADVISORY: zero structural violations" $?

# ── Context-file advisory: a >150-line CLAUDE.md, exits 0 ──────────────────────
cf="$temp_dir/CLAUDE.md"
i=0; while [ "$i" -lt 160 ]; do echo "context line $i"; i=$((i + 1)); done > "$cf"
out=$("$linter" "$cf"); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1;                                    check "CONTEXT: over-long context file exits 0" "$r"
printf '%s\n' "$out" | grep -q 'adv-context-lines.*CLAUDE.md';   check "CONTEXT: line budget flagged as INFO" $?

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
