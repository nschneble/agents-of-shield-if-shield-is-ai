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
- **Executor-writability pre-flight.** Before queueing waves that write a given directory, confirm `the-looper` (a SUBAGENT) can actually write there. Some projects gate subagent writes to UI dirs (e.g. a `.tsx`/`components/` write-gate or a permission allowlist) — invisible to a main-agent check, since the gate is subagent-scoped. A queue full of waves the executor cannot write turns every wave into an unclearable escalation (the specialist that would "clear" it has no Write tool either — see Step 2b). Probe once (or read project memory for a known gate); if the executor is gated out of the target dir, surface to the user BEFORE burning a pilot dispatch, and consider a non-gated target or a main-agent-build fallback.

Scope stop conditions fire → Loop de Looper stops. Do NOT improvise around scope refusal.

### Step 2: Per-wave loop

For each wave in queue, in order:

#### 2a. Dispatch the-looper

**Stale-candidate pre-check (cheap, before the dispatch).** Scope builds the queue ONCE up front; by a later wave an earlier wave may have already renamed, deleted, or fixed what this wave targets. A full `the-looper` dispatch is expensive — don't spend one to hand back "nothing here / file gone." Before dispatching, run a cheap glob/grep: do the candidate's target files still exist, and do they still exhibit the thing the wave addresses? This mirrors ComPilot's two-stage check (a lightweight filter ahead of the costly compiler call). If the candidate is stale → mark the queue item `status: "skipped-stale"` with the reason, log it (`gates.jsonl`, `kind: "stale-skip"`), and move to the next wave. Do NOT escalate — a stale candidate is already-handled work, not a blocker. Distinguish from a real miss: skip only when the target is provably gone or already-satisfied, not merely when a path moved (a moved target is a re-point, still a live wave). A stale-skip is NOT a no-progress event — no `the-looper` ran, so it never touches `consecutive_no_progress`; it's benign queue hygiene, not thrash.

Invoke `the-looper` agent via Task tool. Pass wave brief from scope's queue + project target (branch name, PR number).

`the-looper` runs full protocol internally: research → plan → build → verify → review → learn → commit. Returns hand-back report (`shipped`, `deferred`, `gate needed pre-build`, `gates needed post-build`, `ranked alternates`, `learn`, `flags`).

**Brief authoring — PR + push directives.** Every wave brief carries two SEPARATE flags. Never bundle them into one "No PR, nothing flipped to ready" phrase — that conflation collapses two different actions and orphaned PR creation in a real run (every wave deferred PR to "the end," and the end had no PR action, so none was ever created). See `## PR lifecycle + push ownership`.

- `pr:` — `create-on-wave-1` (default on a fresh multi-wave branch) | `existing #N` (every wave once the PR exists) | `skip` (explicit, rare — throwaway spike). "Don't flip to ready-for-review" is NOT a `pr:` value; the draft is still created.
- `target.push: true` — on EVERY wave of an orchestrated run. PR creation and a current remote both require the branch pushed. The orchestrator owns push timing (per `looper-commit`); its default-off is for standalone use, so the orchestrator must set this explicitly.

#### 2b. Handle escalation (if any)

If hand-back contains `gate needed pre-build`, FIRST classify the gate — they are not all the same kind:

- **Design gate** (a judgment a specialist supplies: palette/contrast values, threat model, ARIA contract). A specialist CLEARS it by producing the missing judgment. Route to the named specialist below.
- **Tooling gate** (a write-block / permission denial / missing credential the executor hit). A specialist CANNOT clear it — `accessibility-lead` and the review crew have Read/Glob/Grep/Task but **no Write tool**, so invoking one to "clear" a write-gate accomplishes nothing. A tooling gate is a USER decision (exempt the executor, change the target, or accept a main-agent-build fallback). Escalate to the user immediately; do NOT round-trip a specialist that can't resolve it. Log the gate `ran: false` with the tooling reason.

For a design gate:

1. Invoke named specialist (e.g. `accessibility-agents:accessibility-lead`) via Task tool with input the-looper specified
2. Append specialist output to brief as `gate outputs`
3. Re-dispatch the-looper with updated brief. the-looper sees `gate outputs` populated, skips plan, resumes at build.

Record each pre-build specialist gate in the wave's gate artifact (see `## Gate artifacts`): which specialist, ran-vs-unavailable, verdict. A specialist gate the-looper *requested* but the orchestrator could not actually invoke (no Task tool) must be logged as `available: false` — never recorded as passed.

Repeat 2b only until escalation cleared. Same specialist gate requested twice for same wave → STOP, escalate to user (palette / architecture decision needed beyond specialist resolve).

**Pre-mandated gates fire up-front, not via a round-trip.** When `looper-scope` already tagged a wave with a required specialist gate (e.g. a mandatory accessibility-lead contract on a hover/press viewer), the orchestrator invokes that specialist BEFORE dispatching `the-looper`, and ships the contract as `gate outputs` in the first brief — so the wave skips plan and builds directly. Do NOT dispatch `the-looper` only to have its plan re-discover the known gate and hand back `gate needed pre-build`; that round-trip burns a full dispatch to surface what scope already declared. The reactive 2b path above is for gates the plan discovers that scope did NOT foresee. If the specialist returns open design decisions that are implementation specifics inside the user's already-stated design (clip strategy, control reuse, caption copy), the orchestrator resolves them on the specialist's recommended defaults — these are not user-authority scope changes. A decision that genuinely re-opens scope (changes what the feature does) still goes to the user.

Other stop conditions from the-looper (verify fails twice, review verdict `rethink`, etc) do NOT bubble straight up — a *retryable* one earns ONE from-scratch retry first (see 2b-retry). Do NOT swallow either way: a retry that fails again bubbles up unchanged.

#### 2b-retry. Stuck-wave retry-from-scratch (one shot, bounded)

Before bubbling a **retryable** the-looper stop up to Step 4, attempt EXACTLY ONE fresh-context re-dispatch. This is the loop-engineering "restart to escape a local optimum" move: an agent stuck after repeated failures escapes more often from a clean restart than from more turns on a rotted context (the ComPilot study's multi-run finding — a from-scratch dialogue beats continued exploration on a wedged one). "From scratch" here means fresh CONTEXT — a clean re-dispatch that drops the rotted transcript — NOT a freshly-improvised plan (mechanic 2 below: revert to the next ranked alternate, improvise only when none exists).

**Retryable** (non-deterministic — a fresh attempt can plausibly differ):

- `verify fails twice` on the same root cause
- review verdict `rethink`
- a wave that tripped `consecutive_no_progress` (shipped nothing / re-opened the same blocker)

**NOT retryable** (deterministic — a retry hits the same wall and burns a dispatch): tooling gate / write-block / permission denial (2b above), nonbeliever STOP, scope refusal, a budget governor rail, or a design `gate needed pre-build` (that is the 2b specialist path, not a retry). These bubble up immediately.

Mechanics:

1. **Fresh agent, not a resume.** Re-dispatch `the-looper` with NEW context — the whole point is to drop the rotted context and the failed path. A resume re-feeds the dead end and reproduces the failure.
2. **Directed, not blind — revert to the next ranked plan first.** The retry brief carries a `prior attempt failed:` note — the failure mode in one line (e.g. "verify failed twice on null-deref in `X`; prior approach tiled via `Y`"). For the new strategy, the retry FIRST reverts to the next-highest-ranked alternate plan the wave's `looper-plan` emitted (its `## Ranked alternate plans` list, surfaced in the stuck hand-back), if one exists — that fallback was vetted against the same constraints, exit criteria, and mechanized predictions while the research context was fresh, so the one shot is spent on a pre-vetted approach, not a cold guess. This is MapCoder's move (ACL 2024): on failure, revert to the next-highest-confidence plan rather than re-running the failed one. Only when the plan emitted NO ranked alternate — a trivial wave, or one with a single viable approach — does the retry improvise a DIFFERENT strategy from the failure signal. Either way pass the `prior attempt failed:` note: restarting with zero memory of why the last attempt died wastes the retry.
3. **One shot.** Best-of-2, no more. A second stuck hand-back on the SAME wave bubbles to Step 4 and escalates to the user. No third attempt.
4. **Log it.** Append a `kind: "wave-retry"` event to `gates.jsonl` (wave, original failure mode, retry outcome) — auditable like any gate. A retry that the orchestrator could not actually dispatch (no Task tool) logs `ran: false`, same discipline as `## Gate artifacts`.
5. **Counters.** A retry dispatch increments `total_waves` and `wave_retries` (never reset — budget input). It does NOT increment `corrective_waves` (those are crew-blocker fixes, a different cause). A retry that ships net-new work resets `consecutive_no_progress`; a retry that fails again counts toward it.

#### 2b-flags. Triage cross-file flags before advancing

A wave can SHIP clean yet hand back a `flag` that names a **cross-file incompleteness** — it introduced a reference (to a field, section, contract, or channel in ANOTHER file) that does not exist yet, or left a sibling file needing a matching change. Do NOT let that ride to the crew pass. A flag that says "X references Y, but Y isn't defined" is a known defect the moment it's reported; deferring it converts a one-line fix into a crew BLOCKER plus a full corrective wave plus a re-crew (observed: a ranked-alternates hand-back field referenced by three files but defined in none rode from its wave to the final crew, costing exactly that churn).

On every shipped wave, read the hand-back `flags` before dispatching the next wave:

- **Cross-file incompleteness** (a dangling reference the wave itself created) → action it NOW: if a later queued wave already touches the named file, fold the fix into that wave's brief; otherwise spawn an immediate corrective wave for it. Either way it is resolved before the crew sees it.
- **Out-of-scope observation** (a pre-existing issue the wave noticed but didn't cause) → capture for a future scope run; do not action mid-run.

The test is causation + reachability: did THIS wave create the dangling reference, and can a queued/cheap wave close it? Yes → triage now. A flag about something the run never touched is not this case.

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
| `wave_retries`             | +1 on each stuck-wave from-scratch retry dispatch (2b-retry); never reset — budget governor input |

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

Each agent gets cumulative diff since last crew pass (or, for the final crew, since the run's own first wave commit). Scope the diff to THIS run's commits, NOT blindly `main..HEAD`: a branch handed to the orchestrator mid-flight already carries unrelated pre-run work, so `main..HEAD` drags in commits the run never touched and drowns the crew in out-of-scope findings. Derive the base as the parent of wave 1's commit (`git diff <wave1>^..HEAD`); only a branch forked fresh for this run makes that equal `main..HEAD`. Findings categorized:

- **Blocker**: must fix before continuing (interim) or before goal-complete (final)
- **Warning**: should fix; track count for warning-saturation trigger
- **Nit**: capture for future scope run; no loop back

Blockers found → loop back: produce mini-brief for blocker fixes, invoke `the-looper` for one corrective wave, re-run crew on fix. No "ship anyway" path.

Re-crew scope follows the corrective diff, not ceremony. Re-run the agents whose findings the fix targeted (they confirm CLEARED), plus any agent whose domain the corrective diff actually touched. An agent that was clean AND whose domain the fix never entered need not re-run — e.g. a docs+test corrective wave that only deletes a dead attribute from the runtime path doesn't re-summon the correctness/a11y reviewers, provided the byte-identical/behavior-unchanged claim is verified (by the wave's own tests or a finding-agent). State which agents you re-ran and why; do NOT silently drop a clean agent whose domain the fix DID touch.

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
    "total_waves": 1, "corrective_waves": 0, "consecutive_no_progress": 0,
    "wave_retries": 0
  },
  "last_crew_wave": 0,
  "pr": { "number": 214, "url": "...", "state": "draft" }
}
```

Resume mode (`/loop-de-looper resume`):

- **Primary**: read `run-state.json`. Branch matches + file present → trust it for queue, counters, PR, last-crew. Reconcile `last_crew_wave` against `gates.jsonl` crew entries (jsonl wins on any disagreement about *what ran*).
- **Fallback only** (file missing / corrupt / pre-snapshot run): re-derive as before — re-run scope, diff `git log main..HEAD` for shipped waves, re-derive counters from git stat, grep commit messages for last crew. Lossy; the snapshot exists so this is the exception, not the path.

## Budget governor

The wave queue is bounded (scope caps it ≤15), but **corrective waves and stuck-wave retries are not** — a crew blocker spawns a fix wave, which can spawn another, and each retryable stop spends a from-scratch retry. That churn, not the queue, is the runaway shape. The governor rails on what the orchestrator can actually observe (wave counts, churn) — NOT token spend, which a Skill-driven orchestrator has no reliable way to meter. No fake gauge.

Evaluated in step 2c after `run-state.json` is written, before the crew trigger:

| Rail                       | Default | Hit → |
| -------------------------- | ------- | ----- |
| `max_total_waves`          | 25      | STOP + escalate: queue + corrective waves exceeded the ceiling |
| `max_corrective_waves`     | 6       | STOP + escalate: too many crew-blocker fixes; drift is structural, not patchable |
| `consecutive_no_progress`  | 3       | STOP + escalate: 3 waves running without shipping net-new queue work (thrash) |
| `max_wave_retries`         | 4       | STOP + escalate: too many waves needed a from-scratch retry; the goal is systematically too hard for the executor, not a one-off wedge |

Hitting a rail is a STOP, not a failure — same discipline as a scope refusal. The persisted `run-state.json` makes the halt resumable: surface the state report, let the user raise a ceiling or redirect, then `/loop-de-looper resume`.

Defaults are tunable per project — see the single canonical override block in `## Crew trigger + budget tuning`.

## Stop conditions

- **Nonbeliever STOP verdict**: goal hard-conflicts with CLAUDE.md/directive, smuggles a user-authority decision, or substitutes orchestrator judgment for a required gate → STOP before scope, surface nonbeliever output to user
- **Scope refuses goal**: open-ended, conflicts with rules, candidates all high-risk same-specialist → STOP, surface scope output to user
- **Plan stops**: research output ambiguous, mechanized infra missing, all recovery options fail → STOP, surface plan output
- **the-looper stops**: verify fails twice same root cause, review verdict `rethink`, gate not pre-flighted → ONE from-scratch retry first if the stop is retryable (`## Protocol` 2b-retry); STOP and surface agent output only after the retry also fails (or immediately, for a non-retryable stop)
- **Crew finds blocker requiring rollback**: drift past patchable → STOP, escalate to user (no auto-revert commits)
- **Budget governor rail hit**: `max_total_waves`, `max_corrective_waves`, `consecutive_no_progress`, or `max_wave_retries` exceeded → STOP, escalate with the persisted state report (`## Budget governor`). Resumable after the user raises a ceiling or redirects.
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
- Does NOT loop unbounded. The budget governor caps total waves, corrective waves, no-progress thrash, AND from-scratch retries; a rail hit is a STOP, not a "push through." It does NOT meter token spend — that gauge isn't readable from a Skill orchestrator, so it rails only on what it can observe.
- Does NOT defer a wave's cross-file-incompleteness flag to the crew pass. A shipped wave that flags a dangling reference it created (a field/section/contract named but not defined) gets triaged immediately — folded into a later wave's brief or fixed in an immediate corrective — not ridden to the crew where it surfaces as a blocker (`## Protocol` 2b-flags).
- Does NOT retry a deterministic stop. A write-gate, a governor rail, a scope refusal hits the same wall every time — those bubble up immediately. Only a non-deterministic stop (verify-twice, `rethink`, no-progress) earns a from-scratch retry, and never more than ONCE per wave (`## Protocol` 2b-retry). A retry is a fresh-context re-dispatch, never a resume of the wedged attempt — reverting to the next pre-ranked plan from `looper-plan` when one exists, improvising only when none does.
- Does NOT keep run state only in-context. Queue + counters persist to `run-state.json` (atomic write) every wave, so a compacted or crashed run stays resumable; in-context is a cache of the file, not the source of truth.
- Does NOT skip nonbeliever pre-flight, and does NOT halt on a mere challenge. Only a nonbeliever STOP verdict halts; PROCEED-WITH-NOTES carries notes into scope.
- Does NOT skip run-level learn on a success path. It is the only step that diagnoses the orchestration itself; per-wave learn can't see past its own wave. But run-level learn only WRITES lessons (skill/agent/memory edits) — it does NOT gate, flip, revert, or re-open the run.
- Does NOT let recap decide, fix, or flip anything, and does NOT let it replace the structured exit report. Recap is read-only narration layered on top; its facts trace to `gates.jsonl` / git log, never invented.

## Crew trigger + budget tuning

Crew-trigger defaults: every 4 waves OR 30 cumulative file changes, whichever first. Budget governor defaults: `max_total_waves=25`, `max_corrective_waves=6`, `consecutive_no_progress=3`, `max_wave_retries=4` (see `## Budget governor`).

Single canonical override block in the project CLAUDE.md:

```
## Loop de Looper
- crew-trigger: waves=N, files=M
- budget: max-waves=N, max-corrective=N, no-progress=N, max-retries=N
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
