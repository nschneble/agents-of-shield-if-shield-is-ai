# Looper Custodian — design rationale + decision log

Status: **built.** Operational spec (phases, artifacts, scheduling, the full
"what it does") lives in `skills/looper-custodian/SKILL.md` — that is the source
of truth. This doc holds only what the skill doesn't: *why* it exists, *why* the
choices are what they are, and the *decision record*. Don't duplicate mechanics
here — if a phase's behavior changes, it changes in `SKILL.md`.

## Why it exists

The looper system learns and tidies *per run*: `looper-learn` writes lessons at
the end of each wave and orchestration; `the-turncoat` streamlines an agent or
skill when asked. Nothing runs *across* runs and *across* repos on a cadence.
Over weeks that leaves three rots no per-run step can see:

- **Memory rot** — `MEMORY.md` + memory files accumulate duplicates and
  contradictions; a later memory supersedes an earlier one but the earlier is
  never removed, so recall surfaces stale guidance.
- **Artifact litter** — `local/loops/<branch>/` keeps `run-state.json` +
  `gates.jsonl` for branches long since merged and deleted.
- **Lost cross-run signal** — the same crew finding recurs across many runs and
  repos, but no one looks at the aggregate, so the systemic fix never surfaces.

Custodian is the scheduled, cross-run, cross-repo maintenance layer. It does not
replace `looper-learn` or `the-turncoat` — it batches and aggregates what they
do, plus the memory-contradiction GC neither does today.

## Governing principle: custodian PROPOSES, human DISPOSES

The spine of the design, and the reason it's split into auto vs gated phases.

An unattended job that auto-edits memories or agents is exactly the "merging
outpaces comprehension" failure the loop-engineering sources warn about.
Auto-deleting a memory because a later one "contradicts" it can silently destroy
a deliberate exception. So:

- **Read-only / regenerable work runs automatically** — artifact GC, memory
  audit report, cross-repo digest, research digest.
- **Anything that writes a memory or an agent is propose-only** — it lands as a
  checkbox in the report issue and applies ONLY through `apply` after a human
  ticks the box.

This is the same discipline the loop already holds (does NOT auto-revert
commits, does NOT flip draft→ready). Carried rails follow from it: no memory
deleted on contradiction alone without both sides quoted verbatim; no agent
rewritten except via `the-turncoat` on an approved target; bounded proposals per
run; unavailable tool ⇒ `ran: false`, never an invented outcome.

## Why these mechanisms (the non-obvious choices)

- **Report = GitHub issue, not a local file.** The run is an unattended cron and
  `local/` is gitignored — a local report would be both invisible (nobody
  watching) and unreachable by a later `apply`. The issue is notification +
  durable report + checkbox approval surface + stable ref for `apply`, all at
  once. Quiet week → no issue → no noise.
- **Local launchd, not cloud `/schedule`.** Phases A/B/C read local-only state
  (`local/loops/` scratch, the `~/.claude` memory dir, `gates.jsonl` across
  local repos) an isolated cloud session can't reach. The host has to be the dev
  machine. (This contradiction — local artifacts under a "cloud cron" plan —
  was caught only when the host got concrete; see decision 6.)
- **External research promoted to a core phase, not a stretch opt-in.** It's
  read-only and auto-applies nothing, so it carries the same risk as the
  cross-repo digest — no reason to gate it behind a separate opt-in.

## Decision log

Greenlit 2026-06-27 (open questions resolved before build):

1. **Repo list** — explicit, not auto-discover. `linklater`, `tuffgal`,
   `tuffgal-action`, `agents-of-shield-if-shield-is-ai`, `rss-reader`. An
   unattended job scanning every repo it can reach is the unbounded reach the
   propose/dispose discipline exists to prevent.
2. **Phase A aggressiveness** — GC immediately on merged, no grace window. The
   merge already comprehended the work and `local/` is regenerable scratch.
3. **Phase D trigger** — checkbox approval in the report issue, then
   `/looper-custodian apply #<issue>`. Explicit + idempotent, no fuzzy parsing.
4. **Cadence** — weekly, all phases on one tick.
5. **External research** — promoted from stretch opt-in to **Phase E**,
   integrated from the start (rationale above).
6. **Cron host** — local launchd, not cloud `/schedule` (rationale above).
   Decided during the build when the cloud host's inability to reach local state
   surfaced.

Refined 2026-06-27 by the first supervised run (commit `2d8d767`):

7. **Phase A: merged overrides a lingering local branch.** Original rule was
   ambiguous on whether a leftover *local* branch blocks reaping. It doesn't — a
   merged local branch is cruft, not a resumable run. "Merged" is tested by
   ancestry OR a merged PR (squash-safe); only an open PR or genuinely-unmerged
   work blocks GC. Backstopped by enabling `delete_branch_on_merge` on all five
   repos so the remote signal stays clean.
8. **Phase B: deterministic, coverage-counted enumeration.** The audit must not
   depend on a subagent's bash discovery (it silently under-audited 26/63 on the
   first pass). The orchestrator owns enumeration; delegated reads get explicit
   paths + Read-only; `files_audited < files_total` ⇒ a `partial` verdict, never
   a clean bill on uncovered files.
