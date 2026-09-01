#!/usr/bin/env bash
# custodian-mutation-kill — plants declared mutants, requires the paired
# suite go red. Mutants are hand-written, never generated (no LLM oracle).
# Rationale + perl gotchas: docs/decisions/looper-custodian.md decision 25.
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
    # --root/--table let the suite target fixtures instead of live rules
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
# perl + equivalent-mutant gotchas: looper-custodian.md decision 25
# gotcha: the replacement side interpolates too, a stray `\{` breaks awk

# checked here, not in mutants(): exit 2 there ends only the subshell
# -s tests size, not readability; head -c1 catches a mode-000 table too
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
hook-truncation-off|hooks/record-execution-receipt.sh|loop-receipts.test.sh|s/cut -c "1-\$CMD_KEEP"/cat/
hook-cmd-digest-dropped|hooks/record-execution-receipt.sh|loop-receipts.test.sh|s/cmd_sha=\$\(sha_of "\$cmd"\)/cmd_sha=""/
hook-interrupted-normalizer-off|hooks/record-execution-receipt.sh|loop-receipts.test.sh|s/\*\) interrupted=false ;;/*) interrupted=null ;;/
ceiling-comparison-never-fires|skill-body-ceiling.sh|skill-body-ceiling.test.sh|s/if \[ "\$actual" -gt "\$ceiling" \]; then/if false; then/
ceiling-slack-note-off|skill-body-ceiling.sh|skill-body-ceiling.test.sh|s/\$slack" -gt \$\(\(ceiling \/ 5\)\)/\$slack" -gt 999999/
ceiling-comment-skip-eats-rows|skill-body-ceiling.sh|skill-body-ceiling.test.sh|s/case "\$\{skill:-\}" in ''\|\\#\*\) continue ;; esac/continue/
g3-group-drop-wave|custodian-guardrails.sh|custodian-guardrails.test.sh|s/\Q[.repo, .branch, (.wave | tostring)]\E/[.repo, .branch]/
lexer-opener-gate-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (codestart[ln] && t ~ /^\{\E!if (t ~ /^\\{!
lexer-slash-gate-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (codestart[ln] && t ~ /^\/\E!if (t ~ /^\\/!
lexer-rail-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (lx_cmt || lx_sp > 0) for (i = 1; i <= nlines; i++) codestart[i] = 1\E!if (0) for (i = 1; i <= nlines; i++) codestart[i] = 1!
lexer-codestart-after-line|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s%\Qcodestart[i] = (!lx_cmt && (lx_sp == 0 || lx_expr[lx_sp] == 1))\E\n((?:[^\n]*#[^\n]*\n)?[ ]*if \(lx_cmt[^\n]*)%$1\n    codestart[i] = (!lx_cmt && (lx_sp == 0 || lx_expr[lx_sp] == 1))%
lexer-hole-not-code|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s%\Qcodestart[i] = (!lx_cmt && (lx_sp == 0 || lx_expr[lx_sp] == 1))\E%codestart[i] = (!lx_cmt && (lx_sp == 0))%
lexer-comment-never-opens|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (d == "*") { lx_cmt = 1\E!if (0) { lx_cmt = 1!
lexer-comment-never-closes|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (c == "*" && substr(line, i + 1, 1) == "/") { lx_cmt = 0\E!if (0) { lx_cmt = 0!
lexer-quote-never-opens|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qi = skip_quoted(line, i, c); continue\E!i++; continue!
lexer-quote-never-closes|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (c == q) return i + 1\E!if (0) return i + 1!
lexer-quote-escape-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (c == "\\") { i += 2; continue }\E!if (0) { i += 2; continue }!
lexer-template-never-closes|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (c == "`") { lx_sp--; i++; continue }\E!if (c == "`") { i++; continue }!
lexer-template-escape-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s%\Qif (!lx_raw && c == "\\") { i += 2; continue }\E%if (0) { i += 2; continue }%
lexer-go-raw-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qlx_raw = (f ~ \E!lx_raw = (0 && f ~ !
lexer-go-raw-always|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qlx_raw = (f ~ \E!lx_raw = (1 || f ~ !
lexer-tick-drop-tsx|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Q(ts|tsx|js|jsx|mjs|cjs|go)\E!(ts|js|jsx|mjs|cjs|go)!
lexer-tick-always|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qlx_tick = (f ~ \E!lx_tick = (1 || f ~ !
lexer-subst-enter-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qlx_expr[lx_sp] = 1; lx_brace[lx_sp] = 0; i += 2; continue\E!i += 2; continue!
lexer-subst-nesting-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (lx_brace[lx_sp] == 0) lx_expr[lx_sp] = 0; else lx_brace[lx_sp]--\E!lx_expr[lx_sp] = 0!
lexer-slash-body-lexed|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s!\Qif (d == "/") return\E!if (d == "/") { i += 2; continue }!
lexer-per-file-reset-off|doc-bloat-scan.sh|doc-bloat-scan.test.sh|s%\Qlx_cmt = 0; lx_sp = 0\E%lx_cmt = lx_cmt; lx_sp = lx_sp%
probe-five-hour-renamed|usage-window-probe.sh|usage-window-probe.test.sh|s/\Q"five_hour":window("5h")\E/"5h":window("5h")/
probe-unreadable-spaced|usage-window-probe.sh|usage-window-probe.test.sh|s/\Q{"read_ok":false,"reason":"%s"}\E/{"read_ok": false, "reason": "%s"}/
probe-reason-renamed|usage-window-probe.sh|usage-window-probe.test.sh|s/\Qemit_unreadable "probe_failed"\E/emit_unreadable "curl_failed"/
probe-status-from-bare-header|usage-window-probe.sh|usage-window-probe.test.sh|s/\Q"status":h.get(f"anthropic-ratelimit-unified-{prefix}-status")\E/"status":h.get("anthropic-ratelimit-unified-status")/
probe-representative-hardcoded|usage-window-probe.sh|usage-window-probe.test.sh|s/\Qh.get("anthropic-ratelimit-unified-representative-claim")\E/"five_hour"/
probe-expiry-skew-dropped|usage-window-probe.sh|usage-window-probe.test.sh|s/\Q+ 60000))\E/+ 0))/
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

# one pristine copy, made once; `cp -a` failures are silent, so assert it
pristine="$temp_root/pristine"
mkdir -p "$pristine"
/bin/cp -a "$repo_root/scripts" "$pristine/scripts" 2>/dev/null \
  || { echo "FATAL: could not copy scripts/ into the sandbox" >&2; exit 2; }
# an empty sandbox would make every suite pass and every mutant "killed"
copied=$(find "$pristine/scripts" -name '*.sh' -type f 2>/dev/null | grep -c . || true)
[ -d "$pristine/scripts" ] && [ "$copied" -gt 0 ] \
  || { echo "FATAL: sandbox copy landed no scripts; refusing to score" >&2; exit 2; }
/bin/cp -a "$repo_root/skills" "$pristine/skills" 2>/dev/null || true
[ -d "$repo_root/local" ] && /bin/cp -a "$repo_root/local" "$pristine/local" 2>/dev/null
# without hooks/ + git, loop-receipts/loop-state-audit baseline RED here
[ -d "$repo_root/hooks" ] && /bin/cp -a "$repo_root/hooks" "$pristine/hooks" 2>/dev/null
# agents/ too: a ceilings-tsv row naming a missing agents/*.md exits 2
[ -d "$repo_root/agents" ] && /bin/cp -a "$repo_root/agents" "$pristine/agents" 2>/dev/null
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

# every suite must pass unmutated first, or a later red proves nothing
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
# exercising nothing isn't a pass: a bad --target once faked a clean sweep
if [ $((killed + survived + noop)) -eq 0 ]; then
  echo "NOTHING MUTATED  no declared mutant ran, so no suite was scored."
  [ -n "$ONLY" ] && echo "                 --target '$ONLY' matches no declared mutant."
  exit 2
fi
echo "killed $killed · SURVIVED $survived · did not apply $noop"
[ "$survived" -eq 0 ] && [ "$noop" -eq 0 ]
