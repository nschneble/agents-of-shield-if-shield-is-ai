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

# Ceiling-kill: phases C/A/B ran and are logged, but Phase E was terminated
# before the report issue was opened. Leave a breadcrumb + a loud, actionable
# issue so the run is resumed, not silently lost.
alert_partial() {
  local sid="$1" tdir="$2"
  cat > "$LOGDIR/resume.json" <<EOF
{"date":"$DATE","reason":"bg-wait-ceiling","partial":true,"session_id":"$sid","transcript_dir":"$tdir","resume_cmd":"/looper-custodian resume $DATE"}
EOF
  osascript -e "display notification \"Phase E cut off at the bg-wait ceiling. Resume: /looper-custodian resume $DATE\" with title \"looper-custodian INCOMPLETE\"" >>"$LOG" 2>&1 || true
  gh issue create \
    --title "Custodian INCOMPLETE $DATE" \
    --body "$(printf 'The headless run hit `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` and Phase E (deep-research) was terminated before the report issue was opened. C/A/B completed and are logged.\n\nPhases done (`local/custodian/%s/custodian-log.jsonl`):\n\n```\n%s\n```\n\n**Finish it:** `/looper-custodian resume %s` — replays only the unlogged tail (Phase E → report), reusing C/A/B. The killed workflow'\''s findings are on disk at `%s`.\n' "$DATE" "$(phases_summary)" "$DATE" "$tdir")" \
    >>"$LOG" 2>&1 || true
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
  status=$?
  cat "$ATTEMPT_LOG" >> "$LOG"
  echo "=== attempt $attempt exit $status ($(date)) ===" >> "$LOG"

  # A ceiling-kill exits 0 but left the run half-done — catch it before the
  # exit-0 success path, and do NOT retry (a retry re-runs C/A/B and re-hits
  # the ceiling on E). Hand it to the resume path instead.
  if grep -q "$CEILING_MARKER" "$ATTEMPT_LOG"; then
    echo "=== attempt $attempt hit bg-wait ceiling — partial run, leaving resume breadcrumb (no retry) ===" >> "$LOG"
    alert_partial "$SID" "$TDIR"
    exit 3
  fi

  if [ "$status" -eq 0 ]; then
    exit 0
  fi
  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "=== all $MAX_ATTEMPTS attempts failed — alerting ===" >> "$LOG"
    alert_failure
    exit "$status"
  fi
  sleep "${BACKOFFS[$attempt]}"
  attempt=$((attempt + 1))
done
