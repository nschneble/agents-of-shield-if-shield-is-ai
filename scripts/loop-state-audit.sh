#!/usr/bin/env bash
# loop-state-audit — asserts run-state.json agrees with the append-only
# records beside it (gates.jsonl, wave-N.jsonl); logs are the oracle. A
# field the logs can't settle reports NOT EVALUABLE, never guessed.
# Usage: loop-state-audit.sh [--branch NAME] [--dir PATH] [--pr]
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BRANCH=""
DIR=""
CHECK_PR=0

# exit 2 for usage errors: 1 is reserved for "drift found"
needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) needs_value --branch "$#"; BRANCH="$2"; shift 2;;
    --dir)    needs_value --dir    "$#"; DIR="$2";    shift 2;;
    --pr)     CHECK_PR=1; shift;;
    -h|--help)
      echo "usage: $0 [--branch NAME] [--dir PATH] [--pr]" >&2
      echo "  asserts run-state.json agrees with gates.jsonl + wave-N.jsonl" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

[ -n "$BRANCH" ] || BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
[ -n "$DIR" ] || DIR="$REPO_ROOT/local/loops/$BRANCH"
STATE="$DIR/run-state.json"

drift=0
compared=0
skipped_arms=0
notes=()

echo "loop-state-audit — $BRANCH"
echo "  ASSERTS SNAPSHOT AGAINST LOCAL RECORDS ONLY, never run health"
echo

[ -d "$DIR" ] || { echo "no run dir: $DIR" >&2; echo "NOTHING CHECKED"; exit 2; }
[ -s "$STATE" ] || { echo "empty or missing snapshot: $STATE" >&2; echo "NOTHING CHECKED"; exit 2; }
jq -e . "$STATE" >/dev/null 2>&1 \
  || { echo "unparseable snapshot: $STATE" >&2; echo "NOTHING CHECKED"; exit 2; }

# oracle 1: shipped = a done commit below the last _declared line
shipped_waves=()
declared_waves=()
retry_dispatches=0
unevaluable=()
journals=0
for j in "$DIR"/wave-*.jsonl; do
  [ -e "$j" ] || continue
  journals=$((journals + 1))
  n=$(basename "$j" .jsonl); n="${n#wave-}"
  if grep -qv '^[[:space:]]*$' "$j" && ! jq -e . "$j" >/dev/null 2>&1; then
    unevaluable+=("$n"); continue
  fi
  declared_waves+=("$n")
  retry_dispatches=$(( retry_dispatches + $(jq -s '[.[] | select(.step == "_declared" and .reason == "retry")] | length' "$j") ))
  # `last` over the declaration index, then any done commit below it
  if jq -es '
      (map(.step == "_declared") | index(true)) as $_
      | (to_entries | map(select(.value.step == "_declared")) | last | .key // -1) as $d
      | [.[($d + 1):][] | select(.step == "commit" and .status == "done")] | length > 0
    ' "$j" >/dev/null 2>&1; then
    shipped_waves+=("$n")
  fi
done

# oracle 2: gates.jsonl for the crew cadence
gates="$DIR/gates.jsonl"
gates_last_crew=""
if [ -s "$gates" ] && jq -e . "$gates" >/dev/null 2>&1; then
  # numbers only: max() over mixed types could rank a string above real
  gates_last_crew=$(jq -s '[.[] | select(.kind == "crew") | .wave | numbers] | max // empty' "$gates")
fi

# schema probe: a legacy snapshot must not read as drift on every arm
queue_len=$(jq -r '.queue | if type == "array" then length else 0 end' "$STATE")
queue_modern=$(jq -r '[.queue[]? | select(has("wave"))] | length' "$STATE")
legacy_queue=0
[ "$queue_len" -gt 0 ] && [ "$queue_modern" -eq 0 ] && legacy_queue=1
has_lcw=$(jq -r 'has("last_crew_wave")' "$STATE")

# each arm prints even on agreement: silence looks like it never ran
cmp_field() { # label, snapshot value, oracle value, oracle name
  compared=$((compared + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok     %-24s snapshot %s · %s %s\n' "$1" "$2" "$4" "$3"
  else
    printf '  DRIFT  %-24s snapshot %s · %s %s\n' "$1" "$2" "$4" "$3"
    drift=$((drift + 1))
  fi
}

if [ ${#unevaluable[@]} -gt 0 ]; then
  notes+=("NOT EVALUABLE  wave(s) ${unevaluable[*]}: journal carries an unparseable line, so the wave cannot be typed — excluded from every count below")
fi

# compared only if every journal is typeable, else the floor reads as drift
if [ "$journals" -eq 0 ]; then
  # absent journals aren't zero waves: a mute oracle at 0 would fake drift
  notes+=("NOT EVALUABLE  the four journal-derived arms: no wave-N.jsonl in this dir, so the journals cannot settle position — a run predating the journal contract, or one that lost them")
  skipped_arms=$((skipped_arms + 4))
elif [ ${#unevaluable[@]} -eq 0 ]; then
  cmp_field "waves_shipped" \
    "$(jq -r '.counters.waves_shipped // "absent"' "$STATE")" \
    "${#shipped_waves[@]}" "journals"
  cmp_field "queue shipped entries" \
    "$(jq -r '[.queue[]? | select(.status == "shipped")] | length' "$STATE")" \
    "${#shipped_waves[@]}" "journals"
  cmp_field "total_waves" \
    "$(jq -r '.counters.total_waves // "absent"' "$STATE")" \
    "${#declared_waves[@]}" "journals"
  cmp_field "wave_retries" \
    "$(jq -r '.counters.wave_retries // "absent"' "$STATE")" \
    "$retry_dispatches" "journals"
else
  notes+=("SKIPPED  the four journal-derived arms: see NOT EVALUABLE above")
  skipped_arms=$((skipped_arms + 4))
fi

if [ "$has_lcw" != "true" ]; then
  notes+=("NOT EVALUABLE  last_crew_wave: the snapshot carries no such key, so there is no claim to check against gates.jsonl")
  skipped_arms=$((skipped_arms + 1))
elif [ -n "$gates_last_crew" ]; then
  cmp_field "last_crew_wave" \
    "$(jq -r '.last_crew_wave // "absent"' "$STATE")" \
    "$gates_last_crew" "gates.jsonl"
else
  notes+=("NOT EVALUABLE  last_crew_wave: gates.jsonl is absent, empty, unparseable, or logs no crew line carrying a numeric wave")
  skipped_arms=$((skipped_arms + 1))
fi

# a shipped entry's commit must resolve, or it's drift the counters miss
# REPO_ROOT may not own this dir (a sweep over other checkouts, e.g. A)
# check it's a repo first, or a misconfigured root fabricates five drifts
if [ "$legacy_queue" -eq 1 ]; then
  # a legacy queue's prose status matches nothing; sha arms vacuously pass
  notes+=("NOT EVALUABLE  the two sha arms: $queue_len queue entry(s), none carrying a \`wave\` key — a snapshot predating the documented queue shape, so its shipped entries cannot be selected")
  skipped_arms=$((skipped_arms + 2))
elif git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  bad_sha=0
  while read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$REPO_ROOT" rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1 \
      || bad_sha=$((bad_sha + 1))
  done < <(jq -r '.queue[]? | select(.status == "shipped") | .commit // empty' "$STATE")
  cmp_field "shipped commits resolve" "$bad_sha" "0" "git"
else
  notes+=("NOT EVALUABLE  shipped commits resolve: REPO_ROOT ($REPO_ROOT) is not a git repo — set it to the repo owning this run dir")
  skipped_arms=$((skipped_arms + 1))
fi

if [ "$legacy_queue" -eq 0 ]; then
  missing_sha=$(jq -r '[.queue[]? | select(.status == "shipped" and (.commit == null or .commit == ""))] | length' "$STATE")
  cmp_field "shipped entries have sha" "$missing_sha" "0" "snapshot"
fi

# PR arm is opt-in (only one leaving the machine): ask GitHub, don't guess
if [ "$CHECK_PR" -eq 1 ]; then
  if live=$(gh pr list --head "$BRANCH" --state all --json number --jq '.[0].number // "none"' 2>/dev/null); then
    cmp_field "pr.number" "$(jq -r '.pr.number // "none"' "$STATE")" "$live" "gh"
  else
    notes+=("NOT EVALUABLE  pr.number: gh could not be reached")
    skipped_arms=$((skipped_arms + 1))
  fi
fi

echo
for note in ${notes+"${notes[@]}"}; do echo "  $note"; done
[ ${#notes[@]} -eq 0 ] || echo

if [ "$compared" -eq 0 ]; then
  echo "NOTHING CHECKED — no field could be settled against a record"
  exit 2
fi

# exit 0 means fully checked and clean; resume trusts the snapshot on it
if [ "$drift" -gt 0 ]; then
  echo "STATE DRIFT: $drift of $compared field(s) disagree with the records"
  exit 1
fi
if [ "$skipped_arms" -gt 0 ]; then
  echo "STATE DRIFT: 0 of $compared field(s) disagree — INCOMPLETE, $skipped_arms arm(s) could not be settled"
  exit 2
fi
echo "STATE DRIFT: 0 of $compared field(s) disagree with the records"
exit 0
