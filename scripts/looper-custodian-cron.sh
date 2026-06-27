#!/bin/zsh
# looper-custodian weekly maintenance run (launchd-driven).
#
# Hosted LOCALLY, not via cloud /schedule: phases A/B/C read local-only state
# (local/loops scratch, ~/.claude memory, gates.jsonl across local repos) that
# an isolated cloud session cannot reach.
#
# Runs headless with --dangerously-skip-permissions because an unattended job
# cannot answer permission prompts. This is bounded: the scheduled run is
# PROPOSE-ONLY. Phase A rm's gitignored scratch, B/C are read-only, E hits the
# web, and the run ends by OPENING a GitHub issue. No tracked-file edits happen
# on this path. Destructive memory/agent edits are Phase D
# (/looper-custodian apply), which is human-triggered and never scheduled. The
# destructive-git guard hook still blocks history rewrites.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
REPO="$HOME/Developer/Repos/agents-of-shield-if-shield-is-ai"
cd "$REPO"

DATE="$(date +%Y-%m-%d)"
LOGDIR="$REPO/local/custodian/$DATE"
mkdir -p "$LOGDIR"

echo "=== looper-custodian run $(date) ===" >> "$LOGDIR/cron.log"
claude -p "/looper-custodian" \
  --dangerously-skip-permissions \
  --output-format text \
  >> "$LOGDIR/cron.log" 2>&1
echo "=== done $(date) (exit $?) ===" >> "$LOGDIR/cron.log"
