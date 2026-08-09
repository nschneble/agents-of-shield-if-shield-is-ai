#!/bin/zsh
# looper-custodian weekly maintenance run (launchd-driven).
#
# Hosted LOCALLY, not via cloud /schedule: phases C/A/B read local-only state
# (local/loops scratch, ~/.claude memory, gates.jsonl across local repos) that
# an isolated cloud session cannot reach.
#
# Runs headless with --dangerously-skip-permissions because an unattended job
# cannot answer permission prompts. This is bounded: the scheduled run is
# PROPOSE-ONLY. C ingests the history index (derived cache), A rm's gitignored
# scratch (only after C has indexed it — ingest-guard), B is read-only, E hits
# the web, and the run ends by OPENING a GitHub issue. No tracked-file edits
# happen on this path. Destructive memory/agent edits are Phase D
# (/looper-custodian apply), which is human-triggered and never scheduled. The
# destructive-git guard hook still blocks history rewrites.
#
# The claude call gets MAX_ATTEMPTS tries with backoff — the 2026-07-06 and
# 2026-07-13 runs both died to a transient "API Error: Connection closed
# mid-response" and nobody noticed for two weeks. If every attempt fails, the
# failure is made loud: macOS notification + a "Custodian run FAILED" GitHub
# issue. No set -e: claude's exit code is handled explicitly so a failed
# attempt reaches the retry/alert path instead of killing the script.
#
# Phase E (deep-research) runs as a harness-backgrounded workflow; in -p mode
# the CLI blocks at end-of-turn waiting for it, capped by
# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS. The 2026-07-20 run hit the old 600s
# default mid-research: the harness terminated Phase E, and because a
# ceiling-kill still exits 0, the wrapper counted it a clean success — so the
# report issue was never opened and ~1.4M tokens of research were silently
# thrown away. Two guards now:
#   1. The ceiling is raised so a normal Phase E finishes and Phase F runs.
#   2. A ceiling-kill is DETECTED (marker in the run log), never retried
#      (a retry re-runs C/A/B and re-hits the ceiling), and turned into a
#      loud, RESUMABLE state: a resume.json breadcrumb + a "Custodian
#      INCOMPLETE" issue. /looper-custodian resume <date> then replays only
#      the unlogged tail (Phase E → report), reusing C/A/B. Each attempt runs
#      under a known --session-id so resume can find the killed workflow's
#      on-disk findings (resumeFromRunId is same-session only; the transcript
#      journal is the cross-session handle).
#
# A session-limit hit mid-run ("You've hit your session limit · resets 2pm",
# 2026-07-27) is a third failure mode: retries into the same dead window all
# die identically, so it's detected like a ceiling-kill, breadcrumbed, and the
# wrapper sleeps until the window's real reset epoch (usage-window-probe.sh)
# before running the resume path once. Only if that also fails does it alert.
#
# Those three all react AFTER a session was spent. The run-start gate below
# fires first: the skill's usage-window probe guards only Phase E, so a
# weekly tick landing in an already-hot window burns C/A/B before anything
# looks. This wrapper therefore probes BEFORE launching claude at all,
# against the same 95% default the Phase E gate uses.
#   hot on the 5-hour window   => wait out the reset, launch once, and
#                                 defer if it is still hot after the wait
#   hot on the WEEKLY window   => defer straight away, without the wait: a
#                                 7-day window cannot roll inside the 6h
#                                 wait cap, so waiting would burn the
#                                 morning and defer anyway
#   unread window              => launch unguarded and log it; unread is
#                                 not 0%
# Either defer path is as loud as a failure (notification + "Custodian
# INCOMPLETE" issue), because the original sin these alert paths exist for
# is a Monday that quietly did nothing.
#
# Exit codes: 0 ran (or resumed) cleanly; 3 bg-wait ceiling cut the run
# short, resumable; 4 session limit hit and the post-reset resume also
# failed; 5 the run-start usage-window gate deferred the run before any
# phase ran; anything else is claude's own exit from the last attempt.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Give a backgrounded Phase E room to finish before end-of-turn tears it down.
# The ~11 min deep-research fan-out this 30 min was sized against was observed
# under the INTERLEAVE — E dispatched while Phase B was still running, so part
# of E's runtime elapsed beside B's rather than inside this wait. Phases now
# run one at a time (decision 24, docs/looper-custodian.md), which moves more
# of E's runtime into the wait: the margin here is thinner than 11-vs-30 reads.
# The value is left alone until a live Monday measures it under the serial
# shape. A ceiling-kill past this is handled below (resume), not retried.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=1800000

REPO="$HOME/Developer/Repos/agents-of-shield-if-shield-is-ai"
cd "$REPO"

# ~/.claude transcript slug: the repo path with every "/" turned into "-".
SLUG="${REPO//\//-}"

DATE="$(date +%Y-%m-%d)"
LOGDIR="$REPO/local/custodian/$DATE"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/cron.log"

MAX_ATTEMPTS=3
BACKOFFS=(60 900)  # zsh arrays are 1-indexed: wait before attempt 2, attempt 3

# Usage-window threshold for the run-start gate. Deliberately the SAME
# default as the Phase E gate in skills/looper-custodian/SKILL.md — one
# rule checked at two points, not two policies. Move both or they drift.
# Overridable so the doc's word "tunable" is true of the code as well.
WINDOW_THRESHOLD="${WINDOW_THRESHOLD:-0.95}"
# Operator-facing copy says percent, because every doc surface and the
# probe's own output do. Derived once: interpolating the raw 0.95 next to
# an observed `97%` put two units in one sentence.
WINDOW_THRESHOLD_PCT="$(printf '%.0f%%' "$((WINDOW_THRESHOLD * 100))")"

# The harness prints this when it terminates background tasks at the ceiling.
# Matched as a substring so it holds regardless of the "<n>s" in the message.
CEILING_MARKER="Background tasks still running after"

# The CLI prints this when the subscription usage window is exhausted mid-run
# ("You've hit your session limit · resets 2pm"). Matched as a substring so it
# holds regardless of the reset-time suffix.
LIMIT_MARKER="hit your session limit"

# One line per logged phase, for the INCOMPLETE issue body.
phases_summary() {
  local logfile="$LOGDIR/custodian-log.jsonl"
  if command -v jq >/dev/null 2>&1 && [ -f "$logfile" ]; then
    jq -r '"\(.phase)\t\(.repo // "*")\t\(.action // "")\t\((.detail // "")[0:80])"' "$logfile" 2>/dev/null
  else
    tail -20 "$LOG"
  fi
}

alert_failure() {
  osascript -e "display notification \"Weekly run failed after $MAX_ATTEMPTS attempts. See local/custodian/$DATE/cron.log\" with title \"looper-custodian FAILED\"" >>"$LOG" 2>&1 || true
  gh issue create \
    --title "Custodian run FAILED $DATE" \
    --body "$(printf 'Headless custodian run failed after %s attempts.\n\nLog: `local/custodian/%s/cron.log` — last 30 lines:\n\n```\n%s\n```\n' "$MAX_ATTEMPTS" "$DATE" "$(tail -30 "$LOG")")" \
    >>"$LOG" 2>&1 || true
}

# Partial run: some phases ran and are logged, but the run was cut off before
# the report issue was opened. Leave a breadcrumb + a loud, actionable issue so
# the run is resumed, not silently lost. $3 is the machine reason slug for
# resume.json, $4 the human first sentence for the issue body.
alert_partial() {
  local sid="$1" tdir="$2" reason="$3" cause="$4"
  cat > "$LOGDIR/resume.json" <<EOF
{"date":"$DATE","reason":"$reason","partial":true,"session_id":"$sid","transcript_dir":"$tdir","resume_cmd":"/looper-custodian resume $DATE"}
EOF
  osascript -e "display notification \"Run cut off ($reason). Resume: /looper-custodian resume $DATE\" with title \"looper-custodian INCOMPLETE\"" >>"$LOG" 2>&1 || true
  gh issue create \
    --title "Custodian INCOMPLETE $DATE" \
    --body "$(printf '%s Completed phases are logged.\n\nPhases done (`local/custodian/%s/custodian-log.jsonl`):\n\n```\n%s\n```\n\n**Finish it:** `/looper-custodian resume %s` — replays only the unlogged tail (Phase E → report), reusing the phases already logged. Any killed workflow'\''s findings are on disk at `%s`.\n' "$cause" "$DATE" "$(phases_summary)" "$DATE" "$tdir")" \
    >>"$LOG" 2>&1 || true
}

# Render a window_state string as a clause naming WHY the window is hot.
# `rejected` must NOT borrow the threshold narrative: window_state flags it
# at ANY utilization precisely because the bare pct would read like a
# threshold trip that never happened, and an alert that then hardcodes
# "at or over the N% threshold" reintroduces the same misread.
window_reason() {
  local state="$1" win
  win="${state#hot }"; win="${win%% *}"
  case "$state" in
    *rejected@*)
      printf 'the API rejected requests on the %s window, which is a hard stop at any utilization (observed: `%s`)' "$win" "$state" ;;
    'hot '*)
      printf 'the %s window was at or over the %s threshold (observed: `%s`)' "$win" "$WINDOW_THRESHOLD_PCT" "$state" ;;
    # defensive: only `hot *` states reach alert_deferred today, and this
    # arm must stay true of whatever else ever does
    *)
      printf 'the run-start gate did not clear the usage window (observed: `%s`)' "$state" ;;
  esac
}

# Run-start defer: the window blocked the run at launch, so NO phase ran.
# Nothing is logged and there is no tail to replay, which is why the
# breadcrumb names a fresh run rather than `resume`. Kept as loud as a hard
# failure on purpose — a weekly job that quietly does nothing is the
# 2026-07 silent Monday again.
#
# $2 is the caller's own history sentence, the way alert_partial takes its
# $cause. The two callers reach here with materially different histories —
# the weekly branch defers immediately, having waited zero seconds — and a
# single hardcoded "still over it after waiting for the reset" told the
# operator about a wait that never happened.
alert_deferred() {
  local state="$1" cause="$2"
  cat > "$LOGDIR/resume.json" <<EOF
{"date":"$DATE","reason":"usage-window","partial":false,"started":false,"window":"$state","resume_cmd":"/looper-custodian"}
EOF
  osascript -e "display notification \"Usage window blocked the run ($state) — deferred. Retry: /looper-custodian\" with title \"looper-custodian INCOMPLETE\"" >>"$LOG" 2>&1 || true
  gh issue create \
    --title "Custodian INCOMPLETE $DATE" \
    --body "$(printf 'The weekly run never started: %s. %s No phase ran, so nothing is logged and there is no tail to replay.\n\n**Run it:** `/looper-custodian` — a fresh run, not `resume`.\n' "$(window_reason "$state")" "$cause")" \
    >>"$LOG" 2>&1 || true
}

# Read the real rate-limit window and classify it against WINDOW_THRESHOLD.
# Echoes exactly one of:
#   hot <window> <why>   over threshold, or the server said "rejected"
#   ok                   under threshold on both windows
#   unread <reason>      probe could not read the window, or WINDOW_THRESHOLD
#                        was not a number to compare it against
# <why> names which signal fired, not just a number: a "rejected" status is
# a hard stop at ANY utilization, so reporting its (possibly tiny) pct
# alone would read like a threshold trip that never happened.
# An unread window is UNREAD, not 0% — the caller launches and says so, the
# same contract usage-window-probe.sh documents for read_ok:false. That
# includes an absent python3: with no interpreter this echoed nothing, the
# caller's `case ""` fell through to its catch-all, and the log said the
# window was ok — a fabricated reading, the exact thing the unread arm
# exists to prevent.
window_state() {
  command -v python3 >/dev/null 2>&1 || { echo "unread no_python3"; return; }
  "$REPO/scripts/usage-window-probe.sh" 2>/dev/null \
    | THRESHOLD="$WINDOW_THRESHOLD" python3 -c '
import json, os, sys
try:
    p = json.load(sys.stdin)
except Exception:
    print("unread parse_failed"); sys.exit(0)
if not p.get("read_ok"):
    print("unread %s" % p.get("reason", "unknown")); sys.exit(0)
# a non-numeric WINDOW_THRESHOLD raised here, which printed nothing, and
# the caller read an empty state as "unrecognized probe output: ''" and
# launched with both windows possibly at 99%. Fail-open stays the
# contract; naming the threshold is what makes it fixable, since the env
# override is the only way to reach this at all.
try:
    t = float(os.environ["THRESHOLD"])
except ValueError:
    print("unread bad_threshold=%r" % os.environ["THRESHOLD"]); sys.exit(0)
# weekly first, both passes. Returning on the first hit of a
# ("five_hour", "weekly") scan let a hot 5-hour window MASK a hot weekly
# one: the caller then took the wait arm, slept up to 6h, re-probed and
# deferred anyway — the outcome the weekly fast path exists to avoid, and
# not an exotic case, since a weekly window at 95% generally got there by
# burning 5-hour windows.
names = ("weekly", "five_hour")
def pct(w):
    u = w.get("utilization")
    return "%.0f%%" % (u * 100) if u is not None else "unread"
# rejected is a hard stop at ANY utilization, so it outranks every
# threshold comparison and is scanned across BOTH windows first.
for name in names:
    w = p.get(name) or {}
    if w.get("status") == "rejected":
        print("hot %s rejected@%s" % (name, pct(w))); sys.exit(0)
readable = 0
for name in names:
    w = p.get(name) or {}
    u = w.get("utilization")
    if u is None:
        continue
    readable += 1
    if u >= t:
        print("hot %s %s" % (name, pct(w))); sys.exit(0)
# read_ok with no utilization on either window is still no reading. Saying
# "ok" here would fabricate 0% just as surely as an absent probe does.
if readable == 0:
    print("unread no_utilization"); sys.exit(0)
print("ok")
'
}

# Sleep until the 5h usage window resets. Reads the real reset epoch from the
# ratelimit-header probe; a bounded fallback covers an unreadable probe. Capped
# at 6h so a bad epoch can't park the job forever.
wait_for_window_reset() {
  local probe now reset wait
  probe="$("$REPO/scripts/usage-window-probe.sh" 2>/dev/null || true)"
  now=$(date +%s)
  reset=$(printf '%s' "$probe" | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin)["five_hour"]["reset"]))
except Exception: pass' 2>/dev/null)
  if [ -n "$reset" ] && [ "$reset" -gt "$now" ]; then
    wait=$((reset - now + 120))
  else
    wait=3600
  fi
  [ "$wait" -gt 21600 ] && wait=21600
  echo "=== waiting ${wait}s for the usage window to reset ($(date)) ===" >> "$LOG"
  sleep "$wait"
}

# Run-start gate. The Phase E probe guards only the run's biggest dispatch;
# C/A/B run before it and are not free, so a cron firing into an already
# hot window has spent what's left by the time E looks. Probe before
# spending a headless session at all: hot on the 5h window => wait the
# reset and launch once, defer if still hot; hot on the weekly window =>
# defer straight away, no wait. Unread => launch, say so.
gate_state="$(window_state)"
case "$gate_state" in
  'hot weekly'*)
    # A 7-day window does not roll inside wait_for_window_reset's 6h cap,
    # and that helper reads the 5h reset epoch anyway — so waiting one out
    # would burn the morning and defer regardless. Defer now, loudly.
    echo "=== run-start gate: usage window $gate_state — weekly window will not reset inside the wait cap, deferring the run ===" >> "$LOG"
    alert_deferred "$gate_state" \
      'The run deferred immediately, without waiting: a 7-day window cannot reset inside the wrapper 6-hour wait cap, so waiting would have burned the morning and deferred anyway.'
    exit 5
    ;;
  'hot '*)
    echo "=== run-start gate: usage window $gate_state (threshold $WINDOW_THRESHOLD_PCT) — waiting for reset before launching ($(date)) ===" >> "$LOG"
    wait_for_window_reset
    gate_state="$(window_state)"
    if [[ "$gate_state" == 'hot '* ]]; then
      echo "=== run-start gate: window still $gate_state after the wait — deferring the run ===" >> "$LOG"
      alert_deferred "$gate_state" \
        'The wrapper waited out the window reset and re-probed; the window was still blocking.'
      exit 5
    fi
    echo "=== run-start gate: window cleared ($gate_state) — launching ($(date)) ===" >> "$LOG"
    ;;
  'unread '*)
    echo "=== run-start gate: usage window $gate_state — launching unguarded ($(date)) ===" >> "$LOG"
    ;;
  ok)
    echo "=== run-start gate: usage window ok — launching ($(date)) ===" >> "$LOG"
    ;;
  # anything window_state has no vocabulary for is UNREAD, not ok. This
  # arm used to log "usage window ok", so a probe that echoed nothing —
  # no python3, a crashed interpreter — recorded a reading never taken.
  *)
    echo "=== run-start gate: usage window unread (unrecognized probe output: '$gate_state') — launching unguarded ($(date)) ===" >> "$LOG"
    ;;
esac

attempt=1
while true; do
  SID="$(uuidgen)"
  TDIR="$HOME/.claude/projects/$SLUG/$SID"
  ATTEMPT_LOG="$LOGDIR/attempt-$attempt.out"
  echo "=== looper-custodian run $(date) (attempt $attempt/$MAX_ATTEMPTS, session $SID) ===" >> "$LOG"
  claude -p "/looper-custodian" \
    --session-id "$SID" \
    --dangerously-skip-permissions \
    --output-format text \
    > "$ATTEMPT_LOG" 2>&1
  rc=$?  # NOT `status` — that's a read-only zsh special parameter (it IS $?);
         # assigning it is fatal in a script, which is how the 2026-07-27 run
         # died with every recovery path below unreached.
  cat "$ATTEMPT_LOG" >> "$LOG"
  echo "=== attempt $attempt exit $rc ($(date)) ===" >> "$LOG"

  # A ceiling-kill exits 0 but left the run half-done — catch it before the
  # exit-0 success path, and do NOT retry (a retry re-runs C/A/B and re-hits
  # the ceiling on E). Hand it to the resume path instead.
  if grep -q "$CEILING_MARKER" "$ATTEMPT_LOG"; then
    echo "=== attempt $attempt hit bg-wait ceiling — partial run, leaving resume breadcrumb (no retry) ===" >> "$LOG"
    alert_partial "$SID" "$TDIR" "bg-wait-ceiling" \
      'The headless run hit `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` and Phase E (deep-research) was terminated before the report issue was opened.'
    exit 3
  fi

  # Session limit hit mid-run (2026-07-27). Retrying into the same dead window
  # is futile — every attempt dies the same way — and a full retry after reset
  # would redo the already-logged phases. Instead: breadcrumb now (survives a
  # reboot mid-sleep), wait out the window, then run the RESUME path once —
  # it replays only the unlogged tail.
  if grep -q "$LIMIT_MARKER" "$ATTEMPT_LOG"; then
    echo "=== attempt $attempt hit the session limit — waiting for reset, then resuming (no blind retry) ===" >> "$LOG"
    cat > "$LOGDIR/resume.json" <<EOF
{"date":"$DATE","reason":"session-limit","partial":true,"session_id":"$SID","transcript_dir":"$TDIR","resume_cmd":"/looper-custodian resume $DATE"}
EOF
    wait_for_window_reset
    RESUME_SID="$(uuidgen)"
    RESUME_LOG="$LOGDIR/resume-attempt.out"
    echo "=== resume attempt $(date) (session $RESUME_SID) ===" >> "$LOG"
    claude -p "/looper-custodian resume $DATE" \
      --session-id "$RESUME_SID" \
      --dangerously-skip-permissions \
      --output-format text \
      > "$RESUME_LOG" 2>&1
    rrc=$?
    cat "$RESUME_LOG" >> "$LOG"
    echo "=== resume attempt exit $rrc ($(date)) ===" >> "$LOG"
    if [ "$rrc" -ne 0 ] || grep -q -e "$LIMIT_MARKER" -e "$CEILING_MARKER" "$RESUME_LOG"; then
      alert_partial "$SID" "$TDIR" "session-limit" \
        'The headless run hit the session usage limit mid-flight, and the automatic post-reset resume attempt also failed.'
      exit 4
    fi
    exit 0
  fi

  if [ "$rc" -eq 0 ]; then
    exit 0
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "=== all $MAX_ATTEMPTS attempts failed — alerting ===" >> "$LOG"
    alert_failure
    exit "$rc"
  fi
  sleep "${BACKOFFS[$attempt]}"
  attempt=$((attempt + 1))
done
