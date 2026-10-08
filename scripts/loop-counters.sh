#!/usr/bin/env bash
# loop-counters — applies one classified wave outcome to run-state.json
set -uo pipefail

STATE=""
OUTCOME=""
CLAUDE_MD=""

needs_value() { [ "$2" -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --state)     needs_value --state "$#";     STATE="$2";     shift 2;;
    --outcome)   needs_value --outcome "$#";   OUTCOME="$2";   shift 2;;
    --claude-md) needs_value --claude-md "$#"; CLAUDE_MD="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 --state PATH --outcome FILE|- [--claude-md PATH]" >&2
      echo "  applies a wave outcome to the counters, then checks the governor" >&2
      exit 0;;
    --*) echo "unknown flag: $1" >&2; exit 2;;
    *)   echo "unexpected arg: $1" >&2; exit 2;;
  esac
done

refuse() { echo "$1" >&2; echo "NOTHING WRITTEN — $STATE left as it was"; exit 2; }

[ -n "$STATE" ] || { echo "--state is required" >&2; exit 2; }
[ -n "$OUTCOME" ] || { echo "--outcome is required" >&2; exit 2; }

[ -s "$STATE" ] || refuse "empty or missing run-state: $STATE"
jq -e 'type == "object" and ((.counters // {}) | type == "object")' "$STATE" >/dev/null 2>&1 \
  || refuse "unparseable run-state, or counters is not an object: $STATE"

if [ "$OUTCOME" = "-" ]; then
  outcome=$(cat)
else
  [ -r "$OUTCOME" ] || refuse "unreadable outcome: $OUTCOME"
  outcome=$(cat "$OUTCOME")
fi
printf '%s' "$outcome" | jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 \
  || refuse "outcome is not exactly one JSON object"
outcome=$(printf '%s' "$outcome" | jq -c .)

problems=$(jq -r --argjson o "$outcome" '
  def bool($k): ($o | has($k) | not) or ($o[$k] | type == "boolean");
  def count($v): ($v | type == "number") and $v >= 0 and ($v | floor) == $v;
  [
    ($o | keys - ["kind","shipped","files_changed","touched_product","net_new",
                  "reopened","review_verdict","gating","wave"] | .[] | "unknown key: \(.)"),
    (if ($o.kind | IN("queue","corrective","direct-fix","retry","crew-pass")) then empty
     else "kind must be queue|corrective|direct-fix|retry|crew-pass" end),
    (("shipped","touched_product","net_new","reopened","gating") | select(bool(.) | not) | "\(.) must be a boolean"),
    (if ($o | has("review_verdict")) and ($o.review_verdict | type | IN("string","null") | not)
     then "review_verdict must be a string or null" else empty end),
    (if $o.kind == "crew-pass" then
       (if count($o.wave) then empty else "crew-pass needs wave as a count" end),
       ($o | keys - ["kind","wave","gating"] | .[] | "crew-pass does not take \(.)")
     else
       (if ($o | has("shipped")) then empty else "shipped is required" end),
       (if $o.shipped == true and (count($o.files_changed) | not) then "a shipped outcome needs files_changed as a count" else empty end),
       (if $o.shipped == true and ($o | has("touched_product") | not) then "a shipped outcome needs touched_product" else empty end),
       (if $o.shipped != true and (($o.files_changed // 0) != 0 or $o.net_new == true) then "an unshipped outcome cannot carry files or net_new" else empty end)
     end)
  ] | .[]' "$STATE" 2>&1) || refuse "could not validate outcome: $problems"
[ -z "$problems" ] || refuse "invalid outcome:
$problems"

not_counts=$(jq -r '
  (.counters // {}) as $c
  | ("waves_shipped","waves_since_crew","cumulative_files_changed","total_waves",
     "corrective_waves","correctives_this_wave","consecutive_no_progress",
     "wave_retries","retries_this_wave","scaffolding_only_correctives","batched_findings")
  | . as $k
  | select($c | has($k))
  | select($c[$k] | (type == "number" and . >= 0 and floor == .) | not)
  | "  \($k) = \($c[$k] | tojson)"' "$STATE" 2>&1) \
  || refuse "could not read the counters: $not_counts"
[ -z "$not_counts" ] || refuse "run-state counters that are not non-negative integers:
$not_counts"

# defaults are the skill's rail table; the project CLAUDE.md overrides
L_PER_WAVE=1
L_TOTAL=25
L_CORRECTIVE=6
L_NO_PROGRESS=3
L_RETRIES=4
L_SCAFFOLDING=2
limits_from="defaults"

if [ -z "$CLAUDE_MD" ]; then
  top=$(git -C "$(dirname "$STATE")" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$top" ] && [ -e "$top/CLAUDE.md" ] && CLAUDE_MD="$top/CLAUDE.md"
else
  [ -r "$CLAUDE_MD" ] || refuse "unreadable --claude-md: $CLAUDE_MD"
fi

if [ -n "$CLAUDE_MD" ]; then
  budget=$(awk '
    function run(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
    {
      t = $0; sub(/^ ? ? ?/, "", t); c = substr(t, 1, 1)
      if (fence_n) {
        if (c == fence_c && run(t, c) >= fence_n && substr(t, run(t, c) + 1) ~ /^[ \t]*$/) fence_n = 0
        next
      }
      if ((c == "`" || c == "~") && run(t, c) >= 3) { fence_c = c; fence_n = run(t, c); next }
    }
    /^## /{ in_loop = ($0 ~ /^## Loop de Looper[[:space:]]*$/) }
    in_loop && /^- budget:/ { print NR "\t" $0 }' "$CLAUDE_MD")
  if [ "$(printf '%s\n' "$budget" | grep -c .)" -gt 1 ]; then
    refuse "more than one budget line under ## Loop de Looper in $CLAUDE_MD:
$(printf '%s\n' "$budget" | awk -F'\t' '{ print "  line " $1 ": " $2 }')"
  fi
  if [ -n "$budget" ]; then
    limits_from="$CLAUDE_MD"
    budget=${budget#*$'\t'}
    budget=${budget#- budget:}
    budget=${budget%%#*}
    while IFS= read -r pair; do
      pair=$(printf '%s' "$pair" | tr -d '[:space:]')
      [ -n "$pair" ] || continue
      key=${pair%%=*}
      val=${pair#*=}
      case "$val" in ''|*[!0-9]*) refuse "budget $key needs a positive integer, got '$val' in $CLAUDE_MD";; esac
      val=$((10#$val))
      [ "$val" -gt 0 ] || refuse "budget $key=0 would trip its rail on every call, in $CLAUDE_MD"
      case "$key" in
        per-wave-corrective) L_PER_WAVE=$val;;
        max-waves)           L_TOTAL=$val;;
        max-corrective)      L_CORRECTIVE=$val;;
        no-progress)         L_NO_PROGRESS=$val;;
        max-retries)         L_RETRIES=$val;;
        scaffolding-only)    L_SCAFFOLDING=$val;;
        *) refuse "unknown budget key '$key' in $CLAUDE_MD";;
      esac
    done < <(printf '%s\n' "$budget" | tr ',' '\n')
  fi
fi

tmp="$STATE.tmp"
trap 'rm -f "$tmp"' EXIT

jq --argjson o "$outcome" '
  def n($k): (.counters[$k] // 0);
  ($o.shipped == true) as $shipped
  | ($o.kind | IN("queue","corrective","retry")) as $wave
  | ($o.kind | IN("corrective","direct-fix")) as $fix
  | .counters = (.counters // {})
  | if $wave and $shipped then .counters.waves_shipped = n("waves_shipped") + 1 else . end
  | if $wave then .counters.waves_since_crew = n("waves_since_crew") + 1 else . end
  | if $wave and $shipped then .counters.cumulative_files_changed = n("cumulative_files_changed") + $o.files_changed else . end
  | if $o.kind == "crew-pass" then .counters.waves_since_crew = 0 | .counters.cumulative_files_changed = 0 | .last_crew_wave = $o.wave else . end
  | if ($o | has("review_verdict")) then .counters.last_review_verdict = $o.review_verdict else . end
  | if $wave then .counters.total_waves = n("total_waves") + 1 else . end
  | if $fix then .counters.corrective_waves = n("corrective_waves") + 1 else . end
  | if $o.kind == "queue" then .counters.correctives_this_wave = 0 | .counters.retries_this_wave = 0 else . end
  | if $fix then .counters.correctives_this_wave = n("correctives_this_wave") + 1 else . end
  | if $o.net_new == true then .counters.consecutive_no_progress = 0
    elif $wave and (($shipped | not) or $o.reopened == true) then .counters.consecutive_no_progress = n("consecutive_no_progress") + 1
    else . end
  | if $o.kind == "retry" then .counters.wave_retries = n("wave_retries") + 1 | .counters.retries_this_wave = n("retries_this_wave") + 1 else . end
  | if $shipped and $o.touched_product == true then .counters.scaffolding_only_correctives = 0
    elif $fix and $shipped then .counters.scaffolding_only_correctives = n("scaffolding_only_correctives") + 1
    else . end
  | .counters.batched_findings = ((.cleanup_batch // []) | length)
' "$STATE" > "$tmp" 2>/dev/null \
  || refuse "jq could not apply the outcome to $STATE"
jq -e 'type == "object" and (.counters | type == "object")' "$tmp" >/dev/null 2>&1 \
  || refuse "the rewritten snapshot failed validation; $STATE left as it was"

tripped=$(jq -r --argjson o "$outcome" \
  --argjson per "$L_PER_WAVE" --argjson total "$L_TOTAL" \
  --argjson corr "$L_CORRECTIVE" --argjson nop "$L_NO_PROGRESS" \
  --argjson ret "$L_RETRIES" --argjson scaf "$L_SCAFFOLDING" '
  .counters as $c
  | def at($k): ($c[$k] // 0);
  (if at("total_waves") >= $total then "max_total_waves\t\(at("total_waves"))\t\($total)" else empty end),
  (if at("corrective_waves") >= $corr then "max_corrective_waves\t\(at("corrective_waves"))\t\($corr)" else empty end),
  (if at("consecutive_no_progress") >= $nop then "consecutive_no_progress\t\(at("consecutive_no_progress"))\t\($nop)" else empty end),
  (if at("wave_retries") >= $ret then "max_wave_retries\t\(at("wave_retries"))\t\($ret)" else empty end),
  (if at("scaffolding_only_correctives") >= $scaf then "scaffolding_only_correctives\t\(at("scaffolding_only_correctives"))\t\($scaf)" else empty end),
  (if $o.gating == true and at("correctives_this_wave") >= $per then "max_correctives_per_wave\t\(at("correctives_this_wave"))\t\($per)\t\(at("retries_this_wave"))" else empty end)
' "$tmp") || refuse "could not evaluate the governor rails; $STATE left as it was"
mv -f "$tmp" "$STATE" || refuse "could not rename $tmp over $STATE"

echo "loop-counters — $STATE"
echo "  limits from $limits_from: per-wave $L_PER_WAVE · total $L_TOTAL · corrective $L_CORRECTIVE · no-progress $L_NO_PROGRESS · retries $L_RETRIES · scaffolding $L_SCAFFOLDING"
jq -r '.counters | to_entries[] | "  \(.key)\t\(.value)"' "$STATE" | expand -t 34
echo

verdict="clear"
while IFS=$'\t' read -r rail count limit wave_retried; do
  [ -n "$rail" ] || continue
  case "$rail" in
    max_correctives_per_wave)
      if [ "$wave_retried" -ge 1 ]; then
        action="STOP + escalate: rethink again after the wave's one 2b-retry"; verdict="STOP"
      else
        action="rethink: one 2b-retry on the next ranked alternate, then STOP"
        [ "$verdict" = "STOP" ] || verdict="rethink"
      fi;;
    max_total_waves)         action="STOP + escalate: queue + corrective waves reached the ceiling"; verdict="STOP";;
    max_corrective_waves)    action="STOP + escalate: too many floor-gated fixes; drift is structural"; verdict="STOP";;
    consecutive_no_progress) action="STOP + escalate: waves without shipping net-new queue work"; verdict="STOP";;
    max_wave_retries)        action="STOP + escalate: the goal is systematically too hard for the executor"; verdict="STOP";;
    scaffolding_only_correctives) action="STOP + escalate: consecutive correctives touched only test scaffolding"; verdict="STOP";;
  esac
  echo "  TRIPPED  $rail $count/$limit — $action"
done <<< "$tripped"
[ -z "$tripped" ] || echo

echo "GOVERNOR: $verdict — snapshot written"
[ "$verdict" = "clear" ]
