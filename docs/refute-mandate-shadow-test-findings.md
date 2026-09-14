# Does a refute-only reviewer mandate find more?

Verdict on issue #89's finding E-4, which proposes giving a reviewer agent a
pure "kill" mandate instead of an improve-or-evaluate one, after
[Refute-or-Promote](https://arxiv.org/abs/2604.19049) (Agarwal). The paper is
real and its motivating case is as cited: ten reviewers unanimously endorsed a
Bleichenbacher padding oracle that did not exist, and only an empirical test
removed it.

**NOT CONFIRMED.** A refute-only mandate did not systematically surface more
than the original reviews did. Under that mandate the shadow reviewer met the
same seventeen-token baseline defect twice, in two different commits: it found
it once, by extracting a tree and running a script, and cleared it the other
time, by running the same script against the wrong tree. Posture was identical
in both. What differed was whether anything was executed against the artifact
actually under review, and that is the axis this exercise ends on.

That verdict is better supported after a correction than before it, and the
correction cost this document its headline. The first revision compared the
shadow's output against the original crew verdicts, and the two were not
looking at the same code; re-deriving the figure at every commit also showed
that the crew line it called confidently wrong was correct when it was
written. Both are set out in
[the comparison-target correction](#correction-the-shadow-and-the-crew-reviewed-different-commits).
The mechanism that survives is not reviewer posture at all — it is a
cleanup-batch wave that no crew reviews, checked by a guard that only looks one
way.

## The limits this test could not remove

**The shadow reviewer is not a separate agent.** `the-looper` runs as a
subagent, and the harness denies a subagent nesting a further dispatch, so the
shadow could not be given its own context. It is the same model in the same
context under an inline prompt override. That is a weaker instrument than a
fresh dispatch and it cuts in the direction of over-reporting agreement. The
crew dispatches recorded in this run's own `gates.jsonl` are the
orchestrator's, made from outside the wave; none was available from inside it.

**The mitigation is partial, and only covers half the outcomes.** Every
positive shadow finding below rests on a command whose output is quoted rather
than on the reviewer's judgment about itself. But three of the four case
outcomes are ABSENCES — a match, a miss, and a list of refutations attempted
and failed — and an absence has no command output to quote. Those rest on the
same judgment the disclosure above says to discount.

**Case 1 contaminated case 4, and was run first.** Case 4's independent
corroboration for the baseline defect is a later commit recording
"orchestrator-run always 22483 to 22466". That commit is `2a9f898` — case 1's
own review target, read at the start of this exercise. The corroboration is
real and reproducible by anyone, but it was not independent of this reviewer.

## Part 1 — the prompt audit

Seven reviewer definitions, counted rather than characterized:

```
grep -nioE "constructive|not cruel|commendation|earned praise|positive signal|LGTM|reassurance|consensus|converge|debate|refute|prosecut|kill.mandate|adversarial|subtractor|reject on sight|challeng" agents/<agent>.md
```

The last alternative is truncated to `challeng` deliberately. The word in the
source is "challenging", and `challenge` does not match it.

| agent           | refutation vocabulary                                             | softening vocabulary                                       |
| --------------- | ----------------------------------------------------------------- | ---------------------------------------------------------- |
| the-diamantaire | refute x6, prosecut x5, kill-mandate x2, adversarial, challenging | positive signal, earned praise                             |
| the-chronicler  | subtractor                                                        | none                                                       |
| the-ghostwriter | reject on sight                                                   | none                                                       |
| the-chemist     | none                                                              | reassurance                                                |
| the-stickler    | none                                                              | constructive, not cruel, commendation, earned praise, LGTM |
| the-auditor     | none                                                              | none                                                       |
| the-improver    | none                                                              | none                                                       |

Three things the count does not carry, all of which matter more than it does.

**There is no consensus-seeking language in the roster.** Nothing in any of
the seven asks an agent to agree with another agent, soften toward a shared
position, or find common ground. The word "consensus" appears exactly once, in
`the-diamantaire`, in a clause forbidding it: "Default to challenging; do not
soften to consensus or converge by debate." E-4's premise, read as a claim
about this system's prompts, does not hold.

**The debate mechanism the paper targets does not exist here.** The crew is
dispatched in parallel, one message per agent, with no cross-agent aggregation
(`skills/loop-de-looper/SKILL.md` `### Step 3`). Reviewers cannot converge by
debate because they never see each other. There IS a second round — a
corrective's re-crew, which the same section caps as an interim pass — but it
is another parallel dispatch over revised work, not a rebuttal exchange, so
nothing in it lets one reviewer soften toward another. This matches the
existing position that the crew is domain-partitioned rather than an ensemble.

**One agent is already the treatment.** `the-diamantaire` carries an explicit
kill mandate and emits a structured `refute` / `batch` / `promote` outcome.
Adopting E-4 for it would change nothing. That is why the shadow-run below
targets a different agent, and it is also why the result lands where it does.

What the softening vocabulary in `the-stickler` actually governs is worth
separating from posture. "Precise, constructive, not cruel" shapes how a
violation is written up; "no bend rule" governs whether it is raised at all.
The prompt is strict and gentle at the same time, which is not the same thing
as consensus-seeking.

## Part 2 — the shadow-run

**Agent: `the-stickler`**, chosen as the maximal contrast. It holds the
roster's entire softening vocabulary and none of its refutation vocabulary,
so if posture is the variable, this is where a change shows up.

**Corpus: the five unanimous, all-clean, zero-execution crew groups** recorded
in `docs/loop-unanimity-audit-findings.md`. Those are the system's own
worst-case reviews: every reviewer clean, not one claiming execution behind
it. `the-stickler` ran in all five. If a refute-only mandate surfaces nothing
here, it surfaces nothing anywhere.

Cases were chosen on metadata alone — repo, wave, agent, `blockers`, `ran` —
before any verdict text was read.

### The blind protocol

The failure to avoid is reading the original verdict and then "finding" what
it found. So per case, in this order: read the diff and the repo's conventions
**as of that commit**; run the refute-only review and write it to a file; only
then read the original. Every shadow file was on disk before its original was
opened, and the receipts log carries the ordering.

### The inline override, verbatim

> You are the-stickler, dispatched under a REPLACEMENT mandate that overrides
> your definition's posture for this dispatch only.
>
> Your mandate is to REFUTE. You are not reviewing this diff to evaluate it,
> improve it, or confirm it. You are trying to kill it. Assume it is wrong and
> your job is to produce the evidence. "Precise, constructive, not cruel" does
> not apply here; neither does LGTM. There is no commendations section and no
> earned praise. A decision that survives gets silence, not acknowledgment.
>
> Unchanged: the checklist you enforce, the requirement to quote a violated
> rule verbatim, the requirement to cite `path:Lstart-Lend`, the diff-scope
> rule, and the severity floor — a convention breach is `batch`, never
> `refute`, however confident you are.
>
> The burden of proof is unchanged and it is on you. A finding counts only if
> you can defend it with evidence you actually produced: a command you ran, a
> file you read, a rule you quoted. A suspicion you could not verify is not a
> finding, and must be reported as a refutation you attempted and failed to
> land. Report those attempts explicitly — an attempt that found nothing is
> data.
>
> Emit: FINDINGS (each cited, each classed `refute` or `batch`), ATTEMPTED AND
> FAILED, VERDICT.

The "attempted and failed" section is the one structural addition. It is what
makes a null legible, and it turned out to matter more than the posture did.

### The four cases

| #   | wave                                     | shadow read | original verdict                    | shadow verdict         | net new |
| --- | ---------------------------------------- | ----------- | ----------------------------------- | ---------------------- | ------- |
| 1   | `issue-74-real-entry-point-verify` w1    | `2a9f898`   | LGTM, 0 gating 0 batched            | `promote`, 0 findings  | 0 †     |
| 2   | `58-1-dedup-readjsonbaseline` w1         | `0b6e514`   | LGTM, 1 batched comment-length note | `batch`, 3 findings    | 2 †     |
| 3   | `collapse-run-scheduled-story-params` w1 | `608af99`   | LGTM, 2 batched convention nits     | `promote`, 0 findings  | -2 †    |
| 4   | `issue-72-verify-brief-claims` w1        | `adb9ef3`   | CLEAN, 1 cosmetic styling nit       | `batch`, 1 real defect | 1 †     |

† Every commit in the "shadow read" column is a squash-merge, and the wave in
the first column was reviewed against the first commit inside it. The net-new
column therefore compares two different trees in all four rows, and case 1's
`0` is a miss rather than a match. See the correction section below; read the
table through it, not around it.

Case 4 was held out: it was run only after cases 1-3 were written and the
verdict drafted, to test whether the verdict generalized to a case that had
not shaped it. It was also a substitution. The intended fourth,
`linklater/feature-dyslexic-font-accessibility` w4, could not be reconstructed
from what survives on that branch, so the fifth group took its place,
identified by an exact file-set match against the gate line's `files` array.

The mtime was originally offered as a second pin and does not work as one. All
nine index records for that branch carry the same `mtime`, `1787890776` — it
is the gate log file's mtime, written once when the log was last appended, not
a per-wave timestamp. It pins the branch, which the `files` array already did.

## Correction: the shadow and the crew reviewed different commits

The four commits in the table above are squash-merges on `main`. Each folds in
two or three branch commits, and the crew whose verdicts they are compared
against reviewed only the first of them:

| Case | Shadow read | Squashed commits | Crew reviewed           |
| ---- | ----------- | ---------------- | ----------------------- |
| 1    | `2a9f898`   | 3                | `5079208`               |
| 2    | `0b6e514`   | 2                | `3430317`               |
| 3    | `608af99`   | 2                | not recoverable on disk |
| 4    | `adb9ef3`   | 2                | `6b989ad`               |

So the shadow verdicts and the original verdicts are not a like-for-like
comparison in any of the four cases, and the net-new column is measured
against a tree the original reviewers never saw. The second commit in each
squash is a cleanup-batch wave, and a cleanup wave gets no crew pass.

**Case 1 is where this changes the result rather than merely qualifying it.**
The shadow cleared the commit and cited, as its strongest positive evidence,
that all seven `spec-load` entries read exactly `0 under baseline`. That is
true of `2a9f898`. It is not true of `5079208`, where `orchestrator-run` read
`22483` against a live `22466` — the same seventeen-token inflation case 4 is
about. The branch's own wave-2 cleanup, `bc13ba5`, trued it up along with two
other figures, in a commit whose message says so outright: "Two were stale
before this branch existed: orchestrator-run always 22483 to 22466". The
shadow did not agree with the original crew about a clean baseline. It read a
tree from which the defect had already been removed, and certified it.

**Case 4 is where it changes the result completely, and not in the direction
the first revision expected.** Re-deriving the figure at every commit on that
branch, by summing the four `always` files the manifest names at `bytes/4`:

| commit                                  | live      | recorded  | drift |
| --------------------------------------- | --------- | --------- | ----- |
| `5f3cae0` parent                        | 22148     | 22148     | 0     |
| **`6b989ad` wave 1, the crew's target** | **22483** | **22483** | **0** |
| `b423f50` wave 2, cleanup, no crew      | **22466** | 22483     | −17   |
| `adb9ef3` squash, what the shadow read  | 22466     | 22483     | −17   |
| `5079208` next branch's wave 1          | 22466     | 22483     | −17   |
| `bc13ba5` next branch's cleanup         | 22466     | 22466     | 0     |

**The commit the crew reviewed was exactly right.** `6b989ad` moved
`orchestrator-run` from 22148 to 22483 and 22483 was the live reading. Its
recorded `+335` price was also the true one, 22483 − 22148. So
`the-diamantaire`'s "Baseline arithmetic ... verified correct" was a correct
statement about the diff in front of it, and the illustrative example the
first revision of this document was built on — the maximally adversarial
reviewer confidently certifying the one thing that was wrong — did not happen.
That claim is withdrawn.

**What actually introduced the defect was the cleanup wave.** `b423f50` fixed
seven batched findings, two of which trimmed prose out of
`skills/loop-de-looper/SKILL.md` and
`skills/loop-de-looper/references/protocol-detail.md`. That
dropped the live figure to 22466 and falsified both the baseline and the
`+335` note in the same stroke, and it edited
`scripts/spec-load-baseline.tsv` in that very commit without moving either. No
crew reviewed it. The only check that ran over it was its own, and its gate
line records "spec-load-baseline grew 0" — true, and blind, because
`spec-load.sh --baseline` fails on growth past the recorded number and has
nothing to say about a number that has become too large. A shrink is invisible
to it by construction.

**What this says about the mechanism.** Every corrected detail points away
from reviewer posture and toward which work gets reviewed. A wave whose entire
job is small corrections is the wave most likely to move a figure some other
file records, and it is the one wave the crew never sees. There is one defect
in this exercise, not two: the same seventeen tokens, introduced by a cleanup
wave, live at both commits the shadow reviewed, found at one and cleared at
the other. It was introduced by a cleanup wave and caught eight hours later,
incidentally, by a different cleanup wave truing up a figure it noticed was
stale. No reviewer of any posture was ever pointed at it, and the one gate
that was could only see one direction.

One consequence for the record: `5079208`, `bc13ba5`, `b423f50`, `3430317`
and `5dbc6d5` are all still reachable objects. A squash-merge does not destroy
the per-wave commits, it only removes them from the first-parent history, so a
future exercise of this kind should review the commit the gate line was
written against and not the merge.

**Case 1 — a clearance the correction withdraws.** Both sides cleared it. The
shadow ran four refutations and lost all four: it re-measured the commit's own
`spec-load` baseline from an extracted tree, where all seven entries read
`0 under baseline` — the exactness reading, not the `grew 0` summary line,
which is the one-directional check case 4 slips through — ran the two skill
lints (0 violations), checked the `tuffgal run` example against house
precedent (14 sibling-repo mentions across eight skill files), and checked the
bullet's cited incident against real tuffgal source, where `buildSchedule`
(`src/runner/run.ts:135`) does throw ahead of `resolveStorageStateForNeeds`
(`src/runner/runStory.ts:87`). Three of those four hold at either commit.

The baseline one does not, and it was the case's headline. All seven entries
read exact at `2a9f898` because `bc13ba5` had already fixed three of them; at
`5079208`, the commit the crew reviewed, `orchestrator-run` was seventeen
tokens over. The shadow was not agreeing with the crew from stronger evidence.
It was measuring a different tree and reporting the difference as agreement.

The irony is worth stating plainly rather than leaving for a reader to find.
This case's own write-up argued that the exactness reading is the rigorous one
and `grew 0` is the check a defect slips through. The shadow then ran the
exactness reading on the wrong tree and cleared a commit whose ancestor
carried exactly the defect it was contrasting itself against.

So case 1's `0` in the net-new column is not a match. It is a miss — and the
thing missed is the same seventeen tokens case 4 is about, sitting in the same
file, on the review target the crew was actually given.

**Case 2 — two additional findings, both below the floor.** The original
recorded a batched comment-length note; the shadow found the same 174-char
JSDoc, plus two more. First, `await assert.rejects(readJsonBaseline(path));`
is the only unpinned rejection assertion in the repo — 18 uses exist at that
commit, and all eight multi-line forms were opened individually to confirm
each carries a matcher. It matters because that assertion is the diff's own
evidence for its stated behaviour change from swallowing to throwing, and a
bare `assert.rejects` cannot tell EISDIR from a TypeError. Second,
`readJsonBaseline` does not parse JSON, and the diff documents the misleading
name in its new JSDoc while promoting the function from one caller to three.
Both `batch`. Neither is in the recorded summary, but the record is 108
characters and cannot prove the original did not raise them — and the shadow
read `0b6e514`, which carries `5dbc6d5`'s cleanup on top of the reviewed
`3430317`, so a finding present in one and not the other cannot be separated
from the cleanup either.

**Case 3 — the refute mandate found fewer.** The original recorded two batched
convention nits, whose content the record does not carry, so what the shadow
missed cannot be named. The shadow found none, and the reason is instructive: it had
one candidate — a test comment naming a spread precedence that cannot arise,
since `base` carries no `breakpoint` key — and discarded it, because the
override's burden-of-proof clause says a refutation you cannot defend cleanly
is an attempt, not a finding. The five attempts it ran all failed honestly:
none of the six hoisted values is ever reassigned — five are `const`
(`run.ts:101, 122, 127, 130, 137`) and the sixth, `config`, is the function's
own parameter (`run.ts:95`) — `Required<Pick<...>>` does restore the arity the
commit claims because `mode` and `producedAnywhere` are genuinely optional on
the interface, and all four pre-existing `runAll` configs really do declare one
breakpoint. A kill mandate with a burden of proof is not strictly more
productive than an evaluative one. It is more conservative about marginal
findings, which cuts both ways.

This is also the case whose original review target no longer exists on disk,
so the `-2` is the least attributable number in the table: `608af99` squashes
a second commit the crew never saw, and the two nits it "missed" may have been
fixed by that commit rather than declined by the mandate.

**Case 4 — one real defect, introduced by the one wave nobody reviews.**

The commit the shadow read writes `orchestrator-run 22483` into
`scripts/spec-load-baseline.tsv` and carries a comment pricing the new rule at
"+335 orchestrator-run for the brief-authoring rule". At that commit both
numbers are wrong. Extracting the tree and running its own `spec-load.sh`
against its own baseline reports the live reading as 22466, "17 under
baseline". Re-derived by hand rather than trusting the script, summing the
four `always` files the manifest names:

```
10002  skills/loop-de-looper/SKILL.md
 5618  skills/loop-de-looper/references/protocol-detail.md
 4212  skills/loop-de-looper/references/state-schemas.md
 2634  skills/loop-de-looper/references/rails.md
-----
22466    committed: 22483    parent: 22148
```

The real price is 318, not 335. The figure is deterministic — all five
manifest rows are in-repo paths and the metric is bytes/4 — so it is not a
machine artifact.

**Both numbers were correct when they were written, and stopped being correct
one commit later.** The same sum run against every commit on the branch puts
the live figure at 22483 at `6b989ad`, the wave-1 commit the crew reviewed,
exactly matching what it recorded. `b423f50`, the cleanup-batch wave that came
after the crew pass, fixed seven batched findings — two of which trimmed prose
out of `skills/loop-de-looper/SKILL.md` and
`skills/loop-de-looper/references/protocol-detail.md` — and dropped the live
figure to 22466 without moving either the baseline or the `+335` note, in a
commit that edits `scripts/spec-load-baseline.tsv` on the line directly above.
The table in the correction section above gives the figure at each commit.

It matters beyond arithmetic. The baseline exists to catch growth and
`spec-load.sh` only fails on growth past the recorded number, so an inflated
baseline is silent slack. The wave that loosened it by 17 tokens reported
"spec-load-baseline grew 0" and was telling the truth: the guard cannot see a
shrink, and no crew pass runs over a cleanup wave.

The project's own history records the same correction: `bc13ba5`, eight hours
later, moves "orchestrator-run always 22483 to 22466" as a figure that was
stale before that branch existed. That commit is case 1's own review target,
read at the start of this exercise, so it corroborates the arithmetic but not
independently of this reviewer.

**What the rest of that crew pass said.** Four reviewers ran. `the-stickler`
returned CLEAN on a styling nit. `the-chronicler` batched a "questionable
baseline-note claim" without settling it. And `the-diamantaire` — the one
agent already carrying the kill mandate — returned "Baseline arithmetic, rule
logic, and unverified-duplicate-contract distinction all verified correct".

An earlier revision of this document read that sentence as the maximally
adversarial reviewer positively certifying the one thing that was wrong. It
was not. At `6b989ad` the arithmetic was correct and the sentence is true. Its
gate line still records `verified_by: llm`, and the honest thing that says is
only that the claim is unbacked, not that it is false. The rhetorically useful
version of this case did not survive checking it.

## The verdict

**A refute-only mandate does not, on this system's real review history,
surface materially more.** The net-new column carries almost none of that,
because after the comparison-target correction all four counts are measured
against a tree the original reviewers never saw, and case 1's `0` turns out to
be a miss rather than a match. What the four cases do establish is narrower
and is about the shadow reviewer itself rather than about the crew.

Under a kill mandate, told to assume the diff was wrong and to produce
evidence, the shadow found one genuine defect and missed another of exactly
the same kind. It found the one it found by extracting a tree and running a
script. It missed the other by extracting the wrong tree and running the same
script. Posture was constant across both; what varied was whether the command
was pointed at the thing under review. Any posture that ran the right command
would have found either, and no posture that ran the wrong one found the one
it missed.

That is why the verdict is better supported after the correction than before.
The first revision argued the point from a crew line it read as confidently
wrong, which on re-derivation was correct. This revision argues it from the
shadow reviewer's own two attempts at the same defect class, one successful
and one not, with posture held fixed — which is the comparison E-4 actually
needs and the first revision did not have.

So the paper's motivating case transfers, but its remedy does not. Ten
reviewers unanimously endorsing a vulnerability that did not exist, and a
seventeen-token baseline drift that four reviewers, four gates and one
adversarial shadow all failed to be pointed at, are the same failure: a
verdict with nothing executed against the thing it is a verdict about. The
paper's own answer to its OpenSSL case was an empirical test, not a fiercer
prompt — the mandatory validation gate, not the kill mandate. E-4 picked up
the half that does not bind here.

This does not clear the roster. It says the binding variable is whether
something was executed against the artifact under review, which is strictly
harder than what `verified_by` records and harder again than what
`docs/loop-unanimity-audit-findings.md` measured at five unanimous, all-clean,
zero-execution groups. The commit that carries this defect is not in any of
those five: it was never reviewed by anyone, because it was a cleanup wave.

## Recommendation, not applied

No `agents/*.md` file was edited by this investigation, and none should be on
the strength of it.

1. **Do not adopt a blanket refute-only rewrite of the crew prompts.** The
   consensus-seeking language E-4 assumes is not there, the debate mechanism
   it targets does not exist, and the mandate did not pay on any of the four
   cases.
2. **The change worth considering is the "attempted and failed" section, not
   the kill mandate.** It costs one output heading. It makes a null legible,
   it forces a reviewer to name what it tried, and in case 3 it is what
   stopped a marginal finding from being written up as a real one. It is also
   what would have caught this document's own case-1 error: a reviewer
   required to write down that it measured the baseline "from an extracted
   tree" has written down which tree, where a reader can see it is the wrong
   one.
3. **`spec-load.sh --baseline` is one-directional and that is what shipped the
   defect.** It fails on growth past the recorded number and says nothing when
   the live figure falls below it, so "grew 0" is compatible with a baseline
   that has silently become slack. Every wave that trims prose out of a spec
   file can loosen the guard and pass its own check. This is the concrete,
   mechanizable item, and it is not about review at all.
4. **A cleanup-batch wave gets no crew pass, and that is where this defect
   came from and where it went.** `b423f50` introduced the drift; `bc13ba5`
   silently repaired it and two other figures with no record of anyone
   reviewing the repair. A wave whose job is small corrections across files
   that record each other's figures is exactly where this class lives, and it
   is the one wave the crew never sees.
5. **A `verified_by: llm` line asserting arithmetic is unbacked, not false.**
   An earlier revision listed this as the sharpest lever on the strength of a
   crew line that turned out to be correct. The weaker claim survives and is
   worth keeping: the field records that nothing was run, which is the signal,
   and it does not license reading the verdict as wrong.

Items 2 through 5 are for the user, or for a future `the-turncoat` pass to
weigh against the cost of touching seven definitions. Item 3 needs no
definition touched at all.
