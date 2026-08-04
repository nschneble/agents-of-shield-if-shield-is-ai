#!/usr/bin/env bash
# format-scope-gate.test.sh — both-directions test for the format-scope gate.
#
# Standing rule: a new invariant is tested RED (fires on a violating fixture) AND
# green (a clean fixture passes). Proves the gate's two failure modes each flag
# their own file, that exit is 1 on any violation and 0 when clean, and that the
# two carve-outs (a prettier-unsupported touched file; an unclean out-of-scope
# change) do NOT fire.
#
# Self-contained: prettier is stubbed by a fixture script injected via $PRETTIER,
# so the test needs no node/prettier install and runs in CI (which has neither).
# The stub mirrors prettier's exit codes keyed on sentinels in the file body:
#   @unsupported -> 2 (no parser) · @dirty -> 1 (style issues) · else -> 0 (clean).
# The gate's logic — not prettier's formatting rules — is what is under test, so a
# controlled verdict per fixture file is the right oracle. A real-prettier end-to-
# end pass is proven separately at build time and reported, not committed here.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gate="$here/format-scope-gate.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# stub prettier — see header. Last arg is the file `--check` was given.
stub="$temp_dir/prettier-stub.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
file="${!#}"
grep -q '@unsupported' "$file" 2>/dev/null && exit 2
grep -q '@dirty' "$file" 2>/dev/null && exit 1
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

# --- RED-B: an out-of-scope file was reformatted (clean, not declared) = drift. ---
rb="$temp_dir/redb"; mkdir -p "$rb"
printf '.a { color: red; }\n' > "$rb/a.css"       # touched, clean
printf 'const x = 1;\n'       > "$rb/vendor.js"   # changed, NOT touched, clean -> drift
printf 'a.css\nvendor.js\n'   > "$rb/changed.txt"
out=$(PRETTIER="$stub" "$gate" --dir "$rb" --changed "$rb/changed.txt" a.css); rc=$?
[ "$rc" -eq 1 ] && r=0 || r=1; check "RED-B: out-of-scope reformat (drift) fails (exit 1)" "$r"
printf '%s\n' "$out" | grep -q 'VIOLATION B .*full-tree drift.*vendor.js'; check "RED-B: cites the drifted out-of-scope file" $?

# --- CONTROL: both carve-outs present, must stay GREEN. ---
# logo.png is touched but prettier-unsupported -> note not violation (out-of-glob
# carve-out). notes.txt changed out-of-scope but UNCLEAN -> not format drift.
c="$temp_dir/control"; mkdir -p "$c"
printf '.a { color: red; }\n'  > "$c/a.css"
printf 'PNGDATA @unsupported\n' > "$c/logo.png"
printf 'raw @dirty\n'           > "$c/notes.txt"
printf 'a.css\nlogo.png\nnotes.txt\n' > "$c/changed.txt"
out=$(PRETTIER="$stub" "$gate" --dir "$c" --changed "$c/changed.txt" a.css logo.png); rc=$?
[ "$rc" -eq 0 ] && r=0 || r=1; check "CONTROL: unsupported-touched + unclean-out-of-scope stays clean (exit 0)" "$r"
printf '%s\n' "$out" | grep -q 'note .*unsupported/parse.*logo.png'; check "CONTROL: unsupported touched file is a note, not a violation" $?
! printf '%s\n' "$out" | grep -q 'notes.txt'; check "CONTROL: unclean out-of-scope file is NOT flagged as drift" $?

echo
if [ "$fails" -eq 0 ]; then echo "all format-scope-gate tests passed"; exit 0
else echo "$fails format-scope-gate test(s) FAILED"; exit 1; fi
