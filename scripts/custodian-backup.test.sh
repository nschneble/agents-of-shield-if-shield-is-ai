#!/usr/bin/env bash
# both-directions test; background: docs/test-suites.md#custodian-backup
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/custodian-backup.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
temp_dir=$(cd "$temp_dir" && pwd -P) || die_temp "cannot resolve $temp_dir"
trap 'chmod -R u+rw "$temp_dir" 2>/dev/null; rm -rf "$temp_dir"' EXIT

fails=0
checks=0
check() { # desc, condition-already-evaluated ($?)
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
has() { printf '%s\n' "$out" | grep -qxF -- "$1"; }

home="$temp_dir/custodian"
mem="$temp_dir/memory"
mkdir -p "$home" "$mem/sub" || die_temp "cannot create fixture dirs"
run() { out=$(CUSTODIAN_HOME="$home" "$runner" "$@" 2>&1); rc=$?; }
seed() { echo "a v1" > "$mem/a.md"; echo "b v1" > "$mem/sub/b.md"; echo "index v1" > "$mem/MEMORY.md"; }

# --- snapshot: one dir, every file, manifest written ---
seed
run snapshot --issue 94 --date 2026-10-01 --tag B-merge-1 "$mem/a.md" "$mem/MEMORY.md" \
  --tag B-retire-2 "$mem/sub/b.md" "$mem/MEMORY.md"
b1="$home/2026-10-01/backup-94-1"
[ "$rc" -eq 0 ]; check "SNAPSHOT: exits 0 (got $rc)" $?
has "$(printf 'snapshot\t%s\t3 file(s)' "$b1")"; check "SNAPSHOT: names the dir and dedupes a twice-tagged file" $?
cmp -s "$b1/files$mem/a.md" "$mem/a.md" && cmp -s "$b1/files$mem/sub/b.md" "$mem/sub/b.md"
check "SNAPSHOT: copies are byte-identical" $?
jq -e --arg p "$mem/MEMORY.md" '.entries[] | select(.original == $p) | .tags == ["B-merge-1","B-retire-2"]' \
  "$b1/manifest.json" >/dev/null
check "SNAPSHOT: a file two items touch carries both tags" $?
jq -e --arg p "$mem/sub/b.md" '.issue == 94 and .seq == 1 and .date == "2026-10-01"
  and (.entries[] | select(.original == $p) | .tags == ["B-retire-2"] and .backup == ("files" + $p))' \
  "$b1/manifest.json" >/dev/null
check "SNAPSHOT: manifest records issue, seq, original, backup and tag" $?

(cd "$mem" && CUSTODIAN_HOME="$home" "$runner" snapshot --issue 94 --date 2026-10-01 --tag T a.md >/dev/null 2>&1)
jq -e --arg p "$mem/a.md" '.entries[0].original == $p' "$home/2026-10-01/backup-94-2/manifest.json" >/dev/null
check "SNAPSHOT: a second snapshot takes the next seq; relative paths go absolute" $?

# --- snapshot refuses before writing anything ---
run snapshot --issue 94 "$mem/a.md"
[ "$rc" -eq 2 ]; check "REFUSE: a file before any --tag exits 2 (got $rc)" $?
run snapshot --issue x --tag T "$mem/a.md"
[ "$rc" -eq 2 ]; check "REFUSE: a non-numeric issue exits 2 (got $rc)" $?
run snapshot --issue 94 --tag T "$mem/missing.md"
[ "$rc" -eq 2 ]; check "REFUSE: a missing file exits 2 (got $rc)" $?
run snapshot --issue 94 --tag T "$mem/sub"
[ "$rc" -eq 2 ]; check "REFUSE: a directory exits 2 (got $rc)" $?
[ "$(find "$home" -name 'backup-*' | grep -c .)" -eq 2 ]
check "REFUSE: no refused call created a backup dir" $?

# --- a partial copy writes no manifest and exits 1 ---
if [ "$(id -u)" -ne 0 ]; then
  echo locked > "$mem/locked.md"; chmod 000 "$mem/locked.md"
  run snapshot --issue 95 --date 2026-10-02 --tag T "$mem/a.md" "$mem/locked.md"
  [ "$rc" -eq 1 ]; check "PARTIAL: an unreadable file exits 1 (got $rc)" $?
  printf '%s\n' "$out" | grep -q '^PARTIAL'; check "PARTIAL: says so" $?
  [ ! -e "$home/2026-10-02/backup-95-1/manifest.json" ]
  check "PARTIAL: no manifest, so the dir is never a snapshot" $?
  run undo --issue 95
  [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'incomplete'
  check "PARTIAL: undo refuses rather than falling back to an older apply" $?
  chmod 644 "$mem/locked.md"
  mv "$home/2026-10-02" "$temp_dir/held-partial"
fi

# --- undo restores the latest snapshot, idempotently ---
echo "a OLDER" > "$mem/a.md"; echo "b EDITED" > "$mem/sub/b.md"; rm "$mem/MEMORY.md"
run snapshot --issue 96 --date 2026-09-30 --tag older "$mem/a.md"
seed; echo "a EDITED" > "$mem/a.md"
CUSTODIAN_HOME="$home" "$runner" snapshot --issue 97 --date 2026-10-01 --tag T "$mem/a.md" "$mem/sub/b.md" "$mem/MEMORY.md" >/dev/null 2>&1
b3="$home/2026-10-01/backup-97-3"
echo "a NEWER" > "$mem/a.md"; rm "$mem/MEMORY.md"
before=$(cd "$home" && find . -type f -exec cksum {} + | sort)
run undo --issue 97
[ "$rc" -eq 0 ]; check "UNDO: exits 0 (got $rc)" $?
has "$(printf 'restored\t%s\tT' "$mem/a.md")"; check "UNDO: an edited file is restored" $?
has "$(printf 'restored\t%s\tT' "$mem/MEMORY.md")"; check "UNDO: a deleted file is restored" $?
has "$(printf 'unchanged\t%s\tT' "$mem/sub/b.md")"; check "UNDO: a matching file is left alone" $?
[ "$(cat "$mem/a.md")" = "a EDITED" ] && [ "$(cat "$mem/MEMORY.md")" = "index v1" ]
check "UNDO: restores the newest snapshot (97-3 on 10-01), not an older date or seq" $?
has "$(printf 'undo\t%s\trestored=2 unchanged=1 failed=0' "$b3")"; check "UNDO: summary names the dir and counts" $?
[ "$(cd "$home" && find . -type f -exec cksum {} + | sort)" = "$before" ]
check "UNDO: never deletes or alters the backup it restored from" $?
run undo --issue 97
has "$(printf 'no-op\t%s\tevery file already matches the snapshot' "$b3")"
check "UNDO: a second undo is a no-op and says so" $?
has "$(printf 'undo\t%s\trestored=0 unchanged=3 failed=0' "$b3")"; check "UNDO: the no-op restores nothing" $?

# --- undo refuses unusable input ---
run undo extra
[ "$rc" -eq 2 ]; check "UNDO REFUSE: an argument exits 2 (got $rc)" $?
mkdir -p "$home/2026-10-03/backup-89-1"
echo '{"issue":89,"namespaces":[]}' > "$home/2026-10-03/backup-89-1/manifest.json"
run undo --issue 89
[ "$rc" -eq 2 ] && [ "$(cat "$mem/a.md")" = "a EDITED" ]
check "UNDO REFUSE: a newest manifest in another shape exits 2, restores nothing" $?
mkdir -p "$home/2026-10-04/backup-90-1/files$mem"
jq -n --arg p "$mem/a.md" '{issue:90,date:"2026-10-04",seq:1,entries:[{original:$p,backup:("files"+$p),tags:["T"]}]}' \
  > "$home/2026-10-04/backup-90-1/manifest.json"
run undo --issue 90
[ "$rc" -eq 2 ] && [ "$(cat "$mem/a.md")" = "a EDITED" ]
check "UNDO REFUSE: a snapshot missing its copy exits 2, restores nothing" $?
out=$(CUSTODIAN_HOME="$temp_dir/empty-home" "$runner" undo --issue 1 2>&1); rc=$?
[ "$rc" -eq 2 ]; check "UNDO REFUSE: no snapshot at all exits 2 (got $rc)" $?
run bogus
[ "$rc" -eq 2 ]; check "USAGE: an unknown subcommand exits 2 (got $rc)" $?

# --- undo is per issue; a create-only apply is a clean no-op ---
home="$temp_dir/issue-home"; f="$temp_dir/issue-files"; mkdir -p "$f"
echo a1 > "$f/a"; echo b1 > "$f/b"
run snapshot --issue 10 --date 2026-10-05 --tag X "$f/a"; echo a2 > "$f/a"
run snapshot --issue 11 --date 2026-10-05 --tag Y "$f/b"; echo b2 > "$f/b"
run snapshot --issue 12 --date 2026-10-05
[ "$rc" -eq 0 ] && jq -e '.issue == 12 and .entries == []' "$home/2026-10-05/backup-12-3/manifest.json" >/dev/null
check "ISSUE: a zero-file snapshot writes an empty manifest (got $rc)" $?
echo "edited by hand" > "$f/a"
run undo --issue 12
[ "$rc" -eq 0 ] && [ "$(cat "$f/a")" = "edited by hand" ] && [ "$(cat "$f/b")" = b2 ] \
  && has "$(printf 'no-op\t%s\tevery file already matches the snapshot' "$home/2026-10-05/backup-12-3")"
check "ISSUE: undo of a create-only apply touches nothing (got $rc)" $?
run undo --issue 11
[ "$rc" -eq 2 ] && [ "$(cat "$f/b")" = b2 ] && printf '%s\n' "$out" | grep -q 'issue 12'
check "ISSUE: undo refuses when the newest snapshot is another issue's" $?
run undo
[ "$rc" -eq 2 ]; check "ISSUE: undo without --issue exits 2 (got $rc)" $?

# --- a refused snapshot leaves no backup dir behind ---
home="$temp_dir/shim-home"; shim="$temp_dir/shim"; mkdir -p "$shim"
real_jq=$(command -v jq)
printf '#!/usr/bin/env bash\nfor a; do [ "$a" = seq ] && exit 5; done\nexec %q "$@"\n' "$real_jq" > "$shim/jq"
chmod +x "$shim/jq"
echo c1 > "$f/c"
run snapshot --issue 20 --date 2026-10-06 --tag T "$f/c"
out=$(PATH="$shim:$PATH" CUSTODIAN_HOME="$home" "$runner" snapshot --issue 21 --date 2026-10-06 --tag T "$f/c" 2>&1); rc=$?
[ "$rc" -eq 2 ] && [ "$(find "$home" -name 'backup-*' | grep -c .)" -eq 1 ]
check "NO MANIFEST: a snapshot that cannot build its manifest creates no dir (got $rc)" $?
echo c2 > "$f/c"; run undo --issue 20
[ "$rc" -eq 0 ] && [ "$(cat "$f/c")" = c1 ]; check "NO MANIFEST: the prior snapshot still undoes" $?

# --- a symlinked original is snapshotted and restored as the link ---
home="$temp_dir/link-home"; target="$temp_dir/agent-target.md"
echo "agent v1" > "$target"; ln -s "$target" "$f/agent.md"
run snapshot --issue 30 --date 2026-10-07 --tag L "$f/agent.md"
bl="$home/2026-10-07/backup-30-1/files$f/agent.md"
[ "$rc" -eq 0 ] && [ -L "$bl" ] && [ "$(readlink "$bl")" = "$target" ]
check "LINK: the snapshot holds the link itself (got $rc)" $?
rm "$f/agent.md"; echo "agent replaced" > "$f/agent.md"
run undo --issue 30
[ "$rc" -eq 0 ] && [ -L "$f/agent.md" ] && [ "$(readlink "$f/agent.md")" = "$target" ] \
  && [ "$(cat "$target")" = "agent v1" ]
check "LINK: undo puts the link back over a file that replaced it (got $rc)" $?
rm "$f/agent.md"; cp "$target" "$f/agent.md"
run undo --issue 30
[ "$rc" -eq 0 ] && [ -L "$f/agent.md" ]; check "LINK: a same-bytes file in the link's place is restored" $?
echo "agent v2" > "$f/agent.md"
run undo --issue 30
[ "$rc" -eq 0 ] && [ "$(cat "$target")" = "agent v2" ] && has "$(printf 'unchanged\t%s\tL' "$f/agent.md")"
check "LINK: an edit through the link is not undone; the link already matches" $?

# --- a restore never follows a link standing in the original's place ---
home="$temp_dir/dirlink-home"; d1="$temp_dir/d1"; d2="$temp_dir/d2"
mkdir -p "$d1" "$d2"; ln -s "$d1" "$f/dirlink"
run snapshot --issue 31 --date 2026-10-08 --tag DL "$f/dirlink"
[ "$rc" -eq 0 ]; check "DIR LINK: a link to a directory is snapshotted as the link (got $rc)" $?
rm "$f/dirlink"; ln -s "$d2" "$f/dirlink"
run undo --issue 31
[ "$rc" -eq 0 ] && [ -L "$f/dirlink" ] && [ "$(readlink "$f/dirlink")" = "$d1" ]
check "DIR LINK: undo re-points the link, not a copy inside its target (got $rc)" $?
[ -z "$(ls -A "$d2")" ] && [ -z "$(ls -A "$d1")" ]
check "DIR LINK: nothing is left inside either directory" $?
echo "plain v1" > "$f/plain"
run snapshot --issue 32 --date 2026-10-08 --tag P "$f/plain"
rm "$f/plain"; ln -s "$d2" "$f/plain"
run undo --issue 32
[ "$rc" -eq 0 ] && [ ! -L "$f/plain" ] && [ "$(cat "$f/plain")" = "plain v1" ] && [ -z "$(ls -A "$d2")" ]
check "DIR LINK: a file replaced by a link to a directory is restored in place (got $rc)" $?
rm "$f/plain"; mkdir "$f/plain"
run undo --issue 32
[ "$rc" -eq 1 ] && [ -d "$f/plain" ] && [ -z "$(ls -A "$f/plain")" ] \
  && has "$(printf 'failed\t%s\tP' "$f/plain")"
check "DIR LINK: a real directory in the original's place fails, untouched (got $rc)" $?

echo
if [ "$fails" -eq 0 ]; then echo "all $checks custodian-backup test(s) passed"; exit 0
else echo "$fails of $checks custodian-backup test(s) FAILED"; exit 1; fi
