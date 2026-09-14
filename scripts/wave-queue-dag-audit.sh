#!/usr/bin/env bash
# wave-queue-dag-audit — checks a run-state.json wave queue against the
# DAG/topological-sort invariant (SPOQ, arxiv 2606.03115). The dependency
# edges scope prints are never persisted, so that half reports NOT
# EVALUABLE; a schema era the arm cannot read declines, never fails.
# Usage: wave-queue-dag-audit.sh [--git REPO] [run-state.json ...]
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GIT_REPO=""
paths=()

# exit 2 for usage errors: 1 is reserved for "invariant violated"
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --git) needs_value --git "$#"; GIT_REPO="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--git REPO] [run-state.json ...]" >&2
      echo "  checks queue[] wave numbering + ask coverage; --git adds the" >&2
      echo "  execution-order proxy arm over shipped commits" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   paths+=("$1"); shift;;
  esac
done

if [ ${#paths[@]} -eq 0 ]; then
  branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ -n "$branch" ] || { echo "no paths given and no branch to infer one" >&2; exit 2; }
  paths=("$REPO_ROOT/local/loops/$branch/run-state.json")
fi

violations=0
checked=0
skipped_arms=0
snapshots_read=0

echo "wave-queue-dag-audit — ${#paths[@]} snapshot(s)"
echo "  DEPENDENCY-EDGE ORDERING IS NOT CHECKABLE ON THIS SCHEMA, see each report"
echo

arm() { # label, observed, want
  checked=$((checked + 1))
  if [ "$2" = "$3" ]; then
    printf '    ok     %-34s %s\n' "$1" "$2"
  else
    printf '    VIOLATION %-31s got %s · want %s\n' "$1" "$2" "$3"
    violations=$((violations + 1))
  fi
}

na() { printf '    n/a    %-34s %s\n' "$1" "$2"; }

decline() { # label, why -- an arm that COULD have been settled but wasn't
  skipped_arms=$((skipped_arms + 1))
  printf '    SKIP   %-34s %s\n' "$1" "$2"
}

for state in "${paths[@]}"; do
  echo "  $state"
  if [ ! -s "$state" ] || ! jq -e . "$state" >/dev/null 2>&1; then
    decline "whole snapshot" "missing, empty, or unparseable"
    echo
    continue
  fi
  snapshots_read=$((snapshots_read + 1))

  queue_len=$(jq -r '.queue | if type == "array" then length else -1 end' "$state")
  numbered=$(jq -r '[.queue[]? | select((.wave | type) == "number")] | length' "$state")

  if [ "$queue_len" -lt 0 ]; then
    decline "wave numbering (3 arms)" "no queue[] array in this snapshot"
    skipped_arms=$((skipped_arms + 2))
  elif [ "$queue_len" -eq 0 ]; then
    decline "wave numbering (3 arms)" "queue[] is empty — a snapshot keeping its wave records elsewhere"
    skipped_arms=$((skipped_arms + 2))
  elif [ "$numbered" -eq 0 ]; then
    decline "wave numbering (3 arms)" "$queue_len entry(s), none carrying a numeric \`wave\` — pre-queue-shape snapshot"
    skipped_arms=$((skipped_arms + 2))
  else
    arm "every entry has a wave number" "$((queue_len - numbered))" "0"

    distinct=$(jq -r '[.queue[]? | .wave | numbers] | unique | length' "$state")
    arm "no wave number used twice" "$((numbered - distinct))" "0"

    gaps=$(jq -r '
      ([.queue[]? | .wave | numbers] | unique) as $w
      | ($w | max) as $m
      | [range(1; $m + 1)] - $w | length' "$state")
    arm "waves are 1..N with no gaps" "$gaps" "0"
  fi

  # goal_contract ships in two shapes: {asks:[...]} and a bare array
  ask_ids=$(jq -r '
    (if (.goal_contract | type) == "array" then .goal_contract
     else (.goal_contract.asks? // []) end)
    | map(.id | tostring) | sort | join(",")' "$state")
  has_closes=$(jq -r '[.queue[]? | select(has("closes"))] | length' "$state")

  if [ -z "$ask_ids" ]; then
    decline "ask assignment (2 arms)" "snapshot declares no goal-contract asks"
    skipped_arms=$((skipped_arms + 1))
  elif [ "$has_closes" -eq 0 ]; then
    decline "ask assignment (2 arms)" "no queue entry carries \`closes\` — asks are not mapped to waves here"
    skipped_arms=$((skipped_arms + 1))
  else
    unassigned=$(jq -r --arg ids "$ask_ids" '
      ($ids | split(",")) as $asks
      | ([.queue[]? | .closes[]? | tostring] | unique) as $claimed
      | ($asks - $claimed) | length' "$state")
    arm "every ask is claimed by a wave" "$unassigned" "0"

    dangling=$(jq -r --arg ids "$ask_ids" '
      ($ids | split(",")) as $asks
      | ([.queue[]? | .closes[]? | tostring] | unique) as $claimed
      | ($claimed - $asks) | length' "$state")
    arm "every closes id is a declared ask" "$dangling" "0"
  fi

  # not a stub: the else arm is real, no snapshot has ever carried the field
  edges=$(jq -r '[.queue[]? | select(has("depends_on") or has("dependsOn")
                                     or has("depends") or has("blocked_by"))] | length' "$state")
  if [ "$edges" -eq 0 ]; then
    na "dependency edges ordered" \
      "NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints \`depends on:\` as prose only"
  else
    bad_edge=$(jq -r '
      [.queue[]? | . as $t | (.depends_on // .dependsOn // .depends // .blocked_by // [])[]
       | select(($t.wave | type) != "number" or (. | type) != "number" or . >= $t.wave)]
      | length' "$state")
    arm "dependency edges ordered" "$bad_edge" "0"
  fi

  # proxy arm: a correct topological order shows up as waves landing in order
  if [ -z "$GIT_REPO" ]; then
    na "execution realizes wave order" "not requested — pass --git REPO"
  elif ! git -C "$GIT_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    decline "execution realizes wave order" "$GIT_REPO is not a git repo"
  else
    shas=()
    while read -r sha; do
      [ -n "$sha" ] || continue
      git -C "$GIT_REPO" rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1 \
        && shas+=("$sha")
    done < <(jq -r '[.queue[]? | select(.status == "shipped" and (.wave | type) == "number"
                                       and .commit != null and .commit != "")]
                    | sort_by(.wave) | .[] | .commit' "$state")
    if [ ${#shas[@]} -lt 2 ]; then
      decline "execution realizes wave order" "${#shas[@]} shipped wave(s) with a resolvable sha — needs 2"
    else
      out_of_order=0
      for ((i = 1; i < ${#shas[@]}; i++)); do
        git -C "$GIT_REPO" merge-base --is-ancestor "${shas[$((i - 1))]}" "${shas[$i]}" 2>/dev/null \
          || out_of_order=$((out_of_order + 1))
      done
      arm "execution realizes wave order" "$out_of_order" "0"
    fi
  fi
  echo
done

if [ "$snapshots_read" -eq 0 ]; then
  echo "NOTHING CHECKED — no snapshot could be read"
  exit 2
fi
if [ "$checked" -eq 0 ]; then
  echo "NOTHING CHECKED — $snapshots_read snapshot(s) read, no arm could be settled"
  exit 2
fi

if [ "$violations" -gt 0 ]; then
  echo "QUEUE INVARIANT: $violations of $checked arm(s) violated across $snapshots_read snapshot(s)"
  exit 1
fi
if [ "$skipped_arms" -gt 0 ]; then
  echo "QUEUE INVARIANT: 0 of $checked arm(s) violated — INCOMPLETE, $skipped_arms arm(s) declined"
  exit 2
fi
echo "QUEUE INVARIANT: 0 of $checked arm(s) violated across $snapshots_read snapshot(s)"
exit 0
