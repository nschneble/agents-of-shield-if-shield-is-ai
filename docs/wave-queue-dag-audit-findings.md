# Wave-queue DAG invariant — run against real history

Issue #89 finding E-8 proposed checking this system's goal-decomposition output against the
dependency-ordering rule from SPOQ ([arxiv 2606.03115](https://arxiv.org/abs/2606.03115)), whose
abstract describes "wave-based topological dispatch that computes parallel execution waves from task
dependency graphs". `scripts/wave-queue-dag-audit.sh` is that check. This is its output against every
wave-queue snapshot on disk on 2026-09-14, and the verdict.

## Verdict

**The checkable half holds; the headline half is not checkable, and that is itself the finding.**

The invariant has two halves. One says every dependency edge orders its source wave strictly before its
target. The other says every task gets a wave number, with no gaps and nothing left unassigned.

What is audited is the PERSISTED queue — `run-state.json`'s `queue[]` — not `looper-scope`'s own report,
which is prose and is not kept. That distinction is the whole reason the two halves land differently.

- **Assignment half: PASS, 13 arms over 3 conforming snapshots, 0 violations.** Every wave numbered,
  no number reused, no gap in `1..N`, every goal-contract ask claimed by some wave, and no `closes` id
  naming an ask the contract never declared.
- **Ordering half: NOT EVALUABLE against any real data.** `looper-scope` emits `depends on: <wave M | none>`
  as a column of its section-3 prose report (`skills/looper-scope/SKILL.md`), and nothing persists it.
  `run-state.json`'s `queue[]` is `{wave, candidate, status, commit, closes}`
  (`skills/loop-de-looper/references/state-schemas.md`) — there is no dependency field, and a `grep` for
  one across every `local/` in this repo, `linklater`, `tuffgal` and `rss-reader` returns nothing. The
  scope report itself is not archived either: no `gates.jsonl` survives on disk (the custodian's Phase A
  reaps them) and `local/custodian/history-index.jsonl` keeps `wave` but no edges.

So the system's dependency graph exists only in the prose of a report that is read once and discarded.
No dependency graph was fabricated to validate against; the audit probes for the field, finds none, and
says so on every snapshot.

**One real proxy for the ordering half does pass.** A correct topological order shows up downstream as
waves landing in wave order, and that is checkable from git. `rss-reader`'s three shipped waves each have
a resolvable sha, and each is an ancestor of the next — so on the one historical run with enough shipped
waves to test, execution did realize the declared wave order. It is a consequence of the invariant, not
the invariant, and the audit labels it as its own arm rather than folding it into the ordering verdict.

**The other finding is schema drift, not a violation.** Four of the seven snapshots predate the documented
queue shape, in three distinct eras — `linklater/main-v160-review` keys entries `n` with values like `"8a"`
and `"1c"`, and the three `tuffgal` runs carry `queue: []` with their wave records in top-level `wave_N`
keys and a `goal_contract` that is a bare array of integer-id asks. The audit declines on each rather than
reporting the gap as lost position. Removing that guard makes the `linklater` snapshot report 17 false
violations, which is what the suite's legacy arms exist to catch.

## Output — all seven snapshots

```
wave-queue-dag-audit — 7 snapshot(s)
  DEPENDENCY-EDGE ORDERING IS NOT CHECKABLE ON THIS SCHEMA, see each report

  local/loops/investigate-custodian-89-research-findings/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    ok     every ask is claimed by a wave     0
    ok     every closes id is a declared ask  0
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/linklater/local/loops/main/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    ok     every ask is claimed by a wave     0
    ok     every closes id is a declared ask  0
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/linklater/local/loops/main-v160-review/run-state.json
    SKIP   wave numbering (3 arms)            17 entry(s), none carrying a numeric `wave` — pre-queue-shape snapshot
    SKIP   ask assignment (2 arms)            snapshot declares no goal-contract asks
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/rss-reader/local/loops/theme-palette-logo/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    SKIP   ask assignment (2 arms)            snapshot declares no goal-contract asks
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/tuffgal/local/loops/feat/50-diff-history/run-state.json
    SKIP   wave numbering (3 arms)            queue[] is empty — a snapshot keeping its wave records elsewhere
    SKIP   ask assignment (2 arms)            no queue entry carries `closes` — asks are not mapped to waves here
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/tuffgal/local/loops/feat/50-ssim-variant/run-state.json
    SKIP   wave numbering (3 arms)            queue[] is empty — a snapshot keeping its wave records elsewhere
    SKIP   ask assignment (2 arms)            no queue entry carries `closes` — asks are not mapped to waves here
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/tuffgal/local/loops/test/50-pixelthreshold-status-flip/run-state.json
    SKIP   wave numbering (3 arms)            queue[] is empty — a snapshot keeping its wave records elsewhere
    SKIP   ask assignment (2 arms)            no queue entry carries `closes` — asks are not mapped to waves here
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

QUEUE INVARIANT: 0 of 13 arm(s) violated — INCOMPLETE, 22 arm(s) declined
exit=2
```

Exit 2 is the honest code here: nothing disagreed, and 22 arms could not be settled because four
snapshots predate the shape they would read.

## Output — the git execution-order proxy

```
  /Users/nickschneble/Developer/Repos/rss-reader/local/loops/theme-palette-logo/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    SKIP   ask assignment (2 arms)            snapshot declares no goal-contract asks
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    ok     execution realizes wave order      0
```

`linklater/main` declines the same arm with `1 shipped wave(s) with a resolvable sha — needs 2`, and this
repo's own run is `pending` on all five waves. `rss-reader` is the only snapshot on disk that can answer it.

## What would make the ordering half checkable

Persisting `depends_on: [<wave>, …]` on each `queue[]` entry when the orchestrator writes the queue. The
audit's arm 6 already evaluates that field the moment any snapshot carries it — strict source-before-target,
which also rejects a self-edge — so the gap is in the writer, not the check. Whether it is worth adding is
a separate scope decision, not one this audit makes.
