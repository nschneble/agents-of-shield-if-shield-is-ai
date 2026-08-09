# State schemas

Field shapes + provenance lint for the loop's on-disk records. The governing rules live elsewhere — SKILL.md `## Gate artifacts` and `## State tracking` for the two orchestrator-owned files, `agents/the-looper.md` `## Step journal` for the executor-owned per-wave journal. Consult this file only when writing or validating an artifact.

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
  "pr": { "number": 214, "url": "...", "state": "draft", "body_sha": "9f2a3c7e" },
  "usage": {
    "paused": false,
    "window_reset": 1784258400,
    "observed_pct": 41,
    "read_ok": true
  }
}
```

`pr.body_sha` hashes the PR body as the LOOP last wrote it (wave-1 creation, then the terminal recap refresh) — the baseline Step 4's user-edit guard compares the live body against to tell its own text from the owner's. Without a persisted baseline that guard has nothing to diff and cannot fire correctly, and `editor.login` can't substitute: the loop authenticates as `@me`, so its edits and the owner's carry the same login. Absent on a run predating the field or one whose PR the loop didn't create — the guard reads absent as "assume user-edited" and takes the augment path, which is the safe direction.

`usage` is the usage-window guard's snapshot (`## Usage-window guard`): `window_reset` is the unix epoch (seconds) when the currently-binding window rolls — the over-threshold window on a pause, else the `representative` window (`anthropic-ratelimit-unified-representative-claim`, the axis the host says is binding) — snapshotted at the last read (a wake compares against it: `now >= window_reset` _corroborates_ a roll, but the fresh probe is the resume gate, not this value). `observed_pct` is that window's last real utilization as a percent, `read_ok: false` when the probe couldn't read the window (unguarded run, not a fabricated 0). `paused: true` marks a run halted on the window and awaiting a scheduled wake — a resume re-probes the real window before continuing, never trusting this snapshot's staleness.

## wave-N.jsonl line shapes

The per-wave step journal — one file per wave in the same branch-keyed dir, named for its wave (`wave-3.jsonl`), appended by `the-looper`, never by the orchestrator. Two line kinds.

Declaration, written BEFORE step one runs:

```json
{
  "step": "_declared",
  "wave": 3,
  "dispatch": 1, // 1 on the first dispatch, +1 per RETRY — never per resume
  "reason": "initial", // "initial" | "retry" | "resume-after-torn"
  "steps": ["research", "plan", "build", "verify", "review", "learn", "commit"]
}
```

Completion, appended AFTER each step finishes:

```json
{
  "step": "plan",
  "status": "done", // "done" | "skipped" | "escalated" | "stopped"
  "artifact": "wave-3-plan.md" // a filename in this dir | null — see below
}
```

| `status`    | Means                                                            | To a re-dispatch                                                           |
| ----------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `done`      | ran to completion                                                | do not re-run — subject to the step's oracle                               |
| `skipped`   | deliberately not run (plan, when the brief carried gate outputs) | do not run; there is no artifact to reload                                 |
| `escalated` | ran and handed back `gate needed pre-build`                      | the brief decides: `gate outputs` present ⇒ do not re-run, resume at build |
| `stopped`   | a stop condition fired at this step                              | resumed dispatch re-runs it; a retry opens a new segment instead           |

`artifact` names a file in this dir or is `null` — never a sentinel. The plan is the only persisted artifact (`agents/the-looper.md` `## Step journal`), so every other step writes `null`, build included: its output lives in the working tree and git, which is what build's oracle reads. A reader waiting on a `"working-tree"` string would wait forever, because no writer built from the agent spec emits one.

Reader rules:

- **Segments.** Only the lines after the LAST `_declared` describe the live attempt. A retry appends a new declaration; a resume appends none and continues the current segment, the one exception being the torn-declaration case below. Everything above the last declaration is audit trail, never an input to a skip.
- **An unparseable COMPLETION line is discarded — that line, wherever it sits, never the file.** A kill mid-append leaves a truncated line, not a corrupt file, and it need not be the last one: a dispatch that appends onto an unterminated fragment fuses its line to the wreckage and leaves the mess mid-file. Read a discarded line's step as not-done. Discarding errs in exactly one direction and it is the safe one — a *completion* line is written only after its step completes, so the worst case is re-running a step that had already finished, which its oracle then confirms. Never repair or rewrite a line, and never void the whole journal over one: the good checkpoints around it are still good, and the oracles, not the parse, are what stop a bad line from authorizing a skip.
- **A `_declared` line is never discarded, and that exception is what makes the rule above safe.** The discard rule rests on "written only after the step completed", which is false of exactly one line kind: the declaration is written BEFORE step one. A retry that dies mid-declaration therefore leaves a torn line that, if discarded, hands segment-boundary duty back to the *initial* declaration — so the dead-end attempt's `done` lines read as live, and the plan oracle confirms them, because the dead end really did write a non-empty `wave-N-plan.md`. The oracles cannot arbitrate this; they confirm both attempts equally. So: **an unparseable line that cannot be typed as a completion voids skip authority for the segment below it.** Treat its position as a segment boundary of unknown intent — re-run every step from the top of the wave, ignoring the `done` lines above and below it. Say so in the hand-back.
- **Type a damaged line by its HEAD, not by whatever suffix parses.** Fusion is the common shape, not the exotic one — a dispatch appending onto an unterminated fragment produces one line carrying wreckage followed by a complete object, which satisfies "unparseable completion, discard it" and "never discard a `_declared`" at the same time. The hinge is the wreckage, not the tail: if the text before the first well-formed object mentions `_declared`, the line is a torn declaration and gets the never-discard treatment, whatever else rides on it. Only when that leading text is completion wreckage — or absent — does the discard rule apply.
- **A resume that voids skip authority appends a fresh `_declared`, `reason: "resume-after-torn"`, `dispatch` unchanged.** Without it the void is permanent: a resume otherwise appends no declaration, only a retry does, and a retry is issued off a hand-back that a mid-declaration kill is defined by not having. So one torn line would cost the wave its journal forever, every later resume restarting from step one — the failure the journal exists to prevent, under exactly the repeated-kill conditions that produce it. The new declaration is honest, because a resume under a void really is about to run every step it names. `dispatch` does not move: it counts retries, and this is not one.
- **The `commit` terminal marker reads only the LIVE segment.** A `commit` line below a torn declaration is audit trail like everything else there, so it does not report the wave shipped; the wave re-runs from the top. What keeps that re-run from duplicating anything is the oracles, which the void never touched — `git log` already holds the commit, and `learn`'s memory files already hold the memory, so each step's re-run reconciles against what it finds rather than appending a second copy. The void takes the journal's word away, never the oracles'.
- **Blank lines are noise.** Skip them. Emptiness is not evidence of anything.
- **Absent file** = first dispatch. **Absent line for a declared step** = that step is not known to have run — which is also what a kill mid-step leaves.
