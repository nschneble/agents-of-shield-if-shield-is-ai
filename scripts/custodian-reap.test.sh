#!/usr/bin/env bash
# both-directions test; background: docs/test-suites.md#custodian-reap
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$here/custodian-reap.sh"

die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'chmod -R u+w "$temp_dir" 2>/dev/null; rm -rf "$temp_dir"' EXIT

fails=0
checks=0
check() { # desc, condition-already-evaluated ($?)
  checks=$((checks + 1))
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
has() { printf '%s\n' "$out" | grep -qxF -- "$1"; }

stub_bin="$temp_dir/bin"
mkdir -p "$stub_bin" || die_temp "cannot create $stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${GH_STUB_FAIL:-}" ] || { echo "gh: network down" >&2; exit 1; }
state=""; head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --state) state=$2; shift 2;;
    --head)  head=$2;  shift 2;;
    *) shift;;
  esac
done
row=$(awk -F'\t' -v s="$state" -v h="$head" '$1 == s && $2 == h { print $3 "\t" $4; exit }' "$GH_STUB_DB")
n=${row%%$'\t'*}; oid=${row#*$'\t'}
if [ -n "$n" ]; then printf '[{"number":%s,"headRefOid":"%s"}]\n' "$n" "$oid"; else echo '[]'; fi
STUB
chmod +x "$stub_bin/gh"

gitq() { git -C "$repo" -c user.email=fixture@test -c user.name=fixture "$@"; }
branch_commit() { # name — a branch off main carrying one commit
  gitq checkout -q -b "$1" main && echo "$1" > "$repo/$(echo "$1" | tr / -).txt" \
    && gitq add -A && gitq commit -q -m "$1" && gitq checkout -q main
}
gates() { # branch, line count — a gates.jsonl with n lines
  local i
  mkdir -p "$loops/$1"
  for i in $(seq 1 "$2"); do
    printf '{"wave":%d,"kind":"crew","agent":"the-stickler","ran":true,"blockers":0}\n' "$i"
  done > "$loops/$1/gates.jsonl"
}
index_upto() { # branch, n — index lines 1..n of its gates.jsonl under their cites
  local i
  for i in $(seq 1 "$2"); do
    printf '{"cite":"repo/local/loops/%s/gates.jsonl:%d"}\n' "$1" "$i"
  done >> "$home/history-index.jsonl"
}
index_all() { index_upto "$1" "$(grep -c . "$loops/$1/gates.jsonl")"; }
record() { # dir, commit — a run-state.json naming one shipped commit
  mkdir -p "$loops/$1"
  jq -n --arg c "$2" '{queue: [{wave: 1, status: "shipped", commit: $c}]}' > "$loops/$1/run-state.json"
}
sha() { gitq rev-parse "$1"; }

build() { # builds $repo with the full branch roster
  repo="$temp_dir/$1/repo"; home="$temp_dir/$1/custodian"; loops="$repo/local/loops"
  mkdir -p "$repo" "$home"
  git init -q -b main "$repo" || die_temp "git init failed in $repo"
  echo seed > "$repo/seed.txt"
  gitq add -A && gitq commit -q -m seed || die_temp "seed commit failed"
  gitq remote add origin "$temp_dir/no-such-origin.git" && gitq update-ref refs/remotes/origin/main main \
    && gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main || die_temp "origin/HEAD failed"
  for b in anc anc-open sq wip gone gonepr fix/slash ungated broken nest stray garbled tail reused; do
    branch_commit "$b" || die_temp "branch $b failed"
  done
  for b in anc anc-open fix/slash ungated broken nest stray garbled tail; do
    gitq merge -q --ff-only "$b" 2>/dev/null \
    || gitq merge -q --no-edit "$b" || die_temp "merge $b failed"; done
  gitq update-ref refs/remotes/origin/main main || die_temp "push origin/main failed"
  gitq branch -q fresh main || die_temp "branch fresh failed"
  for b in anc anc-open sq wip gone gonepr fix/slash ungated broken nest tail reused; do
    record "$b" "$(sha "$b")"
  done
  record stray "$(sha wip)"
  mkdir -p "$loops/fresh" "$loops/garbled"
  echo '{"queue":[{"wave":1,"status":"shipped-no-commit","commit":null}]}' > "$loops/fresh/run-state.json"
  echo '{not json' > "$loops/garbled/run-state.json"
  printf 'merged\tsq\t12\t%s\nmerged\treused\t30\t%s\nmerged\tgonepr\t31\t%s\n' \
    "$(sha sq)" "$(sha anc)" "$(sha gonepr)" > "$temp_dir/$1/gh.tsv"
  printf 'open\tanc-open\t7\t\nopen\twip\t\t\n' >> "$temp_dir/$1/gh.tsv"
  gitq branch -q -D gone gonepr || die_temp "delete gone failed"
  for b in anc anc-open sq fix/slash; do gates "$b" 2; index_all "$b"; done
  gates ungated 2; index_upto ungated 1
  gates tail 3; index_upto tail 2
  printf '%s' "$(cat "$loops/tail/gates.jsonl")" > "$loops/tail/gates.jsonl"
  printf '{"wave":1}\nnot json\n' > "$loops/broken/gates.jsonl"
  for b in main nest/inner; do mkdir -p "$loops/$b"; echo '{}' > "$loops/$b/run-state.json"; done
  mkdir -p "$loops/.claude/.cc-writes"; echo x > "$loops/.claude/.cc-writes/w"
  echo '{}' > "$loops/wip/run-state.json.tmp"
  echo '{}' > "$loops/anc/run-state.json.tmp"
}
run() { # command and args, run with the fixture env
  out=$(env REPO_ROOT="$repo" CUSTODIAN_HOME="$home" GH_STUB_DB="$temp_dir/$case/gh.tsv" \
    PATH="$stub_bin:$PATH" "$@" 2>&1); rc=$?
}
tree() { (cd "$loops" && find . | sort); }

# --- plan mode: every verdict, nothing deleted ---
case=plan; build "$case"
before=$(tree)
run "$runner"
[ "$rc" -eq 0 ]; check "PLAN: exits 0 (got $rc)" $?
has $'reap\tanc\tmerged (ancestry)'; check "PLAN: ancestry-merged branch reaps" $?
has $'reap\tsq\tmerged (PR #12)'; check "PLAN: squash-merged PR reaps without ancestry" $?
has $'keep\tanc-open\tkept (open PR #7)'; check "PLAN: an open PR keeps even a merged tip" $?
has $'keep\twip\tkept (unmerged)'; check "PLAN: unmerged branch is kept" $?
has $'keep\tgone\tkept (unmerged)'; check "PLAN: deleted unmerged branch is kept" $?
has $'reap\tfix/slash\tmerged (ancestry)'; check "PLAN: slash branch is one dir, reaped" $?
has $'keep\tungated\tkept (unindexed — ingest gap)'; check "PLAN: one unindexed gates line blocks the reap" $?
has $'keep\tbroken\tkept (unindexed — ingest gap)'; check "PLAN: unreadable gates.jsonl blocks the reap" $?
has $'keep\tmain\tkept (default branch)'; check "PLAN: the default branch's dir is kept" $?
has $'keep\tnest\tkept (nests branch dir nest/inner)'; check "PLAN: a dir nesting another branch dir is kept" $?
has $'clear\twip\trun-state.json.tmp'; check "PLAN: orphaned tmp on a kept dir is cleared" $?
has $'clear\tanc\trun-state.json.tmp'; check "PLAN: orphaned tmp on a reaped dir is cleared" $?
has $'keep\tfresh\tkept (merged tip, no recorded commit)'
check "PLAN: a branch with no commit of its own is not merged by ancestry" $?
has $'keep\tstray\tkept (recorded commit off origin/main)'; check "PLAN: a recorded commit off main blocks ancestry" $?
has $'keep\tgarbled\tkept (run-state.json unreadable)'; check "PLAN: an unreadable run-state blocks ancestry" $?
has $'keep\ttail\tkept (unindexed — ingest gap)'; check "PLAN: an unterminated last gates line is its own cite" $?
has $'keep\treused\tkept (unmerged)'; check "PLAN: a merged PR for another tip of the name does not count" $?
has $'reap\tgonepr\tmerged (PR #31)'; check "PLAN: a deleted branch's merged PR counts" $?
has $'skip\t.claude/.cc-writes\tnot a branch name'; check "PLAN: a dot-dir is skipped, not a branch dir" $?
! printf '%s\n' "$out" | grep -qE $'^(keep|reap)\t\\.claude'; check "PLAN: a dot-dir gets no verdict" $?
has $'summary\trepo\treap=4 keep=13 clear=2 failed=0 mode=plan'; check "PLAN: summary counts every dir" $?
[ "$(tree)" = "$before" ]; check "PLAN: deletes nothing without --apply" $?

# --- --default spelled as a ref still guards the default branch's dir ---
gitq update-ref refs/remotes/origin/main main
for spelling in origin/main refs/heads/main refs/remotes/origin/main; do
  run "$runner" --default "$spelling"
  has $'keep\tmain\tkept (default branch)'; check "DEFAULT: --default $spelling keeps the main dir" $?
done

# --- a symbolic --default resolves to the branch it names, or refuses ---
gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
for spelling in origin/HEAD refs/remotes/origin/HEAD; do
  run "$runner" --default "$spelling"
  [ "$rc" -eq 0 ] && has $'keep\tmain\tkept (default branch)' \
    && has $'reap\tanc\tmerged (ancestry)'
  check "DEFAULT: --default $spelling resolves to main (got $rc)" $?
done
run "$runner"
has $'keep\tmain\tkept (default branch)'; check "DEFAULT: origin/HEAD, auto-detected, resolves to main" $?
gitq checkout -q wip
for spelling in HEAD head Head @ "$(sha main)" main~0 Main MAIN origin/head Origin/HEAD; do
  run "$runner" --default "$spelling"
  [ "$rc" -eq 2 ] && ! printf '%s\n' "$out" | grep -qE $'^(keep|reap)\t'
  check "DEFAULT: --default $spelling names no default branch, refused (got $rc)" $?
done
gitq checkout -q main

# --- a remote with a slash in its name strips to the branch it names ---
gitq remote add up/stream "$temp_dir/no-such-upstream.git"
gitq update-ref refs/remotes/up/stream/main main
for spelling in up/stream/main refs/remotes/up/stream/main; do
  run "$runner" --default "$spelling"
  [ "$rc" -eq 0 ] && has $'keep\tmain\tkept (default branch)'
  check "DEFAULT: --default $spelling, a slashed remote, keeps the main dir (got $rc)" $?
done
gitq update-ref refs/remotes/nowhere/main main
run "$runner" --default nowhere/main
[ "$rc" -eq 2 ]; check "DEFAULT: a remote ref under no configured remote is refused (got $rc)" $?
gitq update-ref -d refs/remotes/nowhere/main

# --- auto-detect measures merges against origin's ref, not local main ---
gitq branch -q unpushed main && gitq checkout -q unpushed && echo unpushed > "$repo/unpushed.txt" \
  && gitq add unpushed.txt && gitq commit -q -m unpushed && gitq checkout -q main \
  || die_temp "branch unpushed failed"
record unpushed "$(sha unpushed)"
pre_main=$(sha main)
gitq checkout -q wip && gitq update-ref refs/heads/main "$(sha unpushed)"
run "$runner"
[ "$rc" -eq 0 ] && has $'keep\tmain\tkept (default branch)' && ! has $'reap\tunpushed\tmerged (ancestry)'
check "DEFAULT: an unpushed merge into local main does not reap (got $rc)" $?
gitq update-ref refs/heads/main "$pre_main" && gitq checkout -q main

# --- a remote nested in origin's name never re-splits origin's ref ---
gitq config remote.origin/release.url "$temp_dir/no-such-release.git"
gitq update-ref refs/remotes/origin/release/main main
run "$runner"
[ "$rc" -eq 0 ] && has $'keep\tmain\tkept (default branch)'
check "DEFAULT: a nested remote leaves origin/HEAD on origin/main alone (got $rc)" $?
gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release/main
run "$runner"
[ "$rc" -eq 0 ] && ! has $'keep\tmain\tkept (default branch)'
check "DEFAULT: auto-detect strips exactly origin from origin/release/main (got $rc)" $?
gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run "$runner" --default origin/release/main
[ "$rc" -eq 2 ] && ! printf '%s\n' "$out" | grep -qE $'^(keep|reap)\t'
check "DEFAULT: a ref two remote names could split is refused (got $rc)" $?
gitq update-ref -d refs/remotes/origin/release/main
gitq config --remove-section remote.origin/release

# --- origin/HEAD under another remote splits that remote, not origin ---
gitq remote add upstream "$temp_dir/no-such-upstream2.git"
gitq update-ref refs/remotes/upstream/main main
gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/upstream/main
run "$runner"
[ "$rc" -eq 0 ] && has $'keep\tmain\tkept (default branch)' && ! has $'reap\tmain\tmerged (ancestry)'
check "DEFAULT: origin/HEAD under another remote keeps the main dir (got $rc)" $?
gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
gitq update-ref -d refs/remotes/upstream/main
gitq remote remove upstream

# --- an unset or dangling origin/HEAD is refused, never guessed ---
gitq branch master main
gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
run "$runner"
[ "$rc" -eq 2 ] && ! printf '%s\n' "$out" | grep -qE $'^(keep|reap)\t'
check "DEFAULT: a dangling origin/HEAD is refused, not guessed (got $rc)" $?
gitq symbolic-ref --delete refs/remotes/origin/HEAD
run "$runner"
[ "$rc" -eq 2 ] && ! printf '%s\n' "$out" | grep -qE $'^(keep|reap)\t'
check "DEFAULT: an unset origin/HEAD is refused, though a main exists (got $rc)" $?
gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
gitq branch -D -q master

# --- a merged PR behind the local tip is named, not called unmerged ---
gitq checkout -q -b ahead main && echo ahead > "$repo/ahead.txt" \
  && gitq add ahead.txt && gitq commit -q -m ahead || die_temp "branch ahead failed"
printf 'merged\tahead\t40\t%s\n' "$(sha ahead)" >> "$temp_dir/$case/gh.tsv"
echo more >> "$repo/ahead.txt" && gitq commit -q -am more && gitq checkout -q main \
  || die_temp "ahead tip failed"
record ahead "$(sha ahead)"
run "$runner"
has $'keep\tahead\tkept (merged PR #40, local tip ahead)'
check "AHEAD: a merged PR behind the local tip keeps, and says so" $?
has $'keep\treused\tkept (unmerged)'; check "AHEAD: another tip's merged PR is still not named" $?

# --- gh absent or failing: never a guessed merge ---
run env GH_BIN="$temp_dir/no-such-gh" "$runner"
has $'keep\tsq\tkept (merge unverifiable — gh absent)'; check "GH ABSENT: squash merge is kept, not guessed" $?
has $'reap\tanc\tmerged (ancestry)'; check "GH ABSENT: recorded ancestry still reaps" $?
has $'keep\tfresh\tkept (merged tip, no recorded commit)'; check "GH ABSENT: a bare merged tip still keeps" $?
has $'keep\twip\tkept (merge unverifiable — gh absent)'; check "GH ABSENT: unmerged reads unverifiable" $?
run env GH_STUB_FAIL=1 "$runner"
has $'keep\tsq\tkept (merge unverifiable — gh absent)'; check "GH FAILING: squash merge is kept, not guessed" $?
[ "$rc" -eq 0 ]; check "GH FAILING: still exits 0 (got $rc)" $?

# --- ingest guard with no index at all ---
mv "$home/history-index.jsonl" "$home/held.jsonl"
run "$runner"
has $'keep\tanc\tkept (unindexed — ingest gap)'; check "NO INDEX: a gated merged dir is kept" $?
mv "$home/held.jsonl" "$home/history-index.jsonl"

# --- apply: deletes exactly the reap set ---
case=apply; build "$case"
run "$runner" --apply
[ "$rc" -eq 0 ]; check "APPLY: exits 0 (got $rc)" $?
has $'summary\trepo\treap=4 keep=13 clear=2 failed=0 mode=apply'; check "APPLY: summary names apply mode" $?
[ ! -e "$loops/anc" ] && [ ! -e "$loops/sq" ] && [ ! -e "$loops/gonepr" ]; check "APPLY: merged dirs are gone" $?
[ ! -e "$loops/fix" ]; check "APPLY: an emptied slash parent is pruned" $?
[ -d "$loops/anc-open" ] && [ -d "$loops/ungated" ] && [ -d "$loops/broken" ] \
  && [ -d "$loops/main" ] && [ -d "$loops/gone" ] && [ -d "$loops/nest/inner" ] \
  && [ -d "$loops/fresh" ] && [ -d "$loops/tail" ] && [ -d "$loops/reused" ] \
  && [ -d "$loops/.claude/.cc-writes" ]
check "APPLY: every kept dir survives" $?
[ ! -e "$loops/wip/run-state.json.tmp" ] && [ -e "$loops/wip/run-state.json" ]
check "APPLY: tmp cleared, the kept snapshot beside it untouched" $?
run "$runner" --apply
has $'summary\trepo\treap=0 keep=13 clear=0 failed=0 mode=apply'; check "APPLY: a second apply reaps nothing" $?

# --- a newline in a file name never yields a dir outside local/loops ---
case=newline; build "$case"
branch_commit bar && gitq merge -q --ff-only bar || die_temp "branch bar failed"
decoy="$temp_dir/$case/cwd"; mkdir -p "$decoy/bar"
jq -n --arg c "$(sha bar)" '{queue: [{commit: $c}]}' > "$decoy/bar/run-state.json"
echo x > "$loops/wip/x"$'\n'"bar"
out=$(cd "$decoy" && env REPO_ROOT="$repo" CUSTODIAN_HOME="$home" GH_STUB_DB="$temp_dir/$case/gh.tsv" \
  PATH="$stub_bin:$PATH" "$runner" --apply 2>&1)
[ -e "$decoy/bar/run-state.json" ]; check "NEWLINE: a dir named by a split path is never deleted" $?
! printf '%s\n' "$out" | grep -q $'\tbar\t'; check "NEWLINE: the split fragment gets no verdict" $?

# --- a deletion that fails exits 1 ---
if [ "$(id -u)" -ne 0 ]; then
  case=locked; build "$case"
  chmod a-w "$loops/fix"
  run "$runner" --apply
  [ "$rc" -eq 1 ]; check "LOCKED: a failed deletion exits 1 (got $rc)" $?
  has $'summary\trepo\treap=4 keep=13 clear=2 failed=1 mode=apply'; check "LOCKED: summary counts the failure" $?
  chmod u+w "$loops/fix"
fi

# --- unusable input exits 2 ---
case=usage; build "$case"
run "$runner" --bogus
[ "$rc" -eq 2 ]; check "USAGE: unknown flag exits 2 (got $rc)" $?
run "$runner" --default no-such-branch
[ "$rc" -eq 2 ]; check "USAGE: unresolvable default exits 2 (got $rc)" $?
mkdir -p "$temp_dir/notrepo"
out=$(GIT_CEILING_DIRECTORIES="$temp_dir" REPO_ROOT="$temp_dir/notrepo" CUSTODIAN_HOME="$home" "$runner" 2>&1); rc=$?
[ "$rc" -eq 2 ]; check "USAGE: a non-repo exits 2 (got $rc)" $?
repo="$temp_dir/bare"; mkdir -p "$repo"; git init -q -b main "$repo"
gitq commit -q --allow-empty -m seed
gitq remote add origin "$temp_dir/no-such-origin.git"
gitq update-ref refs/remotes/origin/main main && gitq symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run "$runner"
[ "$rc" -eq 0 ] && has $'summary\tbare\treap=0 keep=0 clear=0 failed=0 mode=plan (no local/loops)'
check "EMPTY: a repo with no local/loops reports zero and exits 0" $?

echo
if [ "$fails" -eq 0 ]; then echo "all $checks custodian-reap test(s) passed"; exit 0
else echo "$fails of $checks custodian-reap test(s) FAILED"; exit 1; fi
