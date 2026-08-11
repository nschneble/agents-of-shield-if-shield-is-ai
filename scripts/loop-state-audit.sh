#!/usr/bin/env bash
# loop-state-audit — asserts a run's run-state.json still agrees with the
# append-only records beside it.
#
# The asymmetry it exploits: of the three files under
# `local/loops/<branch>/`, two are append-only and one is overwritten.
# `gates.jsonl` and `wave-N.jsonl` accumulate; `run-state.json` is
# rewritten wholesale after every wave (SKILL.md `## State tracking`).
# Only the overwritten one can silently lose a wave's worth of position,
# and when it does the logs still hold the truth — nothing was reading
# them. Observed on the branch this check was written for: two waves
# shipped, both journals complete, snapshot still reading zero counters
# and no PR.
#
# So the logs are the oracle and the snapshot is the claim. A field is
# only compared when the logs can settle it; anything they cannot type
# is reported NOT EVALUABLE rather than guessed, and excluded from the
# comparison it would otherwise poison.
#
# ASSERTS SNAPSHOT AGAINST LOCAL RECORDS ONLY. It says nothing about
# whether the run is progressing, whether a wave's work is correct, or
# whether the PR matches — the PR arm needs the network and is opt-in
# behind --pr for that reason. A clean result means the snapshot is a
# faithful summary of what the logs already recorded, no more.
#
# Over the ~100-line bar at 152, and the bulk is arithmetic rather than
# slack: seven comparison arms cost three lines each, and splitting the
# oracles from the arms they feed would put the derivation and its
# comparison in different files with nothing holding them in step —
# the exact failure this check exists to catch. Trim the header before
# reaching for the code.
#
# Usage: loop-state-audit.sh [--branch NAME] [--dir PATH] [--pr]
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BRANCH=""
DIR=""
CHECK_PR=0

# a value-taking flag given no value must not fall through to `$2`
# unbound: under `set -u` that aborts with status 1, which the exit
# contract reserves for "drift found". Usage errors exit 2, matching
# custodian-phase-order.sh and custodian-guardrails.sh.
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

# --- Oracle 1: the per-wave journals. A wave counts as shipped when its
#     LIVE segment carries a done `commit` line. Live means below the
#     last `_declared` (state-schemas.md `## wave-N.jsonl line shapes`):
#     lines above it are audit trail from a superseded dispatch, and a
#     `commit` up there reports a wave that was later retried.
#
#     A journal holding ANY unparseable line is typed NOT EVALUABLE
#     instead. The schema's discard rules turn on where the damage sits
#     within the line — a torn declaration voids its segment, fused
#     completion wreckage does not — and that is a judgement this audit
#     deliberately does not make. Reporting the wave as untypeable costs
#     one line of output; guessing it costs the count's meaning. ---
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

# --- Oracle 2: gates.jsonl, append-only, for the crew cadence. ---
gates="$DIR/gates.jsonl"
gates_last_crew=""
if [ -s "$gates" ] && jq -e . "$gates" >/dev/null 2>&1; then
  # numbers only: a crew line may carry `wave: null`, and a max over
  # mixed types returns whichever the type ordering happens to rank
  # last — a string like "9d" outranking every real wave number
  gates_last_crew=$(jq -s '[.[] | select(.kind == "crew") | .wave | numbers] | max // empty' "$gates")
fi

# --- Schema probe. These records have a documented shape and older runs
#     predate it: queue entries keyed `n` with a prose `status`, no
#     `last_crew_wave`, no journals at all. Compared field-by-field a
#     legacy snapshot reports as drift on every arm, which is this
#     check's own failure mode wearing its output — a disagreement about
#     SCHEMA read as a disagreement about POSITION. So each oracle is
#     asked whether it can speak to this snapshot before it is believed
#     over it. ---
queue_len=$(jq -r '.queue | if type == "array" then length else 0 end' "$STATE")
queue_modern=$(jq -r '[.queue[]? | select(has("wave"))] | length' "$STATE")
legacy_queue=0
[ "$queue_len" -gt 0 ] && [ "$queue_modern" -eq 0 ] && legacy_queue=1
has_lcw=$(jq -r 'has("last_crew_wave")' "$STATE")

# --- Compare. Each arm prints its own line whether it agrees or not:
#     a silent pass is indistinguishable from an arm that never ran. ---
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

# waves_shipped, only when every journal was typeable: one unreadable
# journal makes the oracle a floor rather than a count, and a floor
# compared as a count reports drift that may not exist
if [ "$journals" -eq 0 ]; then
  # absent journals are not zero waves. state-schemas.md reads an absent
  # file as "first dispatch", but a whole dir without one is either a run
  # predating the journal contract or a run whose journals are gone, and
  # nothing here can tell those apart. Both make the oracle mute, and a
  # mute oracle that returns 0 would report every shipped wave as drift.
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

# every queue entry marked shipped must name a commit that resolves —
# a sha the snapshot invented, or one lost to a reset, is drift the
# counters alone cannot show.
#
# REPO_ROOT has to be the repo that OWNS this run dir, which is not the
# repo this script lives in whenever a caller sweeps other checkouts
# (looper-custodian Phase A does exactly that). Ask git whether it is a
# repo at all first: without the guard every sha reads as unresolvable
# and a misconfigured root reports as five fabricated drifts, which is a
# worse lie than declining to answer.
if [ "$legacy_queue" -eq 1 ]; then
  # a legacy queue keys entries `n` and writes `status` as prose, so
  # `select(.status == "shipped")` matches nothing and BOTH sha arms
  # would pass having examined no entry at all. A vacuous pass reads
  # exactly like a real one in the headline, which is the reading this
  # whole check exists to make impossible.
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

# --- The PR arm is opt-in because it is the only one that leaves the
#     machine. Off by default so the check stays runnable offline and
#     its suite stays hermetic; a proxy for "a PR exists" derived from
#     the push state was considered and rejected, since a gate that
#     infers a remote fact from a local one is the shape that has cost
#     this repo whole corrective waves. Ask GitHub or do not ask. ---
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

# Exit 0 has to mean FULLY checked and clean, not merely "nothing I got
# round to comparing disagreed". A resume branches on this code to
# decide whether to trust the snapshot, and a run whose four position
# arms were skipped has not earned that trust however green the arms
# that did run look. So an incomplete audit exits 2 with the skipped
# arms, alongside the inputs it could not read at all. Drift still wins
# over incompleteness: a disagreement the audit DID settle is
# actionable now, and saying so beats reporting the gap around it.
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
