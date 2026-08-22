# State schemas

Field shapes + provenance lint for the loop's on-disk records. The governing rules live elsewhere — SKILL.md `## Gate artifacts` and `## State tracking` for the two orchestrator-owned files, `agents/the-looper.md` `## Step journal` for the executor-owned per-wave journal. Consult this file only when writing or validating an artifact.

## gates.jsonl line shape

```json
{
  "wave": 4,
  "kind": "crew", // CLOSED enum, see below — the audit rejects anything else
  "pass": "final", // crew lines only: "interim" | "final" | "re-crew"; else null
  "agent": "the-diamantaire", // crew member or specialist name
  "task_tool_available": true, // false = orchestrator could NOT invoke; rules in SKILL.md `## Gate artifacts`
  "ran": true, // false when task_tool_available is false
  "verdict": "MERGE-READY", // agent's own words, verbatim — no paraphrase
  "outcome": "promote", // refutation-posture reviewers only: "refute" | "batch" | "promote"; else null
  "verified_by": "llm", // provenance: "executable" | "llm" | null
  "gates": false, // true = this line's finding blocks the wave and earns a corrective
  "gated_by": null, // one class from SKILL.md `## Finding severity floor`; null unless gates is true
  "contract_ref": null, // goal_contract ask id ("A2") or `path:Lstart-Lend` in the run's diff; null unless gates is true
  "blockers": 0,
  "summary": "one line, cited from agent output"
}
```

`kind` is a CLOSED enum of exactly nine tokens: `crew`, `pre-build-specialist`, `wave-retry`, `stale-skip`, `executor-handback`, `usage-window`, `finding-audit`, `pr-finalization`, `orchestration-incident`. Anything else is a write bug, and the audit fails on it.

**The variant belongs in `pass`, never in `kind`.** This is the whole reason the enum is enforced rather than merely documented. Every consumer selects on `.kind == "crew"`, so a line spelled `crew-interim`, `crew-final`, `crew-final-summary` or `crew-final-all-seven` is not a stricter label — it is a line the audit cannot see. One real run logged 31 distinct spellings across ~50 lines, and its crew coverage was invisible to `loop-finding-audit.sh` for every one of them that was not exactly `crew`. A closed enum plus a separate `pass` field is what makes a crew line countable.

`gates` is the field that separates a finding from a corrective wave. A crew agent's own severity label does NOT set it — the orchestrator sets it after applying `SKILL.md` `## Finding severity floor`, and a `true` without both `gated_by` and `contract_ref` is inadmissible. Everything else is a batched finding: `gates: false`, both justification fields `null`, and the finding itself recorded in `run-state.json` `cleanup_batch` rather than here.

`gated_by` takes one of exactly five literal tokens, and the audit rejects anything else — write them as spelled here, not as the prose table's labels: `correctness-regression`, `security`, `data-loss`, `a11y-regression`, `false-user-string`. The last one is the trap, since its prose label is "false user-visible string".

`contract_ref` takes either a `goal_contract` ask id (`A2`, which must be one the contract declares) or a citation into the run's own diff, `path:Lstart-Lend`. The citation is checked for shape only — the audit cannot resolve it against the diff without the repo, so a well-formed reference to nothing passes. That gap is real and the run-wide corrective ceiling, not this field, is what bounds it.

`outcome: "batch"` is the refutation-posture reviewer's own way of saying the same thing — a defensible defect it can cite, below the floor. It exists because a binary `refute|promote` forces a reviewer to either block on a nit or stay silent about it, and the first is what produced four consecutive `refute` verdicts on a one-line CSS fix.

## Provenance lint

```
jq -c 'select(.ran == true and (.kind == "crew" or .kind == "pre-build-specialist"))
       | select(.verified_by == null
                or (.kind == "crew" and .agent == "the-diamantaire" and .outcome == null))' gates.jsonl   # must print nothing
```

The `verified_by` check spans both verdict-bearing kinds (matching the field's crew-or-specialist scope in SKILL.md `## Gate artifacts`); the `outcome` check is crew-refutation-only. Each run's `gates.jsonl` is branch-keyed and fresh, so a run created after this schema landed has no legacy lines to trip it; older logs predate the fields and are exempt.

Admissibility is checked separately by `scripts/loop-finding-audit.sh` over five arms: the `gates` / `gated_by` / `contract_ref` triple, whether a cited ask resolves, whether every corrective was paid for by a justified gating finding, the per-wave corrective cap, and the interim crew size. It reads `run-state.json` alongside the log because two arms need the contract's ask ids and the corrective counter; the other three read the log alone.

### Receipts: the half `verified_by` cannot prove

`verified_by` is written by the same agent whose work it describes, so a
rule reading it asks that agent to grade itself. Across the custodian's
cross-repo index the field holds 17 distinct values — `executable`,
`llm`, and fourteen one-off prose strings — so a rule comparing it to one
string both misses real evidence and accepts a typed claim.

`hooks/record-execution-receipt.sh` records each shell execution to
`local/loops/<branch>/receipts.jsonl`, and no agent authors it.
`scripts/loop-receipts.sh` checks a wave's `executable` claim against it,
run over each kept dir by the custodian's Phase A.

A receipt carries no exit code, and that is not an omission: the
PostToolUse payload exposes none. The event fires on tool SUCCESS —
failures route to `PostToolUseFailure` — so a receipt's EXISTENCE is the
success signal, and `interrupted` is the one recorded qualifier.

**G3 was deliberately NOT rewritten to read receipts.** Receipts begin
when the hook is installed and every archived run predates them, so
swapping G3's predicate would turn hundreds of historical `executable`
lines into violations — the same flood the legacy `verified_by`-absent
exemption above exists to prevent. The receipts check is era-gated the
same way: a branch with no receipts log is NOT EVALUABLE, never a
violation. When receipts cover a meaningful span, G3 can retire into it.

## run-state.json shape

```json
{
  "goal": "<scope's goal restatement>",
  "goal_contract": {
    "asks": [
      {
        "id": "A1",
        "ask": "<the user's words>",
        "done_when": "<exit criterion>"
      },
      { "id": "A2", "ask": "...", "done_when": "..." }
    ],
    "fixed_at": "step-1"
  },
  "sizing": "full-orchestration",
  "queue": [
    {
      "wave": 1,
      "candidate": "...",
      "status": "shipped",
      "commit": "abc1234",
      "closes": ["A1"]
    },
    {
      "wave": 2,
      "candidate": "...",
      "status": "pending",
      "commit": null,
      "closes": ["A2"]
    }
  ],
  "cleanup_batch": [
    {
      "wave": 1,
      "agent": "the-chronicler",
      "class": "docs",
      "ref": "src/lib/x.ts:40",
      "finding": "<one line, cited>"
    }
  ],
  "open_questions": [
    "<a crew finding implying scope the contract does not carry>"
  ],
  "counters": {
    "waves_shipped": 1,
    "waves_since_crew": 1,
    "cumulative_files_changed": 6,
    "last_review_verdict": "clean",
    "total_waves": 1,
    "corrective_waves": 0,
    "correctives_this_wave": 0,
    "consecutive_no_progress": 0,
    "wave_retries": 0,
    "scaffolding_only_correctives": 0,
    "batched_findings": 1
  },
  "last_crew_wave": 0,
  "pr": {
    "number": 214,
    "url": "...",
    "state": "draft",
    "body_sha": "9f2a3c7e"
  },
  "usage": {
    "paused": false,
    "window_reset": 1784258400,
    "observed_pct": 41,
    "read_ok": true
  }
}
```

`goal_contract` is written once, at the end of Step 1, and never edited afterwards — a run that grows its own contract can always justify whatever it did. `queue[].closes` names which asks a wave is meant to close, which is what makes "shipped 9 waves, ask A2 unstarted" visible in the snapshot rather than only in hindsight. `cleanup_batch` accumulates every finding the severity floor did not gate, and drains in one terminal wave; `open_questions` holds what the crew surfaced that the contract does not cover, and drains only by the user answering.

This file is the one of the three that gets overwritten, so it is the only one that can silently lose position while the records beside it stay correct. `scripts/loop-state-audit.sh` compares it against them — the journals settle `waves_shipped`, `total_waves`, `wave_retries` and the queue's shipped entries, `gates.jsonl` settles `last_crew_wave`, and git settles the shas those entries name. Run it before trusting a snapshot on resume (SKILL.md `## State tracking`); exit 0 means every arm was compared and agreed, 1 means a named field disagreed and the records win, 2 means the audit could not settle everything it exists to settle. The `pr` arm is opt-in behind `--pr` because it needs the network.

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
- **An unparseable COMPLETION line is discarded — that line, wherever it sits, never the file.** A kill mid-append leaves a truncated line, not a corrupt file, and it need not be the last one: a dispatch that appends onto an unterminated fragment fuses its line to the wreckage and leaves the mess mid-file. Read a discarded line's step as not-done. Discarding errs in exactly one direction and it is the safe one — a _completion_ line is written only after its step completes, so the worst case is re-running a step that had already finished, which its oracle then confirms. Never repair or rewrite a line, and never void the whole journal over one: the good checkpoints around it are still good, and the oracles, not the parse, are what stop a bad line from authorizing a skip.
- **A `_declared` line is never discarded, and that exception is what makes the rule above safe.** The discard rule rests on "written only after the step completed", which is false of exactly one line kind: the declaration is written BEFORE step one. A retry that dies mid-declaration therefore leaves a torn line that, if discarded, hands segment-boundary duty back to the _initial_ declaration — so the dead-end attempt's `done` lines read as live, and the plan oracle confirms them, because the dead end really did write a non-empty `wave-N-plan.md`. The oracles cannot arbitrate this; they confirm both attempts equally. So: **an unparseable line that cannot be typed as a completion voids skip authority for the segment below it.** Treat its position as a segment boundary of unknown intent — re-run every step from the top of the wave, ignoring the `done` lines above and below it. Say so in the hand-back.
- **Type a damaged line by its HEAD, not by whatever suffix parses.** Fusion is the common shape, not the exotic one — a dispatch appending onto an unterminated fragment produces one line carrying wreckage followed by a complete object, which satisfies "unparseable completion, discard it" and "never discard a `_declared`" at the same time. The hinge is the wreckage, not the tail: if the text before the first well-formed object mentions `_declared`, the line is a torn declaration and gets the never-discard treatment, whatever else rides on it. Only when that leading text is completion wreckage — or absent — does the discard rule apply.
- **A resume that voids skip authority appends a fresh `_declared`, `reason: "resume-after-torn"`, `dispatch` unchanged.** Without it the void is permanent: a resume otherwise appends no declaration, only a retry does, and a retry is issued off a hand-back that a mid-declaration kill is defined by not having. So one torn line would cost the wave its journal forever, every later resume restarting from step one — the failure the journal exists to prevent, under exactly the repeated-kill conditions that produce it. The new declaration is honest, because a resume under a void really is about to run every step it names. `dispatch` does not move: it counts retries, and this is not one.
- **The `commit` terminal marker reads only the LIVE segment.** A `commit` line below a torn declaration is audit trail like everything else there, so it does not report the wave shipped; the wave re-runs from the top. What keeps that re-run from duplicating anything is the oracles, which the void never touched — `git log` already holds the commit, and `learn`'s memory files already hold the memory, so each step's re-run reconciles against what it finds rather than appending a second copy. The void takes the journal's word away, never the oracles'.
- **Blank lines are noise.** Skip them. Emptiness is not evidence of anything.
- **Absent file** = first dispatch. **Absent line for a declared step** = that step is not known to have run — which is also what a kill mid-step leaves.
