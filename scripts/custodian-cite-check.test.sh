#!/usr/bin/env bash
# custodian-cite-check.test.sh — both-directions test for the Phase B
# citation resolver: every verdict has a fixture that hits it and a near
# miss that must not, against a hermetic home and repos dir.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/custodian-cite-check.sh"
fingerprint="$here/custodian-fingerprint-cache.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'chmod -R u+rwx "$temp_dir" 2>/dev/null; rm -rf "$temp_dir"' EXIT

fails=0; checks=0
check() { # desc, condition-already-evaluated ($?)
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

H="$temp_dir/home"
R="$temp_dir/Repos"
C="$H/.claude"
mkdir -p "$C/skills/hs" "$C/agent-memory/the-x" "$R"
echo "home skill" > "$C/skills/hs/SKILL.md"

mkrepo() { mkdir -p "$R/$1"; git init -q "$R/$1"; }
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-content}" > "$1"; }
mkrepo alpha; mkrepo beta; mkrepo alpha-two
put "$R/alpha/scripts/tool.sh" $'#!/bin/sh\ndo_thing() { :; }\nexit 0'
put "$R/alpha/docs/guide.md" $'one\ntwo\nthree'
put "$R/alpha/docs/decisions/moved.md"
put "$R/alpha/lib/unique_sym.sh" 'rare_symbol_xyz=1'
put "$R/alpha/skills/s1/references/detail.md"
put "$R/alpha/shared/both.md" alpha-copy
put "$R/alpha/only-alpha/item.md"
put "$R/beta/shared/both.md" beta-copy
put "$R/beta/beta-only/thing.md"
put "$R/beta/.gitignore" 'local/'
put "$R/beta/node_modules/pkg/index.js"
put "$R/beta/local/scratch/kept-copy.md" 'scratch_only_sym'

# the encoder under test uses sed; this one uses tr on purpose
enc() { printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'; }
PA="$C/projects/$(enc "$R/alpha")/memory"
PB="$C/projects/$(enc "$R/beta")/memory"
PG="$C/projects/$(enc "$R/ghost-repo")/memory"
AM="$C/agent-memory/the-x"
mkdir -p "$PA" "$PB" "$PG"

out=""; rc=0
run() { out=$("$runner" --home "$H" --repos-dir "$R" "$@" 2>"$temp_dir/err"); rc=$?; }
row() { # verdict, kind, citation -> the matching output rows
  printf '%s\n' "$out" | awk -F'\t' -v v="$1" -v k="$2" -v c="$3" '$1 == v && $4 == k && $5 == c'
}
has_row() { [ -n "$(row "$1" "$2" "$3")" ]; }
detail_is() { row "$1" "$2" "$3" | awk -F'\t' -v d="$4" '$6 == d { f = 1 } END { exit !f }'; }
cited() { printf '%s\n' "$out" | awk -F'\t' -v c="$1" '$5 == c { f = 1 } END { exit !f }'; }

# --- RESOLVED, and line drift is not staleness ---
put "$PA/resolved.md" '- see `scripts/tool.sh` for the runner
- drifted `docs/guide.md:999` and a range `docs/guide.md:2-3`
- anchor form `scripts/tool.sh#L40`
- missing `scripts/nope-tool.sh` here'
run "$PA/resolved.md"
detail_is RESOLVED path scripts/tool.sh "$R/alpha/scripts/tool.sh"
check "RESOLVED: an existing repo-relative path resolves against its repo" $?
has_row RESOLVED path docs/guide.md:999
check "RESOLVED: a line number past EOF is drift, not staleness" $?
has_row RESOLVED path docs/guide.md:2-3
check "RESOLVED: a :start-end range on an existing file resolves" $?
has_row RESOLVED path 'scripts/tool.sh#L40'
check "RESOLVED: a #L anchor on an existing file resolves" $?
! has_row RESOLVED path scripts/nope-tool.sh
check "RESOLVED near miss: a missing path is not RESOLVED" $?

# --- MOVED vs GONE: the relocation search decides ---
put "$PA/moved.md" '- old `docs/moved.md` location
- vanished `docs/vanished.md` entirely
- relocated by symbol `lib/old_place.sh` holds `rare_symbol_xyz`
- no trace `lib/old_other.sh` holds `absent_symbol_q`
- partial `references/detail.md` path
- whole dir `skills/s1/`'
run "$PA/moved.md"
detail_is MOVED path docs/moved.md "$R/alpha/docs/decisions/moved.md"
check "MOVED: same basename elsewhere in the owning repo" $?
detail_is MOVED path lib/old_place.sh "$R/alpha/lib/unique_sym.sh"
check "MOVED: a line symbol found elsewhere relocates the path" $?
! has_row MOVED path docs/vanished.md && ! has_row MOVED path lib/old_other.sh
check "MOVED near miss: no basename or symbol hit is never MOVED" $?
row GONE path docs/vanished.md | grep -qF "find $R/alpha -path '*/docs/vanished.md' -o -name vanished.md: 0 hits"
check "GONE: an empty relocation search is GONE and quotes the search" $?
row GONE path lib/old_other.sh | grep -qF "grep -rlF -e absent_symbol_q $R/alpha"
check "GONE: the quoted search includes the line's symbol grep" $?
! has_row GONE path docs/moved.md && ! has_row GONE path lib/old_place.sh
check "GONE near miss: a relocation hit is never GONE" $?
detail_is RESOLVED path references/detail.md "$R/alpha/skills/s1/references/detail.md"
check "RESOLVED: a partial path matching as a suffix resolves, not MOVED" $?
detail_is RESOLVED path skills/s1/ "$R/alpha/skills/s1"
check "RESOLVED: a directory cite with a trailing slash resolves" $?

# --- symbols paired with a path ---
put "$PA/symbols.md" '- `scripts/tool.sh` defines `do_thing`
- `scripts/tool.sh` never defined `missing_fn_zz`
- `docs/guide.md` mentions `rare_symbol_xyz`'
run "$PA/symbols.md"
detail_is RESOLVED symbol do_thing "$R/alpha/scripts/tool.sh"
check "SYMBOL RESOLVED: grep -F finds it in the cited file" $?
has_row GONE symbol missing_fn_zz
check "SYMBOL GONE: absent from the file and the repo" $?
! has_row RESOLVED symbol missing_fn_zz
check "SYMBOL near miss: an absent symbol is not RESOLVED" $?
detail_is MOVED symbol rare_symbol_xyz "$R/alpha/lib/unique_sym.sh"
check "SYMBOL MOVED: absent from the cited file, present elsewhere" $?

# --- UNRESOLVED: no root, missing owner, dependency or ignored path ---
put "$PG/ghost.md" '- `scripts/tool.sh` in a repo nobody has'
run "$PG/ghost.md"
has_row UNRESOLVED path scripts/tool.sh
check "UNRESOLVED: a project dir whose owning repo is absent" $?
put "$PB/deps.md" '- dep `node_modules/pkg/index.js` installed
- dep `node_modules/other/index.js` not installed
- ignored `local/state.json` absent
- tracked `src/absent.ts` absent'
run "$PB/deps.md"
has_row RESOLVED path node_modules/pkg/index.js
check "UNRESOLVED near miss: an installed dependency path is RESOLVED" $?
has_row UNRESOLVED path node_modules/other/index.js
check "UNRESOLVED: an uninstalled node_modules path is never GONE" $?
has_row UNRESOLVED path local/state.json
check "UNRESOLVED: a gitignored path that is absent is never GONE" $?
has_row GONE path src/absent.ts
check "UNRESOLVED near miss: an absent tracked path is GONE" $?
plain="$temp_dir/elsewhere/plain.md"
put "$plain" '- `scripts/tool.sh` with no owning dir'
run "$plain"
has_row UNRESOLVED path scripts/tool.sh
check "UNRESOLVED: a repo-relative cite outside any memory dir has no root" $?
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$R/beta/sealed"; chmod 000 "$R/beta/sealed"
  put "$PB/sealed.md" '- `src/also-absent.ts` behind a sealed dir'
  run "$PB/sealed.md"
  row UNRESOLVED path src/also-absent.ts | grep -qF 'relocation search errored'
  check "UNRESOLVED: a relocation search that errored is never GONE" $?
  chmod 755 "$R/beta/sealed"
  run "$PB/sealed.md"
  has_row GONE path src/also-absent.ts
  check "UNRESOLVED near miss: the same search, readable, is GONE" $?
fi

# --- a fifo under a root is never opened: reading one blocks forever ---
fifo="$R/beta/pipe.fifo"
mkfifo "$fifo"
put "$PB/fifo.md" "- \`$fifo\` holds \`fifo_probe_sym\`"
"$runner" --home "$H" --repos-dir "$R" "$PB/fifo.md" >"$temp_dir/fifo.out" 2>&1 &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do sleep 0.2; waited=$((waited + 1)); done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null
  exec 4<>"$fifo"; exec 4>&-
  false
else
  wait "$pid"
  grep -q $'^GONE\t.*\tsymbol\tfifo_probe_sym\t' "$temp_dir/fifo.out"
fi
check "FIFO: a cited fifo and a fifo in the searched tree are skipped" $?
rm -f "$fifo"

# --- gitignored copies are not relocations ---
put "$PB/scratch.md" '- `docs/kept-copy.md` holds `scratch_only_sym`'
run "$PB/scratch.md"
has_row GONE path docs/kept-copy.md
check "MOVED near miss: a hit only in gitignored scratch is not MOVED" $?

# --- the 4-cell root table: memory location x cite form ---
put "$PA/cells.md" '- home `~/.claude/skills/hs/SKILL.md`
- home env `$HOME/.claude/skills/hs/SKILL.md`
- shared `shared/both.md`
- other repo `beta-only/thing.md`'
run "$PA/cells.md"
detail_is RESOLVED path '~/.claude/skills/hs/SKILL.md' "$C/skills/hs/SKILL.md"
check "ROOT project x ~/: resolves against the home root" $?
detail_is RESOLVED path '$HOME/.claude/skills/hs/SKILL.md' "$C/skills/hs/SKILL.md"
check "ROOT project x \$HOME/: resolves against the home root" $?
detail_is RESOLVED path shared/both.md "$R/alpha/shared/both.md"
check "ROOT project x relative: resolves against the owning repo only" $?
! has_row RESOLVED path beta-only/thing.md
check "ROOT project x relative near miss: another repo's file is not RESOLVED" $?
put "$AM/cells.md" '- home `~/.claude/skills/hs/SKILL.md`
- unnamed `beta-only/thing.md`
- named alpha only `beta-only/thing.md`
- in beta `shared/both.md`
- in alpha-two `only-alpha/item.md`
- in alpha `only-alpha/item.md`
- in Alpha capitalized `beta-only/thing.md`'
run "$AM/cells.md"
detail_is RESOLVED path '~/.claude/skills/hs/SKILL.md' "$C/skills/hs/SKILL.md"
check "ROOT agent x ~/: resolves against the home root" $?
[ "$(printf '%s\n' "$out" | awk -F'\t' '$3 == 2 && $1 == "RESOLVED" && $6 == "'"$R"'/beta/beta-only/thing.md"' | wc -l)" -eq 1 ]
check "ROOT agent x relative, no repo named: tries each configured repo" $?
[ "$(printf '%s\n' "$out" | awk -F'\t' '$3 == 3 && $1 != "RESOLVED"' | wc -l)" -eq 1 ]
check "ROOT agent x relative, repo named: only the named repo is tried" $?
[ "$(printf '%s\n' "$out" | awk -F'\t' '$3 == 4 && $6 == "'"$R"'/beta/shared/both.md"' | wc -l)" -eq 1 ]
check "ROOT agent x relative, beta named: beta's copy, not alpha's" $?
[ "$(printf '%s\n' "$out" | awk -F'\t' '$3 == 5 && $1 != "RESOLVED"' | wc -l)" -eq 1 ]
check "ROOT agent: naming alpha-two does not also name alpha" $?
[ "$(printf '%s\n' "$out" | awk -F'\t' '$3 == 6 && $1 == "RESOLVED"' | wc -l)" -eq 1 ]
check "ROOT agent: naming alpha resolves alpha's file" $?
[ "$(printf '%s\n' "$out" | awk -F'\t' '$3 == 7 && $1 != "RESOLVED"' | wc -l)" -eq 1 ]
check "ROOT agent: a repo named in another case still counts as named" $?
put "$PA/home-miss.md" '- `~/.claude/skills/hs/vanished.md` gone
- `~/.claude/skills/old-skill/SKILL.md` renamed'
run "$PA/home-miss.md"
row GONE path '~/.claude/skills/hs/vanished.md' | grep -qF "find $C -path"
check "ROOT home GONE: the relocation search ran under the home root" $?
detail_is MOVED path '~/.claude/skills/old-skill/SKILL.md' "$C/skills/hs/SKILL.md"
check "ROOT home MOVED: a located home cite found elsewhere is MOVED" $?

# --- fences and placeholders are not citations ---
put "$PA/prose.md" '```bash
cat `docs/fenced-gone.md`
```
- placeholders `<repo>/x.md` `some/dir/` `scripts/foo.sh` `references/b.md` `docs/.../y.md` `skills/*/SKILL.md` `wave-N.md`
- slash command `/loop-de-looper` and branch `origin/main`
- real `docs/unfenced-gone.md`'
run "$PA/prose.md"
! cited docs/fenced-gone.md
check "FENCE: a path inside a fenced block is not a citation" $?
has_row GONE path docs/unfenced-gone.md
check "FENCE near miss: the same shape outside a fence is checked" $?
n_placeholders=0
for p in '<repo>/x.md' some/dir/ scripts/foo.sh references/b.md 'docs/.../y.md' 'skills/*/SKILL.md' wave-N.md /loop-de-looper origin/main; do
  cited "$p" && n_placeholders=$((n_placeholders + 1))
done
[ "$n_placeholders" -eq 0 ]
check "PLACEHOLDER: placeholders, slash commands and branches are skipped ($n_placeholders cited)" $?

# --- bare names have no location, so never GONE ---
put "$PA/bare.md" '- bare `tool.sh` and `nonexistent-bare.sh`
- bare `tool.sh` beside `unanchored_sym_k`
- git state `.git/index.lock` is transient'
run "$PA/bare.md"
detail_is RESOLVED path tool.sh "$R/alpha/scripts/tool.sh"
check "BARE: a bare filename found under the root resolves" $?
has_row UNRESOLVED path nonexistent-bare.sh && ! has_row GONE path nonexistent-bare.sh
check "BARE: a bare filename found nowhere is UNRESOLVED, never GONE" $?
has_row UNRESOLVED symbol unanchored_sym_k && ! has_row GONE symbol unanchored_sym_k
check "SYMBOL: a symbol anchored only by a bare name is never GONE" $?
has_row UNRESOLVED path .git/index.lock
check "UNRESOLVED: a path under .git/ is transient state, never GONE" $?

# --- GONE needs every root searched; a narrow root only decides RESOLVED ---
E="$temp_dir/elsewhere"
put "$E/refs/proto-ref.md" 'linked_only_sym=1'
mkdir -p "$C/skills/linked"
ln -s "$E/refs" "$C/skills/linked/references"
put "$C/skills/hs/references/home-ref.md"
put "$C/skills/hs/notes.txt" 'visible_sym_m=1'
put "$R/beta/cross/cross-file.md" 'beta_only_sym=1'
put "$R/alpha/app/routes/[slug].tsx"
put "$R/alpha/app/routes/x.tsx"
put "$PA/wide.md" '- repo as first segment `beta/cross/cross-file.md`
- in beta `cross/cross-file.md`
- no repo named `cross/cross-file.md`
- home only `references/home-ref.md`
- brackets `app/[slug].tsx`
- bracket class `app/[x].tsx`
- absent `docs/nowhere-at-all.md`
- home relative `skills/hs/SKILL.md`
- `scripts/tool.sh` calls `beta_only_sym`'
run "$PA/wide.md"
detail_is RESOLVED path beta/cross/cross-file.md "$R/beta/cross/cross-file.md"
check "WIDE project: a cite led by a repo name resolves in that repo" $?
detail_is RESOLVED path cross/cross-file.md "$R/beta/cross/cross-file.md"
check "WIDE project: a repo named on the line resolves there" $?
[ "$(printf '%s\n' "$out" | awk -F'\t' '$3 == 3 && $1 == "MOVED" && $6 == "'"$R"'/beta/cross/cross-file.md"' | wc -l)" -eq 1 ]
check "WIDE project: another repo's file, unnamed, is MOVED, never GONE" $?
detail_is MOVED path references/home-ref.md "$C/skills/hs/references/home-ref.md"
check "WIDE project: a file only under the home root is MOVED, never GONE" $?
detail_is MOVED path 'app/[slug].tsx' "$R/alpha/app/routes/[slug].tsx"
check "LITERAL: brackets in a cited name are not a glob class" $?
has_row GONE path 'app/[x].tsx'
check "LITERAL near miss: [x].tsx does not match x.tsx" $?
gone_detail=$(row GONE path docs/nowhere-at-all.md | cut -f6)
n_roots=0
for r in "$C" "$R/alpha" "$R/alpha-two" "$R/beta"; do
  case "$gone_detail" in *"find $r -path"*) n_roots=$((n_roots + 1));; esac
done
[ "$n_roots" -eq 4 ]
check "INVARIANT: GONE quotes a search under every root ($n_roots of 4)" $?
has_row MOVED path skills/hs/SKILL.md
check "WIDE project near miss: a home-relative cite is not RESOLVED" $?
detail_is MOVED symbol beta_only_sym "$R/beta/cross/cross-file.md"
check "WIDE symbol: a symbol only in another repo is MOVED, never GONE" $?
put "$AM/wide.md" '- the beta flag lives in `only-alpha/item.md`
- home relative `skills/hs/SKILL.md`
- relinked `~/.claude/skills/gone-skill/references/proto-ref.md`
- the beta flag `docs/absent-named.md`'
run "$AM/wide.md"
detail_is MOVED path only-alpha/item.md "$R/alpha/only-alpha/item.md"
check "WIDE agent: a prose repo name does not narrow GONE to that repo" $?
detail_is RESOLVED path skills/hs/SKILL.md "$C/skills/hs/SKILL.md"
check "WIDE agent: an unnamed relative cite tries the home root" $?
detail_is MOVED path '~/.claude/skills/gone-skill/references/proto-ref.md' "$C/skills/linked/references/proto-ref.md"
check "SYMLINK: the home search follows a symlinked dir" $?
row GONE path docs/absent-named.md | grep -qF "find $R/alpha -path"
check "WIDE agent: GONE under a named repo still searched the others" $?
put "$AM/self.md" '- `~/.claude/skills/hs/vanished-self.md` held `self_only_sym`
- `~/.claude/skills/hs/vanished-vis.md` held `visible_sym_m`'
run "$AM/self.md"
has_row GONE path '~/.claude/skills/hs/vanished-self.md' && ! has_row MOVED symbol self_only_sym
check "MEMORY: the memory file's own text is never a relocation hit" $?
detail_is MOVED path '~/.claude/skills/hs/vanished-vis.md' "$C/skills/hs/notes.txt"
check "MEMORY near miss: the same symbol outside a memory dir is MOVED" $?
put "$C/agent-memory/the-y/moved-mem.md"
put "$AM/sibling-mem.md"
put "$AM/names.md" '- migrated `~/.claude/agent-memory/the-old/moved-mem.md`
- sibling `sibling-mem.md`
- itself `names.md`'
run "$AM/names.md"
detail_is MOVED path '~/.claude/agent-memory/the-old/moved-mem.md' "$C/agent-memory/the-y/moved-mem.md"
check "MEMORY: a memory file moved to another memory dir is MOVED, never GONE" $?
detail_is RESOLVED path sibling-mem.md "$AM/sibling-mem.md"
check "MEMORY: a bare name of a sibling memory file resolves" $?
! detail_is RESOLVED path names.md "$AM/names.md"
check "MEMORY near miss: a memory file never resolves a cite to itself" $?
run --pairs "$AM/self.md" "$AM/names.md"
! printf '%s\n' "$out" | awk -F'\t' '$1 == $2 { f = 1 } END { exit !f }'
check "MEMORY: --pairs never pairs a memory file with itself" $?
put "$R/beta/local/build/out.js"
put "$PB/ignored-suffix.md" '- build output `build/out.js` only in ignored scratch
- build output `build/other.js` nowhere'
run "$PB/ignored-suffix.md"
has_row UNRESOLVED path build/out.js && ! has_row GONE path build/out.js
check "IGNORED: a gitignored file at the cited path suffix is never GONE" $?
has_row GONE path build/other.js
check "IGNORED near miss: no copy at all is GONE" $?
put "$PB/dep-relative.md" '- package-relative `pkg/index.js` installed
- package-relative `pkg/never-shipped.js` absent'
run "$PB/dep-relative.md"
has_row UNRESOLVED path pkg/index.js && ! has_row GONE path pkg/index.js
check "DEPENDENCY: a path present under node_modules is never GONE" $?
has_row GONE path pkg/never-shipped.js
check "DEPENDENCY near miss: the same shape absent from node_modules is GONE" $?
put "$E/gamma-real/docs/deep/kept-gamma.md" 'gamma_link_sym=1'
git init -q "$E/gamma-real"
mkdir -p "$temp_dir/Repos2"
ln -s "$E/gamma-real" "$temp_dir/Repos2/gamma"
put "$AM/gamma.md" '- gamma `docs/kept-gamma.md`
- gamma `docs/old-gamma.md` holds `gamma_link_sym`
- symbol behind a link `~/.claude/skills/gone-three/old.txt` held `linked_only_sym`'
out=$("$runner" --home "$H" --repos-dir "$temp_dir/Repos2" "$AM/gamma.md" 2>/dev/null)
detail_is MOVED path docs/kept-gamma.md "$temp_dir/Repos2/gamma/docs/deep/kept-gamma.md"
check "SYMLINK: a symlinked repo root is searched" $?
detail_is MOVED path docs/old-gamma.md "$temp_dir/Repos2/gamma/docs/deep/kept-gamma.md"
check "SYMLINK: the symbol grep follows a symlinked repo root" $?
detail_is MOVED path '~/.claude/skills/gone-three/old.txt' "$C/skills/linked/references/proto-ref.md"
check "SYMLINK: the symbol grep follows a symlinked dir under home" $?
put "$temp_dir/shim/find" "#!/bin/sh
printf '%s\\n' \"\$2\" >> '$temp_dir/find.log'
exec '$(command -v find)' \"\$@\""
chmod +x "$temp_dir/shim/find"
PATH="$temp_dir/shim:$PATH" "$runner" --home "$H" --repos-dir "$R" "$PA/wide.md" >/dev/null 2>&1
[ -s "$temp_dir/find.log" ] && [ "$(sort "$temp_dir/find.log" | uniq -c | awk '$1 > 2' | wc -l)" -eq 0 ]
check "CACHE: each root is walked once per run, not once per search" $?
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$R/beta/sealed"; chmod 000 "$R/beta/sealed"
  run "$PA/wide.md"
  has_row UNRESOLVED path docs/nowhere-at-all.md && ! has_row GONE path docs/nowhere-at-all.md
  check "INVARIANT: an errored search under a non-owner root is never GONE" $?
  chmod 755 "$R/beta/sealed"
  put "$R/beta/local/locked.md" 'locked_probe_sym=1'
  chmod 000 "$R/beta/local/locked.md"
  put "$PB/locked.md" '- `src/absent-two.ts` holds `locked_probe_sym`'
  run "$PB/locked.md"
  has_row GONE path src/absent-two.ts
  check "IGNORED: an unreadable gitignored file is never searched" $?
  chmod 644 "$R/beta/local/locked.md"
fi

# --- summary and exit codes ---
run "$PA/symbols.md"
[ "$(printf '%s\n' "$out" | tail -1)" = $'summary\tcitations_total=6\tcitations_resolved=5\tresolved=4\tmoved=1\tgone=1\tunresolved=0' ]
check "SUMMARY: totals, resolved = RESOLVED + MOVED, per-verdict counts" $?
[ "$rc" -eq 1 ]
check "EXIT 1: any non-RESOLVED citation (got $rc)" $?
put "$PA/clean.md" '- `scripts/tool.sh` with `do_thing`'
run "$PA/clean.md"
[ "$rc" -eq 0 ]
check "EXIT 0: every citation RESOLVED (got $rc)" $?
run < <(printf '%s\n' "$PA/clean.md")
[ "$rc" -eq 0 ] && has_row RESOLVED symbol do_thing
check "STDIN: memory files read one per line from stdin" $?
run "$temp_dir/no-such.md"
[ "$rc" -eq 2 ]
check "EXIT 2: a missing memory file (got $rc)" $?
run --bogus "$PA/clean.md"
[ "$rc" -eq 2 ]
check "EXIT 2: an unknown flag (got $rc)" $?
run "$PA/clean.md" --repo
[ "$rc" -eq 2 ] && grep -qF -- '--repo needs a value' "$temp_dir/err"
check "EXIT 2: a flag missing its value (got $rc)" $?
"$runner" -h >/dev/null 2>&1
check "USAGE: -h exits 0" $?

# --- fingerprint feed pipes into the cache's diff ---
before=$(cat "$PA/moved.md" "$PA/resolved.md" | shasum -a 256)
run --pairs "$PA/resolved.md" "$PA/moved.md"
want=$(printf '%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n' \
  "$PA/resolved.md" "$R/alpha/scripts/tool.sh" \
  "$PA/resolved.md" "$R/alpha/docs/guide.md" \
  "$PA/resolved.md" "$R/alpha/docs/guide.md" \
  "$PA/resolved.md" "$R/alpha/scripts/tool.sh" \
  "$PA/moved.md" "$R/alpha/docs/decisions/moved.md" \
  "$PA/moved.md" "$R/alpha/lib/unique_sym.sh" \
  "$PA/moved.md" "$R/alpha/skills/s1/references/detail.md")
[ "$out" = "$want" ]
check "PAIRS: only RESOLVED/MOVED paths, as memory_file<TAB>abs" $?
! printf '%s\n' "$out" | grep -q "skills/s1$"
check "PAIRS: a RESOLVED directory is not a fingerprintable pair" $?
grep -qF 'citations_total=' "$temp_dir/err"
check "PAIRS: the summary moves to stderr" $?
export CACHE="$temp_dir/fingerprint-cache.json"
diffed=$(printf '%s\n' "$out" | "$fingerprint" diff 2>"$temp_dir/fp.err")
[ "$(printf '%s\n' "$diffed" | grep -c '^NEW')" -eq 7 ] && grep -qF 'gone=0' "$temp_dir/fp.err"
check "PAIRS: fingerprint diff reads them, all NEW, none GONE" $?
printf '%s\n' "$out" | while IFS=$'\t' read -r m p; do "$fingerprint" record "$m" "$p"; done
diffed=$(printf '%s\n' "$out" | "$fingerprint" diff 2>/dev/null)
[ "$(printf '%s\n' "$diffed" | grep -c '^UNCHANGED')" -eq 7 ]
check "PAIRS: recorded pairs come back UNCHANGED" $?
[ "$(cat "$PA/moved.md" "$PA/resolved.md" | shasum -a 256)" = "$before" ]
check "REPORT-ONLY: memory files are never edited" $?

echo
if [ "$fails" -eq 0 ]; then echo "all $checks custodian-cite-check test(s) passed"; exit 0
else echo "$fails of $checks custodian-cite-check test(s) FAILED"; exit 1; fi
