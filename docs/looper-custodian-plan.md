# Looper Custodian — build plan

Status: **plan / not built.** Design for a new scheduled housekeeping skill,
`looper-custodian`. Greenlight required before any SKILL.md is written.

## Why it exists

The looper system learns and tidies *per run*: `looper-learn` writes lessons
at the end of each wave and each orchestration; `the-turncoat` streamlines an
agent or skill when asked; each run GCs nothing. Nothing runs *across* runs and
*across* repos on a cadence. Over weeks that leaves:

- **Memory rot** — `MEMORY.md` + memory files accumulate duplicates and
  contradictions (a later memory supersedes an earlier one, but the earlier one
  is never removed, so recall surfaces stale guidance).
- **Artifact litter** — `local/loops/<branch>/` keeps `run-state.json` +
  `gates.jsonl` for branches long since merged and deleted.
- **Lost cross-run signal** — the same crew finding recurs across many runs and
  repos, but no one is looking at the aggregate, so the systemic fix never gets
  proposed.

Custodian is the scheduled, cross-run, cross-repo maintenance layer. It does
NOT replace `looper-learn` (per-run lessons) or `the-turncoat` (on-demand
streamlining) — it batches and aggregates what they do, plus the
memory-contradiction GC neither does today.

## Governing principle: custodian PROPOSES, human DISPOSES

This is the same discipline the loop already holds (does NOT auto-revert
commits, does NOT flip draft→ready). An unattended job that auto-edits memories
or agents is exactly the "merging outpaces comprehension" failure the loop-
engineering sources warn about. Auto-deleting a memory because a later one
"contradicts" it can silently destroy a deliberate exception.

So the rule is sharp:

- **Read-only / regenerable work runs automatically** (artifact GC, audit
  reports, cross-repo digests).
- **Anything that writes a memory or an agent is propose-only** — it lands in a
  report a human approves before a single destructive edit is applied.

## Phases

| Phase | Does | Risk | Mode |
| ----- | ---- | ---- | ---- |
| A — artifact GC | delete `run-state.json` / `gates.jsonl` for branches that are merged AND deleted; clear stale `*.tmp` | low (regenerable) | **auto** |
| B — memory audit | scan `MEMORY.md` + memory files; flag duplicates + contradictions (later supersedes earlier); emit a report | low (read-only) | **auto report; edits propose-only** |
| C — cross-repo mining | read wave history (`gates.jsonl`, `git log`) across configured repos; surface recurring patterns as a digest | low (read-only) | **auto digest** |
| D — apply + turncoat | apply human-approved memory consolidations; trigger `the-turncoat` on flagged bloated agents/skills | high (writes agents/memory) | **gated on human OK of A–C report** |
| Stretch — research | `deep-research` skill for proactive external improvements → digest | med | **separate opt-in; never auto-apply** |

### Phase A — artifact GC (auto)

- Enumerate `local/loops/<branch>/` dirs. For each, resolve `<branch>`:
  merged into the default branch AND no longer present on the remote → the
  run is done, GC the dir.
- A branch still open (PR live, or branch exists) → keep; an in-flight or
  resumable run owns it.
- Clear orphaned `run-state.json.tmp` (crash residue) regardless of branch
  state — the atomic-write contract means a `.tmp` is always disposable.
- `local/` is gitignored, so this never touches tracked files. Pure scratch
  hygiene. Log a one-line summary of what was reaped.

### Phase B — memory audit (auto report, propose-only edits)

- Load `MEMORY.md` index + every memory file under the memory dir.
- Detect two conditions:
  - **Duplicates** — two files cover the same fact (same `name` intent,
    overlapping body). Propose: merge into one, keep the richer.
  - **Contradictions** — a later memory states the opposite of an earlier one
    (e.g. a feedback memory reversed by a newer correction). Propose: retire
    the superseded one, leave a `[[link]]` breadcrumb in the survivor.
- Output a **report only**: each proposed merge/retire with the two file paths,
  the conflicting lines verbatim, and a recommended action. NO file is edited
  in Phase B. Edits happen in Phase D after a human signs off.
- Verbatim-citation discipline (same as the loop's gate reports): quote the
  conflicting memory lines, never paraphrase away the conflict.

### Phase C — cross-repo mining (auto digest)

- Take a configured list of looper repos (where `local/loops/` exists).
- Read each run's `gates.jsonl` + `git log` to extract: which crew agents
  flagged what, how often, in which domains; which waves needed retries; which
  goals hit governor rails.
- Aggregate into a digest: "the-stickler flagged convention drift in `repoX`
  across 4 of 6 runs", "auth-surface goals hit `max_corrective_waves` twice".
- Read-only. The digest is signal for a human (or a future scoped run), not an
  action. Surfaces the systemic pattern a per-run learn can't see.

### Phase D — apply + turncoat (gated)

- Runs ONLY after a human approves the Phase A–C report.
- Applies the approved memory merges/retires from Phase B (the only place
  custodian writes a memory).
- For agents/skills the digest flagged as bloated or over-privileged, invokes
  `the-turncoat` (it already does lean rewrites + tool-access trimming) with
  the specific target — custodian decides *what* to hand it, turncoat decides
  *how* to trim, the human approved *that it runs*.
- Every write is auditable: log each applied edit (file, before/after summary)
  to the custodian run log.

### Stretch — external research (separate opt-in)

- Invoke the existing `deep-research` skill on a framed question
  ("recent advances in agent loop orchestration / verification patterns").
- Output a digest of candidate improvements mapped to our pieces (which skill /
  agent each could touch). NEVER auto-applies — it feeds a human decision, same
  as Phase C. Kept opt-in and separate because external research is the highest-
  variance, lowest-determinism input; it shouldn't ride the weekly cadence
  until A–C have proven their value.

## Scheduling

- Cloud cron via the `/schedule` skill (routine), default **weekly**. Low
  frequency — this is hygiene, not a hot loop.
- One run does A → B → C automatically and stops with a combined report.
- D is a separate, human-triggered follow-up (`/looper-custodian apply` against
  the approved report), not part of the scheduled run.
- The stretch research phase is its own opt-in invocation, not on the weekly
  tick.

## State + artifacts

- Custodian writes its own run log + report under `local/custodian/<date>/`
  (gitignored, same as `local/loops/`). Report is the human-review surface.
- Phase A acts on `local/loops/`; it never reads or writes tracked repo files.
- Phase D's applied edits ARE tracked-file changes (memory dir, agents) — those
  go through the normal review/commit path, never silently.

## Safety rails (carried from the loop's own discipline)

- **Propose-vs-dispose split** is the spine: read-only auto, destructive gated.
- **No memory deleted on contradiction alone** without the human seeing both
  sides quoted verbatim.
- **No agent rewritten** except via `the-turncoat`, and only on an approved
  target — custodian doesn't hand-edit agents itself.
- **Bounded like the loop** — cap proposals per run so a single tick can't
  dump an unreviewable wall of edits; surface "N more not shown" rather than
  silently truncating.
- **Task-tool availability honored** — if custodian can't actually invoke
  `the-turncoat` / `deep-research` (no Task tool), it logs the gate
  `ran: false`, never an invented outcome (same rule as `gates.jsonl`).

## Integration with existing pieces

- `looper-learn` — per-run/per-orchestration lessons. Custodian reads the
  lessons learn already wrote; it does not duplicate learn's diagnosis.
- `the-turncoat` — the only actor that rewrites an agent/skill. Custodian
  routes to it; never does the rewrite itself.
- `deep-research` — the stretch phase's engine. Reused, not reinvented.
- `/schedule` — the cron host. Reused.

## Open questions for the greenlight

1. Repo list for Phase C — explicit config file, or auto-discover every repo
   with a `local/loops/`?
2. Phase A aggressiveness — GC immediately on merged+deleted, or keep a grace
   window (e.g. 30 days) before reaping?
3. Phase D trigger — a dedicated `/looper-custodian apply <report>`, or fold
   approval into a reply on the report itself?
4. Cadence — weekly default confirmed, or monthly for the cross-repo/research
   phases vs weekly for GC?
