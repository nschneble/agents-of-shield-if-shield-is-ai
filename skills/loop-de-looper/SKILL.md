---
name: loop-de-looper
description: Orchestrator for multi-wave goals. Trigger when the user says "loop de looper", "run all the waves", "autonomous loop", or hands a multi-wave goal expecting hands-off execution.
---

Parent orchestrator. Input = raw goal. Output = goal-complete or escalation. Composes existing pieces; no re-invent.

Loop de Looper NOT execute waves directly. Dispatches `the-looper` agent per wave; the-looper runs full wave protocol internally (research → plan → build → verify → review → learn → commit). Crew passes scheduled at trigger points by `loop-de-looper` itself. Orchestrator = parent (entity invoking this skill), not separate agent.

## Why exists

User hands multi-wave goal ("finish theme refactor", "harden auth boundary"). Without orchestrator: each wave needs manual queue management and brief construction, crew passes get skipped or run wastefully per-wave, and termination is ad-hoc. Loop de Looper formalizes the protocol so the parent runs goal → done without per-wave human intervention, preserving safety gates.

The failure it must not have is the opposite one: a run that ships the ask in wave 1 and then spends nine waves on findings nobody asked for. `## Goal contract` and `## Finding severity floor` are what hold the run to the ask, and they outrank every other rule in this skill and its references.

## Composition

```
loop-de-looper(goal)
├── looper-nonbeliever(goal, approach)   → PROCEED|NOTES|STOP + sizing inline|single-wave|full
├── looper-scope(goal[, notes])          → goal contract + wave queue + exit criteria + required-not-loopable
├── write run-state.json                 → first checkpoint, before any wave dispatches
└── for each wave in queue:
    ├── the-looper(brief + goal contract) → research → plan → build → verify → review → learn → commit
    │      └── plan emits ESCALATE       → fire specialist, append `gate outputs`, re-dispatch
    ├── counters → run-state.json → finding audit → governor → usage guard
    └── if crew_trigger(): crew pass     → gating findings loop back; everything else batches
├── cleanup batch wave                   → one dispatch over everything that batched
├── final crew pass (domain-matched)     → once, last, before declaring goal-complete
├── PR finalization backstop             → assert PR exists; create if a wave missed it
├── looper-learn(run mode)               → diagnose the orchestration; WRITES lessons before recap
└── looper-recap(run state)              → read-only closing summary, then exit report
```

Crew = seven agents (named in `## Step 3`), invoked in parallel via Task tool per memory `[[the-crew-agent-group]]`.

## Goal contract

`looper-scope` emits the goal contract as its section 0: the user's asks as numbered atomic items in their own words, plus the exit criterion that closes each. Persist it at Step 1 into `run-state.json` as `goal_contract` (`references/state-schemas.md`), and reproduce it VERBATIM in every wave brief and **every crew-agent prompt**.

It is the run's definition of done and the reference every finding is measured against. Without it in the prompt, a reviewer has nothing to be relevant to, and its findings drift to whatever the diff suggests — the observed failure, twice: a run whose ask was "centre this status message" spent three of four waves rebuilding the test scanner around a correct one-line fix, and a run whose asks were "stop the logouts" and "cut the boot screen" reached 13 commits with the second ask unstarted.

The contract is fixed at Step 1 and does NOT grow. New work the run discovers goes to the user as a question (`## Step 3`), never into the contract, never into the queue.

## Finding severity floor

A finding may block a wave and spawn a corrective ONLY when it is in a gating class AND admissible. Everything else is recorded to `cleanup_batch` and worked once, at the end.

**Gating classes:**

| class                     | test                                                                                                                                                |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| correctness regression    | a defect at a `file:line` inside THIS run's diff (`git diff <wave1>^..HEAD`)                                                                        |
| security                  | an exploitable defect on a line the run touched                                                                                                     |
| data loss                 | irreversible state or unrecoverable user data                                                                                                       |
| a11y regression           | a WCAG failure on UI THIS run shipped                                                                                                               |
| false user-visible string | a string an END USER sees at runtime that is factually wrong about what the code does. Spec, doc and comment prose is NOT in this class (see below) |

**Batched, never gating:** docs, comments, docstrings, naming, conventions, LOC and god-file size, test hygiene, surviving mutants, oracle shape or completeness, refactor opportunities, voice and tone, commit-message and PR-body prose, and anything pre-existing that this run did not cause.

**Admissibility, on top of class.** A gating finding must also cite either a `goal_contract` ask it protects or a `path:Lstart-Lend` the run changed. A finding citing neither batches regardless of class. This is the rule that ends the unrelated-issue chase: a defensible defect about code the run never touched is still not this run's business.

A crew agent calling something a blocker does not make it gating — the floor does, and `## Step 3` applies it. Voice and tone never gate: a string that is _false_ gates under the last class and may be raised by any agent, a string that is merely off-voice batches.

**A false statement in a spec, doc, or comment batches — it is not a "false user-visible string".** The two entries collided honestly: a stale cross-reference is both documentation (never gating) and a shipped string that is wrong about what the code does (gating), and four reviewers reading the same defect split three-to-one on it. The tie is broken toward BATCH, for a reason that is not merely "docs are cheap": a reader misled by a spec fails loudly at the next step — the path does not resolve, the heading is not there, the check refuses — whereas an end user misled by a runtime string has no such backstop. Those spec failures are also now MECHANICAL: `scripts/validate-looper-config.sh` resolves every backtick'd path AND every cited `## Heading`, in reference and template bodies as well as specs. A class a check already owns does not need the floor to stop a wave for it. On an extraction wave a per-output-file LOC ceiling IS the contract, so it gates as an exit criterion, not as a size finding (`references/protocol-detail.md` `## Step 2a`).

Every gating claim is logged with `gated_by` + `contract_ref` on its `gates.jsonl` line and checked by `scripts/loop-finding-audit.sh` (`## Gate artifacts`).

## Corrective budget

| sizing               | interim crew               | correctives                                |
| -------------------- | -------------------------- | ------------------------------------------ |
| `inline`             | none                       | 0                                          |
| `single-wave`        | none (one final crew only) | 1 for the whole run                        |
| `full-orchestration` | cadence (`## Step 2d`)     | 1 per wave, `max_corrective_waves` per run |

**One corrective per wave, then batch.** `max_correctives_per_wave: 1`. A second gating finding on the same wave after its corrective has shipped is recorded to `cleanup_batch` and surfaced in the report — the wave advances. A wave needing two correctives is a wave whose approach is wrong; that is a `rethink`, not a third patch.

**One re-crew, scoped, terminal.** A corrective is re-checked exactly once, by the agents whose findings it targeted plus any whose domain its diff touched (`references/protocol-detail.md` `## Step 3`). That re-crew answers CLEARED / NOT-CLEARED on those findings and nothing else. New findings it raises batch. NOT-CLEARED is a STOP to the user, never another corrective. Without this the ladder is infinite: each corrective grows the diff, the re-crew reviews the bigger diff, and the new blocker earns the next corrective — observed at five correctives on one wave.

## Inputs

1. **Goal**: raw user input. Single sentence to single paragraph.
2. **PR context (optional)**: existing PR number if updating draft. `gh pr view <N>` body becomes scope input.
3. **Resume flag (optional)**: `resume` to continue prior run. Reads `local/loops/<branch>/run-state.json` as authoritative; falls back to git-derive only if that snapshot is missing or corrupt (`## State tracking`).
4. **Fast flag (optional)**: `--fast` to assert the ask is trivial and take the single-dispatch route without the pre-flight (`## Step 0−`). The guards still bind.

## Protocol

### Step 0−: Fast path (small, unambiguous asks)

Three ways in, in order of how much the run gets to assume.

**Auto-detect.** A goal qualifies when ALL of these hold: it is a single sentence; it names a concrete file or symbol that RESOLVES on disk; and it contains no conjunction joining separate asks. Then skip Step 0 and Step 1, dispatch `the-looper` once, run one domain-matched crew pass, and go to the exit report.

**`--fast`.** The user asserts the ask is trivial. Same route, without the resolution test — their assertion stands in for it.

**Everything else** takes Step 0 normally. That is the default, and it stays the common case.

Four guards, none optional, because this path bypasses the contradiction, authority and gate-substitution STOPs that `looper-nonbeliever` exists to raise:

- **Vague is never small.** A goal with no definition of done fails detection outright — the same rule nonbeliever applies, applied earlier. "Improve performance" is not a fast path, it is a STOP.
- **Resolution is mechanical, not rhetorical.** The named file or symbol must be found on disk. A confident sentence about a symbol that does not exist is not a concrete ask.
- **UI globs override everything.** A goal touching a UI path takes the normal route however it is phrased. The accessibility gate is not bypassable by phrasing, and not by `--fast` either.
- **The route is logged.** Every fast-path decision writes a `gates.jsonl` line naming what matched and which steps it skipped, with `ran: false` against the skipped gates. A wrong route has to be readable afterwards, not reconstructed.

The goal contract still exists on this path. The parent writes it from the raw goal before dispatching — one ask, one exit criterion — and persists `run-state.json` as usual. A wave with no contract has nothing to measure its findings against, which is the failure `## Goal contract` is about, and it does not stop being true because the run is small.

### Step 0: Nonbeliever pre-flight (once per run)

Invoke `looper-nonbeliever` via Skill tool with the goal + the orchestrator's intended approach. It interrogates both against `CLAUDE.md`, existing agents, skills, and active directives, and emits a verdict: **PROCEED** → continue; **PROCEED-WITH-NOTES** → carry the notes into scope input; **STOP** → hard contradiction (rule conflict, user-authority decision, required-gate substitution), surface its output and do NOT proceed. Nonbeliever is advisory by design: a challenge being _raised_ does not halt the run, only a STOP does. Do NOT improvise around a STOP.

It also emits a **SIZING** label. Route on it BEFORE Step 1 — a misfiled small ask should not pay full freight, and sizing now carries a corrective budget (`## Corrective budget`), so it binds for the whole run rather than only skipping the crew cadence. **inline** → the goal does not warrant the loop; skip scope AND the wave loop, make the change inline (or hand back "do this inline"), go to the exit report. **single-wave** → dispatch `the-looper` once (`pr: create-on-wave-1`, `target.push: true`), **skip `looper-scope` entirely** along with the queue and the crew cadence, still run the PR-finalization backstop. Nonbeliever emits the goal contract for this route — it has already read the raw goal, and one ask with one exit criterion needs no decomposition pass to produce. Persist `run-state.json` from it before dispatching, exactly as Step 1 would. Until this was written down the route was ambiguous and nothing owned the contract, so a `single-wave` run could reach its executor with no definition of done. **full-orchestration** → proceed to Step 1; default and common case.

A STOP halts regardless of sizing. Sizing never overrides a STOP, and never shrinks a vague goal — nonbeliever sizes unspecified work as STOP, not `inline`.

### Step 1: Scope (once per run)

Invoke `looper-scope` via Skill tool with goal + PR context (+ nonbeliever notes). Validate its output:

- **Goal contract present and faithful** — the asks are the user's, not a restatement that has already drifted. Surface to the user if it has.
- Classification non-REFUSE (open-ended goals → scope refuses → stop)
- Wave queue non-empty (empty queue → goal already met → report + stop)
- `Required, not loopable` items captured (surface at end, never silent skip)
- Executor-writability pre-flight (`references/protocol-detail.md` `## Step 1`)

Scope stop conditions fire → Loop de Looper stops. Do NOT improvise around a scope refusal. A goal arriving as an already-vetted user-approved plan may skip scope's decomposition but not these checks (`references/protocol-detail.md` `## Step 1`).

**Then write `run-state.json` before dispatching wave 1** (atomic, `## State tracking`) — the goal contract, queue, `sizing`, `nonbeliever`, `required_not_loopable`, empty `cleanup_batch`, `last_crew_wave: 0`, every counter at zero, every wave `pending`. Until it lands, the contract and the whole decomposition exist nowhere but context: a session that dies here has nothing to resume from and a second nonbeliever pass is free to size the goal differently.

### Step 2: Per-wave loop

**2a. Dispatch the-looper.** Run the cheap stale-candidate pre-check first, then invoke `the-looper` via Task tool with the wave brief, the goal contract verbatim, and the project target (branch, PR number). It returns a hand-back (`shipped`, `deferred`, `gate needed pre-build`, `gates needed post-build`, `ranked alternates`, `learn`, `flags`). Every runtime-code brief includes `templates/wave-brief-standing.md` verbatim — the standing quality instructions that pre-empt the most common corrective. The rest of the brief-authoring rules — PR/push directives, deletion-wave gate scope, extraction-wave LOC criteria — are in `references/protocol-detail.md` `## Step 2a`.

**2b. Handle escalation.** Classify the gate first: a **design gate** routes to the named specialist, whose output comes back as `gate outputs` on a re-dispatch; a **tooling gate** (write-block, permission denial, missing credential) is a USER decision no specialist can clear. Pre-mandated gates — scope-tagged or UI-glob-matched — fire up-front rather than via a round-trip. Mechanics and the UI-glob definition: `references/protocol-detail.md` `## Step 2b`.

**2b-retry.** A _retryable_ stop (verify-fails-twice, `rethink`, no-progress) earns EXACTLY ONE fresh-context re-dispatch on the next ranked alternate before bubbling up. A deterministic stop does not. An interrupted wave that never handed back is a resume, not a retry. `references/protocol-detail.md` `## Step 2b-retry`.

**2b-flags.** Triage a shipped wave's `flags` before dispatching the next: cross-file incompleteness the wave itself created gets folded into a later wave's brief or into `cleanup_batch`; self-caused dead code is cleaned inside the creating wave; a pre-existing observation the run did not cause goes to a future scope run and nowhere else. `references/protocol-detail.md` `## Step 2b-flags`.

**2c. Update counters.**

| Counter                        | Updated when                                                                                                    |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `waves_shipped`                | wave commit succeeds                                                                                            |
| `waves_since_crew`             | every wave; reset on crew pass. Reported, no longer a trigger (`## Step 2d`)                                    |
| `cumulative_files_changed`     | sum of `files changed` for shipped waves; reset on crew pass. Reported, no longer a trigger                     |
| `last_review_verdict`          | from the-looper's review step                                                                                   |
| `total_waves`                  | every wave dispatched, queue + corrective (never reset)                                                         |
| `corrective_waves`             | every floor-gated fix wave (not a queue item); never reset                                                      |
| `correctives_this_wave`        | +1 per corrective on the current wave; reset when the wave advances                                             |
| `consecutive_no_progress`      | +1 on a wave that shipped nothing / re-opened the same blocker; reset on any wave that ships net-new queue work |
| `wave_retries`                 | +1 on each stuck-wave retry dispatch; never reset                                                               |
| `scaffolding_only_correctives` | +1 on a corrective whose commit touches no product file; reset on any wave that touches one                     |
| `batched_findings`             | count of `cleanup_batch` entries; reported, never a rail                                                        |

Then, in this order: write `run-state.json` (atomic), run `scripts/loop-finding-audit.sh`, evaluate the budget governor, the usage-window guard, and the crew trigger. Persist before you might STOP or PAUSE, so a halt still leaves a resumable snapshot.

**2d. Crew trigger check.** ONE trigger, evaluated after every wave:

- **concentrated risk**: the wave shipped a new algorithm, a state machine, a model inversion, or one large diff — crew it now so a structural flaw surfaces small. Fires at most ONCE per cluster, not on every wave in it.

The three drift triggers this used to carry — `waves_since_crew >= 4`, `cumulative_files_changed >= 30`, and `batched_findings` growing by 5 — are RETIRED. The measured record is why. Across the one run with a complete gate log, fourteen crew agent dispatches returned **zero** gating findings and 57 batched ones, every last of which the terminal cleanup wave worked anyway. The batch trigger was not merely idle, it was self-reinforcing: a pass generates roughly eleven batched findings, so a threshold of five guarantees the next pass, and interim crews duly fired on consecutive waves.

What made the cadence redundant is the severity floor itself. Before the floor, an interim pass was the only thing between a drifting run and a shipped defect. Now a finding either gates on its own class and admissibility — which the executor's own review already applies, every wave, at no dispatch cost — or it batches to a wave that runs regardless. The cadence was spending roughly 40,000 tokens a run to rediscover the batch.

Concentrated risk survives because it is the one signal that record does NOT cover: a structural flaw in a novel mechanism is what per-wave review is worst at catching, and finding it late costs a rewrite rather than a cleanup line. Tunable per project (`## Crew trigger + budget tuning`).

### Step 3: Crew pass (interim OR final)

**EVERY pass is domain-matched by the diff's file globs — the final pass included.** Interim passes take three agents maximum; a corrective's re-crew is an interim pass under the same cap, narrower still (`## Corrective budget`). The roster, invoked in parallel via Task tool, one call per agent, same message: `the-auditor` (a11y), `the-chemist` (test coverage), `the-chronicler` (doc drift), `the-diamantaire` (correctness), `the-ghostwriter` (voice on prose surfaces), `the-improver` (refactor opportunities), `the-stickler` (conventions).

**An agent whose globs miss the diff is not dispatched — and is not silent either.** Log it to `gates.jsonl` with `ran: false` and the glob that missed, and name it in the report beside the ones that ran. "Report all seven by name with each verdict" is unchanged; what changes is that four of those verdicts may be `not-applicable` with a reason you can audit. An all-seven final pass on a diff with no UI, no tests, and no product prose is not thoroughness: an agent handed a domain the diff cannot contain does not return empty, it reaches, and a reaching finding is where a corrective wave comes from.

**Diff scope.** An interim pass reads the diff **since the last crew pass**; only the final pass reads the cumulative diff. Handing every interim the cumulative diff means wave ten pays to re-read wave one, once per agent, for code an earlier pass already cleared.

Every prompt carries the goal contract verbatim, the severity floor, and the explicit line "report findings only, do not edit any files". Diff base, the no-edit guardrail's `git status` check, and re-crew scope are in `references/protocol-detail.md` `## Step 3`.

Findings are triaged by `## Finding severity floor`, not by the label the agent used:

- **Gating** (in a gating class AND admissible) → one corrective wave, budget permitting. Log `gated_by` + `contract_ref`.
- **Batched** (everything else) → append to `run-state.json` `cleanup_batch` as `{wave, agent, class, ref, finding}`. Recorded, reported, worked once at the end. Not a loop-back, not a warning to escalate on, not silently dropped.

**The crew has no scope authority.** A finding implying work outside the goal contract is not a queue item and not a corrective: record it in `run-state.json` `open_questions` and put it to the user as a question. Observed: a crew-invented wave consumed 6 of one run's 10 correctives while an original ask sat unstarted.

Write the gate artifact BEFORE looping back or resetting counters. Report all seven agents by name with each verdict — `ran: false` and the glob that missed for the ones the domain match did not reach, exactly as for the ones it did. Reset counters after a clean pass.

**Cleanup batch wave.** After the queue drains and before the final crew, dispatch ONE `the-looper` over `cleanup_batch`, ordered by cost. Items that don't fit the wave stay in the report under `deferred_cleanup` for the user. This wave is where docs, comments, naming, test hygiene, and LOC findings get fixed — all at once, against a settled diff, instead of one corrective at a time against a moving one.

**The final crew runs exactly once, and it runs last.** Cleanup batch wave, then final pass, then terminate. A run that crews, then ships another wave, then crews again has not been careful — it has paid for the same pass twice and re-opened a diff it had already settled. Observed: a five-wave run whose log carries a full final pass, a polish wave after it, and a second all-seven pass after that. If a wave genuinely must ship after the final pass, the run is not at termination; fold it in before the pass, or the pass it invalidates is the one that mattered.

### Step 4: Termination

Loop terminates when:

1. **Queue shipped** AND **cleanup batch worked** AND **final crew clean** AND **section 5 empty** → goal-complete
2. **Stop condition fired** at any layer → escalate with state report
3. **Queue shipped** AND **final crew clean** AND **section 5 non-empty** → cannot self-complete; surface the explicit list

Then, in order and on the success paths: **PR finalization backstop** (mandatory on every path — `references/pr-lifecycle.md`), **run-level learn** (`looper-learn` in run mode, passed `gates.jsonl`, `git log --oneline main..HEAD`, the scope queue, the nonbeliever verdict + sizing — it diagnoses the ORCHESTRATION and WRITES its lessons, which is why it precedes the read-only recap), **recap** (`looper-recap`, read-only, layered on top of the structured exit report, never instead of it), then the **structured-recap PR-body refresh** (`references/pr-lifecycle.md`). Skip learn, recap, and the refresh on the STOP/escalation path — a halted run diagnoses live in its escalation report.

For path 3, order is fixed: run the final crew FIRST, then report the bundle in one pass — loopable waves shipped, final crew result, required-not-loopable items still blocking, recommended user actions. User executes section-5 items and returns; Loop de Looper declares goal-complete or resumes.

## Gate artifacts

Every gate the loop runs gets a durable on-disk record in `local/loops/<branch>/gates.jsonl`, appended never rewritten. A gate you can't audit isn't a gate: when the loop runs unattended, the artifact is the only way to tell a real review from one the orchestrator merely narrated. Prose in the final report is NOT a substitute. The rules that make the log trustworthy — `ran: false` for a gate that could not fire, verbatim verdicts, `outcome` for the refutation-posture reviewer, `verified_by` provenance, and the `gated_by` + `contract_ref` justification every gating claim carries — are in `references/rails.md` `## Gate artifacts`; line shapes are in `references/state-schemas.md`. Two checks enforce them: the provenance lint in that schema file, and `scripts/loop-finding-audit.sh`, which fails a run whose correctives were never justified against the floor and the contract.

## State tracking

Run state lives on disk, NOT only in the parent's working memory. A long unattended run gets context-compacted; queue + counters held only in-context can evaporate. The snapshot is authoritative.

Three branch-keyed files under `local/loops/<branch>/`, three different jobs: **`gates.jsonl`** is the append-only audit log, source of truth for _what gates ran_; **`run-state.json`** is the mutable position snapshot, source of truth for _where in the queue we are_; **`wave-N.jsonl`** (+ `wave-N-plan.md`) is the executor's per-wave step journal, source of truth for _how far into a wave it got_ (`agents/the-looper.md` `## Step journal`). The journal is a separate file out of necessity — the orchestrator rewrites the snapshot wholesale (write-tmp-then-`mv`), so an executor appending into it would lose its lines to the next `mv`. Granularity matches ownership: the orchestrator checkpoints WAVES, the executor checkpoints STEPS. Write `run-state.json` **atomically** and BEFORE acting on any governor, guard, or trigger. Shapes in `references/state-schemas.md`.

Resume mode (`/loop-de-looper resume`):

- **Primary**: read `run-state.json`, then **audit it before trusting it** — `bash scripts/loop-state-audit.sh --branch <branch>`. Present-and-stale looks identical to present-and-correct until something compares the snapshot to the records beside it. Exit 0 → trust it. Exit 1 → the records win on every field the audit named; repair, then continue. Exit 2 → treat the unsettled fields as unknown and re-derive by hand. Read the arms it printed, not just the code.
- **Mid-wave**: a wave the snapshot shows `pending` may still have a partly-finished journal. Re-dispatch it normally — do NOT parse the journal to decide which steps to hand it. The executor owns step granularity.
- **Fallback only** (file missing / corrupt / pre-snapshot run): re-run scope, diff `git log main..HEAD` for shipped waves, re-derive counters from git stat. Lossy; the exception, not the path.

## Budget governor

The wave queue is bounded (scope caps it ≤15), but **corrective waves and stuck-wave retries are not**. That churn, not the queue, is the runaway shape. The governor rails on what the orchestrator can actually observe — NOT token spend, which a Skill-driven orchestrator has no reliable way to meter. No fake gauge.

Evaluated in step 2c after `run-state.json` is written and the finding audit has run, before the crew trigger:

| Rail                           | Default | Hit →                                                                                           |
| ------------------------------ | ------- | ----------------------------------------------------------------------------------------------- |
| `max_correctives_per_wave`     | 1       | batch the finding, advance the wave (`## Corrective budget`) — the only rail that is not a STOP |
| `max_total_waves`              | 25      | STOP + escalate: queue + corrective waves exceeded the ceiling                                  |
| `max_corrective_waves`         | 6       | STOP + escalate: too many floor-gated fixes; drift is structural, not patchable                 |
| `consecutive_no_progress`      | 3       | STOP + escalate: 3 waves without shipping net-new queue work (thrash)                           |
| `max_wave_retries`             | 4       | STOP + escalate: the goal is systematically too hard for the executor                           |
| `scaffolding_only_correctives` | 2       | STOP + escalate: consecutive correctives touched only test scaffolding                          |

The scaffolding rail catches a shape the wave counters cannot see. A crew pass against a source-text oracle finds a real hole every time — another spelling, another file, two boxes trading values — so each corrective ships green and earns the next one, and `consecutive_no_progress` never fires because every wave shipped something. Meanwhile the product fix has been finished since wave 1. Two correctives in a row that move no product file means the run is defending its own test, and the answer is usually to delete the test rather than widen it (observed: a 13-line viewport fix that shipped correct in wave 1, then spent three waves rebuilding a scanner around it). The floor is the primary defense against that shape now — oracle completeness is a batched class — and this rail is the backstop for when a finding gets dressed as correctness.

Hitting a STOP rail is not a failure — same discipline as a scope refusal. The persisted `run-state.json` makes the halt resumable.

## Usage-window guard + context-pressure handoff

Two wave-boundary halts the governor's churn rails cannot see. Both finish the in-flight wave, write the snapshot, and stop BEFORE the next dispatch — never mid-wave. Mechanics in `references/rails.md`.

**Usage window.** After the governor, read the REAL rate-limit window (`~/.claude/scripts/usage-window-probe.sh`) and PAUSE if the 5-hour or weekly window is at or above 95% utilization, or the server returned `rejected`. A measured first-party observable, not the token-metering the governor refuses. The pause self-resumes on a scheduled wakeup gated by a FRESH probe, never by elapsed wall-clock alone. A probe that cannot read the window logs not-run and the run continues UNGUARDED and says so — never a fabricated percentage.

**Context pressure.** On an observed signal (a compaction fired, or in-context state had to be re-derived from `run-state.json`), halt with `/loop-de-looper resume`. Never invent a context-% gauge, and don't pre-empt on wave count — that axis has its own rail.

## Stop conditions

- **Nonbeliever STOP verdict** → STOP before scope, surface its output (`## Step 0`)
- **Scope refuses goal** → STOP, surface scope output (`## Step 1`)
- **Plan stops** (research ambiguous, mechanized infra missing, all recovery options fail) → STOP, surface plan output
- **the-looper stops** (verify fails twice, `rethink`, gate not pre-flighted) → ONE from-scratch retry first if retryable, then STOP
- **A corrective's re-crew returns NOT-CLEARED** → STOP, escalate. The fix did not hold; a second patch on the same wave is not the answer (`## Corrective budget`)
- **Crew finds a gating blocker requiring rollback** → STOP, escalate (no auto-revert commits)
- **Budget governor STOP rail hit** → STOP, escalate with the persisted state report; resumable after the user raises a ceiling
- **Finding audit fails** (`scripts/loop-finding-audit.sh` exit 1) → STOP, quote the offending line. A corrective the run cannot justify against the floor and the contract is the exact drift this skill exists to prevent. Exit 2 is NOT a stop: the audit could not settle every arm (an unreadable snapshot, a counter that is not a count). Report which arms it named as unsettled and continue — but do not read it as a pass, and repair the record it could not read at the next wave boundary
- **Context pressure at a wave boundary** → finish the wave, halt before the next dispatch. Clean handoff, not a failure
- **Usage window at/above 95% at a wave boundary** → finish the wave, pause, schedule a self-resume. A PAUSE, not a STOP
- **Queue exhausted, required-not-loopable items remain** → surface explicit list, await user action
- **User intervenes** → current wave completes, then halt

Stopping not failure. Looping past a known blocker = failure. Looping past a budget rail = failure. Looping on findings the goal contract never asked for = failure.

## What loop-de-looper does NOT do

Each of these is a way a real run has gone wrong, and none of them follows from the positive rule alone.

- Does NOT let a finding gate a wave on a crew agent's say-so — the floor and the admissibility test decide, and a gating claim carries `gated_by` + `contract_ref` or it batches (`## Finding severity floor`).
- Does NOT spend more than ONE corrective per wave, and does NOT re-crew a corrective more than once (`## Corrective budget`).
- Does NOT let the crew add queue items or grow the goal contract — a finding implying new scope is a question for the user (`## Step 3`).
- Does NOT drop a below-floor finding either — it lands in `cleanup_batch` and is worked or reported (`## Step 3`).
- Does NOT execute waves directly, does NOT skip a crew pass whose trigger fired, and does NOT run the final pass more than once (`## Step 3`). Not dispatching an agent whose globs miss is a domain match, not a skip — it is logged `ran: false` with the glob and reported by name.
- Does NOT silently swap a specialist gate for a built-in check, record a gate as passed when it didn't run, or let a UI-touching wave build without accessibility-lead.
- Does NOT auto-revert commits, re-scope mid-run, or retry a deterministic stop.
- Does NOT flip a draft PR to ready, revert a PR state it did not set, overwrite a user-edited PR body, or declare goal-complete with committed work and no PR (`references/pr-lifecycle.md`).
- Does NOT invent a usage percentage or a context-% gauge, and does NOT dispatch into a near-exhausted window or a degraded context.
- Does NOT keep run state only in-context, and does NOT halt without naming the next command.
- Does NOT take the fast path on a vague goal, an unresolvable symbol, or anything touching a UI glob, and does NOT dispatch ANY route — fast path included — without a persisted goal contract (`## Step 0−`).
- Does NOT skip run-level learn on a success path, and does NOT let recap decide, fix, or flip anything — it narrates, read-only, over facts that trace to `gates.jsonl` and git log.

## Crew trigger + budget tuning

Crew defaults: no drift cadence, concentrated risk only; interim passes 3 agents, final pass domain-matched. Budget governor defaults: `max_correctives_per_wave=1`, `max_total_waves=25`, `max_corrective_waves=6`, `consecutive_no_progress=3`, `max_wave_retries=4`, `scaffolding_only_correctives=2`. Usage-window guard default: pause at `95%`.

Single canonical override block in the project CLAUDE.md:

```
## Loop de Looper
- crew-cadence: waves=N, files=M   # opt IN to a drift cadence; omitted = risk-only
- crew-agents: interim=N
- budget: max-waves=N, max-corrective=N, per-wave-corrective=N, no-progress=N, max-retries=N, scaffolding-only=N
- usage-pause: pct=N   # 0 disables the usage-window guard
```

The drift cadence is now opt-IN rather than a default to loosen. A project that genuinely wants periodic sweeps — a high-drift domain like a palette or an auth surface, where churn signals a wrong approach early — sets `crew-cadence` and gets the old behaviour. Omit it and the crew fires on concentrated risk and at the end, which is what the measured record supports (`## Step 2d`). The severity floor and the admissibility test are NOT tunable, and neither is domain matching — a project wanting a stricter bar tightens its own `CLAUDE.md` rules, which the crew already reads.

## Voice + style

Reports to user: structured, scannable. Per-wave status line. Crew pass summary. Final state report. Match the lean voice of `looper-commit` and `looper-learn`.

Cite agent outputs verbatim when surfacing blockers; no paraphrase. Per memory `[[feedback-verify-upstream-gate-claims]]` and `[[feedback-task-tool-availability]]`, the orchestrator's job is to surface signal, not summarize it away.

Every report states the run's balance plainly: waves shipped against the goal contract, correctives spent, findings batched. A run that shipped 4 waves and 8 correctives should read that way in its own report, not be narrated as progress.

**Every halt names the next command — literally.** A STOP, an escalation, a budget-rail halt, a context-pressure handoff, or a required-not-loopable termination ends with the exact copy-paste line the user runs next:

- Resumable halt (governor rail, context pressure, user-intervention pause) → `` `/loop-de-looper resume` ``
- Usage-window pause → names BOTH the auto-resume and the manual override: "paused on the 5-hour window (96%), auto-resume scheduled ~HH:MM local when it clears; `` `/loop-de-looper resume` `` to force earlier if you've raised your limit."
- Custodian-style follow-on → `` `/looper-custodian apply #<issue>` ``
- A user-authority decision the run can't make → state the decision, then the command that continues once they've decided.

A halt report that says "the user should re-run when ready" without the runnable line is the gap this rule closes.
