# Corrective waves: full rerun or one failing step?

Archival classification of every corrective wave this system has produced, against looper-custodian
issue #89 finding E-9. E-9 sources a runtime-branching-decomposition result (arxiv 2605.15425) in
which retrying only the failed subtask, rather than the whole downstream chain, measured 52–73% lower
retry cost than a fixed-plan baseline on a comparable coding-agent workload. The question here is
whether this system's own corrective history shows the waste that result implies.

Everything below is reconstructed from records that survive on disk as of 2026-09-14. Every figure
names the command that produces it. Nothing is recalled.

## Verdict

**NOT CONFIRMED.** The premise does not hold for this system, for a structural reason and a measured
one.

Structural: E-9's unit of retry is "the failed subtask". This system's correctives have no failed
subtask to retry. Every one of the 15 was triggered by a gate that runs _outside_ the wave — the
orchestrator's post-build crew pass, a specialist re-review, or the owner — after the wave's own
verify and review had already passed. There is no red step sitting in the journal waiting to be
re-run narrowly.

Measured: on the five correctives whose step boundaries survive as hook-written receipts, the share of
execution cost a narrower retry could have elided runs 3%–68%, median 23%. Two of the five do reach
E-9's 52–73% band on cost, and both are cases where the elided work is what made the fix correct —
one is a plan step that refused an unsatisfiable brief, the other is the failing measurement the fix
and its verification are both written against. In 5 of the 8 correctives with a surviving step
journal, the research or plan step produced a finding that changed what got built — twice by refuting
the corrective's own brief. A build-only retry in those five ships the wrong fix.

The narrow path E-9 proposes already exists here and is already used when it fits: `carn`'s
`16-corrective` is logged `agent: "orchestrator-direct-fix"`, shipped `dbfebca` (1 file, +3−1), and
never became a wave at all.

## The record does not exist where the brief expected it

`kind: "wave-retry"` has never been written. Across all 12 surviving `gates.jsonl` files in 5 repos:

```
find ~/Developer/Repos -path '*/local/loops/*' -name gates.jsonl \
  -exec jq -r '.kind' {} \; | sort | uniq -c
```

returns no `wave-retry`, and every `run-state.json` carries `counters.wave_retries: 0`. The
corrective record is instead spread across four other `kind` spellings — `corrective`,
`corrective-wave`, `correction`, `recrew` — and, more usefully, across wave journals named for the
corrective (`wave-2c.jsonl`, `wave-5-corrective.jsonl`, `wave-1c1.jsonl`).

## Census: 15 correctives, 8 with step-level evidence

| #   | Repo / run                        | Corrective          | Evidence tier      | Commit     | Diffstat     | Trigger                                              |
| --- | --------------------------------- | ------------------- | ------------------ | ---------- | ------------ | ---------------------------------------------------- |
| 1   | agents-of-shield / investigate-89 | `corrective-1`      | journal + receipts | `e859fc5`  | 4f +263−82   | 2 crew gating findings                               |
| 2   | carn / phase/1a                   | `2c`                | journal + receipts | `b92775c`  | 2f +6−13     | crew gating (missing shadowDatabaseUrl) + a dispute  |
| 3   | carn / phase/1b                   | `4c`                | journal + receipts | `56e2a69`  | 2f +54−6     | crew pass against the prior wave's code              |
| 4   | carn / phase/1b                   | `9c`                | journal + receipts | `d815b36`  | 4f +54−5     | crew finding                                         |
| 5   | carn / phase/1c                   | `1c1`               | journal (no rcpts) | `4bb633e`  | 1f +6−2      | crew finding, later refuted by the corrective itself |
| 6   | carn / phase/1e                   | `5-corrective`      | journal            | `8f4eb1a`  | 8f +356−58   | 3 refuting crew agents, 4 gating bugs                |
| 7   | carn / phase/1e                   | `15-corrective`     | journal            | `1a10ac2`  | 2f +136−38   | final crew pass, confirmed by the-auditor            |
| 8   | carn / phase/1f                   | `2` (corrective-G1) | journal            | `fac9b7f`  | 3f +72−20    | crew gating G1                                       |
| 9   | carn / phase/1e                   | `final-corrective`  | gates line only    | unresolved | —            | crew NO-GO                                           |
| 10  | carn / phase/1e                   | `16-corrective`     | gates line only    | `dbfebca`  | 1f +3−1      | undocumented exit code ranked as success             |
| 11  | linklater / main-v160-review      | `1c`                | gates lines        | `adcd4ab9` | 7f +290−34   | gate notes on PR #120                                |
| 12  | linklater / main-v160-review      | `1d`                | gates lines        | `57152188` | 4f +104−20   | gate notes on PR #120                                |
| 13  | linklater / main-v160-review      | `9c`                | gates lines        | `abf3daa1` | 20f +742−402 | 4 blockers on PR #122                                |
| 14  | linklater / main-v160-review      | `9d`                | gates lines        | `978cb36d` | 9f +199−38   | 2 Majors on PR #122                                  |
| 15  | rss-reader / theme-palette-logo   | `3` corrective      | gates line         | `2d6b987`  | 4f +8−3      | the-auditor WARNING (contrast)                       |

Rows 1–8 are the **step-reconstructable** sample: N = 8, short of the 10–15 asked for. The seven
without a step journal are not reaped — the mechanism postdates them. `git log -S "wave-N.jsonl"
--reverse` puts the journal's first appearance at `d74c7c9`, 2026-08-09; linklater's
`main-v160-review` ran 2026-08-07/08 and rss-reader's corrective shipped 2026-06-26. Their per-step
evidence never existed. Row 9's commit could not be matched to a message on any surviving branch;
`carn`'s phase branches were squash-merged and `phase/1e` is gone, so only the reachable objects
survive.

`carn` 1a's `recrew` line is excluded: it is a re-review of an already-shipped corrective diff, not a
corrective.

## Classification

**Full-wave rerun: 14 of 15 (93%).** All eight step-reconstructable correctives declared all seven
steps and journaled a completion line for every one. The six wave-level rows were dispatched to
`the-looper`, which runs the full protocol by construction (`gates.jsonl` logs `ran: "dispatched"`
then `ran: true` with a shipped commit) — structural inference, not per-step evidence, and labelled
as such.

**Narrow, no wave: 1 of 15.** Row 10, `orchestrator-direct-fix`.

So the first half of E-9's premise holds: correctives here are overwhelmingly full waves.

The second half — that they were full waves _for what was really one failing step_ — does not.

### Was the rerun inert?

The threshold was fixed before counting: a meaningful share means **≥30% of step-reconstructable
correctives that both ran all seven steps and had research/plan produce nothing that changed what got
built**. The second arm is the one that decides it. A full wave is only waste if the re-run steps
were inert.

Of the 8:

| #   | Did research/plan change the build?                                                                                                                                                                                                                                                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | **Yes.** Research re-derived the corpus on disk and found two of the brief's six stated constraints false — including the claim that no `gates.jsonl` survives (12 do).                                                                                                                                                        |
| 2   | **Yes.** Plan STOPPED: the brief's items 2–4 were not jointly satisfiable, because the file it ordered deleted also carried non-exclusion environmental facts. Resolved only by an owner amendment.                                                                                                                            |
| 3   | **Yes.** Research probed node v26.7.0 directly and established which spawn arguments throw synchronously (env value, args, cwd NUL) and which do not — the guard's scope is a guess without it.                                                                                                                                |
| 4   | Unknown. Journal is bare — completion lines with no notes.                                                                                                                                                                                                                                                                     |
| 5   | **Yes.** Research REFUTED the crew finding that caused the corrective: the claimed client-visible truncation did not materialise on this stack, every run delivering a byte-exact valid pack. The corrective shipped a 6-line fix for the half of the finding that was real, and recorded that the severity claim was refuted. |
| 6   | **Yes.** Research: "the brief's bug-1 repro does not reproduce bug 1" — the named fixture produced 76,053 wire bytes against a briefed 125,034, and exercised a different bug.                                                                                                                                                 |
| 7   | Unknown. Journal is bare. Its plan artifact does carry a measured before-state reproduction table, so research was not idle, but nothing records it contradicting the brief.                                                                                                                                                   |
| 8   | Unknown. Journal notes exist but none records a research- or plan-stage correction.                                                                                                                                                                                                                                            |

**5 of 8 confirmed non-inert (63%). 0 of 8 confirmed inert.** Three are unknown because their
journals carry no notes — those three cannot be scored either way, and are not counted as inert.

Against the declared ≥30% threshold the trigger condition is **not met**: the confirmed-inert count is
zero, and even scoring all three unknowns as inert reaches 37.5% on an assumption the record does not
support.

The same pattern shows in the wave-level rows, where the `gates.jsonl` verdicts carry a
`corrections_to_orchestrator` field: row 14's corrective reported that the sentence its brief told it
to fix "does NOT exist in the repo — grepped source, both commit messages, PR body."

## Shadow test

Run anyway on five cases despite the threshold not triggering, because the cost-share measurement is
what justifies the threshold call rather than merely restating it.

### Method, and what it approximates

The wave journal is appended by a shell redirect, so every append is itself a PostToolUse receipt
carrying a hook-written timestamp. Selecting receipts whose `.command` contains `"step"` recovers
machine-recorded step-completion boundaries, and counting receipts between two boundaries measures
shell executions in that step:

```
jq -r 'select(.command | test("\"step\"")) | .ts' local/loops/<branch>/receipts.jsonl
jq -r --arg a "$START" --arg b "$END" 'select(.ts > $a and .ts <= $b) | .ts' receipts.jsonl | wc -l
```

The in-journal `ts` / `at` fields are **not** usable and were not used. They are agent-authored and
demonstrably wrong: `carn/local/loops/phase/1b/wave-4c.jsonl` records its commit step at
`2026-08-25T05:15:00Z`, but the commit it names (`56e2a69`) has committer date `2026-08-26T01:13:39Z`
and the receipt for the append that wrote the line is `2026-08-26T01:14:22Z` — about 20 hours out.

Three approximations are named rather than hidden. Shell executions are a proxy for cost, not cost:
they omit model tokens, reads and edits, which no artifact records. Some steps share one append
(research and plan are frequently written in a single `printf`), so those segments cannot be split
and are reported merged. And a segment's boundary is when the step's line was _written_, which trails
when the step's work ended by however long the append took to compose.

### Measured

| Case                                                      | Segment                         | Executions | Share |
| --------------------------------------------------------- | ------------------------------- | ---------- | ----- |
| **carn 1a `2c`** (47 total, `b92775c`)                    | declare → research + plan(stop) | 32         | 68%   |
|                                                           | post-amendment build → commit   | 15         | 32%   |
| **carn 1b `4c`** (22 total, `56e2a69`)                    | declare → research              | 3          | 14%   |
|                                                           | research → build                | 7          | 32%   |
|                                                           | build → verify                  | 5          | 23%   |
|                                                           | verify → review                 | 2          | 9%    |
|                                                           | review → commit                 | 5          | 23%   |
| **carn 1b `9c`** (31 total, `d815b36`)                    | declare → research              | 1          | 3%    |
|                                                           | research → build (merged)       | 18         | 58%   |
|                                                           | build → verify                  | 2          | 6%    |
|                                                           | verify → commit                 | 10         | 32%   |
| **agents-of-shield `corrective-1`** (55 total, `e859fc5`) | declare → research + plan       | 6          | 11%   |
|                                                           | plan → build                    | 22         | 40%   |
|                                                           | build → verify                  | 8          | 15%   |
|                                                           | verify → review + learn         | 17         | 31%   |
|                                                           | learn → commit                  | 2          | 4%    |
| **carn 1e `15-corrective`** (57 total, `1a10ac2`)         | declare → research + plan       | 19         | 33%   |
|                                                           | plan → build                    | 19         | 33%   |
|                                                           | build → verify                  | 2          | 4%    |
|                                                           | verify → review                 | 7          | 12%   |
|                                                           | review → learn                  | 5          | 9%    |
|                                                           | learn → commit                  | 5          | 9%    |

The last row was held out: it was measured only after the first four were written up, as a check that
the method reproduces on a case it had not been tuned against. It does — seven boundaries, segments
summing to the total — and it disagrees with the other four, which is recorded below rather than
smoothed away.

Against the originating waves, measured the same way:

| Corrective                  | Its cost | Originating wave's cost   | Ratio |
| --------------------------- | -------- | ------------------------- | ----- |
| carn 1a `2c`                | 47       | 52 (wave 2)               | 0.90  |
| carn 1b `4c`                | 22       | 50 (wave 4)               | 0.44  |
| carn 1b `9c`                | 31       | 33 (wave 9)               | 0.94  |
| agents-of-shield corrective | 55       | 49 (the wave it corrects) | 1.12  |
| carn 1e `15-corrective`     | 57       | n/a                       | —     |

No ratio for the last one: it answers the run's final crew pass over the cumulative diff, so it has no
single originating wave to divide by.

### What a narrower retry would have saved, and cost

Take the narrowest credible per-step retry: rerun build → verify → commit, eliding research, plan,
review and learn.

| Case                        | Elidable share | What the elided steps actually produced                                                                                                                                                                                                     |
| --------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| carn 1a `2c`                | 68%            | The stop. Plan proved the brief's Amendment-4 instruction unsatisfiable; the build that eventually ran used option A from a _later_ owner amendment. A build-only retry executes the unsatisfiable instruction.                             |
| carn 1b `4c`                | 23%            | The synchronous-throw boundary the guard is written against, plus a review warning that the guard covers `spawn()` only.                                                                                                                    |
| carn 1b `9c`                | 3%             | Not separable — research and plan share one append with build; the measurable saving is the 1 execution before the research line.                                                                                                           |
| agents-of-shield corrective | 11%            | Two false premises in its own brief, one of which ("no `gates.jsonl` survives") the corrective's whole method depended on.                                                                                                                  |
| carn 1e `15-corrective`     | 54%            | The reproduction. Its plan artifact opens with a measured before-state axe table at 320 and 375px in both themes; the fix targets that measurement and verify re-checks it. A build-only retry has no failing measurement to build against. |

Where 11% and 54% are floors rather than exact: those two cases merge research with plan in one
append, and the 11% case also merges verify with review and learn, so the separable elidable segment
is smaller than the true one. The direction of that error favours the narrow-retry case, and it still
does not carry it.

Median elidable share across the five: **23%**. Range 3–68%.

E-9's source reports 52–73% lower retry cost. **Two of five cases reach that band on cost alone**, and
that is the strongest thing the data says for E-9. It is also where the argument stops, because cost
share is necessary and not sufficient: a step is only waste if eliding it changes nothing. In both
band-reaching cases it changes everything. `2c`'s elided work is the plan step that refused the
brief; `15-corrective`'s is the reproduction the fix and its verification are both written against.

The cost of being wrong is not symmetric with the saving. The elided steps in census rows 1, 2, 3, 5
and 6 each caught a brief that was factually wrong about the thing it ordered fixed. A build-only
retry saves a median fifth of the shell executions and, on this sample's base rate, ships a wrong fix
five times in eight.

## Secondary findings

Three things surfaced that are outside the question asked here but are cheaper to record now than to
rediscover.

1. **The `ts` / `at` fields inside wave journals are self-reported and unreliable.** Documented above
   with a ~20h discrepancy. `skills/loop-de-looper/references/state-schemas.md` does not define a
   timestamp field for either journal line shape, so these are agent inventions; anything that
   consumes them as a clock is reading fiction. The receipts log is the real clock.
2. **`gates.jsonl` `kind` was a free-form field for most of this history.** The enum is now closed at
   nine tokens and enforced, but the surviving corpus carries `corrective`, `corrective-wave`,
   `correction`, `crew-pass`, `recrew`, `crew-reverify`, `wave`, `verification`, `finding`, `pr`,
   `merge`, `dependabot`, `decision`, `nonbeliever`, and 42 lines with no `kind` at all. Any
   cross-run query selecting on one spelling under-counts. This is the same failure mode
   `skills/loop-de-looper/references/state-schemas.md` already documents for `crew`, reaching further
   than that note says.
3. **`reason: "corrective"` is written in practice but is not in the schema.** Two journals
   (`carn/phase/1b/wave-9c.jsonl`, and this repo's own run record) carry `_declared` with
   `reason: "corrective"`, while `skills/loop-de-looper/references/state-schemas.md` declares the
   field as `"initial" | "retry" | "resume-after-torn"`. A reader following the schema treats an
   unrecognised reason as undefined behaviour. Pre-existing; not caused by this analysis.

## Reproducing

```
# the corpus
find ~/Developer/Repos -path '*/local/loops/*' -name 'gates.jsonl'
find ~/Developer/Repos -path '*/local/loops/*' -name 'wave-*.jsonl'

# kind census
find ~/Developer/Repos -path '*/local/loops/*' -name gates.jsonl \
  -exec jq -r '.kind' {} \; | sort | uniq -c | sort -rn

# corrective counters
find ~/Developer/Repos -path '*/local/loops/*' -name run-state.json \
  -exec jq -c '{f:input_filename, c:.counters.corrective_waves, r:.counters.wave_retries}' {} \;

# step boundaries for one run
jq -r 'select(.command | test("\"step\"")) | .ts + " " + (.command | gsub("\\s+";" ") | .[0:120])' \
  <repo>/local/loops/<branch>/receipts.jsonl

# executions in a segment
jq -r --arg a "$START" --arg b "$END" 'select(.ts > $a and .ts <= $b) | .ts' \
  <repo>/local/loops/<branch>/receipts.jsonl | wc -l
```
