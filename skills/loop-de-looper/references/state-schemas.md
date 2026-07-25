# State schemas

Field shapes + provenance lint for the loop's on-disk gate records. The governing rules live in SKILL.md `## Gate artifacts` and `## State tracking` — consult this file only when writing or validating an artifact.

## gates.jsonl line shape

```json
{
  "wave": 4,
  "kind": "crew", // "crew" | "pre-build-specialist" | "wave-retry" | "stale-skip"
  "agent": "the-diamantaire", // crew member or specialist name
  "task_tool_available": true, // false = orchestrator could NOT invoke; rules in SKILL.md `## Gate artifacts`
  "ran": true, // false when task_tool_available is false
  "verdict": "MERGE-READY", // agent's own words, verbatim — no paraphrase
  "outcome": "promote", // refutation-posture reviewers only: "refute" | "promote"; else null
  "verified_by": "llm", // provenance: "executable" | "llm" | null
  "blockers": 0,
  "summary": "one line, cited from agent output"
}
```

## Provenance lint

```
jq -c 'select(.ran == true and (.kind == "crew" or .kind == "pre-build-specialist"))
       | select(.verified_by == null
                or (.kind == "crew" and .agent == "the-diamantaire" and .outcome == null))' gates.jsonl   # must print nothing
```

The `verified_by` check spans both verdict-bearing kinds (matching the field's crew-or-specialist scope in SKILL.md `## Gate artifacts`); the `outcome` check is crew-refutation-only. Each run's `gates.jsonl` is branch-keyed and fresh, so a run created after this schema landed has no legacy lines to trip it; older logs predate the fields and are exempt.

## run-state.json shape

```json
{
  "goal": "<scope's goal restatement>",
  "sizing": "full-orchestration",
  "queue": [
    { "wave": 1, "candidate": "...", "status": "shipped", "commit": "abc1234" },
    { "wave": 2, "candidate": "...", "status": "pending", "commit": null }
  ],
  "counters": {
    "waves_shipped": 1,
    "waves_since_crew": 1,
    "cumulative_files_changed": 6,
    "last_review_verdict": "clean",
    "total_waves": 1,
    "corrective_waves": 0,
    "consecutive_no_progress": 0,
    "wave_retries": 0
  },
  "last_crew_wave": 0,
  "pr": { "number": 214, "url": "...", "state": "draft" },
  "usage": {
    "paused": false,
    "window_reset": 1784258400,
    "observed_pct": 41,
    "read_ok": true
  }
}
```

`usage` is the usage-window guard's snapshot (`## Usage-window guard`): `window_reset` is the unix epoch (seconds) when the currently-binding window rolls — the over-threshold window on a pause, else the `representative` window (`anthropic-ratelimit-unified-representative-claim`, the axis the host says is binding) — snapshotted at the last read (a wake compares against it: `now >= window_reset` _corroborates_ a roll, but the fresh probe is the resume gate, not this value). `observed_pct` is that window's last real utilization as a percent, `read_ok: false` when the probe couldn't read the window (unguarded run, not a fabricated 0). `paused: true` marks a run halted on the window and awaiting a scheduled wake — a resume re-probes the real window before continuing, never trusting this snapshot's staleness.
