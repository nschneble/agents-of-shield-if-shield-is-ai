#!/usr/bin/env bash
# gate.test.sh — both-directions test for the format-scope gate.
#
# Standing rule: a new invariant is tested RED (fires on a violating
# fixture) AND green (a clean fixture passes). Proves the gate's two
# failure modes each flag their own file, that exit is 1 on any violation
# and 0 when clean, and that the two carve-outs (a prettier-unsupported
# touched file; an unclean out-of-scope change) do NOT fire.
#
# Covers the REAL-wave input path too: a GIT-DERIVED section runs the gate
# with no --changed, so it derives the changed set from git — the path the
# #41 review flagged as uncovered (every other case passes --changed and
# bypasses it).
#
# Self-contained: prettier is stubbed via $PRETTIER, so the test needs no
# node/prettier install and runs in CI. The stub mirrors prettier's exit
# codes keyed on sentinels in the file body: @unsupported -> 2 (no parser),
# @dirty -> 1 (style issues), else -> 0 (clean); --version -> 0 (the gate's
# pre-flight availability probe). The gate's logic — not prettier's
# formatting — is under test, so a controlled verdict per file is the right
# oracle. A real-prettier end-to-end pass is proven at build, not here.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gate="$here/gate.sh"
# a failing mktemp returns empty, which makes every derived path absolute
# (/gitderived). The mkdir and cd below then fail while silenced, leaving
# the GIT-DERIVED fixture commands running in the CALLER's repo, where they
# commit its working tree and overwrite its user.email. Refuse to run.
# The explicit template is what makes TMPDIR the input the message names:
# a bare `mktemp -d` ignores TMPDIR on BSD, allocating under /var/folders.
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
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# stub prettier — see header. Last arg is the file `--check` was given;
# `grep --` stops the sentinel being read as a grep option.
stub="$temp_dir/prettier-stub.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "0.0.0-stub"; exit 0; }
file="${!#}"
grep -q -- '@unsupported' "$file" 2>/dev/null && exit 2
grep -q -- '@dirty' "$file" 2>/dev/null && exit 1
exit 0
STUB
chmod +x "$stub"

# --- GREEN: only the touched file changed and it is prettier-clean. ---
g="$temp_dir/green"; mkdir -p "$g"
printf '.a { color: red; }\n' > "$g/a.css"
printf 'a.css\n' > "$g/changed.txt"
out=$(PRETTIER="$stub" "$gate" --dir "$g" --changed "$g/changed.txt" a.css); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "GREEN: scoped-clean wave passes (exit 0)" "$r"
printf '%s\n' "$out" | grep -q 'format-scope-gate: clean'; check "GREEN: reports clean" $?

# --- RED-A: a declared touched file is not prettier-clean. ---
ra="$temp_dir/reda"; mkdir -p "$ra"
printf '.a{color:red} @dirty\n' > "$ra/a.css"
printf 'a.css\n' > "$ra/changed.txt"
out=$(PRETTIER="$stub" "$gate" --dir "$ra" --changed "$ra/changed.txt" a.css); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "RED-A: unclean touched file fails (exit 1)" "$r"
printf '%s\n' "$out" | grep -q 'VIOLATION A .*not prettier-clean: a.css'; check "RED-A: cites the unclean touched file" $?

# --- RED-B: out-of-scope file reformatted (clean, not declared). ---
rb="$temp_dir/redb"; mkdir -p "$rb"
printf '.a { color: red; }\n' > "$rb/a.css"       # touched, clean
printf 'const x = 1;\n'       > "$rb/vendor.js"   # changed, NOT touched, clean
printf 'a.css\nvendor.js\n'   > "$rb/changed.txt"
out=$(PRETTIER="$stub" "$gate" --dir "$rb" --changed "$rb/changed.txt" a.css); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "RED-B: out-of-scope clean change fails (exit 1)" "$r"
printf '%s\n' "$out" | grep -q 'VIOLATION B .*vendor.js'; check "RED-B: cites the out-of-scope file" $?
printf '%s\n' "$out" | grep -q 'full-tree drift OR an undeclared edit'; check "RED-B: message names BOTH causes (#41 fix)" $?

# --- CONTROL: both carve-outs present, must stay GREEN. ---
# logo.png is touched but prettier-unsupported -> note not violation
# (out-of-glob carve-out). notes.txt changed out-of-scope but UNCLEAN ->
# not format drift.
c="$temp_dir/control"; mkdir -p "$c"
printf '.a { color: red; }\n'  > "$c/a.css"
printf 'PNGDATA @unsupported\n' > "$c/logo.png"
printf 'raw @dirty\n'           > "$c/notes.txt"
printf 'a.css\nlogo.png\nnotes.txt\n' > "$c/changed.txt"
out=$(PRETTIER="$stub" "$gate" --dir "$c" --changed "$c/changed.txt" a.css logo.png); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "CONTROL: unsupported-touched + unclean-out-of-scope stays clean (exit 0)" "$r"
printf '%s\n' "$out" | grep -q 'note .*unsupported/parse.*logo.png'; check "CONTROL: unsupported touched file is a note, not a violation" $?
! printf '%s\n' "$out" | grep -q 'notes.txt'; check "CONTROL: unclean out-of-scope file is NOT flagged as drift" $?

# --- GIT-DERIVED: the real-wave path (no --changed; gate reads git). ---
gd="$temp_dir/gitderived"; mkdir -p "$gd" || exit 2
(
  # never let the git fixture run in whatever the caller's CWD happens to be
  cd "$gd" || exit 2
  git init -q -b main
  git config user.email test@example.com
  git config user.name  test
  printf '.a { color: red; }\n' > a.css
  printf 'const x = 1;\n'       > vendor.js
  git add -A && git commit -q -m baseline
) >/dev/null 2>&1

# RED: an undeclared, clean, tracked change (what a full-tree format does)
# — the gate must derive it from git and fire VIOLATION B.
printf 'const x = 2;\n' > "$gd/vendor.js"   # still clean, still undeclared
out=$(PRETTIER="$stub" "$gate" --dir "$gd" a.css); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "GIT-DERIVED RED: undeclared clean change fails via git set (exit 1)" "$r"
printf '%s\n' "$out" | grep -q 'VIOLATION B .*vendor.js'; check "GIT-DERIVED RED: cites the git-derived out-of-scope file" $?

# GREEN: only the declared touched file changed — git set = [a.css], in
# scope, clean -> passes. Restore vendor.js to its committed bytes so git
# no longer reports it changed.
printf 'const x = 1;\n'         > "$gd/vendor.js"
printf '.a { color: green; }\n' > "$gd/a.css"
out=$(PRETTIER="$stub" "$gate" --dir "$gd" a.css); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "GIT-DERIVED GREEN: only-touched change passes via git set (exit 0)" "$r"

echo
if [ "$fails" -eq 0 ]; then echo "all format-scope gate tests passed"; exit 0
else echo "$fails format-scope gate test(s) FAILED"; exit 1; fi
