---
name: looper-custodian
description: Scheduled cross-run, cross-repo housekeeping for the looper system. Runs weekly — GCs merged-branch artifacts, audits memory for duplicates/contradictions, mines wave history across repos, and researches external advances — then opens a GitHub report issue with checkbox proposals. Destructive edits (memory merges, agent rewrites via the-turncoat) apply ONLY through a separate human-checked `apply` step. Trigger when the user says "run the custodian", "custodian cleanup", "looper housekeeping", on the weekly cron, or "looper-custodian apply #<issue>".
---

Scheduled maintenance layer for the looper system. `looper-learn` learns per-run; `the-turncoat` streamlines on demand; neither runs **across runs and across repos on a cadence**. Custodian is that layer: weekly GC + memory audit + cross-repo mining + external research, surfaced as a GitHub issue you approve from.

Full design rationale: `docs/looper-custodian-plan.md`. This file is the executable spec.

## Governing principle: custodian PROPOSES, human DISPOSES

Same discipline the loop holds (does NOT auto-revert commits, does NOT flip draft→ready). An unattended job that auto-edits memories or agents is exactly the "merging outpaces comprehension" failure the loop-engineering sources warn about. Auto-deleting a memory because a later one "contradicts" it can silently destroy a deliberate exception.

So the line is sharp:

- **Read-only / regenerable work runs automatically** — artifact GC, memory audit report, cross-repo digest, research digest.
- **Anything that writes a memory or an agent is propose-only** — it lands as a checkbox in the report issue and applies ONLY through `apply` after a human ticks the box.

## Two modes

| Invocation | Does |
| ---------- | ---- |
| default (cron or manual `/looper-custodian`) | the **maintenance run**: phases A → B → C → E, read-only, ends by opening/updating the report issue |
| `/looper-custodian apply #<issue>` | **Phase D**: reads the ticked checkboxes in that issue, applies exactly those, idempotently |

Phase D is NEVER part of the scheduled run. The cron only ever proposes.

## Repos (explicit, not auto-discovered)

Named constant. All under `~/Developer/Repos/`:

```
linklater
tuffgal
tuffgal-action
agents-of-shield-if-shield-is-ai
rss-reader
```

A repo missing, or with no `local/loops/`, is **skipped with a logged note** — never an error. Explicit beats auto-discover: the set is small and stable, and an unattended job scanning every repo it can reach is the unbounded reach the propose/dispose discipline exists to prevent. To add a repo, edit this list.

## Maintenance run — phases A → B → C → E

Run in order. A and C and E are purely informational in the issue; B and E carry the actionable checkboxes (E only when a candidate is concrete enough to act on). Each phase logs to `local/custodian/<date>/custodian-log.jsonl` before the issue is written.

### Phase A — artifact GC (auto, destructive only to scratch)

- Enumerate `local/loops/<branch>/` dirs in each repo. For each, resolve whether `<branch>`'s work is **merged**, by EITHER signal:
  - ancestry — `git branch --merged <default>` lists it (its tip is in the default branch), OR
  - a **merged PR** exists for it — `gh pr list --state merged --head <branch>` returns a row (catches squash-merges, which ancestry misses).
- **Merged ⇒ reap, regardless of a lingering local branch.** A merged local branch is just un-cleaned-up local cruft — it does NOT own resumable work, so it never blocks the GC. The reap test is *merged*, full stop.
- **Keep ONLY when work is genuinely in flight:** an **open PR** exists, OR the branch is **not merged by either signal** (unmerged tip + no merged PR). That is the "in-flight or resumable run owns it" case. A lingering *merged* local branch is NOT that case.
- Squash-merge caveat: if `gh` is unavailable, ancestry alone can't see a squash-merge, so a squash-merged-and-deleted branch reads as unmerged and is conservatively **kept** (never wrongly reaped). Log it as `kept (merge unverifiable — gh absent)` so the miss is visible, not silent.
- Clear orphaned `run-state.json.tmp` (crash residue) regardless of branch state — the atomic-write contract means a `.tmp` is always disposable.
- **No grace window.** Reap immediately once merged. The merge already comprehended the work and `local/` is regenerable scratch — nothing to protect with a delay. The *merged* test IS the safety; an unmerged or open-PR branch is never touched.
- `local/` is gitignored, so this never touches tracked files. Pure scratch hygiene. Log a one-line summary of what was reaped (and what was kept-and-why) per repo.

### Phase B — memory audit (auto report, propose-only edits)

- **Deterministic enumeration FIRST.** The orchestrator itself globs each repo's memory dir to build the explicit file list and records `files_total`. Enumeration is NEVER delegated — a subagent's `bash find`/`grep` can silently fail (path quoting, cwd resets) and under-audit without anyone noticing. The orchestrator owns the list; only the per-file *reading* may be delegated.
- **If delegating the audit** to a subagent (e.g. a large dir like linklater's 60+ files), hand it the **explicit absolute path list** and instruct it to use the **Read tool only** — never bash discovery. The subagent reports back per file so coverage is countable.
- **Coverage accounting is mandatory.** Track `files_audited` vs `files_total`. If `files_audited < files_total`, the phase verdict is **`partial — N/M audited`**, NEVER "clean". A clean bill is only valid at full coverage. Partial coverage names the unread files and recommends a rerun — a tidy "no findings" that silently skipped 37 files is the exact failure this rule exists to prevent.
- Detect two conditions:
  - **Duplicates** — two files cover the same fact (same `name` intent, overlapping body). Propose: merge into one, keep the richer.
  - **Contradictions** — a later memory states the opposite of an earlier one (e.g. a feedback memory reversed by a newer correction). Propose: retire the superseded one, leave a `[[link]]` breadcrumb in the survivor.
- Output **proposals only** — each as a checkbox in the issue (`B-merge-<n>`, `B-retire-<n>`) with the two file paths, the conflicting lines **verbatim**, and the recommended action. NO file is edited in Phase B. Edits happen in Phase D after a human ticks the box.
- **Verbatim-citation discipline** (same as the loop's gate reports): quote the conflicting memory lines, never paraphrase away the conflict. A proposal the human can't verify from the quoted evidence is not shown.

### Phase C — cross-repo mining (auto digest, read-only)

- Across the repo list, read each run's `gates.jsonl` + `git log` to extract: which crew agents flagged what, how often, in which domains; which waves needed retries (`kind: "wave-retry"`); which goals hit governor rails; stale-skips (`kind: "stale-skip"`).
- Aggregate into a digest: "the-stickler flagged convention drift in `tuffgal` across 4 of 6 runs", "auth-surface goals hit `max_corrective_waves` twice in `linklater`".
- Read-only. The digest is signal for a human (or a future scoped run), not an action — it surfaces the systemic pattern a per-run learn can't see. No checkboxes unless a finding is concrete enough to route to `the-turncoat`, in which case it becomes a `D-turncoat-<n>` proposal.

### Phase E — external research (auto digest, read-only)

- Invoke `deep-research` via the Skill tool. Two tracks, alternated so no week is overloaded:
  - **Standing track (every run):** "recent advances in agent loop orchestration / verification patterns" — the moving state of the art.
  - **Rotating track (cycles week to week):** point `deep-research` at our own pieces and ask what the wider world does better — (1) new refactoring / loop-decomposition patterns vs how `looper-scope` + the waves work today; (2) documentation schemes for agent/skill specs; (3) third-party packages / tools that would do something a crew agent or skill currently hand-rolls.
- Output a digest of candidates, each **mapped to the specific piece it could touch** (which skill / agent / doc) and tagged `E-<n>`. A genuinely actionable one becomes a checkbox so it can ride the same approval path into a scoped change.
- NEVER auto-applies — highest-variance, lowest-determinism input, so it feeds a human decision exactly like Phase C. It informs; it never edits.

## The report issue (notification + approval surface)

The weekly run is a cloud cron with nobody watching, and `local/` is gitignored — a local report file would be invisible AND unreachable by a later apply step. So the report is a **GitHub issue** in `agents-of-shield-if-shield-is-ai`, opened with the `gh` CLI.

- **Title:** `Custodian report <date>`
- **Body** mirrors the phases: A reaped (info) / B proposals (checkboxes) / C digest (info) / E research (info + any checkboxes).
- **Every actionable proposal is a checkbox tagged** `B-merge-1`, `B-retire-5`, `D-turncoat-2`, `E-3` — with verbatim evidence inline.
- **No findings → no issue.** A quiet week opens nothing, so no notification noise. This is also how you learn a report is ready: GitHub's issue-opened notification IS the signal.

To approve, tick the boxes you want and run `/looper-custodian apply #<issue>`.

## Phase D — apply (gated, the only place custodian writes)

Triggered ONLY by `/looper-custodian apply #<issue>`. Never on the cron.

1. Read the issue body via `gh`. Parse the checkboxes: a ticked `[x]` tag applies; an unticked `[ ]` is skipped. **No free-text approval parsing** — boxes only.
2. For each ticked `B-merge`/`B-retire`: apply the memory merge/retire (the only place custodian writes a memory). Leave the `[[link]]` breadcrumb on retire.
3. For each ticked `D-turncoat`: invoke `the-turncoat` via the Task tool with the specific flagged target. Custodian decides *what* to hand it; turncoat decides *how* to trim; the human approved *that it runs*. Custodian never hand-edits an agent itself.
4. For each ticked `E-<n>` that maps to a build: hand it off as a scoped change (note it for the user / a `loop-de-looper` run) — custodian does not itself implement features.
5. **Idempotent.** Diff current state first; an already-applied item is a no-op, never a double-edit. Re-running `apply` on the same issue is safe.
6. **Audit every write.** Log each applied edit (file, before/after summary) to `custodian-log.jsonl`, and comment the summary back on the issue.
7. Applied edits to tracked files (memory dir, agents) go through the **normal review/commit path** — never silently committed by custodian.

## Scheduling

**Local launchd, NOT cloud `/schedule`.** Phases A/B/C read local-only state — `local/loops/` scratch (gitignored), the `~/.claude` memory dir (outside any repo), `gates.jsonl` across local repos — none of which an isolated cloud session can reach. So the host is a macOS launchd job on the dev machine.

- Job: `~/Library/LaunchAgents/com.nickschneble.looper-custodian.plist` → runs `scripts/looper-custodian-cron.sh`, **weekly, Monday 09:00 local**, all phases on one tick (A → B → C → E). Low frequency — hygiene, not a hot loop.
- The wrapper runs `claude -p "/looper-custodian" --dangerously-skip-permissions` because an unattended job can't answer prompts. Bounded: the scheduled run is propose-only (see below), so no tracked-file edits happen on it, and the destructive-git guard hook still blocks history rewrites.
- launchd runs a missed tick on next wake, so a sleeping Mac just defers the run rather than skipping it.
- The scheduled run only ever opens/updates the report issue. `apply` is always a separate, human-triggered invocation.

To change cadence, edit `StartCalendarInterval` in the plist and reload (`launchctl bootout` then `bootstrap`).

## Artifacts

Under `local/custodian/<date>/` (gitignored, same as `local/loops/`):

- **`custodian-log.jsonl`** — append-only run log, one JSON line per phase action, never rewritten. The machine record / audit trail.

```json
{
  "phase": "A",                       // "A" | "B" | "C" | "E" | "D-apply"
  "repo": "tuffgal",
  "task_tool_available": true,        // false = could NOT invoke a sub-skill/agent
  "ran": true,                        // false when a needed tool was unavailable
  "action": "reaped local/loops/fix-auth (merged+deleted)",
  "detail": "1 dir, 2 files"
}
```

- The **GitHub issue** is the human-review + approval surface; the jsonl is the machine record. They agree — the issue's claims trace to logged lines.

**`task_tool_available: false` ⇒ `ran: false` ⇒ no invented outcome.** Per the loop's `[[feedback-task-tool-availability]]` discipline: if custodian can't actually invoke `deep-research` / `the-turncoat` (no Task/Skill tool), it logs `ran: false` and says so in the issue — NEVER an invented digest or a claimed-but-unrun edit.

## Safety rails (carried from the loop's own discipline)

- **Propose-vs-dispose split** is the spine: read-only auto, destructive gated behind a ticked box + explicit `apply`.
- **No memory deleted on contradiction alone** without the human seeing both sides quoted verbatim in the issue.
- **No agent rewritten** except via `the-turncoat`, on an approved target — custodian never hand-edits an agent.
- **Bounded** — cap proposals per run (default 20 across B+C+E) so one tick can't dump an unreviewable wall. Surface "N more not shown" rather than silently truncating.
- **Task/Skill availability honored** — unavailable tool ⇒ `ran: false`, never an invented outcome.
- **Explicit repo list** — never reaches beyond the named repos.

## Integration with existing pieces

- `looper-learn` — per-run/per-orchestration lessons. Custodian reads what learn wrote; it does not duplicate learn's diagnosis.
- `the-turncoat` — the only actor that rewrites an agent/skill. Custodian routes to it; never does the rewrite itself.
- `deep-research` — Phase E's engine. Reused, not reinvented.
- **launchd** — the cron host (local, not cloud `/schedule`, which can't reach local state). Plist + wrapper under `~/Library/LaunchAgents/` + `scripts/`.
- `gh` CLI — opens the report issue, reads its checkboxes, comments the apply summary.

## What looper-custodian does NOT do

- Does NOT edit a memory or an agent during the scheduled run — proposes only; writes happen ONLY in `apply` after a ticked box.
- Does NOT parse free-text approval — checkboxes only.
- Does NOT auto-apply Phase E research, ever — it informs a human decision.
- Does NOT GC an open or undeleted branch's artifacts, or touch any tracked file in Phase A.
- Does NOT reach beyond the explicit repo list.
- Does NOT record a result it didn't produce — unavailable tool ⇒ `ran: false`, no invented digest or verdict.
- Does NOT commit applied edits silently — they go through the normal review/commit path.
- Does NOT open an issue on a quiet week — no findings, no noise.
