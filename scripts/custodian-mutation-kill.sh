#!/usr/bin/env bash
# custodian-mutation-kill — asks each check suite the question it never
# asks itself: would you go red if the rule you guard were broken?
#
# Every suite here is gated on passing. None is gated on being ABLE to
# fail, and the two are not the same property. The G1 predicate in
# scripts/custodian-guardrails.sh joins two conditions with `or`, and
# three separate mutations of that line — flipping the operator, dropping
# either side — all left its 18-assertion suite green, because the
# fixtures never separate the two conditions. The rule G1 guards is
# loop-de-looper's hardest one: no verdict without a run.
#
# Mutants are DECLARED, never generated. A generator needs an
# equivalence oracle to know which mutants change behaviour at all, and
# an LLM standing in for that oracle is exactly the say-so this repo
# refuses everywhere else. A hand-written operator mutant on a jq
# predicate needs no oracle: the author asserts it changes meaning, and
# a surviving mutant is a fixture gap either way.
#
# THE NO-OP ARM IS LOAD-BEARING. A mutation whose pattern does not match
# leaves the file untouched, the suite passes, and a naive harness scores
# that as "killed" — a green that means the opposite of what it says. A
# first pass at this check reported three such false kills after its own
# tree copy silently failed. So: every mutant must change the file, and
# the unmutated baseline must pass, before any verdict is taken.
#
# Exit 0 every declared mutant was killed · 1 a mutant SURVIVED or did
# not apply · 2 unusable input: a missing/unreadable table, a mutant
# naming an absent script, a baseline already red, or a run in which no
# declared mutant executed at all.
#
# Usage: custodian-mutation-kill.sh [--target NAME] [--list]
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ONLY=""
LIST=0
TABLE=""

needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --target) needs_value --target "$#"; ONLY="$2"; shift 2;;
    # --root and --table exist so the suite can point this at fixtures.
    # Without them its own test would have to mutate the real checks to
    # test the mutator, and a harness that can only be exercised against
    # live rules is one nobody exercises.
    --root)   needs_value --root "$#";   repo_root="$2"; shift 2;;
    --table)  needs_value --table "$#";  TABLE="$2"; shift 2;;
    --list)   LIST=1; shift;;
    -h|--help)
      echo "usage: $0 [--target NAME] [--root PATH] [--table PATH] [--list]" >&2
      echo "  plants declared mutants and requires each paired suite to go red" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

# Each mutant is: label | target | paired suite | perl expr. A target with
# no slash is taken as `scripts/<name>`; one with a slash is repo-relative,
# which is how hooks/ is reached.
# The perl expr runs with -0pi, so \Q..\E fixed strings are the norm and
# the pattern must be unique in the file.
#
# GOTCHA: \Q suppresses metacharacters but NOT interpolation, and it does
# quote a backslash — so a pattern containing `$foo` silently matches
# nothing, and escaping it as `\$foo` matches a literal backslash instead.
# Anchor on a fragment without sigils. The DID NOT APPLY arm is what
# surfaces this rather than scoring it green.
#
# GOTCHA: `s///` without /g takes the FIRST match in a slurped file, and
# custodian-guardrails.sh quotes its own predicates in comments above
# them. A pattern matching both mutated the comment and left the rule
# intact — a mutant that applies, changes a byte, and challenges nothing.
# Anchor on the `def` so the predicate is the only candidate.
#
# NOT EVERY SURVIVOR IS A GAP. `select(.lineno > $e.lineno)` → `>=` in
# custodian-phase-order.sh survives, and no fixture can kill it: line
# numbers are unique per record, so the two forms select identically.
# That is an equivalent mutant, and declaring it would park a permanent
# red on a suite with nothing to fix. Dropped deliberately — a survivor
# is a fixture gap only when some input can tell the two apart.

# GOTCHA: validated here, not inside mutants() — that runs in a command
# substitution, where `exit 2` ends only the subshell and leaves the
# caller iterating an empty table. `-s` alone tests size, not
# readability, so a mode-000 table passed it and swept clean.
if [ -n "$TABLE" ]; then
  if [ ! -s "$TABLE" ] || ! head -c 1 "$TABLE" >/dev/null 2>&1; then
    echo "empty or unreadable table: $TABLE" >&2; exit 2
  fi
fi

mutants() {
  if [ -n "$TABLE" ]; then
    grep -v '^[[:space:]]*$' "$TABLE"
    return
  fi
  cat <<'TABLE'
g1-or-to-and|custodian-guardrails.sh|custodian-guardrails.test.sh|s/\Q((.ran == false) or (.task_tool_available == false))\E/((.ran == false) and (.task_tool_available == false))/
g1-drop-tool-disjunct|custodian-guardrails.sh|custodian-guardrails.test.sh|s/\Q((.ran == false) or (.task_tool_available == false))\E/(.ran == false)/
g1-drop-ran-disjunct|custodian-guardrails.sh|custodian-guardrails.test.sh|s/\Q((.ran == false) or (.task_tool_available == false))\E/(.task_tool_available == false)/
g2-drop-outcome-arm|custodian-guardrails.sh|custodian-guardrails.test.sh|s/def g2_violation:\s+\(\.verified_by == null\s+or \(\.kind == "crew" and \.agent == "the-diamantaire" and \.outcome == null\)\);/def g2_violation:  (.verified_by == null);/
g3-drop-kind-evidence|custodian-guardrails.sh|custodian-guardrails.test.sh|s/\Qtest("crew|ship|review")\E/test("nomatchzzz")/
legacy-era-inverted|custodian-guardrails.sh|custodian-guardrails.test.sh|s/\Qdef legacy: (has("verified_by") | not);\E/def legacy: (has("verified_by"));/
recall-drop-trigger-exclusions|custodian-log-recall.sh|custodian-log-recall.test.sh|s/\Qtest("not run|NOT RUN|not invokable|not installed|not nestable|bars deep-research")\E/test("zzznomatch")/
recall-downgrade-violation-label|custodian-log-recall.sh|custodian-log-recall.test.sh|s/\QVIOLATION      action\E/noticed        action/
recall-drop-excl-notinstalled|custodian-log-recall.sh|custodian-log-recall.test.sh|s/\Qnot invokable|not installed|\E/not invokable|/
recall-drop-excl-notnestable|custodian-log-recall.sh|custodian-log-recall.test.sh|s/\Q|not nestable|\E/|/
recall-drop-excl-lowercase-notrun|custodian-log-recall.sh|custodian-log-recall.test.sh|s/\Qtest("not run|NOT RUN|\E/test("NOT RUN|/
recall-drop-phase-gate|custodian-log-recall.sh|custodian-log-recall.test.sh|s/\Q(.phase == "E")\E/(.phase != "zzz")/
recall-drop-references-harvest|custodian-log-recall.sh|custodian-log-recall.test.sh|s/-d "\$spec_dir\/references"/-d "\/nonexistent"/
g3-drop-sha-arm|custodian-guardrails.sh|custodian-guardrails.test.sh|s/or \(\(\.summary .. ""\) \| test\("[^"]+"\)\)\);/or false);/
g3-sha-regex-dead|custodian-guardrails.sh|custodian-guardrails.test.sh|s/\Q[0-9a-f]{7,40}\E/[0-9a-f]{70,80}/
receipts-interrupted-ignored|loop-receipts.sh|loop-receipts.test.sh|s/\Q(.interrupted \/\/ false) != true\E/true/
docmirror-never-warns|validate-looper-config.sh|validate-looper-config.test.sh|s/grep -qF -- "\$invocation" "\$family_doc"/true/
docmirror-always-warns|validate-looper-config.sh|validate-looper-config.test.sh|s/grep -qF -- "\$invocation" "\$family_doc"/false/
ciwiring-accept-any-mention|validate-looper-config.sh|validate-looper-config.test.sh|s/run_cmds=\$\(run_commands "\$workflow"\)/run_cmds=\$\(cat "\$workflow"\)/
po-tail-counted-as-p2|custodian-phase-order.sh|custodian-phase-order.test.sh|s/\(\$nob \| map\(select\(\.priorb == 0\)\)\)/(\$nob)/
po-segment-marker-dead|custodian-phase-order.sh|custodian-phase-order.test.sh|s/if \$l\.obj\.phase == "resume" then \.seg \+= 1/if false then .seg += 1/
receipts-era-gate-off|loop-receipts.sh|loop-receipts.test.sh|s/if \[ ! -s "\$receipts" \]; then/if false; then/
hook-nonbash-gate-off|hooks/record-execution-receipt.sh|loop-receipts.test.sh|s/\[ "\$tool" = "Bash" \] \|\| exit 0/: /
hook-interrupted-normalizer-off|hooks/record-execution-receipt.sh|loop-receipts.test.sh|s/\*\) interrupted=false ;;/*) interrupted=null ;;/
g3-group-drop-wave|custodian-guardrails.sh|custodian-guardrails.test.sh|s/\Q[.repo, .branch, (.wave | tostring)]\E/[.repo, .branch]/
TABLE
}

if [ "$LIST" -eq 1 ]; then
  mutants | while IFS='|' read -r label script suite _; do
    printf '%-28s %s -> %s\n' "$label" "$script" "$suite"
  done
  exit 0
fi

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/looper-mutkill.XXXXXX") \
  || { echo "FATAL: mktemp -d failed; refusing to run" >&2; exit 2; }
[ -d "$temp_root" ] || { echo "FATAL: mktemp -d gave no directory" >&2; exit 2; }
trap 'rm -rf "$temp_root"' EXIT

# One pristine copy, made once and verified. `cp -R` and `cp -a` differ
# across shells and aliases; a copy that silently fails is the false-kill
# generator this check was written to avoid, so the result is asserted.
pristine="$temp_root/pristine"
mkdir -p "$pristine"
/bin/cp -a "$repo_root/scripts" "$pristine/scripts" 2>/dev/null \
  || { echo "FATAL: could not copy scripts/ into the sandbox" >&2; exit 2; }
# Assert the copy actually landed, without naming a specific file: a
# silently-empty sandbox makes every suite "pass" and every mutant read
# as killed, which is the false green this whole check is against.
copied=$(find "$pristine/scripts" -name '*.sh' -type f 2>/dev/null | grep -c . || true)
[ -d "$pristine/scripts" ] && [ "$copied" -gt 0 ] \
  || { echo "FATAL: sandbox copy landed no scripts; refusing to score" >&2; exit 2; }
/bin/cp -a "$repo_root/skills" "$pristine/skills" 2>/dev/null || true
[ -d "$repo_root/local" ] && /bin/cp -a "$repo_root/local" "$pristine/local" 2>/dev/null
# hooks/ and a git root: without them loop-receipts.test.sh and
# loop-state-audit.test.sh baseline RED in here (one resolves
# ../hooks/, the other runs `git -C ..`), so no mutant could ever be
# declared for those scripts — a whole area silently unscoreable.
[ -d "$repo_root/hooks" ] && /bin/cp -a "$repo_root/hooks" "$pristine/hooks" 2>/dev/null
if [ ! -d "$pristine/.git" ] && command -v git >/dev/null; then
  ( cd "$pristine" && git init -q . \
      && git -c user.email=mutkill@local -c user.name=mutkill \
             commit -q --allow-empty -m sandbox ) 2>/dev/null || true
fi

run_suite() { # suite name, tree root — returns the suite's status
  ( cd "$2" && bash "scripts/$1" >/dev/null 2>&1 )
}

echo "custodian-mutation-kill — declared mutants over the check suites"
echo

# Baseline: every suite in play must pass unmutated, or a later red says
# nothing about the mutant.
baselined=""
while IFS='|' read -r _ _ suite _; do
  case " $baselined " in *" $suite "*) continue ;; esac
  baselined="$baselined $suite"
  if run_suite "$suite" "$pristine"; then
    echo "  baseline ok     $suite passes unmutated"
  else
    echo "  BASELINE RED    $suite fails before any mutation — nothing below is meaningful" >&2
    exit 2
  fi
done <<EOF
$(mutants)
EOF
echo

survived=0
noop=0
killed=0
while IFS='|' read -r label script suite expr; do
  [ -n "$label" ] || continue
  if [ -n "$ONLY" ] && [ "$label" != "$ONLY" ]; then continue; fi

  work="$temp_root/work"
  rm -rf "$work"; /bin/cp -a "$pristine" "$work"
  case "$script" in */*) rel="$script" ;; *) rel="scripts/$script" ;; esac
  target="$work/$rel"
  [ -e "$target" ] || { echo "  MISSING         $label: no $rel" >&2; exit 2; }

  perl -0pi -e "$expr" "$target" 2>/dev/null
  if cmp -s "$pristine/$rel" "$target"; then
    echo "  DID NOT APPLY   $label — pattern matched nothing, so the suite was never"
    echo "                  challenged. Scoring this as killed is the false green."
    noop=$((noop + 1))
    continue
  fi

  if run_suite "$suite" "$work"; then
    echo "  SURVIVED        $label — $suite still passes with the rule broken"
    survived=$((survived + 1))
  else
    echo "  killed          $label"
    killed=$((killed + 1))
  fi
done <<EOF
$(mutants)
EOF

echo
# A run that exercised nothing is not a pass. Three shapes reached the
# tally with every counter at zero — a --target naming no mutant, a
# whitespace-only table, an unreadable one — and each printed a clean
# sweep. The suites are only scored if at least one mutant actually ran.
if [ $((killed + survived + noop)) -eq 0 ]; then
  echo "NOTHING MUTATED  no declared mutant ran, so no suite was scored."
  [ -n "$ONLY" ] && echo "                 --target '$ONLY' matches no declared mutant."
  exit 2
fi
echo "killed $killed · SURVIVED $survived · did not apply $noop"
[ "$survived" -eq 0 ] && [ "$noop" -eq 0 ]
