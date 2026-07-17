---
name: looper-custodian
description: Scheduled cross-run, cross-repo housekeeping for the looper system. Runs weekly — GCs merged-branch artifacts, audits memory for duplicates/contradictions, mines wave history across repos, and researches external advances — then opens a GitHub report issue with checkbox proposals. Destructive edits (memory merges, agent rewrites via the-turncoat) apply ONLY through a separate human-checked `apply` step, which is previewable (`--dry-run`) and reversible (`undo`). Trigger when the user says "run the custodian", "custodian cleanup", "looper housekeeping", on the weekly cron, "looper-custodian apply #<issue>", "looper-custodian apply #<issue> --dry-run", "looper-custodian undo", or "looper-custodian history <query>".
---

Scheduled maintenance layer for the looper system. `looper-learn` learns per-run; `the-turncoat` streamlines on demand; neither runs **across runs and across repos on a cadence**. Custodian is that layer: weekly GC + memory audit + cross-repo mining + external research, surfaced as a GitHub issue you approve from.

Full design rationale + decision log: `docs/looper-custodian.md`. This file is the executable spec.

## Governing principle: custodian PROPOSES, human DISPOSES

Same discipline the loop holds (does NOT auto-revert commits, does NOT flip draft→ready). An unattended job that auto-edits memories or agents is exactly the "merging outpaces comprehension" failure the loop-engineering sources warn about. Auto-deleting a memory because a later one "contradicts" it can silently destroy a deliberate exception.

So the line is sharp:

- **Read-only / regenerable work runs automatically** — artifact GC, memory audit report, cross-repo digest, research digest.
- **Anything that writes a memory or an agent is propose-only** — it lands as a checkbox in the report issue and applies ONLY through `apply` after a human ticks the box.

## Two modes

| Invocation | Does |
| ---------- | ---- |
| default (cron or manual `/looper-custodian`) | the **maintenance run**: phases C → A → B → E, read-only, ends by opening/updating the report issue |
| `/looper-custodian apply #<issue>` | **Phase D**: reads the ticked checkboxes, snapshots targets to a backup, applies exactly those, idempotently |
| `/looper-custodian apply #<issue> --dry-run` | **Phase D preview**: prints the EXACT before/after of each ticked item and writes nothing. Consent then approves a *previewed* diff, not a *described* one |
| `/looper-custodian undo` | **restore** the most recent Phase D snapshot, reverting the last `apply`. Idempotent — a no-op on an already-clean tree |
| `/looper-custodian history <query> [--agent\|--verdict\|--kind\|--file\|--repo …]` | **read-only lookup** over the cross-run history index — ranked, cited matches from `gates.jsonl` across repos. Writes nothing. `--rebuild` re-derives the index from source. Never on the cron |

Phase D is NEVER part of the scheduled run. The cron only ever proposes. `--dry-run` and `undo` are human-triggered like `apply` itself.

Invocation grammar follows the looper `noun-verb [arg] [--flag]` convention (`docs/looper-skills.md` → `## Subcommand grammar`): `apply` is the verb, `#<issue>` the arg, `--dry-run` the flag; `undo` and `history` are sibling verbs (`history` read-only, takes a query arg + filter flags).

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

## Maintenance run — phases C → A → B → E

Run in order — **C strictly before A.** Phase C's ingest indexes every `gates.jsonl` line while the source dirs still exist; only then may Phase A reap them. The 2026-07-13 run proved the old A-first order destructive: reap deleted 11 `gates.jsonl` files whose lines had never been ingested, and "rebuild from source" cannot rebuild from a source the GC just deleted (decision 13, `docs/looper-custodian.md`). A and C and E are purely informational in the issue; B and E carry the actionable checkboxes (E only when a candidate is concrete enough to act on). Each phase logs to `local/custodian/<date>/custodian-log.jsonl` before the issue is written.

### Phase C — cross-repo mining (auto digest, read-only, index-backed)

- **Runs first — its ingest is Phase A's precondition.** Every `gates.jsonl` line must be in the index before the GC may delete the dir that holds it.
- **Backed by a cross-run history index** — `local/custodian/history-index.jsonl`, append-only, one record per `gates.jsonl` line across the repo list. Each record carries the gate's fields verbatim (`wave, kind, agent, verdict, blockers, summary`) plus `repo`, `branch`, the branch's touched `files` (from `git log --name-only` for its commits; `[]` when git can't resolve them — never invented), and a `cite` = `<repo>/local/loops/<branch>/gates.jsonl:<line>`.
- **Incremental ingest, not re-scan.** Phase C runs `scripts/custodian-history.sh ingest`, appending ONLY `gates.jsonl` lines whose `cite` isn't already indexed (anti-join by `cite` in `jq`). Weekly cost is the *new* runs since last week, not every run ever. Touched `files` come from commit SHAs named in each run's summaries (`git cat-file`-verified, then `git show --name-only`) — SHA-based so they resolve after the branch is merged + deleted. (The `ctx` pattern grafted onto our substrate: query one structured store rather than re-scan, JSONL + `jq`, no SQLite — `gates.jsonl` is already the structured log. `[[reference-ctx-agent-history-search]]`, `[[no-third-party-hosted-tool-reliance]]`.)
- **Digest is queried from the index, and cited.** Aggregate as before ("the-stickler flagged convention drift in `tuffgal` across 4 of 6 runs", "auth-surface goals hit `max_corrective_waves` twice in `linklater`") — but every claim resolves to exact `cite` lines, quoted, never paraphrased away. Same verbatim-citation discipline as Phase B.
- **Derived + regenerable — while the source exists.** The index is a cache of `gates.jsonl`, so `history --rebuild` re-derives it from source; a corrupt or lost index is never a data-loss event. But rebuild-ability holds ONLY until Phase A reaps the source — which is exactly why C runs first and Phase A carries the ingest-guard. It's gitignored scratch, same status as `local/loops/`, and sits on the read-only/auto side of the propose-dispose line.
- Read-only. The digest is signal for a human (or a future scoped run), not an action — it surfaces the systemic pattern a per-run learn can't see. No checkboxes unless a finding is concrete enough to route to `the-turncoat`, in which case it becomes a `D-turncoat-<n>` proposal. If git is unavailable for a repo, its records carry `files: []` and the phase logs the gap per the availability discipline — never an invented touched-file list.

### Phase A — artifact GC (auto, destructive only to scratch)

- Enumerate `local/loops/<branch>/` dirs in each repo. For each, resolve whether `<branch>`'s work is **merged**, by EITHER signal:
  - ancestry — `git branch --merged <default>` lists it (its tip is in the default branch), OR
  - a **merged PR** exists for it — `gh pr list --state merged --head <branch>` returns a row (catches squash-merges, which ancestry misses).
- **Merged ⇒ reap, regardless of a lingering local branch.** A merged local branch is just un-cleaned-up local cruft — it does NOT own resumable work, so it never blocks the GC. The reap test is *merged*, full stop.
- **Ingest-guard (hard rule).** Before reaping a dir that contains a `gates.jsonl`, verify every one of its lines is already in `history-index.jsonl` (anti-join by `cite`, same check as ingest). Any line missing ⇒ do NOT reap; log `kept (unindexed — ingest gap)` and let a later run retry after ingest catches up. With C running first this is a no-op in a healthy run — the guard exists so a partial or failed ingest can never turn the GC destructive again (2026-07-13 incident: 11 unindexed `gates.jsonl` reaped, recovered only via off-site backup).
- **Keep ONLY when work is genuinely in flight:** an **open PR** exists, OR the branch is **not merged by either signal** (unmerged tip + no merged PR). That is the "in-flight or resumable run owns it" case. A lingering *merged* local branch is NOT that case.
- Squash-merge caveat: if `gh` is unavailable, ancestry alone can't see a squash-merge, so a squash-merged-and-deleted branch reads as unmerged and is conservatively **kept** (never wrongly reaped). Log it as `kept (merge unverifiable — gh absent)` so the miss is visible, not silent.
- Clear orphaned `run-state.json.tmp` (crash residue) regardless of branch state — the atomic-write contract means a `.tmp` is always disposable.
- **No grace window.** Reap immediately once merged. The merge already comprehended the work and `local/` is regenerable scratch — nothing to protect with a delay. The *merged* test IS the safety; an unmerged or open-PR branch is never touched.
- `local/` is gitignored, so this never touches tracked files. Pure scratch hygiene. Log a one-line summary of what was reaped (and what was kept-and-why) per repo.

### Phase B — memory audit (auto report, propose-only edits)

- **Deterministic enumeration FIRST.** The orchestrator itself globs each repo's memory dir to build the explicit file list and records `files_total`. Enumeration is NEVER delegated — a subagent's `bash find`/`grep` can silently fail (path quoting, cwd resets) and under-audit without anyone noticing. The orchestrator owns the list; only the per-file *reading* may be delegated.
- **If delegating the audit** to a subagent (e.g. a large dir like linklater's 60+ files), hand it the **explicit absolute path list** and instruct it to use the **Read tool only** — never bash discovery. The subagent reports back per file so coverage is countable.
- **Coverage accounting is mandatory.** Track `files_audited` vs `files_total`. If `files_audited < files_total`, the phase verdict is **`partial — N/M audited`**, NEVER "clean". A clean bill is only valid at full coverage. Partial coverage names the unread files and recommends a rerun — a tidy "no findings" that silently skipped 37 files is the exact failure this rule exists to prevent.
- Detect four conditions:
  - **Duplicates** — two files cover the same fact (same `name` intent, overlapping body). Propose: merge into one, keep the richer.
  - **Contradictions** — a later memory states the opposite of an earlier one (e.g. a feedback memory reversed by a newer correction). Propose: retire the superseded one, leave a `[[link]]` breadcrumb in the survivor.
  - **Distillation** — three-plus *episodic* notes (one-off project observations) that all instance the same underlying rule. Not duplicates (each cites a different occurrence) and not contradictions (they agree) — they're evidence piling up for a pattern no single memory states. Propose: distill into ONE semantic/procedural memory that names the rule, `[[link]]` the episodic instances as its evidence, and retire them. This is the consolidation a flat de-dupe misses: the system has *learned* something the memory dir only implies. Distill, do not just shrink — a one-rule memory that drops the why is worse than the three notes.
  - **Staleness** — a memory cites a `file:line`, script, symbol, or flag that no longer resolves in the surface it documents. Resolve each citation against the RIGHT root (a `~/.claude/…` cite against user-global; a repo-relative cite against that repo) and by existence-plus-`grep` for the symbol, NOT an exact-line match — an unrelated edit shifting `:42` to `:47` is line drift, not a dead reference, and reading it as one floods false retires. A target that merely MOVED is live: propose `B-repoint` — update the citation to its new location, the same "provably gone, not merely moved" line `loop-de-looper`'s stale-candidate pre-check draws. Propose `B-retire` ONLY when a relocation search comes up empty — the thing is genuinely gone. Quote the dead reference verbatim, AND on a retire quote the failed relocation search too, so the human verifies *gone*, not merely *moved*.
- Output **proposals only** — each as a checkbox in the issue (`B-merge-<n>`, `B-retire-<n>`, `B-distill-<n>`, `B-repoint-<n>`) with the file paths, the relevant lines **verbatim**, and the recommended action. NO file is edited in Phase B. Edits happen in Phase D after a human ticks the box.
- **Verbatim-citation discipline** (same as the loop's gate reports): quote the conflicting memory lines, never paraphrase away the conflict. A proposal the human can't verify from the quoted evidence is not shown.

### `history` — query the cross-run index (read-only, never on cron)

Backed by `scripts/custodian-history.sh query`:

```
scripts/custodian-history.sh query <q> \
  [--agent S] [--verdict S] [--kind S] [--repo S] [--file S] [--blocked] [--limit N]
```

Read-only lookup over `history-index.jsonl`. Returns **ranked, cited matches** — most-recent-first (by the source `gates.jsonl` mtime), each printed with its `cite` (`<repo>/local/loops/<branch>/gates.jsonl:<n>`) so every hit traces to source, same way `ctx` returns cited snippets rather than raw logs. `<q>` is a case-insensitive substring over summary+agent+verdict+kind; all flags are case-insensitive substrings too (real `verdict`s are free-text prose like `"CHANGES REQUESTED"`, not an enum — so match on substrings, and use `--blocked` for the reliable `blockers>0` "flagged" signal). Filters compose:

- `--file src/auth.ts` → "what happened last time we touched this" (ctx's file filter, re-created from the indexed `files`).
- `--agent the-diamantaire --blocked` → "everything this crew agent flagged with blockers."
- `--kind wave-retry --repo linklater` → "which waves needed retries here."

`scripts/custodian-history.sh rebuild` wipes and re-derives the whole index from every `gates.jsonl` — safe anytime, since the index is a derived cache. Query writes nothing; disposes nothing; never part of the scheduled run. Human- or agent-triggered, like `apply`/`undo`.

### Phase E — external research (auto digest, read-only)

- Invoke `deep-research` via the Skill tool. Two tracks, alternated so no week is overloaded:
  - **Standing track (every run):** "recent advances in agent loop orchestration / verification patterns" — the moving state of the art.
  - **Rotating track (cycles week to week):** point `deep-research` at our own pieces and ask what the wider world does better — (1) new refactoring / loop-decomposition patterns vs how `looper-scope` + the waves work today; (2) documentation schemes for agent/skill specs; (3) third-party packages / tools that would do something a crew agent or skill currently hand-rolls.
- Output a digest of candidates, each **mapped to the specific piece it could touch** (which skill / agent / doc) and tagged `E-<n>`. A genuinely actionable one becomes a checkbox so it can ride the same approval path into a scoped change.
- **No external claim becomes an actionable checkbox without a local-validation method.** Web research is the highest-variance input — a pattern that works in someone's blog post is not evidence it works *here*. So an `E-<n>` is only eligible to be a checkbox if it carries a concrete way to prove it locally BEFORE adoption: a runnable eval, a shadow run (apply it to one wave/repo and compare), or a replay against a past run's `gates.jsonl`. State the method inline (`validate-by: <how>`). A candidate with no feasible local check stays **informational only** — it goes in the digest as signal, never as a tick-to-apply box. This mirrors the loop's own "executable verification function over LLM say-so" rule (`looper-verify`): adopt on local proof, not on an external author's say-so.
- NEVER auto-applies — highest-variance, lowest-determinism input, so it feeds a human decision exactly like Phase C. It informs; it never edits.

## The report issue (notification + approval surface)

The weekly run is a cloud cron with nobody watching, and `local/` is gitignored — a local report file would be invisible AND unreachable by a later apply step. So the report is a **GitHub issue** in `agents-of-shield-if-shield-is-ai`, opened with the `gh` CLI.

- **Title:** `Custodian report <date>`
- **Body** mirrors the phases: A reaped (info) / B proposals (checkboxes) / C digest (info) / E research (info + any checkboxes).
- **Every actionable proposal is a checkbox tagged** `B-merge-1`, `B-retire-5`, `B-repoint-4`, `D-turncoat-2`, `E-3` — with verbatim evidence inline.
- **No findings → no issue.** A quiet week opens nothing, so no notification noise. This is also how you learn a report is ready: GitHub's issue-opened notification IS the signal.

To approve, tick the boxes you want and run `/looper-custodian apply #<issue>`.

## Phase D — apply (gated, the only place custodian writes)

Triggered ONLY by `/looper-custodian apply #<issue>`. Never on the cron.

1. Read the issue body via `gh`. Parse the checkboxes: a ticked `[x]` tag applies; an unticked `[ ]` is skipped. **No free-text approval parsing** — boxes only.
2. **Snapshot before any write.** Copy every file a ticked item will touch into `local/custodian/<date>/backup-<issue>-<seq>/`, alongside a `manifest.json` listing each backed-up path + its original location + the issue tag that touched it. The snapshot is taken whole, BEFORE the first edit, so `undo` restores a consistent pre-apply state even if apply halts mid-run. (`--dry-run` skips this — it writes nothing to snapshot.)
3. For each ticked `B-merge`/`B-retire`/`B-distill`/`B-repoint`: apply the memory merge/retire/distill/re-point (the only place custodian writes a memory). Leave the `[[link]]` breadcrumb on retire, and on distill link the retired episodic instances into the new semantic memory as its evidence. A `B-repoint` is the one NON-destructive memory write: edit the stale citation in place to its new location, keeping the memory otherwise intact — no removal, no breadcrumb.
4. For each ticked `D-turncoat`: invoke `the-turncoat` via the Task tool with the specific flagged target. Custodian decides *what* to hand it; turncoat decides *how* to trim; the human approved *that it runs*. Custodian never hand-edits an agent itself.
5. For each ticked `E-<n>` that maps to a build: hand it off as a scoped change (note it for the user / a `loop-de-looper` run) — custodian does not itself implement features.
6. **Idempotent.** Diff current state first; an already-applied item is a no-op, never a double-edit. Re-running `apply` on the same issue is safe.
7. **Audit every write.** Log each applied edit (file, before/after summary, backup path) to `custodian-log.jsonl`, and comment the summary back on the issue — including the backup dir and the `undo` command so the reversal is one copy-paste away.
8. Applied edits to tracked files (memory dir, agents) go through the **normal review/commit path** — never silently committed by custodian.

### `--dry-run` — preview, write nothing

`apply #<issue> --dry-run` runs steps 1 + 3–5 in *describe* mode: for each ticked item it prints the exact before/after (the verbatim memory lines being merged/retired/distilled, the turncoat target + its current vs proposed shape, the scoped-change hand-off text) and STOPS. No snapshot (step 2), no write, no log, no issue comment. The point: the human approves the literal diff, not a paraphrase of it. A real `apply` after a `--dry-run` is the same command without the flag.

### `undo` — restore the last snapshot

`undo` reads the most recent `backup-*/manifest.json` under `local/custodian/`, and restores each listed file to its backed-up content, reverting the last `apply`. Idempotent: if the current files already match the backup (nothing to revert, or `undo` already ran), it's a no-op and says so. `undo` reverts custodian's *working-tree* writes; tracked-file edits already committed are reverted through the normal git path (custodian never force-rewrites history — the destructive-git guard blocks that anyway). One level deep: `undo` restores the latest snapshot, not a stack.

## Scheduling

**Local launchd, NOT cloud `/schedule`.** Phases A/B/C read local-only state — `local/loops/` scratch (gitignored), the `~/.claude` memory dir (outside any repo), `gates.jsonl` across local repos — none of which an isolated cloud session can reach. So the host is a macOS launchd job on the dev machine.

- Job: `~/Library/LaunchAgents/com.nickschneble.looper-custodian.plist` → runs `scripts/looper-custodian-cron.sh`, **weekly, Monday 09:00 local**, all phases on one tick (C → A → B → E). Low frequency — hygiene, not a hot loop.
- The wrapper runs `claude -p "/looper-custodian" --dangerously-skip-permissions` because an unattended job can't answer prompts. Bounded: the scheduled run is propose-only (see below), so no tracked-file edits happen on it, and the destructive-git guard hook still blocks history rewrites.
- **The wrapper retries and alerts.** The headless `claude -p` call gets up to 3 attempts with backoff (transient `API Error: Connection closed mid-response` killed the 2026-07-06 and 2026-07-13 runs). If all attempts fail, it fires a macOS notification AND opens a `Custodian run FAILED <date>` GitHub issue — a dead Monday must be loud, not discovered two weeks later.
- launchd runs a missed tick on next wake, so a sleeping Mac just defers the run rather than skipping it.
- The scheduled run only ever opens/updates the report issue. `apply` is always a separate, human-triggered invocation.

To change cadence, edit `StartCalendarInterval` in the plist and reload (`launchctl bootout` then `bootstrap`).

## Artifacts

Under `local/custodian/<date>/` (gitignored, same as `local/loops/`):

- **`custodian-log.jsonl`** — append-only run log, one JSON line per phase action, never rewritten. The machine record / audit trail.
- **`backup-<issue>-<seq>/`** — pre-apply snapshot of every file a Phase D `apply` touched, plus a `manifest.json` (path + original location + issue tag per file). Written by `apply` before its first edit; read by `undo` to revert. The reversibility backstop behind the human-checked apply.
- **`history-index.jsonl`** — lives at `local/custodian/` (NOT under `<date>/`; it's cross-run, not a per-date artifact). The append-only rollup that backs Phase C + `history`: one record per indexed `gates.jsonl` line, carrying the gate fields verbatim + `repo`/`branch`/`files`/`cite`. A **derived cache** of `gates.jsonl` across repos — regenerable via `history --rebuild`, gitignored like the rest of `local/`. Never a source of truth.

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
- **Every apply is previewable and reversible** — `--dry-run` before consent, snapshot + `undo` after. Consent approves a previewed change, not a described one.
- **No external claim actionable without a local-validation method** — no eval/shadow/replay ⇒ informational only (Phase E).
- **No memory deleted on contradiction alone** without the human seeing both sides quoted verbatim in the issue.
- **No memory retired on a dead citation alone** without the human seeing the dead reference AND the failed relocation search quoted verbatim — a not-found cite is `B-repoint` (moved) until the search proves it gone, never a bare retire.
- **No agent rewritten** except via `the-turncoat`, on an approved target.
- **Bounded** — cap proposals per run (default 20 across B+C+E); surface "N more not shown" rather than truncate silently.
- **Task/Skill availability honored** — unavailable ⇒ `ran: false`, never an invented outcome.
- **Explicit repo list** — never reaches beyond the named repos.
- **History index is a derived cache** — rebuilds from `gates.jsonl`, never a source of truth; queries write nothing.

## Integration with existing pieces

- `looper-learn` — per-run/per-orchestration lessons. Custodian reads what learn wrote; it does not duplicate learn's diagnosis.
- `the-turncoat` — the only actor that rewrites an agent/skill. Custodian routes to it; never does the rewrite itself.
- `deep-research` — Phase E's engine. Reused, not reinvented.
- **launchd** — the cron host (local, not cloud `/schedule`, which can't reach local state). Plist + wrapper under `~/Library/LaunchAgents/` + `scripts/`.
- `gh` CLI — opens the report issue, reads its checkboxes, comments the apply summary.
- `scripts/custodian-history.sh` — Phase C's engine + the `history` verb: `ingest` (incremental), `rebuild` (full re-derive), `query` (ranked cited lookup). Pure `jq` + `git`, no external store.

## What looper-custodian does NOT do

- Does NOT edit a memory or agent during the scheduled run — proposes only; writes happen ONLY in `apply` after a ticked box.
- Does NOT parse free-text approval — checkboxes only.
- Does NOT auto-apply Phase E research — it informs a human decision, and no finding is a checkbox without a local-validation method.
- Does NOT write in Phase D without first snapshotting, or offer an `apply` that can't be `--dry-run` previewed or `undo`-reverted.
- Does NOT GC an open or undeleted branch's artifacts, or touch any tracked file in Phase A.
- Does NOT reap a dir whose `gates.jsonl` lines are not yet in the history index — ingest (Phase C) strictly precedes GC (Phase A), and the ingest-guard enforces it per-dir.
- Does NOT reach beyond the explicit repo list.
- Does NOT record a result it didn't produce — unavailable tool ⇒ `ran: false`, no invented digest or verdict.
- Does NOT commit applied edits silently — they go through the normal review/commit path.
- Does NOT open an issue on a quiet week.
- Does NOT re-scan every `gates.jsonl` each run — Phase C ingests only new lines; a lost index rebuilds from source.
- Does NOT invent a touched-file list — git can't resolve a branch's files ⇒ `files` is `[]`, logged, never fabricated.
- Does NOT adopt an external tool's binary/store — `history` grafts `ctx`'s cited-retrieval pattern onto our own `gates.jsonl` (JSONL + `jq`/`grep`), no SQLite (`[[no-third-party-hosted-tool-reliance]]`).
