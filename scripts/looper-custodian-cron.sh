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
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
REPO="$HOME/Developer/Repos/agents-of-shield-if-shield-is-ai"
cd "$REPO"

DATE="$(date +%Y-%m-%d)"
LOGDIR="$REPO/local/custodian/$DATE"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/cron.log"

MAX_ATTEMPTS=3
BACKOFFS=(60 900)  # zsh arrays are 1-indexed: wait before attempt 2, attempt 3

alert_failure() {
  osascript -e "display notification \"Weekly run failed after $MAX_ATTEMPTS attempts. See local/custodian/$DATE/cron.log\" with title \"looper-custodian FAILED\"" >>"$LOG" 2>&1 || true
  gh issue create \
    --title "Custodian run FAILED $DATE" \
    --body "$(printf 'Headless custodian run failed after %s attempts.\n\nLog: `local/custodian/%s/cron.log` — last 30 lines:\n\n```\n%s\n```\n' "$MAX_ATTEMPTS" "$DATE" "$(tail -30 "$LOG")")" \
    >>"$LOG" 2>&1 || true
}

attempt=1
while true; do
  echo "=== looper-custodian run $(date) (attempt $attempt/$MAX_ATTEMPTS) ===" >> "$LOG"
  claude -p "/looper-custodian" \
    --dangerously-skip-permissions \
    --output-format text \
    >> "$LOG" 2>&1
  status=$?
  echo "=== attempt $attempt exit $status ($(date)) ===" >> "$LOG"
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
