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
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

# Give a backgrounded Phase E room to finish before end-of-turn tears it down.
# 30 min clears an observed ~11 min deep-research fan-out with headroom while
# still bounding a genuinely hung task. A ceiling-kill past this is handled
# below (resume), not retried.
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
