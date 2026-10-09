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
# gotcha: inside \Q..\E a `\$` matches backslash-dollar, so hand-escape
# every dollar sign instead of trusting the quotemeta to cover it

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
unanimity-crew-exact-match|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\Qtostring | test("crew")\E/tostring == "crew"/
unanimity-ran-gate-off|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\Qselect(.ran == true)\E/select(.ran != false)/
unanimity-era-gate-off|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\Qmap(select(.all_modern))\E/map(select(true))/
unanimity-rollup-slash-off|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s!\Qor ((.agent | tostring) | test("/"));\E!;!
unanimity-t1-accepts-executable|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\Q(vb == null) or (vb == "llm")\E/(vb == null) or (vb == "llm") or (vb == "executable")/
unanimity-dedup-off|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s%\Qgroup_by(dedup_key)\E\n\s*\Q| map(first(.[] | select(.source == "live")) // .[0])\E%.%
unanimity-dedup-drops-live-row|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\Qfirst(.[] | select(.source == "live"))\E/first(.[] | select(.source == "index"))/
unanimity-fallback-key-drops-summary|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\|\\\(\.agent\)\|\\\(\.summary\)"\);/|\\(.agent)");/
unanimity-rollup-null-agent-off|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\Q(.agent == null)\E/(false)/
unanimity-mixed-era-counted-legacy|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\Qmap(select(.any_modern | not))\E/map(select(.all_modern | not))/
unanimity-mixed-bucket-dead|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/\Q.any_modern and (.all_modern | not)\E/false/
unanimity-unreadable-census-silent|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/census_unreadable=\$\(grep[^)]*\)/census_unreadable=0/
unanimity-blockers-any-count|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s!\Qall_clean: all(.[]; (.blockers // 0) == 0)\E!all_clean: all(.[]; (.blockers // 0) >= 0)!
wq-contiguity-one-sided|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\(\(\$want - \$w\) \+ \(\$w - \$want\)\)%(\$want - \$w)%
wq-asks-nonarray-guard-off|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\Qif type != "array" then 1\E%if false then 1%
wq-asks-type-guard-off|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\Qelse [.[] | select(type != "object")] | length end\E%else 0 end%
wq-closes-type-guard-off|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%elif \[ "\$bad_closes" -gt 0 \]; then%elif false; then%
wq-ask-ids-comma-split|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\Q[.[] | objects | .id | tostring] | unique\E%[.[] | objects | .id | tostring] | unique | join(",") | split(",")%
wq-shipped-sort-dropped|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\Q| sort_by(.wave) | .[] | .commit\E%| .[] | .commit%
wq-depends-alias-dropped|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\. as \$t \| \(\.depends_on // \.dependsOn // \.depends // \.blocked_by // \[\]\)\[\]%. as \$t | (.depends_on // .dependsOn // .blocked_by // [])[]%
wq-first-edge-only|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\. as \$t \| \(\.depends_on // \.dependsOn // \.depends // \.blocked_by // \[\]\)\[\]%. as \$t | (.depends_on // .dependsOn // .depends // .blocked_by // [])[0:1][]%
wq-duplicate-arm-relabelled|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\Qarm "no wave number used twice"\E%arm "no wave number reused"%
wq-closes-null-counted-bad|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\Qselect(.closes != null and (.closes | type) != "array")\E%select(has("closes")) | select((.closes | type) != "array")%
wq-asks-container-noun-collapsed|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\Qif type == "array" then "yes" else "no" end\E%"yes"%
wq-has-closes-null-uncounted|wave-queue-dag-audit.sh|wave-queue-dag-audit.test.sh|s%\Qselect(.closes != null)] | length\E%select(has("closes"))] | length%
unanimity-census-warns-always|loop-unanimity-audit.sh|loop-unanimity-audit.test.sh|s/census_unreadable=\$\(grep[^)]*\)/census_unreadable=1/
lsa-total-ignores-retries|loop-state-audit.sh|loop-state-audit.test.sh|s/ \+ retry_dispatches \)\)"/ ))"/
lc-shipped-not-counted|loop-counters.sh|loop-counters.test.sh|s/waves_shipped"\) \+ 1/waves_shipped") + 0/
lc-since-crew-not-counted|loop-counters.sh|loop-counters.test.sh|s/waves_since_crew"\) \+ 1/waves_since_crew") + 0/
lc-files-not-summed|loop-counters.sh|loop-counters.test.sh|s/n\("cumulative_files_changed"\) \+ \$o\.files_changed/n("cumulative_files_changed")/
lc-crew-reset-off|loop-counters.sh|loop-counters.test.sh|s/then \.counters\.waves_since_crew = 0 \| \.counters\.cumulative_files_changed = 0 \| /then /
lc-last-crew-wave-dropped|loop-counters.sh|loop-counters.test.sh|s/ \| \.last_crew_wave = \$o\.wave//
lc-verdict-dropped|loop-counters.sh|loop-counters.test.sh|s/then \.counters\.last_review_verdict = \$o\.review_verdict else/then . else/
lc-total-not-counted|loop-counters.sh|loop-counters.test.sh|s/total_waves"\) \+ 1/total_waves") + 0/
lc-total-counts-direct-fix|loop-counters.sh|loop-counters.test.sh|s/IN\("queue","cleanup","corrective","retry"\)\) as/IN("queue","cleanup","corrective","retry","direct-fix")) as/
lc-corrective-not-counted|loop-counters.sh|loop-counters.test.sh|s/corrective_waves"\) \+ 1/corrective_waves") + 0/
lc-direct-fix-not-corrective|loop-counters.sh|loop-counters.test.sh|s/IN\("corrective","direct-fix"\)\) as/IN("corrective")) as/
lc-advance-reset-off|loop-counters.sh|loop-counters.test.sh|s/if \(\$o\.kind \| IN\("queue","cleanup"\)\) then/if false then/
lc-retry-resets-this-wave|loop-counters.sh|loop-counters.test.sh|s/if \(\$o\.kind \| IN\("queue","cleanup"\)\) then/if (\$o.kind | IN("queue","cleanup","retry")) then/
lc-cleanup-keeps-wave-correctives|loop-counters.sh|loop-counters.test.sh|s/if \(\$o\.kind \| IN\("queue","cleanup"\)\) then/if \$o.kind == "queue" then/
lc-cleanup-not-a-wave|loop-counters.sh|loop-counters.test.sh|s/IN\("queue","cleanup","corrective","retry"\)\) as/IN("queue","corrective","retry")) as/
lc-cleanup-not-marked|loop-counters.sh|loop-counters.test.sh|s/then \.counters\.cleanup_waves = n\("cleanup_waves"\) \+ 1 else/then . else/
lc-cleanup-empty-batch-dispatched|loop-counters.sh|loop-counters.test.sh|s/\$next == "cleanup" and \(\(\.cleanup_batch/false and ((.cleanup_batch/
lc-cleanup-rerun-dispatched|loop-counters.sh|loop-counters.test.sh|s/\$next == "cleanup" and at\("cleanup_waves"\) >= 1/false/
lc-counter-check-drops-cleanup|loop-counters.sh|loop-counters.test.sh|s/,"cleanup_waves"\)/)/
lc-scaffolding-ignores-gating|loop-counters.sh|loop-counters.test.sh|s/\$o\.gating == true and at\("scaffolding_only_correctives"\)/true and at("scaffolding_only_correctives")/
lc-crlf-not-stripped|loop-counters.sh|loop-counters.test.sh|s/\{ sub\(\/\\r\$\/, ""\) \}/{ }/
lc-this-wave-not-counted|loop-counters.sh|loop-counters.test.sh|s/correctives_this_wave"\) \+ 1/correctives_this_wave") + 0/
lc-no-progress-reset-off|loop-counters.sh|loop-counters.test.sh|s/if \$o\.net_new == true then/if false then/
lc-no-progress-not-counted|loop-counters.sh|loop-counters.test.sh|s/consecutive_no_progress"\) \+ 1/consecutive_no_progress") + 0/
lc-reopened-ignored|loop-counters.sh|loop-counters.test.sh|s/or \$o\.reopened == true\)/or false)/
lc-retries-not-counted|loop-counters.sh|loop-counters.test.sh|s/wave_retries"\) \+ 1/wave_retries") + 0/
lc-scaffolding-reset-off|loop-counters.sh|loop-counters.test.sh|s/if \$shipped and \$o\.touched_product == true then/if false then/
lc-scaffolding-not-counted|loop-counters.sh|loop-counters.test.sh|s/scaffolding_only_correctives"\) \+ 1/scaffolding_only_correctives") + 0/
lc-batched-not-derived|loop-counters.sh|loop-counters.test.sh|s/\| \.counters\.batched_findings = \(\(\.cleanup_batch \/\/ \[\]\) \| length\)/| ./
lc-per-wave-off-by-one|loop-counters.sh|loop-counters.test.sh|s/at\("correctives_this_wave"\) >= /at("correctives_this_wave") > /
lc-per-wave-ignores-gating|loop-counters.sh|loop-counters.test.sh|s/\$o\.gating == true and at\("correctives_this_wave"\)/true and at("correctives_this_wave")/
lc-corrective-ignores-gating|loop-counters.sh|loop-counters.test.sh|s/\$o\.gating == true and at\("corrective_waves"\)/true and at("corrective_waves")/
lc-total-gates-cleanup|loop-counters.sh|loop-counters.test.sh|s/IN\("queue","corrective","retry"\)\) and at/IN("queue","corrective","retry","cleanup")) and at/
lc-total-skips-corrective|loop-counters.sh|loop-counters.test.sh|s/IN\("queue","corrective","retry"\)\) and at/IN("queue","retry")) and at/
lc-total-skips-retry|loop-counters.sh|loop-counters.test.sh|s/IN\("queue","corrective","retry"\)\) and at/IN("queue","corrective")) and at/
lc-retries-gate-any-dispatch|loop-counters.sh|loop-counters.test.sh|s/\$next == "retry" and at\("wave_retries"\)/true and at("wave_retries")/
lc-no-progress-never-retries|loop-counters.sh|loop-counters.test.sh|s/consecutive_no_progress\)  retry_or_stop "[^"]*";;/consecutive_no_progress)  action="STOP + escalate: retry spent, still thrashing"; verdict="STOP";;/
lc-no-progress-retry-unbounded|loop-counters.sh|loop-counters.test.sh|s/consecutive_no_progress\)  retry_or_stop "[^"]*";;/consecutive_no_progress)  action="rethink: one 2b-retry on the next ranked alternate, then STOP"; verdict="rethink";;/
lc-next-kind-unchecked|loop-counters.sh|loop-counters.test.sh|s/''\|queue\|corrective\|retry\|cleanup\) ;;/*) ;;/
lc-next-outcome-not-exclusive|loop-counters.sh|loop-counters.test.sh|s/if \[ -n "\$OUTCOME" \] && \[ -n "\$NEXT" \]; then/if false; then/
lc-next-rails-failure-ignored|loop-counters.sh|loop-counters.test.sh|s/ \|\| refuse "could not evaluate the dispatch rails"/ || true/
lc-spec-thrash-wording|skills/loop-de-looper/SKILL.md|loop-counters.test.sh|s/then STOP \+ escalate: retry spent, still thrashing/then STOP + escalate: retry spent, still looping/
lc-total-off-by-one|loop-counters.sh|loop-counters.test.sh|s/at\("total_waves"\) >= /at("total_waves") > /
lc-corrective-off-by-one|loop-counters.sh|loop-counters.test.sh|s/at\("corrective_waves"\) >= /at("corrective_waves") > /
lc-no-progress-off-by-one|loop-counters.sh|loop-counters.test.sh|s/at\("consecutive_no_progress"\) >= /at("consecutive_no_progress") > /
lc-retries-off-by-one|loop-counters.sh|loop-counters.test.sh|s/at\("wave_retries"\) >= /at("wave_retries") > /
lc-scaffolding-off-by-one|loop-counters.sh|loop-counters.test.sh|s/at\("scaffolding_only_correctives"\) >= /at("scaffolding_only_correctives") > /
lc-rethink-outranks-stop|loop-counters.sh|loop-counters.test.sh|s/\[ "\$verdict" = "STOP" \] \|\| verdict="rethink"/verdict="rethink"/
lc-tripped-exits-zero|loop-counters.sh|loop-counters.test.sh|s/\[ "\$verdict" = "clear" \]/true/
lc-budget-line-ignored|loop-counters.sh|loop-counters.test.sh|s%in_loop && /\^- budget:/%in_loop && /^- zzz:/%
lc-budget-any-section|loop-counters.sh|loop-counters.test.sh|s%in_loop = \(\$0 ~ /\^## Loop de Looper\[\[:space:\]\]\*\$/\)%in_loop = 1%
lc-budget-key-crossed|loop-counters.sh|loop-counters.test.sh|s/max-waves\)( +)L_TOTAL=/max-waves)$1L_CORRECTIVE=/
lc-repo-claude-md-unread|loop-counters.sh|loop-counters.test.sh|s/\[ -n "\$top" \] && \[ -e "\$top\/CLAUDE\.md" \] && CLAUDE_MD="\$top\/CLAUDE\.md"/:/
lc-outcome-validation-off|loop-counters.sh|loop-counters.test.sh|s/\[ -z "\$problems" \] \|\| refuse/true || refuse/
lc-write-in-place|loop-counters.sh|loop-counters.test.sh|s/"\$STATE" > "\$tmp" 2>/"\$STATE" > "\$STATE" 2>/
lc-tmp-trap-off|loop-counters.sh|loop-counters.test.sh|s/trap 'rm -f "\$tmp"' EXIT/:/
lc-retry-spent-ignored|loop-counters.sh|loop-counters.test.sh|s/if \[ "\$wave_retried" -ge 1 \]; then/if false; then/
lc-wave-retry-not-counted|loop-counters.sh|loop-counters.test.sh|s/ \| \.counters\.retries_this_wave = n\("retries_this_wave"\) \+ 1//
lc-wave-retry-reset-off|loop-counters.sh|loop-counters.test.sh|s/ \| \.counters\.retries_this_wave = 0//
lc-counter-check-off|loop-counters.sh|loop-counters.test.sh|s/\[ -z "\$not_counts" \] \|\| refuse/true || refuse/
lc-cleanup-batch-shape-unchecked|loop-counters.sh|loop-counters.test.sh|s/\n       and \(\(\.cleanup_batch \/\/ \[\]\) \| type == "array"\)//
lc-counter-check-drops-retries|loop-counters.sh|loop-counters.test.sh|s/"wave_retries","retries_this_wave"/"retries_this_wave"/
lc-rails-failure-ignored|loop-counters.sh|loop-counters.test.sh|s/ \|\| refuse "could not evaluate the governor rails/ || true "could not evaluate the governor rails/
lc-fence-skip-off|loop-counters.sh|loop-counters.test.sh|s/ && run\(t, c\) >= 3\) \{/ \&\& run(t, c) >= 99) {/
lc-fence-closes-on-any-run|loop-counters.sh|loop-counters.test.sh|s/if \(c == fence_c && run\(t, c\) >= fence_n && /if (c == fence_c \&\& /
lc-second-budget-ignored|loop-counters.sh|loop-counters.test.sh|s/\| grep -c \.\)" -gt 1 \]/| grep -c .)" -gt 99 ]/
lc-zero-budget-accepted|loop-counters.sh|loop-counters.test.sh|s/\[ "\$val" -gt 0 \] \|\| refuse/true || refuse/
lc-spec-ceiling-wording|skills/loop-de-looper/SKILL.md|loop-counters.test.sh|s/dispatched waves reached the ceiling/queue + corrective waves reached the ceiling/
reap-ancestry-dead|custodian-reap.sh|custodian-reap.test.sh|s/grep -qxF -- "\$branch"; then/false; then/
reap-ancestry-without-record|custodian-reap.sh|custodian-reap.test.sh|s/elif \[ -z "\$recorded" \]; then\n\s*tip_note="kept \(merged tip, no recorded commit\)"/elif [ -z "\$recorded" ]; then ancestry=1/
reap-record-off-default-counts|custodian-reap.sh|custodian-reap.test.sh|s/elif on_default "\$recorded"; then/elif true; then/
reap-unreadable-run-state-ignored|custodian-reap.sh|custodian-reap.test.sh|s/("\$1\/run-state.json" 2>\/dev\/null) \|\| return 1/$1 || true/
reap-unterminated-line-uncounted|custodian-reap.sh|custodian-reap.test.sh|s/\Q|| echo; }; }\E/|| true; }; }/
history-unterminated-line-uncounted|custodian-history.sh|custodian-guardrails.test.sh|s/\Q|| echo; }; }\E/|| true; }; }/
reap-default-heads-prefix-kept|custodian-reap.sh|custodian-reap.test.sh|s/DEFAULT=\$\{DEFAULT_REF#refs\/heads\/\}/DEFAULT=\$DEFAULT_REF/
reap-default-head-accepted|custodian-reap.sh|custodian-reap.test.sh|s/  head\|@\) echo/  NOMATCHZZZ) echo/; s/grep -qxF -e "\$given"/true || grep -qxF -e "$given"/
reap-default-case-blind|custodian-reap.sh|custodian-reap.test.sh|s/grep -qxF -e "\$given"/grep -qixF -e "$given"/
reap-default-dangling-origin-head|custodian-reap.sh|custodian-reap.test.sh|s/ && git -C "\$REPO_ROOT" show-ref --verify --quiet "\$origin_head"//
reap-default-guesses-main|custodian-reap.sh|custodian-reap.test.sh|s/\[ -n "\$DEFAULT" \] \|\| \{ echo "origin\/HEAD is unset/[ -n "$DEFAULT" ] || DEFAULT=main; true || { echo "origin\/HEAD is unset/
reap-default-auto-uses-local|custodian-reap.sh|custodian-reap.test.sh|s/    DEFAULT=\$origin_head/    DEFAULT=\$\{origin_head#refs\/remotes\/origin\/\}/
reap-default-slashed-remote-first-slash|custodian-reap.sh|custodian-reap.test.sh|s/remotes\/"\$remote"\/\};;/remotes\/}; DEFAULT=\$\{DEFAULT#*\/};;/
reap-default-unknown-remote-accepted|custodian-reap.sh|custodian-reap.test.sh|s/\[ -n "\$remote" \] \|\| \{ echo "--default \$DEFAULT names no configured remote" >&2; exit 2; \}/remote=\$\{DEFAULT_REF#refs\/remotes\/\}; remote=\$\{remote%%\/*\}/
reap-default-commit-accepted|custodian-reap.sh|custodian-reap.test.sh|s/\*\) echo "--default \$DEFAULT does not name a branch" >&2; exit 2;;/*) DEFAULT_REF=\$DEFAULT;;/
reap-merged-behind-dead|custodian-reap.sh|custodian-reap.test.sh|s/behind=\$\(merged_behind "\$branch" "\$tip"\) && \[ -n "\$behind" \]/false/
reap-merged-behind-any-tip|custodian-reap.sh|custodian-reap.test.sh|s/git -C "\$REPO_ROOT" merge-base --is-ancestor "\$oid" "\$2" 2>\/dev\/null && found/found/
reap-default-remote-prefix-kept|custodian-reap.sh|custodian-reap.test.sh|s/DEFAULT=\$\{DEFAULT#\*\/\}/:/g
reap-newline-split-unguarded|custodian-reap.sh|custodian-reap.test.sh|s/-print0 2>\/dev\/null/-print 2>\/dev\/null | tr "\\n" "\\0"/; s/case "\$dir" in "\$loops"\/\?\*\) ;; \*\) continue ;; esac/:/
reap-dot-dir-not-skipped|custodian-reap.sh|custodian-reap.test.sh|s/if ! git check-ref-format "refs\/heads\/\$branch"; then/if false; then/
reap-pr-tip-ignored|custodian-reap.sh|custodian-reap.test.sh|s/select\(\$tip == "" or \.headRefOid == \$tip\)/select(true)/
reap-deleted-branch-pr-ignored|custodian-reap.sh|custodian-reap.test.sh|s/select\(\$tip == "" or \.headRefOid == \$tip\)/select(.headRefOid == \$tip)/
reap-merged-pr-dead|custodian-reap.sh|custodian-reap.test.sh|s/elif \[ "\$gh_ok" -eq 1 \] && \[ -n "\$merged_pr" \]; then/elif false; then/
reap-open-pr-ignored|custodian-reap.sh|custodian-reap.test.sh|s/if \[ "\$gh_ok" -eq 1 \] && \[ -n "\$open" \]; then/if false; then/
reap-unmerged-reaped|custodian-reap.sh|custodian-reap.test.sh|s/reason="kept \(unmerged\)"/verdict=reap; reason="kept (unmerged)"/
reap-gh-absent-guessed|custodian-reap.sh|custodian-reap.test.sh|s/reason="kept \(merge unverifiable/verdict=reap; reason="kept (merge unverifiable/
reap-ingest-guard-off|custodian-reap.sh|custodian-reap.test.sh|s/!\(\$0 in seen\)/0/
reap-unreadable-gates-reaps|custodian-reap.sh|custodian-reap.test.sh|s/\Q|| missing=unreadable\E/|| missing=0/
reap-tmp-clear-dead|custodian-reap.sh|custodian-reap.test.sh|s/if \[ -e "\$dir\/run-state.json.tmp" \]; then/if false; then/
reap-plan-mode-deletes|custodian-reap.sh|custodian-reap.test.sh|s/\[ "\$APPLY" -eq 1 \] \|\| continue/true || continue/
reap-default-guard-off|custodian-reap.sh|custodian-reap.test.sh|s/if \[ "\$branch" = "\$DEFAULT" \]; then/if false; then/
reap-nested-guard-off|custodian-reap.sh|custodian-reap.test.sh|s/elif \[ -n "\$nested" \]; then/elif false; then/
reap-delete-failure-uncounted|custodian-reap.sh|custodian-reap.test.sh|s/>&2; failed=\$\(\(failed \+ 1\)\); continue/>&2; continue/
backup-copy-failure-ignored|custodian-backup.sh|custodian-backup.test.sh|s/\|\| \{ echo "copy failed: \$original" >&2; failed=\$\(\(failed \+ 1\)\); \}/|| true/
backup-manifest-despite-partial|custodian-backup.sh|custodian-backup.test.sh|s/if \[ "\$failed" -gt 0 \]; then/if false; then/
backup-seq-fixed|custodian-backup.sh|custodian-backup.test.sh|s/seq=\$\(\( \$\{seq:-0\} \+ 1 \)\)/seq=1/
backup-tags-first-only|custodian-backup.sh|custodian-backup.test.sh|s/\Qtags: (map(.tag) | unique)\E/tags: [.[0].tag]/
undo-picks-oldest|custodian-backup.sh|custodian-backup.test.sh|s/\Q-k2,2n | tail -1)\E/-k2,2n | head -1)/
undo-always-restores|custodian-backup.sh|custodian-backup.test.sh|s/if same "\$bdir\/\$backup" "\$original"; then/if false; then/
undo-other-issue-restored|custodian-backup.sh|custodian-backup.test.sh|s/\[ "\$newest" = "\$issue" \] \|\| die/true || die/
snapshot-zero-files-refused|custodian-backup.sh|custodian-backup.test.sh|s/(\n  \[\[ "\$day" =~ [^\n]*\n)/$1  [ -n "\$pairs" ] || die "nothing to snapshot"\n/
undo-empty-manifest-refused|custodian-backup.sh|custodian-backup.test.sh|s/\Q(.entries | type == "array")\E\n/(.entries | type == "array") and (.entries | length > 0)\n/
snapshot-dir-before-manifest|custodian-backup.sh|custodian-backup.test.sh|s/(  manifest=\$\(printf .*?\|\| die "cannot build manifest"\n)(  mkdir "\$bdir" \|\| die "cannot create \$bdir"\n)/$2$1/s
snapshot-follows-link|custodian-backup.sh|custodian-backup.test.sh|s/cp -P -p "\$original"/cp -p "\$original"/
undo-link-compared-by-content|custodian-backup.sh|custodian-backup.test.sh|s/if \[ -L "\$1" \] \|\| \[ -L "\$2" \]; then/if false; then/
undo-restore-follows-link|custodian-backup.sh|custodian-backup.test.sh|s/cp -P -p "\$bdir\/\$backup" "\$tmp"/cp -p "\$bdir\/\$backup" "\$tmp"/
undo-incomplete-not-refused|custodian-backup.sh|custodian-backup.test.sh|s/\[ -s "\$manifest" \] \|\| die "newest snapshot is incomplete[^"]*"/true/
undo-shape-check-off|custodian-backup.sh|custodian-backup.test.sh|s/\Qjq -e '(.entries | type == "array")\E/jq -e 'true or (.entries | type == "array")/
undo-preflight-off|custodian-backup.sh|custodian-backup.test.sh|s/\[ -f "\$bdir\/\$backup" \] \|\| die/true || die/
undo-follows-dir-link|custodian-backup.sh|custodian-backup.test.sh|s/\[ ! -L "\$original" \] \|\| rm -f -- "\$original"/true/
undo-moves-into-real-dir|custodian-backup.sh|custodian-backup.test.sh|s/\{ \[ -L "\$original" \] \|\| \[ ! -d "\$original" \]; \}/true/
undo-follows-parent-link|custodian-backup.sh|custodian-backup.test.sh|s/if ! parent_unmoved "\$original"; then/if false; then/
undo-deletes-backup|custodian-backup.sh|custodian-backup.test.sh|s/(\n  \[ "\$failed" -eq 0 \] \|\| exit 1\n\})/\n  rm -rf "\$bdir"$1/
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
