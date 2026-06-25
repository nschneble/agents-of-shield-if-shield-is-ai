---
name: loop-de-looper
description: Orchestrator for multi-wave goals. Composes looper-nonbeliever (pre-flight) + looper-scope (queue) + looper-plan (per-wave brief) + the-looper agent (per-wave executor) + crew (periodic + final) + looper-recap (closing summary). Trigger when the user says "loop de looper", "run all the waves", "autonomous loop", or hands a multi-wave goal expecting hands-off execution.
---

Parent orchestrator. Input = raw goal. Output = goal-complete or escalation. Composes existing pieces; no re-invent.

Loop de Looper NOT execute waves directly. Dispatches `the-looper` agent per wave; the-looper runs full wave protocol internally (research → plan → build → verify → review → learn). Crew passes scheduled at trigger points by `loop-de-looper` itself. Orchestrator = parent (entity invoking this skill), not separate agent.

## Why exists

User hands multi-wave goal ("finish theme refactor", "harden auth boundary"). Without orchestrator:

- Each wave needs manual queue management (which candidate next?)
- Each wave needs manual brief construction (which files, which contracts?)
- Crew passes skipped (drift accumulates silent) or run per-wave (slow, wasted parallelism)
- Termination ad-hoc (when goal done?)

Loop de Looper formalize protocol so parent runs goal → done without per-wave human intervention, preserve safety gates (specialist escalation, crew passes, stop conditions).

## Composition

```
loop-de-looper(goal)
├── looper-nonbeliever(goal, approach)        → interrogate + size goal; verdict PROCEED|NOTES|STOP + sizing inline|single-wave|full
│      ├── sizing inline       → skip scope + wave loop; do it inline, report (no queue, no crew)
│      ├── sizing single-wave  → one the-looper dispatch, skip queue + crew cadence
│      └── sizing full         → continue to scope (default multi-wave path)
├── looper-scope(goal[, notes])               → wave queue + exit criteria + required-not-loopable items
└── for each wave in queue:
    ├── the-looper agent(wave brief)          → runs research → plan → build → verify → review → learn → commit
    │      ├── wave 1: brief pr=create-on-wave-1, push=true → looper-commit pushes + opens draft PR
    │      ├── waves 2…N: brief pr=existing #N, push=true   → looper-commit commits into the PR
    │      └── if plan emits ESCALATE:        agent stops, hand-back has `gate needed pre-build`
    │            ├── orchestrator invokes specialist via Task tool
    │            ├── orchestrator appends `gate outputs` to brief
    │            └── re-dispatch the-looper (resumes at build, skips plan)
    ├── update counters (waves shipped, cumulative blast radius)
    └── if crew_trigger():
        └── crew pass(branch state)           → blocker / warning / nit findings; loop back if blockers
└── final crew pass(cumulative branch)        → before declaring goal-complete
└── PR finalization backstop                  → assert PR exists; create if a wave missed it
└── looper-learn(run mode)                     → diagnose the orchestration (sizing/scope/cadence); WRITE lessons before recap
└── looper-recap(run state)                    → plain-language closing summary (read-only) before terminate
└── report exit state to user (incl. PR #/URL)
```

`looper-nonbeliever`, `looper-scope`, `looper-plan` (invoked inside the-looper), `the-looper`, `looper-recap` already exist. Crew = `the-auditor`, `the-chemist`, `the-chronicler`, `the-diamantaire`, `the-improver`, `the-stickler`: six agents invoked in parallel via Task tool per memory `[[the-crew-agent-group]]`.

## Inputs

1. **Goal**: raw user input. Single sentence to single paragraph.
2. **PR context (optional)**: existing PR number if updating draft. `gh pr view <N>` body becomes scope input.
3. **Resume flag (optional)**: `resume` to continue prior run. Reads `local/loops/<branch>/run-state.json` as authoritative (queue, counters, PR, last-crew); falls back to git-derive only if that snapshot is missing or corrupt. See `## State tracking`.

## Protocol

### Step 0: Nonbeliever pre-flight (once per run)

Invoke `looper-nonbeliever` via Skill tool. Pass goal + the orchestrator's intended approach (one paragraph: how it means to run this).

Nonbeliever interrogates goal + approach against `CLAUDE.md`, existing agents, existing skills, and active directives. Emits a verdict:

- **PROCEED** → continue to Step 1 unchanged.
- **PROCEED-WITH-NOTES** → carry the notes (drop a redundant wave, add a gate) into scope input at Step 1.
- **STOP** → hard contradiction (rule conflict, user-authority decision, required-gate substitution). Surface nonbeliever output to user; do NOT proceed to scope.

Nonbeliever is advisory by design: a challenge being *raised* does not halt the run, only a STOP verdict does. Do NOT improvise around a STOP — same discipline as a scope refusal.

Nonbeliever also emits a **SIZING** label. On any non-STOP verdict, route on it BEFORE Step 1 — most goals handed here size `full-orchestration`, but a misfiled small ask should not pay full freight:

- **inline** → the goal does not warrant the loop. Skip scope AND the wave loop entirely; make the change inline (or hand back "do this inline"), then go straight to the exit report. No queue, no crew, no recap — there is no multi-wave run to summarize.
- **single-wave** → dispatch `the-looper` once with a single-wave brief (scope + `target` + PR directives: `pr: create-on-wave-1`, `target.push: true`); the-looper runs its own research → plan → build → verify → review → learn → commit internally. Skip the scope queue and the crew cadence; still run the PR-finalization backstop (Step 4) so the one commit lands on a PR.
- **full-orchestration** → proceed to Step 1 (scope) as normal. This is the default and the common case.

A STOP halts regardless of sizing. Sizing never overrides a STOP, and it never shrinks a vague goal — nonbeliever sizes unspecified work as STOP, not `inline`.

### Step 1: Scope (once per run)

Invoke `looper-scope` via Skill tool. Pass goal + PR context (+ nonbeliever notes if PROCEED-WITH-NOTES).

Scope produces 8-section output. Loop de Looper validates:

- Goal restatement matches user intent (orchestrator surface to user if drift suspected)
- Classification non-REFUSE (open-ended goals → scope refuses → Loop de Looper stops)
- Wave queue non-empty (empty queue → goal already met → report + stop)
- `Required, not loopable` items captured (surface to user at end, never silent skip)

Scope stop conditions fire → Loop de Looper stops. Do NOT improvise around scope refusal.

### Step 2: Per-wave loop

For each wave in queue, in order:

#### 2a. Dispatch the-looper

Invoke `the-looper` agent via Task tool. Pass wave brief from scope's queue + project target (branch name, PR number).

`the-looper` runs full protocol internally: research → plan → build → verify → review → learn → commit. Returns hand-back report (`shipped`, `deferred`, `gate needed pre-build`, `gates needed post-build`, `learn`, `flags`).

**Brief authoring — PR + push directives.** Every wave brief carries two SEPARATE flags. Never bundle them into one "No PR, nothing flipped to ready" phrase — that conflation collapses two different actions and orphaned PR creation in a real run (every wave deferred PR to "the end," and the end had no PR action, so none was ever created). See `## PR lifecycle + push ownership`.

- `pr:` — `create-on-wave-1` (default on a fresh multi-wave branch) | `existing #N` (every wave once the PR exists) | `skip` (explicit, rare — throwaway spike). "Don't flip to ready-for-review" is NOT a `pr:` value; the draft is still created.
- `target.push: true` — on EVERY wave of an orchestrated run. PR creation and a current remote both require the branch pushed. The orchestrator owns push timing (per `looper-commit`); its default-off is for standalone use, so the orchestrator must set this explicitly.

#### 2b. Handle escalation (if any)

If hand-back contains `gate needed pre-build`:

1. Invoke named specialist (e.g. `accessibility-agents:accessibility-lead`) via Task tool with input the-looper specified
2. Append specialist output to brief as `gate outputs`
3. Re-dispatch the-looper with updated brief. the-looper sees `gate outputs` populated, skips plan, resumes at build.

Record each pre-build specialist gate in the wave's gate artifact (see `## Gate artifacts`): which specialist, ran-vs-unavailable, verdict. A specialist gate the-looper *requested* but the orchestrator could not actually invoke (no Task tool) must be logged as `available: false` — never recorded as passed.

Repeat 2b only until escalation cleared. Same specialist gate requested twice for same wave → STOP, escalate to user (palette / architecture decision needed beyond specialist resolve).

Other stop conditions from the-looper (verify fails twice, review verdict `rethink`, etc) bubble up to Loop de Looper. Do NOT swallow.

#### 2c. Update counters

Maintain run state (persisted — see `## State tracking`):

| Counter                    | Updated when                                                                        |
| -------------------------- | ----------------------------------------------------------------------------------- |
| `waves_shipped`            | wave commit succeeds                                                                |
| `waves_since_crew`         | every wave; reset on crew pass                                                      |
| `cumulative_files_changed` | sum of `files changed` from `git diff --stat` for shipped waves; reset on crew pass |
| `last_review_verdict`      | from the-looper's review step                                                       |
| `total_waves`              | every wave dispatched, queue + corrective (never reset) — budget governor input     |
| `corrective_waves`         | every crew-blocker fix wave (not a queue item); never reset — budget governor input |
| `consecutive_no_progress`  | +1 on a wave that shipped nothing / re-opened the same blocker; reset on any wave that ships net-new queue work |

After updating counters, write `run-state.json` (atomic, see `## State tracking`), THEN evaluate the budget governor (`## Budget governor`), THEN the crew trigger. Order matters: persist before you might STOP, so a governor halt still leaves a resumable snapshot.

#### 2d. Crew trigger check

After every wave, evaluate trigger:

- `waves_since_crew >= 4` OR
- `cumulative_files_changed >= 30` OR
- `last_review_verdict == warning-saturated` (multiple consecutive warnings across waves)

Trigger fires → invoke crew (step 3). Threshold tunable per project via CLAUDE.md override; defaults above.

### Step 3: Crew pass (interim OR final)

Invoke six crew agents in parallel via Task tool (one Task call per agent, same message):

- `the-auditor`: a11y audit on cumulative diff
- `the-chemist`: test coverage on cumulative diff
- `the-chronicler`: doc drift on cumulative diff
- `the-diamantaire`: expert correctness review
- `the-improver`: refactor opportunities
- `the-stickler`: convention conformance

Each agent gets cumulative diff since last crew pass (or since `main` for final crew). Findings categorized:

- **Blocker**: must fix before continuing (interim) or before goal-complete (final)
- **Warning**: should fix; track count for warning-saturation trigger
- **Nit**: capture for future scope run; no loop back

Blockers found → loop back: produce mini-brief for blocker fixes, invoke `the-looper` for one corrective wave, re-run crew on fix. No "ship anyway" path.

After every crew pass, write the gate artifact (see `## Gate artifacts`) BEFORE looping back or resetting counters. The artifact records which crew agents actually ran, whether the Task tool was available, and each verdict — so the pass is auditable on disk, not just narrated in the final report.

The crew summary in any report (interim or final) enumerates ALL SIX agents by name with each verdict — even when clean. Listing only the agents that found something silently drops the rest; a reader can't tell "ran, clean" from "never ran" (the-improver was dropped from a clean report once exactly this way). A clean agent is reported as clean, not omitted.

Reset counters after crew pass clean.

### Step 4: Termination

Loop terminates when:

1. **All wave queue items shipped** AND **final crew pass clean** AND **section 5 empty** → goal-complete success path
2. **Stop condition fired** at any layer → escalate to user with state report
3. **All wave queue items shipped** AND **final crew pass clean** AND **section 5 non-empty** → cannot self-complete; surface to user with explicit list

**PR finalization (backstop — run on every path before declaring goal-complete or surfacing the report):**

1. Detect the run's PR: `gh pr list --head <branch> --state all --json number,url,state`.
2. No open/draft PR but committed work exists on the branch → backstop: ensure the branch is pushed (`git push -u origin <branch>`), then create the draft now (`looper-commit` Step 3). The Wave-1 model should already have created it; this catches the run where it didn't. NEVER declare goal-complete with committed work and no PR — that orphans the whole run off-dashboard.
3. Report the PR #, URL, and draft/ready state in the final state report. "Branch is not a PR" is not an acceptable terminal state for shipped work. Flipping draft → ready stays the user's call (`looper-commit` spec) — creating the draft does not.

**Run-level learn (run on success paths, after PR finalization, BEFORE recap):**

Invoke `looper-learn` via Skill tool in **run mode** (see its `## Run-level diagnosis`). Pass the run trail: `gates.jsonl`, `git log --oneline main..HEAD`, the scope queue, the nonbeliever verdict + sizing. Learn diagnoses the ORCHESTRATION — was the sizing right, did the queue hold, did crew cadence fire at the right drift, did escalation thrash — and writes any lesson to its proper layer (`Loop de Looper body` / `Agent body` rows, or a memory). This is the only step in the run that learns about the *looping itself*; the per-wave learn inside each `the-looper` dispatch can't see past its own wave.

Learn runs BEFORE recap because learn WRITES (skill/agent/memory edits) and recap is READ-ONLY. Recap then narrates the finished run, and MAY cite a learn outcome as a fact ("loop tightened its own crew cadence for this domain") — pulled from learn's output, never invented. Skip run-level learn on the STOP/escalation path: a halted run hasn't finished looping, so diagnose it live in the escalation report instead.

**Recap (run on success paths, after final crew + PR finalization + run-level learn, before the exit report):**

Invoke `looper-recap` via Skill tool. Pass run state (`gates.jsonl`, `git log main..HEAD`, scope section 5, PR #/URL/state). Recap emits a plain-language closing summary, read-only — it decides nothing and flips nothing. It layers ON TOP of the structured exit report, not instead of it; the structured report still carries the verbatim gate verdicts. Recap pulls its facts from the same on-disk sources, so a gate logged `ran: false` stays `ran: false` in the recap. Skip recap on the STOP/escalation path — a halted run reports its stop state directly.

For path 3 (release-readiness goals typically), order fixed:

1. Run final crew pass FIRST (against cumulative loopable work)
2. Then report to user with bundle:
   - Loopable waves shipped (list)
   - Final crew result (pass / pass-with-nits / blockers)
   - Required-not-loopable items still blocking (list from scope section 5)
   - Recommended user actions (each line)

Final crew runs before surfacing required-not-loopable so user gets verified loopable work + open human gates in one report, not two round-trips.

User executes section-5 items, returns; Loop de Looper declares goal-complete (or resumes if user introduced new state during human gates).

## PR lifecycle + push ownership

A multi-wave run shares ONE branch and ONE PR. The PR is created ONCE, EARLY — not deferred to "the end." Deferring orphans it: each wave reasons "not my job, the orchestrator opens it at the end," and the termination step historically had no PR action, so no actor ever created it. The run shipped seven green commits and zero PRs.

Model:

1. **Wave 1**, after the first successful commit: the brief carries `pr: create-on-wave-1` + `target.push: true`. `looper-commit` pushes (`git push -u origin <branch>`) and creates the draft PR (its Step 3), assigned `@me`. A real PR # now exists.
2. **Waves 2…N**: the brief carries `pr: existing #N` + `target.push: true`. `looper-commit` Step 2 detects the open draft and just commits into it (its "has open/draft PR" path); the push keeps the PR current per wave.
3. **Termination**: PR-finalization backstop (Step 4) asserts the PR exists before goal-complete, and creates it if some earlier wave missed it.

`pr: skip` is the ONLY suppressor of PR creation, and it is explicit + rare. "Don't flip to ready-for-review" is NOT `pr: skip` — the draft is still created; only the draft→ready flip stays the user's call. Collapsing those two is the exact bug this section exists to prevent.

Push is the orchestrator's call BY DESIGN — so the orchestrator must actually make it. An orchestrated run that never pushes can never open a PR: `gh pr create` requires the branch on the remote. `target.push: true` on every wave is not optional in orchestrated mode.

## Gate artifacts

Every gate the loop runs gets a durable on-disk record. A gate you can't audit isn't a gate: when the loop runs unattended (`--dangerously-skip-permissions`, no handback), the artifact is the only way to tell a real review from one the orchestrator merely narrated. Prose in the final report is NOT a substitute. See memory `[[feedback-loop-crew-gate-artifact]]`.

Write to `local/loops/<branch>/gates.jsonl` — one JSON line appended per gate event, never rewritten. The path is branch-keyed so resume runs and parallel branches don't collide; `jsonl` so a crashed run still leaves every prior gate intact.

Each line records:

```json
{
  "wave": 4,
  "kind": "crew",                 // "crew" | "pre-build-specialist"
  "agent": "the-diamantaire",     // crew member or specialist name
  "task_tool_available": true,    // false = orchestrator could NOT invoke; see below
  "ran": true,                    // false when task_tool_available is false
  "verdict": "MERGE-READY",       // agent's own words, verbatim — no paraphrase
  "blockers": 0,
  "summary": "one line, cited from agent output"
}
```

Hard rules:

- **`task_tool_available: false` ⇒ `ran: false` ⇒ no verdict.** Per memory `[[feedback-task-tool-availability]]`, the Task tool is sometimes absent in practice. A gate the loop *wanted* to run but could not is logged as unavailable — NEVER as passed, NEVER with an invented verdict. Detect availability, don't assume it.
- **Verdicts are cited verbatim** from agent output, matching the `## Voice + style` no-paraphrase rule.
- **Write before acting on the result** — log the crew pass before looping back or resetting counters (step 3), log the specialist gate before re-dispatch (step 2b). A blocker found is still a gate that ran.

The final report's crew/gate claims must be backed by these lines. If `gates.jsonl` shows a gate as `ran: false`, the report says so plainly — it does not claim the gate passed.

## State tracking

Run state lives on disk, NOT only in the parent's working memory. A long unattended run gets context-compacted; queue + counters held only in-context can evaporate, and a resume that re-derives them by grepping commit messages is lossy. The snapshot is authoritative.

Two files under `local/loops/<branch>/`, both branch-keyed so resume and parallel branches don't collide:

- **`gates.jsonl`** — append-only audit log. One line per gate event, never rewritten. Source of truth for *what gates ran*.
- **`run-state.json`** — mutable position snapshot. Rewritten after every wave and every crew pass. Source of truth for *where in the queue we are*.

Different shapes, different jobs: the jsonl is a log you append, the json is a snapshot you overwrite. Write `run-state.json` **atomically** — write `run-state.json.tmp`, then `mv` it over `run-state.json` — so a crash mid-write never leaves a half-file. Write it BEFORE acting on the budget governor or crew trigger (step 2c), so a halt still leaves a resumable snapshot.

```json
{
  "goal": "<scope's goal restatement>",
  "sizing": "full-orchestration",
  "queue": [
    { "wave": 1, "candidate": "...", "status": "shipped", "commit": "abc1234" },
    { "wave": 2, "candidate": "...", "status": "pending", "commit": null }
  ],
  "counters": {
    "waves_shipped": 1, "waves_since_crew": 1, "cumulative_files_changed": 6,
    "last_review_verdict": "clean",
    "total_waves": 1, "corrective_waves": 0, "consecutive_no_progress": 0
  },
  "last_crew_wave": 0,
  "pr": { "number": 214, "url": "...", "state": "draft" }
}
```

Resume mode (`/loop-de-looper resume`):

- **Primary**: read `run-state.json`. Branch matches + file present → trust it for queue, counters, PR, last-crew. Reconcile `last_crew_wave` against `gates.jsonl` crew entries (jsonl wins on any disagreement about *what ran*).
- **Fallback only** (file missing / corrupt / pre-snapshot run): re-derive as before — re-run scope, diff `git log main..HEAD` for shipped waves, re-derive counters from git stat, grep commit messages for last crew. Lossy; the snapshot exists so this is the exception, not the path.

## Budget governor

The wave queue is bounded (scope caps it ≤15), but **corrective waves are not** — a crew blocker spawns a fix wave, which can spawn another. That churn, not the queue, is the runaway shape. The governor rails on what the orchestrator can actually observe (wave counts, churn) — NOT token spend, which a Skill-driven orchestrator has no reliable way to meter. No fake gauge.

Evaluated in step 2c after `run-state.json` is written, before the crew trigger:

| Rail                       | Default | Hit → |
| -------------------------- | ------- | ----- |
| `max_total_waves`          | 25      | STOP + escalate: queue + corrective waves exceeded the ceiling |
| `max_corrective_waves`     | 6       | STOP + escalate: too many crew-blocker fixes; drift is structural, not patchable |
| `consecutive_no_progress`  | 3       | STOP + escalate: 3 waves running without shipping net-new queue work (thrash) |

Hitting a rail is a STOP, not a failure — same discipline as a scope refusal. The persisted `run-state.json` makes the halt resumable: surface the state report, let the user raise a ceiling or redirect, then `/loop-de-looper resume`.

Defaults are tunable per project — see the single canonical override block in `## Crew trigger + budget tuning`.

## Stop conditions

- **Nonbeliever STOP verdict**: goal hard-conflicts with CLAUDE.md/directive, smuggles a user-authority decision, or substitutes orchestrator judgment for a required gate → STOP before scope, surface nonbeliever output to user
- **Scope refuses goal**: open-ended, conflicts with rules, candidates all high-risk same-specialist → STOP, surface scope output to user
- **Plan stops**: research output ambiguous, mechanized infra missing, all recovery options fail → STOP, surface plan output
- **the-looper stops**: verify fails twice same root cause, review verdict `rethink`, gate not pre-flighted → STOP, surface agent output
- **Crew finds blocker requiring rollback**: drift past patchable → STOP, escalate to user (no auto-revert commits)
- **Budget governor rail hit**: `max_total_waves`, `max_corrective_waves`, or `consecutive_no_progress` exceeded → STOP, escalate with the persisted state report (`## Budget governor`). Resumable after the user raises a ceiling or redirects.
- **Queue exhausted, required-not-loopable items remain**: surface explicit list, await user action
- **User intervenes**: any user message during run = stop signal; current wave completes, then halt

Stopping not failure. Looping past known blocker = failure. Looping past a budget rail = failure.

## What loop-de-looper does NOT do

- Does NOT execute waves directly. Inside a run, every wave goes through `the-looper`. No bypass. (The `inline` sizing is not an exception: there the loop never starts — it hands the one-liner back to the parent and exits, rather than running a wave itself.)
- Does NOT skip crew passes. Trigger fires → pass runs. No "trust the loop, ship anyway." (The `single-wave` sizing skips the crew *cadence* because there is no cumulative multi-wave drift to catch — one commit, one PR backstop. That is a sizing decision made up front by nonbeliever, not a mid-run "ship anyway.")
- Does NOT auto-revert commits when crew finds blocker. Surfaces, user decides.
- Does NOT silently swap specialist gates for built-in checks. `ESCALATE` fires from plan → orchestrator invokes specialist; no "I checked it myself."
- Does NOT record a gate as passed when it didn't run. Task tool unavailable or agent never invoked → `gates.jsonl` logs `ran: false`, and the final report says the gate did not run. No invented verdicts, no prose-only gate claims.
- Does NOT flip draft PR to ready-for-review. User decision per `looper-commit` spec. But DOES create the draft (wave 1, or termination backstop) — creating ≠ flipping.
- Does NOT declare goal-complete with committed work and no PR. PR finalization (Step 4) is mandatory on every termination path.
- Does NOT defer PR creation to "the end" with no owner, and does NOT bundle "no PR" with "don't flip to ready" in a brief. See `## PR lifecycle + push ownership`.
- Does NOT re-scope mid-run. Goal shifts → user issues new run with new goal.
- Does NOT loop unbounded. The budget governor caps total waves, corrective waves, and no-progress thrash; a rail hit is a STOP, not a "push through." It does NOT meter token spend — that gauge isn't readable from a Skill orchestrator, so it rails only on what it can observe.
- Does NOT keep run state only in-context. Queue + counters persist to `run-state.json` (atomic write) every wave, so a compacted or crashed run stays resumable; in-context is a cache of the file, not the source of truth.
- Does NOT skip nonbeliever pre-flight, and does NOT halt on a mere challenge. Only a nonbeliever STOP verdict halts; PROCEED-WITH-NOTES carries notes into scope.
- Does NOT skip run-level learn on a success path. It is the only step that diagnoses the orchestration itself; per-wave learn can't see past its own wave. But run-level learn only WRITES lessons (skill/agent/memory edits) — it does NOT gate, flip, revert, or re-open the run.
- Does NOT let recap decide, fix, or flip anything, and does NOT let it replace the structured exit report. Recap is read-only narration layered on top; its facts trace to `gates.jsonl` / git log, never invented.

## Crew trigger + budget tuning

Crew-trigger defaults: every 4 waves OR 30 cumulative file changes, whichever first. Budget governor defaults: `max_total_waves=25`, `max_corrective_waves=6`, `consecutive_no_progress=3` (see `## Budget governor`).

Single canonical override block in the project CLAUDE.md:

```
## Loop de Looper
- crew-trigger: waves=N, files=M
- budget: max-waves=N, max-corrective=N, no-progress=N
```

Tighter triggers + budgets for high-drift domains (palette, auth surface) where churn signals a wrong approach early. Looser for long mechanical cleanup loops that legitimately run many waves.

## Voice + style

Reports to user: structured, scannable. Per-wave status line. Crew pass summary. Final state report. Match lean voice of `looper-commit` and `looper-learn`.

Cite agent outputs verbatim when surfacing blockers; no paraphrase. Per memory `[[feedback-verify-upstream-gate-claims]]` and `[[feedback-task-tool-availability]]`, orchestrator's job = surface signal, not summarize away.

## Integration prerequisites

Met as of integration pass:

1. ✓ `the-looper` agent: protocol expanded to include plan step (1.5). Hand-back format adds `gate needed pre-build` field for plan-surfaced escalations.
2. ✓ `looper-build`: pre-build gates section reframed. Plan absorbed deterministic portion; specialists fire only on ESCALATE.
3. ✓ Crew agents present at `~/Developer/Repos/agents-of-shield-if-shield-is-ai/agents/`: `the-auditor`, `the-chemist`, `the-chronicler`, `the-diamantaire`, `the-improver`, `the-stickler`.

Loop de Looper ready for end-to-end exercise.
