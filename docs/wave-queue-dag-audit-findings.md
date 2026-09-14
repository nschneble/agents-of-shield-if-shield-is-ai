# Wave-queue DAG invariant — run against real history

Issue #89 finding E-8 proposed checking this system's goal-decomposition output against the
dependency-ordering rule from SPOQ ([arxiv 2606.03115](https://arxiv.org/abs/2606.03115)), whose
abstract describes "wave-based topological dispatch that computes parallel execution waves from task
dependency graphs". `scripts/wave-queue-dag-audit.sh` is that check. This is its output against every
wave-queue snapshot on disk on 2026-09-14, and the verdict.

The corpus is discovered, never listed: `./scripts/wave-queue-dag-audit.sh --census ~/Developer/Repos`
walks for `*/local/loops/*/run-state.json` and audits whatever it finds. A first pass at this audit named
four repos by hand and missed a fifth entirely — `carn`, which turned out to hold 9 of the 16 snapshots and
every violation below. A hand-written repo list is a census that goes stale the day a new repo runs the
loop, which is why the script does the walking now.

## Verdict

**Both halves are checkable on real data, and the assignment half is violated — five times, all in `carn`.**

The invariant has two halves. One says every dependency edge orders its source wave strictly before its
target. The other says every task gets a wave number, with no gaps and nothing left unassigned.

What is audited is the PERSISTED queue — `run-state.json`'s `queue[]` — not `looper-scope`'s own report,
which is prose and is not kept.

- **Assignment half: 5 violations over 37 settled arms across 16 snapshots, exit 1.** Four snapshots
  disagree with the invariant, and each disagreement is real:
  - `carn/phase/1b` — the contract declares `A1` and `A2`; all eight waves close `A1`, so `A2` is claimed
    by nothing.
  - `carn/phase/1c` — same shape, two waves, `A2` unclaimed.
  - `carn/phase/1d` — two violations. Wave numbers run `1..19, 21..24`: **wave 20 is missing**. And two
    entries close `round-2-item-1`, an id the contract never declares.
  - `carn/phase/1e` — one entry carries `wave: "9b"`, a string where the shape wants a number.
- **Ordering half: EVALUABLE, on the 2 of 16 snapshots that persist an edge field — and it passes where
  the field is well formed.** `carn/phase/1a` carries `depends_on` on all five entries (`[]`, `[1]`, `[1]`,
  `[1,2]`, `[2,3,4]`); the arm evaluates that graph and finds no edge pointing at its own wave or later.
  `carn/phase/1c` carries the same key as prose (`"none"`, `"wave 1"`), which is a schema the arm cannot
  read, so it declines there rather than guessing.

The other fourteen snapshots carry no edge field at all, and on those the arm still reports NOT EVALUABLE:
`looper-scope` emits `depends on: <wave M | none>` as a column of its section-3 prose report
(`skills/looper-scope/SKILL.md`), the documented `queue[]` shape is `{wave, candidate, status, commit, closes}`
(`skills/loop-de-looper/references/state-schemas.md`), and nothing in the writer persists the edges. So the
field is real but incidental — two runs wrote it because their orchestrator chose to, not because the
schema asks for it, and one of those two wrote prose.

Nor is scope's report archived: twelve `gates.jsonl` files survive on disk (seven of them in `carn`), and
no dependency edge appears in any of them — the two `depends` hits inside them are English in a finding's
text. `local/custodian/history-index.jsonl` keeps `wave` but no edges.

**The git proxy for the ordering half passes on every run that can answer it.** A correct topological order
shows up downstream as waves landing in wave order, which is checkable from git ancestry. Six snapshots have
at least two shipped waves with resolvable shas — `carn/phase/{1a,1b,1c,1d,1e}` and
`rss-reader/theme-palette-logo` — and all six pass. It is a consequence of the invariant, not the invariant,
and the audit labels it as its own arm rather than folding it into the ordering verdict.

**Schema drift is not a violation.** Eight of the sixteen snapshots predate the documented queue shape, in
four distinct eras — `carn/fix/3-pin-ssh-channel-close-kill` has no `queue` key at all and keys its records
under `waves`; `carn/phase-1d` keys entries `id: "wave-1"`; `linklater/main-v160-review` keys entries `n`
with values like `"8a"` and `"1c"`; and `carn/phase/{1f,1f-leftovers}` plus the three `tuffgal` runs carry
`queue: []` with their wave records in top-level `wave_N` keys and a `goal_contract` that is a bare array of
integer-id asks. The audit declines on each rather than reporting the gap as lost position — 45 arms
declined in all. Removing that guard makes the `linklater` snapshot report 17 false violations, which is
what the suite's legacy arms exist to catch.

**A prose-era edge value declines too, and that guard is load-tested.** Before it existed, `carn/phase/1c`'s
string `depends_on` crashed the audit — `jq: error … Cannot iterate over string ("none")`, exit 5, a code
the script's own 0/1/2 contract does not define — and in a batch run every snapshot after it was dropped
with no summary line at all. That is how the first pass at this audit reported a clean corpus: it never read
past the crash, and never ran against `carn` to begin with.

## Output — all sixteen snapshots

```
wave-queue-dag-audit — 16 snapshot(s)
  DEPENDENCY-EDGE ORDERING IS CHECKABLE ONLY WHERE PERSISTED, see each report

  /Users/nickschneble/Developer/Repos/agents-of-shield-if-shield-is-ai/local/loops/investigate-custodian-89-research-findings/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    ok     every ask is claimed by a wave     0
    ok     every closes id is a declared ask  0
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/fix/3-pin-ssh-channel-close-kill/run-state.json
    SKIP   wave numbering (3 arms)            no queue[] array in this snapshot
    SKIP   ask assignment (2 arms)            no queue entry carries `closes` — asks are not mapped to waves here
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/phase-1d/run-state.json
    SKIP   wave numbering (3 arms)            1 entry(s), none carrying a numeric `wave` — pre-queue-shape snapshot
    SKIP   ask assignment (2 arms)            no queue entry carries `closes` — asks are not mapped to waves here
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1a/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    SKIP   ask assignment (2 arms)            no queue entry carries `closes` — asks are not mapped to waves here
    ok     dependency edges ordered           0
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1b/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    VIOLATION every ask is claimed by a wave  got 1 · want 0
    ok     every closes id is a declared ask  0
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1c/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    VIOLATION every ask is claimed by a wave  got 1 · want 0
    ok     every closes id is a declared ask  0
    SKIP   dependency edges ordered           2 entry(s) carry a non-array edge value — a shape this arm cannot read
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1d/run-state.json
    ok     every entry has a wave number      0
    ok     no wave number used twice          0
    VIOLATION waves are 1..N with no gaps     got 1 · want 0
    ok     every ask is claimed by a wave     0
    VIOLATION every closes id is a declared ask got 1 · want 0
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1e/run-state.json
    VIOLATION every entry has a wave number   got 1 · want 0
    ok     no wave number used twice          0
    ok     waves are 1..N with no gaps        0
    ok     every ask is claimed by a wave     0
    ok     every closes id is a declared ask  0
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1f-leftovers/run-state.json
    SKIP   wave numbering (3 arms)            queue[] is empty — a snapshot keeping its wave records elsewhere
    SKIP   ask assignment (2 arms)            no queue entry carries `closes` — asks are not mapped to waves here
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1f/run-state.json
    SKIP   wave numbering (3 arms)            queue[] is empty — a snapshot keeping its wave records elsewhere
    SKIP   ask assignment (2 arms)            no queue entry carries `closes` — asks are not mapped to waves here
    n/a    dependency edges ordered           NOT EVALUABLE — no entry carries depends_on/dependsOn/depends/blocked_by; scope prints `depends on:` as prose only
    n/a    execution realizes wave order      not requested — pass --git REPO

  /Users/nickschneble/Developer/Repos/linklater/local/loops/main-v160-review/run-state.json
    SKIP   wave numbering (3 arms)            17 entry(s), none carrying a numeric `wave` — pre-queue-shape snapshot
    SKIP   ask assignment (2 arms)            snapshot declares no goal-contract asks
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

QUEUE INVARIANT: 5 of 37 arm(s) violated across 16 snapshot(s)
exit=1
```

Exit 1 is the honest code here: five arms disagreed. Forty-five further arms could not be settled, because
eight snapshots predate the shape they would read — but a violation outranks incompleteness, so the summary
line reports the disagreement rather than the gap.

## Output — the git execution-order proxy

The proxy arm needs a repo, so it runs one repo at a time
(`--census ~/Developer/Repos/<repo> --git ~/Developer/Repos/<repo>`). Six snapshots can answer it and all
six pass:

```
  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1a/run-state.json
    ok     execution realizes wave order      0
  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1b/run-state.json
    ok     execution realizes wave order      0
  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1c/run-state.json
    ok     execution realizes wave order      0
  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1d/run-state.json
    ok     execution realizes wave order      0
  /Users/nickschneble/Developer/Repos/carn/local/loops/phase/1e/run-state.json
    ok     execution realizes wave order      0
  /Users/nickschneble/Developer/Repos/rss-reader/local/loops/theme-palette-logo/run-state.json
    ok     execution realizes wave order      0
```

The rest decline for want of shipped waves: `linklater/main` and this repo's own run have one resolvable
sha each and the arm needs two; the remaining eight have none.

## What would make the ordering half checkable everywhere

Persisting `depends_on: [<wave>, …]` on each `queue[]` entry when the orchestrator writes the queue —
as an array of wave numbers, which is what `carn/phase/1a` already does and what the arm reads. Two runs
have written the field unprompted and one of those two wrote prose into it, so the gap is not that the
idea is untried; it is that the schema does not ask, and an unasked-for field arrives in whatever shape
the writer felt like. Whether to ask for it is a scope decision, not one this audit makes.
