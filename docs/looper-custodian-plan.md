# Looper Custodian — build plan

Status: **plan / not built — all open questions resolved (2026-06-27).** Design
for a new scheduled housekeeping skill, `looper-custodian`. Greenlight to build
against this spec is the only remaining gate; see Resolved decisions at the end.

## Why it exists

The looper system learns and tidies _per run_: `looper-learn` writes lessons
at the end of each wave and each orchestration; `the-turncoat` streamlines an
agent or skill when asked; each run GCs nothing. Nothing runs _across_ runs and
_across_ repos on a cadence. Over weeks that leaves:

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

| Phase                 | Does                                                                                                         | Risk                        | Mode                                  |
| --------------------- | ------------------------------------------------------------------------------------------------------------ | --------------------------- | ------------------------------------- |
| A — artifact GC       | delete `run-state.json` / `gates.jsonl` for branches that are merged AND deleted; clear stale `*.tmp`        | low (regenerable)           | **auto**                              |
| B — memory audit      | scan `MEMORY.md` + memory files; flag duplicates + contradictions (later supersedes earlier); emit a report  | low (read-only)             | **auto report; edits propose-only**   |
| C — cross-repo mining | read wave history (`gates.jsonl`, `git log`) across configured repos; surface recurring patterns as a digest | low (read-only)             | **auto digest**                       |
| D — apply + turncoat  | apply human-approved memory consolidations; trigger `the-turncoat` on flagged bloated agents/skills          | high (writes agents/memory) | **gated on checkbox approval in the report issue** |
| E — external research | `deep-research` skill for proactive external improvements → digest                                           | med                         | **auto digest; never auto-apply**     |

### Phase A — artifact GC (auto)

- Enumerate `local/loops/<branch>/` dirs. For each, resolve `<branch>`:
  merged into the default branch AND no longer present on the remote → the
  run is done, GC the dir.
- A branch still open (PR live, or branch exists) → keep; an in-flight or
  resumable run owns it.
- Clear orphaned `run-state.json.tmp` (crash residue) regardless of branch
  state — the atomic-write contract means a `.tmp` is always disposable.
- **No grace window.** Reap immediately once a branch is merged AND deleted —
  the merge already comprehended the work, and `local/` is regenerable scratch,
  so there is nothing to protect with a delay. The merged+deleted test IS the
  safety: an open or undeleted branch is never touched.
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

- Explicit repo list (not auto-discovery), all under `~/Developer/Repos/`:
  `linklater`, `tuffgal`, `tuffgal-action`, `agents-of-shield-if-shield-is-ai`,
  `rss-reader`. Lives in the skill as a named constant; a missing or
  `local/loops/`-less repo is skipped with a logged note, never an error.
  Explicit beats auto-discover here: the set is small and stable, and an
  unattended job scanning every repo it can reach is exactly the kind of
  unbounded reach the propose/dispose discipline argues against.
- Read each run's `gates.jsonl` + `git log` to extract: which crew agents
  flagged what, how often, in which domains; which waves needed retries; which
  goals hit governor rails.
- Aggregate into a digest: "the-stickler flagged convention drift in `repoX`
  across 4 of 6 runs", "auth-surface goals hit `max_corrective_waves` twice".
- Read-only. The digest is signal for a human (or a future scoped run), not an
  action. Surfaces the systemic pattern a per-run learn can't see.

### Phase D — apply + turncoat (gated)

- Runs ONLY after a human checks proposals in the report issue (see
  **Notification + approval** below) and invokes `/looper-custodian apply
  #<issue>`.
- Reads the issue, applies ONLY the checked items (each proposal is tagged —
  `B-merge-1`, `B-retire-5`, `D-turncoat-2` — and a box must be ticked for that
  tag to apply). Unchecked = skipped. No free-text approval parsing.
- Applies the approved memory merges/retires from Phase B (the only place
  custodian writes a memory).
- For agents/skills the digest flagged as bloated or over-privileged, invokes
  `the-turncoat` (it already does lean rewrites + tool-access trimming) with
  the specific target — custodian decides _what_ to hand it, turncoat decides
  _how_ to trim, the human approved _that it runs_.
- Idempotent: re-running `apply` against the same issue with the same checks is
  a no-op for already-applied items (it diffs current state, never double-edits).
- Every write is auditable: log each applied edit (file, before/after summary)
  to the custodian run log, and comment a summary back on the issue.

### Phase E — external research (auto digest, integrated from the start)

- Runs on the weekly tick alongside A–C (not a separate opt-in). It is
  read-only and auto-applies nothing, so it carries the same risk profile as the
  cross-repo digest — no reason to hold it back.
- Invokes the existing `deep-research` skill. Two research tracks, alternated so
  no single week is overloaded:
  - **Standing track (every run):** "recent advances in agent loop
    orchestration / verification patterns" — the moving state of the art.
  - **Rotating track (cycles week to week):** points `deep-research` at our own
    pieces and asks what the wider world does better —
    - new refactoring / loop-decomposition patterns vs how `looper-scope` +
      the waves work today,
    - documentation schemes for agent/skill specs (could the SKILL.md or the
      `docs/` framework borrow a better structure),
    - third-party packages / tools that would do something a crew agent or a
      skill currently hand-rolls.
- Output a digest of candidate improvements, each mapped to the specific piece
  it could touch (which skill / agent / doc) and tagged `E-<n>` so a genuinely
  actionable one can ride the same checkbox-approval path into a scoped change.
- NEVER auto-applies — highest-variance, lowest-determinism input, so it feeds a
  human decision exactly like Phase C. It informs; it never edits.

## Scheduling

- Cloud cron via the `/schedule` skill (routine), **weekly for all phases**
  (A, B, C, E on one tick). Low frequency — this is hygiene, not a hot loop.
  One cadence keeps it simple; if E proves too noisy weekly it can drop to a
  rotating-every-other-week track without touching A–C.
- One run does A → B → C → E automatically and stops by opening (or updating)
  the report issue.
- D is the only human-triggered, separate step: `/looper-custodian apply
  #<issue>` against the checked report issue. Never part of the scheduled run.

## Notification + approval (the report issue)

The weekly run is a cloud cron with nobody watching, and `local/` is gitignored
— so a local report file would be both invisible and unreachable by a later
apply step. The report is therefore a **GitHub issue** in this repo
(`agents-of-shield-if-shield-is-ai`), which solves four things at once:

- **Notification** — GitHub pings you when the issue opens. _This is how you
  learn a new report is ready and actionable._ Quiet weeks (nothing found)
  open no issue, so no notification noise.
- **Durable report** — survives the ephemeral cron; not gitignored.
- **Approval surface** — every proposal is a checkbox tagged `B-merge-1`,
  `C-2`, `E-3`, etc., with the verbatim evidence inline (conflicting memory
  lines, recurring-finding counts, research candidate + the piece it maps to).
- **Stable ref for apply** — `/looper-custodian apply #<issue>` reads the
  ticked boxes and applies exactly those, idempotently.

Issue title: `Custodian report <date>`. Body sections mirror the phases
(A reaped / B proposals / C digest / E research), A and C purely informational,
B and E carrying the actionable checkboxes.

## State + artifacts

- Custodian writes its full run log under `local/custodian/<date>/` (gitignored,
  same as `local/loops/`) for the audit trail; the **GitHub issue** is the
  human-review + approval surface (the run log is the machine record).
- Phase A acts on `local/loops/`; it never reads or writes tracked repo files.
- Phase D's applied edits ARE tracked-file changes (memory dir, agents) — those
  go through the normal review/commit path, never silently, and a summary is
  commented back on the issue.

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
- `deep-research` — Phase E's engine. Reused, not reinvented.
- `/schedule` — the cron host. Reused.
- `gh` CLI — opens the report issue, reads its checkboxes, comments the apply
  summary. The issue is the report transport AND the approval surface.

## Resolved decisions (greenlit 2026-06-27)

1. **Phase C/E repo list** — explicit, not auto-discover. All under
   `~/Developer/Repos/`: `linklater`, `tuffgal`, `tuffgal-action`,
   `agents-of-shield-if-shield-is-ai`, `rss-reader`.
2. **Phase A aggressiveness** — GC immediately on merged+deleted, no grace
   window. The merged+deleted test is itself the safety.
3. **Phase D trigger** — checkbox approval in the report issue, then
   `/looper-custodian apply #<issue>`. Explicit + idempotent, no fuzzy parsing.
4. **Cadence** — weekly for all phases (A, B, C, E on one tick).
5. **External research** — promoted from a stretch opt-in to **Phase E**,
   integrated from the start, weekly, read-only auto digest. Standing track =
   loop-orchestration state of the art; rotating track = our pieces vs better
   refactoring patterns / documentation schemes / third-party packages.
6. **Notification** — the run opens a GitHub issue; GitHub's notification is how
   you learn a report is ready.

Greenlight to build `looper-custodian` against this spec is the only remaining
gate.
