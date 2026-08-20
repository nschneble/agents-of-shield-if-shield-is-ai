#!/usr/bin/env bash
# looper-custodian-cron.test.sh — end-to-end test for the run-start
# usage-window gate in scripts/looper-custodian-cron.sh.
#
# Drives every arm of the wrapper's `case "$gate_state"` through a stub
# probe, with claude, gh, osascript and sleep stubbed on PATH — a run here
# costs no session, opens no issue and waits no seconds. Reachable at all
# only because the wrapper takes REPO / LOGDIR / WINDOW_PROBE /
# CUSTODIAN_PATH_PREFIX; the last of those is what makes the stubs bite,
# since the wrapper PREPENDS /opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:
# /sbin and so shadows a stub dir handed in through PATH.
#
# PROBE FIXTURE PROVENANCE — both shapes were CAPTURED by running the real
# scripts/usage-window-probe.sh on 2026-08-20, never hand-written:
#   read_ok:true    one live probe; the account read `allowed` on both
#                   windows, at 58% (5h) and 42% (weekly)
#   read_ok:false   the same probe under HOME=<empty dir> and a
#                   nonexistent USER, reaching its emit_unreadable arm
# They differ in whitespace — json.dumps spacing against a bare printf —
# and that asymmetry is the half a hand-written payload gets wrong. Hot
# and rejected fixtures vary ONLY utilization, status and reset on the
# captured line, through jq. `status: "rejected"` is the one value not
# observed live: the account was `allowed`, and the probe passes the
# anthropic-ratelimit-unified-*-status header through verbatim.
#
# Both directions on every axis the gate branches on: a clear window
# LAUNCHES and a hot one DEFERS; a hot weekly defers with NO wait while a
# hot 5-hour one waits first; a `rejected` status is narrated as a hard
# stop and never as a threshold trip.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cron="$here/looper-custodian-cron.sh"

# a failing mktemp returns empty, which makes every derived fixture path
# absolute (/bin, /case-1) and scatters the run outside the temp tree.
# Abort loudly rather than half-run against paths nobody intended. The
# explicit template is what makes TMPDIR the input the message names: a
# bare `mktemp -d` ignores TMPDIR on BSD and allocates under /var/folders.
# one arm per shape: mktemp's own stderr explains a nonzero exit, but the
# empty-yet-successful shape prints nothing, so "failed" would be a lie
die_temp() { echo "FATAL: $1; refusing to run" >&2; exit 2; }
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/looper-suite.XXXXXX") \
  || die_temp "mktemp -d exited nonzero (TMPDIR=${TMPDIR:-unset})"
[ -n "$temp_dir" ] \
  || die_temp "mktemp -d exited 0 with no path (TMPDIR=${TMPDIR:-unset})"
[ -d "$temp_dir" ] || die_temp "mktemp -d gave a non-directory: $temp_dir"
trap 'rm -rf "$temp_dir"' EXIT

# a skipped suite is not a passing one, and CI's image ships no zsh
command -v zsh >/dev/null 2>&1 \
  || die_temp "zsh is not installed and $cron is a zsh script"

fails=0
check() { # desc, condition-already-evaluated ($?)
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}

# --- captured probe output ----------------------------------------------
CAPTURED_OK='{"read_ok": true, "source": "keychain", "five_hour": {"utilization": 0.58, "status": "allowed", "reset": 1787205000}, "weekly": {"utilization": 0.42, "status": "allowed", "reset": 1787522400}, "representative": "five_hour"}'
CAPTURED_UNREAD='{"read_ok":false,"reason":"no_credentials"}'

# relative to now, so the derived wait is fixed rather than clock-drifted
RESET_AHEAD=$(( $(date +%s) + 3000 ))
variant() { printf '%s\n' "$CAPTURED_OK" | jq -c "$1"; }
OK_LINE=$(variant '.')
HOT_5H=$(variant ".five_hour.utilization = 0.97 | .five_hour.reset = $RESET_AHEAD")
HOT_WEEKLY=$(variant ".weekly.utilization = 0.96 | .five_hour.reset = $RESET_AHEAD")
HOT_BOTH=$(variant ".weekly.utilization = 0.96 | .five_hour.utilization = 0.97 | .five_hour.reset = $RESET_AHEAD")
REJ_WEEKLY=$(variant '.weekly.status = "rejected"')
REJ_5H=$(variant ".five_hour.status = \"rejected\" | .five_hour.reset = $RESET_AHEAD")

# --- stubs: real executables, first on the wrapper's own PATH prefix -----
bin="$temp_dir/bin"; mkdir -p "$bin" || die_temp "cannot create $bin"

# no stub writes stdout: the wrapper greps claude's output for the
# ceiling and session-limit markers, and a stub line would forge one
for tool in osascript sleep; do
  cat > "$bin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$CRON_CALLS/$tool"
EOF
  chmod +x "$bin/$tool"
done
# the wrapper builds a transcript path out of this, so it must look like one
cat > "$bin/uuidgen" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CRON_CALLS/uuidgen"
printf '00000000-0000-4000-8000-000000000000\n'
EOF
chmod +x "$bin/uuidgen"
# the body arrives as one argument holding newlines, so it cannot also
# be the thing counted one-line-per-call
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh\n' >> "$CRON_CALLS/gh"
printf '%s\n' "$*" >> "$CRON_CALLS/gh-args"
EOF
chmod +x "$bin/gh"
# cwd is all REPO still decides once LOGDIR and WINDOW_PROBE are set
cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CRON_CALLS/claude"
pwd -P >> "$CRON_CALLS/claude-cwd"
EOF
chmod +x "$bin/claude"

# the 5-hour arm probes twice — classify, then read the reset epoch — so
# a fixture is a queue whose last line repeats
probe="$bin/usage-window-probe.sh"
cat > "$probe" <<'EOF'
#!/usr/bin/env bash
printf 'probe\n' >> "$CRON_CALLS/probe"
line=$(head -n 1 "$PROBE_QUEUE")
if [ "$(wc -l < "$PROBE_QUEUE")" -gt 1 ]; then
  tail -n +2 "$PROBE_QUEUE" > "$PROBE_QUEUE.next" && mv "$PROBE_QUEUE.next" "$PROBE_QUEUE"
fi
printf '%s\n' "$line"
EOF
chmod +x "$probe"

# the real custodian tree, inventoried before any case runs: an override
# that did not take writes this run's log and breadcrumb into it
real_dir="$here/../local/custodian/$(date +%Y-%m-%d)"
real_before=$(find "$real_dir" -type f 2>/dev/null | sort)

# --- harness ------------------------------------------------------------
case_n=0
setup_case() { # queue-line... — one probe reading per line, in order
  case_n=$((case_n + 1))
  case_dir="$temp_dir/case-$case_n"
  mkdir -p "$case_dir/logs" "$case_dir/calls" "$case_dir/repo" \
    || die_temp "cannot create $case_dir"
  printf '%s\n' "$@" > "$case_dir/queue"
  log="$case_dir/logs/cron.log"
}

run_cron() { # VAR=VAL... — extra env for this run
  env REPO="$case_dir/repo" LOGDIR="$case_dir/logs" \
      WINDOW_PROBE="$probe" CUSTODIAN_PATH_PREFIX="$bin" \
      PROBE_QUEUE="$case_dir/queue" CRON_CALLS="$case_dir/calls" \
      "$@" "$cron" >/dev/null 2>&1
  rc=$?
}

calls() { # tool — how many times it was invoked
  local f="$case_dir/calls/$1"
  if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi
}

logged() { grep -qF "$1" "$log"; }
issue()  { grep -qF "$1" "$case_dir/calls/gh-args" 2>/dev/null; }

# --- CLEAR: under threshold on both windows, on the captured reading ----
setup_case "$OK_LINE"
run_cron
[ "$rc" -eq 0 ] && r=0 || r=1
check "CLEAR: exits 0 (got $rc)" "$r"
logged 'run-start gate: usage window ok — launching'; check "CLEAR: logs the clear reading" $?
[ "$(calls claude)" = 1 ] && r=0 || r=1
check "CLEAR: launched claude once (got $(calls claude))" "$r"
[ "$(calls sleep)" = 0 ] && r=0 || r=1
check "CLEAR: waited for nothing (sleep called $(calls sleep)x)" "$r"
[ "$(calls gh)" = 0 ] && r=0 || r=1
check "CLEAR: opened no issue (gh called $(calls gh)x)" "$r"
[ ! -f "$case_dir/logs/resume.json" ]
check "CLEAR: left no resume breadcrumb" $?
cwd=$(cat "$case_dir/calls/claude-cwd" 2>/dev/null)
want=$(cd "$case_dir/repo" && pwd -P)
[ "$cwd" = "$want" ] && r=0 || r=1
check "CLEAR: REPO override ran it in the fixture repo (cwd $cwd, want $want)" "$r"

# --- HOT WEEKLY: defers immediately, without the wait --------------------
setup_case "$HOT_WEEKLY"
run_cron
[ "$rc" -eq 5 ] && r=0 || r=1
check "HOT-WEEKLY: exits 5 (got $rc)" "$r"
[ "$(calls sleep)" = 0 ] && r=0 || r=1
check "HOT-WEEKLY: never waits (sleep called $(calls sleep)x)" "$r"
[ "$(calls claude)" = 0 ] && r=0 || r=1
check "HOT-WEEKLY: spends no session (claude called $(calls claude)x)" "$r"
logged 'weekly window will not reset inside the wait cap'
check "HOT-WEEKLY: logs why it did not wait" $?
grep -qF '"window":"hot weekly 96%"' "$case_dir/logs/resume.json" 2>/dev/null
check "HOT-WEEKLY: breadcrumb names the observed state" $?
grep -qF '"started":false' "$case_dir/logs/resume.json" 2>/dev/null
check "HOT-WEEKLY: breadcrumb says no phase ran" $?
issue 'Custodian INCOMPLETE'; check "HOT-WEEKLY: opens the INCOMPLETE issue" $?
issue 'the weekly window was at or over the 95% threshold'
check "HOT-WEEKLY: issue names the threshold trip" $?
issue 'deferred immediately, without waiting'
check "HOT-WEEKLY: issue tells the operator no wait happened" $?

# --- HOT 5-HOUR then CLEAR: waits out the reset, then launches -----------
# three readings: classify, read the reset epoch, re-classify after the wait
setup_case "$HOT_5H" "$HOT_5H" "$OK_LINE"
run_cron
[ "$rc" -eq 0 ] && r=0 || r=1
check "HOT-5H-CLEARS: exits 0 (got $rc)" "$r"
[ "$(calls sleep)" = 1 ] && r=0 || r=1
check "HOT-5H-CLEARS: waited once (sleep called $(calls sleep)x)" "$r"
waited=$(head -1 "$case_dir/calls/sleep" 2>/dev/null || echo 0)
# reset + 120, not the 3600 fallback and not the 21600 cap
[ "${waited:-0}" -ge 3000 ] && [ "${waited:-0}" -le 3120 ] && r=0 || r=1
check "HOT-5H-CLEARS: slept the probe's reset + 120 (${waited}s, want 3000-3120)" "$r"
logged 'waiting for reset before launching'; check "HOT-5H-CLEARS: logs the wait" $?
logged 'window cleared (ok) — launching'; check "HOT-5H-CLEARS: logs the re-probe clearing" $?
[ "$(calls claude)" = 1 ] && r=0 || r=1
check "HOT-5H-CLEARS: launched claude once after the wait (got $(calls claude))" "$r"
[ "$(calls gh)" = 0 ] && r=0 || r=1
check "HOT-5H-CLEARS: opened no issue (gh called $(calls gh)x)" "$r"

# --- HOT 5-HOUR still hot after the wait: defers -------------------------
setup_case "$HOT_5H" "$HOT_5H" "$HOT_5H"
run_cron
[ "$rc" -eq 5 ] && r=0 || r=1
check "HOT-5H-STAYS: exits 5 (got $rc)" "$r"
[ "$(calls sleep)" = 1 ] && r=0 || r=1
check "HOT-5H-STAYS: waited before giving up (sleep called $(calls sleep)x)" "$r"
[ "$(calls claude)" = 0 ] && r=0 || r=1
check "HOT-5H-STAYS: spends no session (claude called $(calls claude)x)" "$r"
logged 'still hot five_hour 97% after the wait'
check "HOT-5H-STAYS: logs the state it gave up on" $?
issue 'waited out the window reset and re-probed'
check "HOT-5H-STAYS: issue tells the operator a wait DID happen" $?
issue 'the five_hour window was at or over the 95% threshold'
check "HOT-5H-STAYS: issue names the threshold trip" $?

# --- REJECTED on the weekly window: hard stop, no wait, no threshold tale -
setup_case "$REJ_WEEKLY"
run_cron
[ "$rc" -eq 5 ] && r=0 || r=1
check "REJECTED-WEEKLY: exits 5 (got $rc)" "$r"
[ "$(calls sleep)" = 0 ] && r=0 || r=1
check "REJECTED-WEEKLY: never waits (sleep called $(calls sleep)x)" "$r"
issue 'hard stop at any utilization'
check "REJECTED-WEEKLY: issue calls it a rejection" $?
# 42% is under the threshold, so that sentence would report a phantom trip
! issue 'at or over the 95% threshold'
check "REJECTED-WEEKLY: issue does NOT borrow the threshold narrative" $?
issue 'hot weekly rejected@42%'
check "REJECTED-WEEKLY: issue quotes the observed state verbatim" $?

# --- REJECTED on the 5-hour window: same hard stop, but the WAIT arm -----
setup_case "$REJ_5H" "$REJ_5H" "$OK_LINE"
run_cron
[ "$rc" -eq 0 ] && r=0 || r=1
check "REJECTED-5H: exits 0 once the window clears (got $rc)" "$r"
[ "$(calls sleep)" = 1 ] && r=0 || r=1
check "REJECTED-5H: takes the wait arm, unlike weekly (sleep called $(calls sleep)x)" "$r"
logged 'usage window hot five_hour rejected@58%'
check "REJECTED-5H: logs the rejection on the 5-hour window" $?
[ "$(calls claude)" = 1 ] && r=0 || r=1
check "REJECTED-5H: launched after the wait (got $(calls claude))" "$r"

# --- BOTH hot: the weekly reading must not be masked by the 5-hour one ---
# scanning five_hour first hid a hot weekly one behind a 6h wait
setup_case "$HOT_BOTH"
run_cron
[ "$rc" -eq 5 ] && r=0 || r=1
check "BOTH-HOT: exits 5 (got $rc)" "$r"
[ "$(calls sleep)" = 0 ] && r=0 || r=1
check "BOTH-HOT: weekly wins, so no wait (sleep called $(calls sleep)x)" "$r"
issue 'hot weekly 96%'
check "BOTH-HOT: reports the weekly window, not the 5-hour one" $?

# --- UNREAD: an unreadable probe launches unguarded and says so ----------
setup_case "$CAPTURED_UNREAD"
run_cron
[ "$rc" -eq 0 ] && r=0 || r=1
check "UNREAD: exits 0 (got $rc)" "$r"
logged 'usage window unread no_credentials — launching unguarded'
check "UNREAD: logs the reason the probe gave, not a 0% it never read" $?
[ "$(calls claude)" = 1 ] && r=0 || r=1
check "UNREAD: launches anyway (claude called $(calls claude)x)" "$r"

# --- THRESHOLD override: the same captured reading, a lower bar ---------
# no field touched, so the arm tracks the threshold and not the fixture
setup_case "$OK_LINE" "$OK_LINE" "$OK_LINE"
run_cron WINDOW_THRESHOLD=0.5
[ "$rc" -eq 5 ] && r=0 || r=1
check "THRESHOLD: the unmodified capture defers at 0.5 (got $rc)" "$r"
issue 'the five_hour window was at or over the 50% threshold'
check "THRESHOLD: the issue renders the overridden threshold, not 95%" $?

# --- the seams themselves: nothing was written outside the case dirs ----
[ -f "$temp_dir/case-1/logs/cron.log" ]
check "SEAMS: LOGDIR override placed the run log under the fixture" $?
[ "$(find "$real_dir" -type f 2>/dev/null | sort)" = "$real_before" ]
check "SEAMS: $case_n runs left the repo's own custodian tree untouched" $?

echo
if [ "$fails" -eq 0 ]; then echo "all custodian-cron gate tests passed"; exit 0
else echo "$fails custodian-cron gate test(s) FAILED"; exit 1; fi
