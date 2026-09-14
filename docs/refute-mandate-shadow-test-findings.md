# Does a refute-only reviewer mandate find more?

Verdict on issue #89's finding E-4, which proposes giving a reviewer agent a
pure "kill" mandate instead of an improve-or-evaluate one, after
[Refute-or-Promote](https://arxiv.org/abs/2604.19049) (Agarwal). The paper is
real and its motivating case is as cited: ten reviewers unanimously endorsed a
Bleichenbacher padding oracle that did not exist, and only an empirical test
removed it.

**NOT CONFIRMED, with one finding that points somewhere else.** A refute-only
mandate did not systematically surface more than the original reviews did. On
four real past reviews it matched once, added findings once, produced fewer
than the original once, and found one genuine defect nobody had caught. The
defect was not found by being adversarial. It was found by running a script.
And the reviewer that missed it is the one already carrying a kill mandate.

## The limit this test could not remove

`the-looper` has no Task tool, so the shadow reviewer could not be dispatched
as a separate agent. It is the same model in the same context, running under
an inline prompt override. That is a weaker instrument than a fresh dispatch
and it cuts in the direction of over-reporting agreement.

The mitigation is that every shadow finding below rests on a command whose
output is quoted, not on the shadow reviewer's judgment about itself. Where a
finding rests on judgment alone it is recorded as an attempt that failed, not
as a finding.

## Part 1 — the prompt audit

Seven reviewer definitions, counted rather than characterized:

```
grep -nioE "constructive|not cruel|commendation|earned praise|positive signal|LGTM|reassurance|consensus|converge|debate|refute|prosecut|kill.mandate|adversarial|subtractor|reject on sight|challenge" agents/<agent>.md
```

| agent           | refutation vocabulary                                           | softening vocabulary                                       |
| --------------- | --------------------------------------------------------------- | ---------------------------------------------------------- |
| the-diamantaire | refute x6, prosecut x5, kill-mandate x2, adversarial, challenge | positive signal, earned praise                             |
| the-chronicler  | subtractor                                                      | none                                                       |
| the-ghostwriter | reject on sight                                                 | none                                                       |
| the-chemist     | none                                                            | reassurance                                                |
| the-stickler    | none                                                            | constructive, not cruel, commendation, earned praise, LGTM |
| the-auditor     | none                                                            | none                                                       |
| the-improver    | none                                                            | none                                                       |

Three things the count does not carry, all of which matter more than it does.

**There is no consensus-seeking language in the roster.** Nothing in any of
the seven asks an agent to agree with another agent, soften toward a shared
position, or find common ground. The word "consensus" appears exactly once, in
`the-diamantaire`, in a clause forbidding it: "Default to challenging; do not
soften to consensus or converge by debate." E-4's premise, read as a claim
about this system's prompts, does not hold.

**The debate mechanism the paper targets does not exist here.** The crew is
dispatched in parallel, one message per agent, no second round, no
cross-agent aggregation (`skills/loop-de-looper/SKILL.md` `### Step 3`).
Reviewers cannot converge by debate because they never see each other. This
matches the existing position that the crew is domain-partitioned rather than
an ensemble.

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

| #   | wave                                     | commit    | original verdict                    | shadow verdict         | net new |
| --- | ---------------------------------------- | --------- | ----------------------------------- | ---------------------- | ------- |
| 1   | `issue-74-real-entry-point-verify` w1    | `2a9f898` | LGTM, 0 gating 0 batched            | `promote`, 0 findings  | 0       |
| 2   | `58-1-dedup-readjsonbaseline` w1         | `0b6e514` | LGTM, 1 batched comment-length note | `batch`, 3 findings    | 2       |
| 3   | `collapse-run-scheduled-story-params` w1 | `608af99` | LGTM, 2 batched convention nits     | `promote`, 0 findings  | -2      |
| 4   | `issue-72-verify-brief-claims` w1        | `adb9ef3` | CLEAN, 1 cosmetic styling nit       | `batch`, 1 real defect | 1       |

Case 4 was held out: it was run only after cases 1-3 were written and the
verdict drafted, to test whether the verdict generalized to a case that had
not shaped it. It was also a substitution. The intended fourth,
`linklater/feature-dyslexic-font-accessibility` w4, turned out to be
unreconstructable — its per-wave commits were squashed at merge — so the fifth
group took its place, identified by an exact file-set match against the gate
line's `files` array and an mtime eight minutes before the commit.

**Case 1 — agreement, reached differently.** Both sides cleared it. The shadow
ran four refutations and lost all four: it re-measured the commit's own
`spec-load` baseline from an extracted tree, where all seven entries read
`0 under baseline` — the exactness reading, not the `grew 0` summary line,
which is the one-directional check case 4 slips through — ran the two skill
lints (0 violations), checked the `tuffgal run` example against
house precedent (14 sibling-repo mentions across eight skill files), and
checked the bullet's cited incident against real tuffgal source, where
`buildSchedule` (`src/runner/run.ts:135`) does throw ahead of
`resolveStorageStateForNeeds` (`src/runner/runStory.ts:87`). Same verdict, more
evidence under it.

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
characters and cannot prove the original did not raise them.

**Case 3 — the refute mandate found fewer.** The original recorded two batched
convention nits, whose content the record does not carry, so what the shadow
missed cannot be named. The shadow found none, and the reason is instructive: it had
one candidate — a test comment naming a spread precedence that cannot arise,
since `base` carries no `breakpoint` key — and discarded it, because the
override's burden-of-proof clause says a refutation you cannot defend cleanly
is an attempt, not a finding. The five attempts it ran all failed honestly:
the six hoisted values are all `const` and never reassigned (`run.ts:101, 122,
127, 130, 137`), `Required<Pick<...>>` does restore the arity the commit
claims because `mode` and `producedAnywhere` are genuinely optional on the
interface, and all four pre-existing `runAll` configs really do declare one
breakpoint. A kill mandate with a burden of proof is not strictly more
productive than an evaluative one. It is more conservative about marginal
findings, which cuts both ways.

**Case 4 — one real defect, missed by everyone, and the reason it was missed.**

The commit writes `orchestrator-run 22483` into `scripts/spec-load-baseline.tsv`
and adds a comment claiming "+335 orchestrator-run for the brief-authoring
rule". Both numbers are wrong. Extracting the tree at that commit and running
its own `spec-load.sh` against its own baseline reports the live reading as
22466, "17 under baseline". Re-derived by hand rather than trusting the
script, summing the four `always` files the manifest names:

```
10002  skills/loop-de-looper/SKILL.md
 5618  skills/loop-de-looper/references/protocol-detail.md
 4212  skills/loop-de-looper/references/state-schemas.md
 2634  skills/loop-de-looper/references/rails.md
-----
22466    committed: 22483    parent: 22148
```

The real price is 318, not 335. The parent commit measures 22148 against a
recorded 22148, exact, so this commit introduced the drift rather than
inheriting it. The figure is deterministic — all five manifest rows are
in-repo paths and the metric is bytes/4 — so it is not a machine artifact.
The project's own history corroborates it independently: a commit later the
same day records "orchestrator-run always 22483 to 22466" as a figure that was
stale before that branch existed.

It matters beyond arithmetic. The baseline exists to catch growth and
`spec-load.sh` only fails on growth past the recorded number, so an inflated
baseline is silent slack. The commit that added the guard's entry loosened it
by 17 tokens, and the guard reported `ok` throughout.

**What the rest of that crew pass said is the actual result of this exercise.**
Four reviewers ran. `the-stickler` returned CLEAN on a styling nit.
`the-chronicler` got closest, batching a "questionable baseline-note claim"
without settling it. And `the-diamantaire` — the one agent already carrying
the kill mandate, the one E-4 would change nothing about — returned "Baseline
arithmetic, rule logic, and unverified-duplicate-contract distinction all
verified correct".

The maximally adversarial reviewer positively asserted the correctness of the
one thing that was wrong. Its gate line records `verified_by: llm`.

## The verdict

**A refute-only mandate does not, on this system's real review history,
surface materially more.** Across four cases it added two below-floor findings
in one, subtracted two in another, and matched in a third. The one genuine
defect it found in the fourth was not found by adversarial posture. It was
found by extracting a tree and running a script, and any posture that ran the
script would have found it.

The evidence for that is case 4's own crew pass, where posture and outcome
came apart completely. The most adversarial prompt in the roster produced the
most confidently wrong sentence in the pass, because it reasoned about
arithmetic instead of executing it. Meanwhile a gentler reviewer's hedge
("questionable baseline-note claim") was closer to the truth and was batched
rather than resolved, because nothing in the process converts a doubt into a
command.

So the paper's motivating case transfers, but its remedy does not. Ten
reviewers unanimously endorsing a vulnerability that did not exist, and four
reviewers unanimously clearing a baseline that was 17 tokens off, are the same
failure: a verdict with no execution behind it. The paper's own answer to its
OpenSSL case was an empirical test, not a fiercer prompt — the mandatory
validation gate, not the kill mandate. E-4 picked up the half that does not
bind here.

This does not clear the roster. It says the binding variable is whether a
reviewer executed anything, which is the axis `verified_by` already records
and `docs/loop-unanimity-audit-findings.md` already measured at five
unanimous, all-clean, zero-execution groups. Case 4 is the sixth reading of
the same instrument, and the first with a confirmed defect sitting under one.

## Recommendation, not applied

No `agents/*.md` file was edited by this investigation, and none should be on
the strength of it.

1. **Do not adopt a blanket refute-only rewrite of the crew prompts.** The
   consensus-seeking language E-4 assumes is not there, the debate mechanism
   it targets does not exist, and on four real cases the mandate did not pay.
2. **The change worth considering is the "attempted and failed" section, not
   the kill mandate.** It costs one output heading. It makes a null legible,
   it forces a reviewer to name what it tried, and in case 3 it is what
   stopped a marginal finding from being written up as a real one. It is also
   the part that would have made case 4 visible: a reviewer required to list
   what it tried has an obvious place to notice it tried nothing.
3. **The sharper lever is already in the system and is not being pulled.** A
   crew line that asserts arithmetic is correct while recording
   `verified_by: llm` is the exact shape of case 4. Whether that should be
   inadmissible is a live question and a larger one than this wave.

Items 2 and 3 are for the user, or for a future `the-turncoat` pass to weigh
against the cost of touching seven definitions.
