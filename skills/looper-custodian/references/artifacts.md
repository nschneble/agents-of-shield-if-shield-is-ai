# Artifacts — what a run writes and where

The per-run and cross-run files under `local/custodian/`, the log line's
schema, and what each artifact is authoritative for. SKILL.md `## Artifacts` is
the pointer site. Consult this file when reading a run's own record.

Under `local/custodian/<date>/` (gitignored, same as `local/loops/`):

- **`custodian-log.jsonl`** — append-only run log, one JSON line per phase action, never rewritten. The machine record / audit trail. It is both the INPUT to the phase-order check and the DESTINATION of that check's output: Phase F appends a `phase:"F"` line whose `action` carries the verdict counts and whose `detail` carries the cited line numbers, because the check prints its cites to stdout and an unattended cron's stdout is not a destination (`## Maintenance run`). That line records the CHECK, never Phase F's completion (`references/resume.md`).
- **`backup-<issue>-<seq>/`** — pre-apply snapshot of every file a Phase D `apply` touched, plus a `manifest.json` (path + original location + issue tag per file). Written by `apply` before its first edit; read by `undo` to revert. The reversibility backstop behind the human-checked apply.
- **`history-index.jsonl`** — lives at `local/custodian/` (NOT under `<date>/`; it's cross-run, not a per-date artifact). The append-only rollup that backs Phase C + `history`: one record per indexed `gates.jsonl` line, carrying the gate fields verbatim + `repo`/`branch`/`files`/`cite`. A **derived cache** of `gates.jsonl` across repos — regenerable via `history --rebuild`, gitignored like the rest of `local/`. Never a source of truth.

```json
{
  "phase": "A",                       // "start" | "C" | "A" | "B" | "E" | "F"
                                      // | "resume" | "D-apply"
  "repo": "tuffgal",
  "task_tool_available": true,        // false = could NOT invoke a sub-skill/agent
  "ran": true,                        // false when a needed tool was unavailable
  "action": "reaped local/loops/fix-auth (merged+deleted)",
  "detail": "1 dir, 2 files"
}
```

- The **GitHub issue** is the human-review + approval surface; the jsonl is the machine record. They agree — the issue's claims trace to logged lines.
- `phase` is read by `scripts/custodian-phase-order.sh`, which orders B against E and splits segments at each `resume` line. So a `resume` line is not bookkeeping — it is the boundary that lets a replayed tail be judged on its own terms, and a resume that logs no marker merges its tail into the segment before it.

**`task_tool_available: false` ⇒ `ran: false` ⇒ no invented outcome.** Per the loop's `[[feedback-task-tool-availability]]` discipline: if custodian can't actually invoke `deep-research` / `the-turncoat` (no Task/Skill tool), it logs `ran: false` and says so in the issue — NEVER an invented digest or a claimed-but-unrun edit.
