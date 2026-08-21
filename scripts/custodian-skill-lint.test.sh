#!/usr/bin/env bash
# custodian-skill-lint.test.sh — both-directions test for the skill linter.
#
# Each STRUCTURAL check RED on its own violation, and an ADVISORY-only
# fixture still exits 0. Self-contained fixtures under a temp dir.
# Background: docs/test-suites.md#custodian-skill-lint
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

# reference cross-link: references/a.md links to references/b.md (both exist).
# ADVISORY since decision 29 — it stays in the RED batch to prove an advisory
# raises no violation while sitting beside twelve fixtures that do.
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
printf '%s\n' "$out" | grep -q 'INFO.*adv-reference-chain.*red-nesting';    check "RED: reference cross-link flagged as advisory" $?
! printf '%s\n' "$out" | grep -q 'VIOLATION.*red-nesting';                  check "RED: reference cross-link raises no violation" $?
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

# ── G-d: a cross-skill cite is another skill's, a bare sibling is this one's ───
# The two cites differ by nothing but the leading `skills/<other>/`. A
# fully qualified cross-skill cite names another skill's file and stays
# out of scope even though this skill bundles references/; the bare
# sibling is this skill's own and must still redden. Flagging the
# qualified one was silent until a skill both bundled references/ and
# cited another skill's reference.
d="$temp_dir/gd-qualified"; mkdir -p "$d/references"
printf 'x\n' > "$d/references/here.md"
cat > "$d/SKILL.md" <<'EOF'
---
name: gd-qualified
description: Use this when a qualified cross-skill path must stay out of scope.
---
Reuses the lint in `skills/loop-de-looper/references/state-schemas.md`.
Its own note lives in `references/here.md`.
EOF
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                          check "G-d: qualified cross-skill cite plus a resolving own ref exits 0" "$result"
! printf '%s\n' "$out" | grep -q 'state-schemas';                 check "G-d: qualified cross-skill cite is not read as this skill's own" $?
# Reverse: identical but for the bare sibling, which now dangles.
d="$temp_dir/gd-dangling"; mkdir -p "$d/references"
printf 'x\n' > "$d/references/here.md"
cat > "$d/SKILL.md" <<'EOF'
---
name: gd-dangling
description: Use this when a bare sibling dangles beside a qualified cite.
---
Reuses the lint in `skills/loop-de-looper/references/state-schemas.md`.
Its own note lives in `references/absent.md`.
EOF
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1;                          check "G-d: a dangling bare skill-relative token still exits 1" "$result"
printf '%s\n' "$out" | grep -q 'broken-link.*gd-dangling.*references/absent.md'; check "G-d: the dangling bare token is the finding" $?
! printf '%s\n' "$out" | grep -q 'state-schemas';                 check "G-d: and the qualified cite stays out of scope on the red path" $?

# ── G-e: a leading `./` starts a path, bare or backticked ─────────────────────
# `./references/x.md` IS skill-relative — the char before `references`
# is `/`, so a "preceded by a non-path char" test drops it and a
# genuinely broken ref goes invisible. Two distinct targets, so the
# backticked and bare spellings are each pinned rather than collapsing
# into one deduped finding.
d="$temp_dir/ge-dotslash"; mkdir -p "$d/references"
printf 'x\n' > "$d/references/keep.md"
cat > "$d/SKILL.md" <<'EOF'
---
name: ge-dotslash
description: Use this when a dot-slash prose ref dangles.
---
The backticked note lives in `./references/gone-a.md` and nowhere else.
The bare one is ./references/gone-b.md instead.
EOF
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1;                          check "G-e: dangling ./ refs exit 1" "$result"
printf '%s\n' "$out" | grep -q 'broken-link.*ge-dotslash.*references/gone-a.md'; check "G-e: backticked ./ ref flagged" $?
printf '%s\n' "$out" | grep -q 'broken-link.*ge-dotslash.*references/gone-b.md'; check "G-e: bare ./ ref flagged" $?

# Green: the same two spellings resolving, plus a `../` parent escape
# that is NOT this skill's to resolve — resolve_ref rejects the escape
# on its own terms.
d="$temp_dir/ge-dotslash-ok"; mkdir -p "$d/references"
printf 'x\n' > "$d/references/keep-a.md"
printf 'x\n' > "$d/references/keep-b.md"
cat > "$d/SKILL.md" <<'EOF'
---
name: ge-dotslash-ok
description: Use this when dot-slash refs resolve and a parent escape does not count.
---
The backticked note lives in `./references/keep-a.md` and nowhere else.
The bare one is ./references/keep-b.md instead.
A sibling skill keeps ../references/elsewhere.md out of our reach.
EOF
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                          check "G-e: resolving ./ refs exit 0" "$result"
! printf '%s\n' "$out" | grep -q '^VIOLATION';                    check "G-e: no violation on the resolving path" $?
! printf '%s\n' "$out" | grep -q 'elsewhere';                     check "G-e: a ../ parent escape is not read as skill-relative" $?

# ── G-f: the same predicate applies to refs found INSIDE references/ ──────────
# scoped_refs scans SKILL.md; extract_refs scans files under
# references/ and feeds reference-nesting. A fixture citing only from
# SKILL.md never reaches extract_refs, so these three put the cite in
# references/note.md instead.
# Green: a cross-skill cite must not be read as this skill's own, even
# when the skill bundles a same-named reference file for the tail to
# collide with.
d="$temp_dir/gf-crossskill"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
---
name: gf-crossskill
description: Use this when a reference file cites another skill by full path.
---
See [note](references/note.md).
EOF
cat > "$d/references/note.md" <<'EOF'
Reuses the lint in `skills/loop-de-looper/references/state-schemas.md`.
EOF
printf 'x\n' > "$d/references/state-schemas.md"
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                          check "G-f: cross-skill cite from a reference file exits 0" "$result"
! printf '%s\n' "$out" | grep -q 'reference-nesting\|adv-reference-chain'; check "G-f: cross-skill cite raises neither nesting arm" $?

# Advisory 1: the same shape, but the cite is this skill's OWN file by full
# path — the prefix strips and the remainder is a real sibling cross-link.
d="$temp_dir/gf-own-fullpath"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
---
name: gf-own-fullpath
description: Use this when a reference file cites its own skill by full path.
---
See [note](references/note.md).
EOF
cat > "$d/references/note.md" <<'EOF'
Reuses the lint in `skills/gf-own-fullpath/references/state-schemas.md`.
EOF
printf 'x\n' > "$d/references/state-schemas.md"
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                          check "G-f: own-skill full-path cite from a reference file exits 0" "$result"
printf '%s\n' "$out" | grep -q 'INFO.*adv-reference-chain.*note.md.*state-schemas.md'; check "G-f: own-skill full-path cite is a cross-link advisory" $?

# Advisory 2: same, spelled `./` — pins the dot-slash arm of extract_refs'
# own grep.
d="$temp_dir/gf-own-dotslash"; mkdir -p "$d/references"
cat > "$d/SKILL.md" <<'EOF'
---
name: gf-own-dotslash
description: Use this when a reference file cites a sibling with a dot-slash path.
---
See [note](references/note.md).
EOF
cat > "$d/references/note.md" <<'EOF'
Reuses the lint in `./references/state-schemas.md`.
EOF
printf 'x\n' > "$d/references/state-schemas.md"
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                          check "G-f: dot-slash cite from a reference file exits 0" "$result"
printf '%s\n' "$out" | grep -q 'INFO.*adv-reference-chain.*note.md.*state-schemas.md'; check "G-f: dot-slash cite is a cross-link advisory" $?

# ── G-g: a skill's own fully qualified self-cite is still its own ─────────────
# `skills/<this-skill>/references/x.md` names a file this skill owns, so
# the prefix strips and the remainder resolves. Skipping it wholesale (as
# any `skills/`-prefixed token) would let a skill's own broken link go
# unreported.
d="$temp_dir/gg-selfcite"; mkdir -p "$d/references"
printf 'x\n' > "$d/references/keep.md"
cat > "$d/SKILL.md" <<'EOF'
---
name: gg-selfcite
description: Use this when a skill cites its own missing file by full path.
---
The note lives in `skills/gg-selfcite/references/gone.md` and nowhere else.
EOF
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 1 ] && result=0 || result=1;                          check "G-g: broken own-skill self-cite by full path exits 1" "$result"
printf '%s\n' "$out" | grep -q 'broken-link.*gg-selfcite.*references/gone.md'; check "G-g: broken own-skill self-cite flagged" $?

d="$temp_dir/gg-selfcite-ok"; mkdir -p "$d/references"
printf 'x\n' > "$d/references/keep.md"
cat > "$d/SKILL.md" <<'EOF'
---
name: gg-selfcite-ok
description: Use this when a skill cites its own present file by full path.
---
The note lives in `skills/gg-selfcite-ok/references/keep.md` and nowhere else.
EOF
out=$("$linter" "$d"); rc=$?
[ "$rc" -eq 0 ] && result=0 || result=1;                          check "G-g: resolving own-skill self-cite by full path exits 0" "$result"
! printf '%s\n' "$out" | grep -q '^VIOLATION';                    check "G-g: resolving own-skill self-cite raises nothing" $?

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
# Depth is structural, cross-linking is advisory — the two arms share a fixture
# shape, so pin that this one raises the violation and NOT the advisory name.
! printf '%s\n' "$out" | grep -q 'adv-reference-chain';          check "G-b: depth violation is not demoted to the advisory" $?

# ── G-h: one cite, every spelling, one verdict ────────────────────────────────
# The defect decision 29 fixes: `b.md` and `references/b.md` name the same file
# and got clean vs exit-1. A SIGNATURE is the exit code plus every finding as
# `TIER check basename`, sorted — the cite TEXT may differ between spellings,
# nothing else may, so equal signatures across spellings IS the invariant.
chain_sig() { # skill_dir -> "<rc>|TIER check base;TIER check base;..."
  local d="$1" out rc
  out=$("$linter" "$d" 2>&1); rc=$?
  printf '%s|%s\n' "$rc" "$(printf '%s\n' "$out" \
    | awk '/^(VIOLATION|INFO)/ { n = split($3, p, "/"); sub(/:$/, "", p[n]); print $1, $2, p[n] }' \
    | sort | tr '\n' ';')"
}

# Every fixture is byte-identical but for the one cite line, so any signature
# difference is the spelling and nothing else.
chain_fixture() { # name  cite-line -> skill dir
  local d="$temp_dir/$1"
  mkdir -p "$d/references"
  cat > "$d/SKILL.md" <<EOF
---
name: $1
description: Use this when one cite gets spelled more than one way.
---
See [a](references/a.md).
EOF
  printf '%s\n' "$2" > "$d/references/a.md"
  printf 'leaf\n' > "$d/references/b.md"
  printf '%s' "$d"
}

# Direction 1 — a sibling cite, five spellings. All must agree.
sig_bare=$(chain_sig "$(chain_fixture gh-bare      'Now go read `b.md` for the rest.')")
sig_pref=$(chain_sig "$(chain_fixture gh-prefixed  'Now go read `references/b.md` for the rest.')")
sig_dot=$(chain_sig  "$(chain_fixture gh-dotslash  'Now go read `./b.md` for the rest.')")
sig_mdb=$(chain_sig  "$(chain_fixture gh-mdbare    'Now go read [b](b.md) for the rest.')")
sig_mdp=$(chain_sig  "$(chain_fixture gh-mdprefix  'Now go read [b](references/b.md) for the rest.')")
# Line-START `./`, the one spelling whose leading char is inside the delimiter
# class — a normalizer that strips it leaves `/b.md`, which resolve_ref rejects
# as absolute, so the cite vanishes silently.
sig_lead=$(chain_sig "$(chain_fixture gh-leadslash './b.md is where the rest lives.')")

[ "$sig_bare" = "$sig_pref" ] && result=0 || result=1
check "G-h: bare and prefixed sibling cites get the SAME verdict" "$result"
[ "$sig_bare" = "$sig_dot" ] && result=0 || result=1
check "G-h: dot-slash sibling cite gets that same verdict" "$result"
[ "$sig_bare" = "$sig_mdb" ] && result=0 || result=1
check "G-h: markdown-link sibling cite gets that same verdict" "$result"
[ "$sig_bare" = "$sig_mdp" ] && result=0 || result=1
check "G-h: prefixed markdown-link sibling cite gets that same verdict" "$result"
[ "$sig_bare" = "$sig_lead" ] && result=0 || result=1
check "G-h: line-start dot-slash cite gets that same verdict" "$result"
# Pin what they agree ON, or five identical wrong answers would pass above.
[ "$sig_bare" = "0|INFO adv-reference-chain a.md;" ] && result=0 || result=1
check "G-h: and the shared verdict is one advisory, exit 0" "$result"

# Direction 2 — the toggle's off side. A cite pointing UP to SKILL.md is depth
# ZERO, so both spellings must stay silent; `[the body](SKILL.md)` used to fire.
sig_upmd=$(chain_sig   "$(chain_fixture gh-upmdlink 'Back up to [the body](SKILL.md) for the rule.')")
sig_upbare=$(chain_sig "$(chain_fixture gh-upbare   'Back up to `SKILL.md` for the rule.')")
[ "$sig_upmd" = "$sig_upbare" ] && result=0 || result=1
check "G-h: both spellings of an upward SKILL.md cite agree" "$result"
[ "$sig_upmd" = "0|" ] && result=0 || result=1
check "G-h: and they agree on silence — an upward cite is not a chain" "$result"
# A file naming itself is not a chain either, in both spellings — and `./a.md`
# only equals the file once the normalizer has taken the `./` off.
sig_self=$(chain_sig    "$(chain_fixture gh-self    'This file, `a.md`, is the one you are reading.')")
sig_selfdot=$(chain_sig "$(chain_fixture gh-selfdot 'This file, `./a.md`, is the one you are reading.')")
[ "$sig_self" = "$sig_selfdot" ] && result=0 || result=1
check "G-h: both spellings of a self-cite agree" "$result"
[ "$sig_self" = "0|" ] && result=0 || result=1
check "G-h: and they agree on silence — a file citing itself is not a chain" "$result"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
