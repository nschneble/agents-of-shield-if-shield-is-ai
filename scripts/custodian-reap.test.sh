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
n=$(awk -F'\t' -v s="$state" -v h="$head" '$1 == s && $2 == h { print $3; exit }' "$GH_STUB_DB")
if [ -n "$n" ]; then printf '[{"number":%s}]\n' "$n"; else echo '[]'; fi
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
index_all() { # branch — index every line of its gates.jsonl under its cite
  local n i
  n=$(grep -c . "$loops/$1/gates.jsonl")
  for i in $(seq 1 "$n"); do
    printf '{"cite":"repo/local/loops/%s/gates.jsonl:%d"}\n' "$1" "$i"
  done >> "$home/history-index.jsonl"
}

build() { # builds $repo with the full branch roster
  repo="$temp_dir/$1/repo"; home="$temp_dir/$1/custodian"; loops="$repo/local/loops"
  mkdir -p "$repo" "$home"
  git init -q -b main "$repo" || die_temp "git init failed in $repo"
  echo seed > "$repo/seed.txt"
  gitq add -A && gitq commit -q -m seed || die_temp "seed commit failed"
  for b in anc anc-open sq wip gone fix/slash ungated broken nest; do
    branch_commit "$b" || die_temp "branch $b failed"
  done
  for b in anc anc-open fix/slash ungated broken nest; do gitq merge -q --ff-only "$b" 2>/dev/null \
    || gitq merge -q --no-edit "$b" || die_temp "merge $b failed"; done
  gitq branch -q -D gone || die_temp "delete gone failed"
  for b in anc anc-open sq fix/slash; do gates "$b" 2; index_all "$b"; done
  gates ungated 2; printf '{"cite":"repo/local/loops/ungated/gates.jsonl:1"}\n' >> "$home/history-index.jsonl"
  mkdir -p "$loops/broken"; printf '{"wave":1}\nnot json\n' > "$loops/broken/gates.jsonl"
  for b in wip gone main nest nest/inner; do mkdir -p "$loops/$b"; echo '{}' > "$loops/$b/run-state.json"; done
  echo '{}' > "$loops/wip/run-state.json.tmp"
  echo '{}' > "$loops/anc/run-state.json.tmp"
  printf 'open\tanc-open\t7\nmerged\tsq\t12\nopen\twip\t\n' > "$temp_dir/$1/gh.tsv"
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
has $'summary\trepo\treap=3 keep=8 clear=2 failed=0 mode=plan'; check "PLAN: summary counts every dir" $?
[ "$(tree)" = "$before" ]; check "PLAN: deletes nothing without --apply" $?

# --- gh absent or failing: never a guessed merge ---
run env GH_BIN="$temp_dir/no-such-gh" "$runner"
has $'keep\tsq\tkept (merge unverifiable — gh absent)'; check "GH ABSENT: squash merge is kept, not guessed" $?
has $'reap\tanc\tmerged (ancestry)'; check "GH ABSENT: ancestry alone still reaps" $?
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
has $'summary\trepo\treap=3 keep=8 clear=2 failed=0 mode=apply'; check "APPLY: summary names apply mode" $?
[ ! -e "$loops/anc" ] && [ ! -e "$loops/sq" ]; check "APPLY: merged dirs are gone" $?
[ ! -e "$loops/fix" ]; check "APPLY: an emptied slash parent is pruned" $?
[ -d "$loops/anc-open" ] && [ -d "$loops/ungated" ] && [ -d "$loops/broken" ] \
  && [ -d "$loops/main" ] && [ -d "$loops/gone" ] && [ -d "$loops/nest/inner" ]
check "APPLY: every kept dir survives" $?
[ ! -e "$loops/wip/run-state.json.tmp" ] && [ -e "$loops/wip/run-state.json" ]
check "APPLY: tmp cleared, the kept snapshot beside it untouched" $?
run "$runner" --apply
has $'summary\trepo\treap=0 keep=8 clear=0 failed=0 mode=apply'; check "APPLY: a second apply reaps nothing" $?

# --- a deletion that fails exits 1 ---
if [ "$(id -u)" -ne 0 ]; then
  case=locked; build "$case"
  chmod a-w "$loops/fix"
  run "$runner" --apply
  [ "$rc" -eq 1 ]; check "LOCKED: a failed deletion exits 1 (got $rc)" $?
  has $'summary\trepo\treap=3 keep=8 clear=2 failed=1 mode=apply'; check "LOCKED: summary counts the failure" $?
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
run "$runner"
[ "$rc" -eq 0 ] && has $'summary\tbare\treap=0 keep=0 clear=0 failed=0 mode=plan (no local/loops)'
check "EMPTY: a repo with no local/loops reports zero and exits 0" $?

echo
if [ "$fails" -eq 0 ]; then echo "all $checks custodian-reap test(s) passed"; exit 0
else echo "$fails of $checks custodian-reap test(s) FAILED"; exit 1; fi
