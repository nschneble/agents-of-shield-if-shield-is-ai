---
name: loop-de-looper
description: Orchestrator for multi-wave goals. Composes looper-scope (queue) + looper-plan (per-wave brief) + the-looper agent (per-wave executor) + crew (periodic + final). Trigger when the user says "loop de looper", "run all the waves", "autonomous loop", or hands a multi-wave goal expecting hands-off execution.
---

Parent orchestrator. Input = raw goal. Output = goal-complete or escalation. Composes existing pieces — does not re-invent them.

Loop de Looper does NOT execute waves directly. It dispatches `the-looper` agent per wave; the-looper runs the full wave protocol internally (research → plan → build → verify → review → learn). Crew passes scheduled at trigger points by `loop-de-looper` itself. Orchestrator is the parent — the entity invoking this skill — not a separate agent.

## Why exists

User hands a multi-wave goal ("finish theme refactor", "harden auth boundary"). Without an orchestrator:

- Each wave requires manual queue management (which candidate next?)
- Each wave requires manual brief construction (which files, which contracts?)
- Crew passes get skipped (drift accumulates silently) or run per-wave (slow, wasted parallelism)
- Termination is ad-hoc (when is goal done?)

Loop de Looper formalizes the protocol so the parent runs goal → done without per-wave human intervention, while preserving safety gates (specialist escalation, crew passes, stop conditions).

## Composition

```
loop-de-looper(goal)
├── looper-scope(goal)                        → wave queue + exit criteria + required-not-loopable items
└── for each wave in queue:
    ├── the-looper agent(wave brief)          → runs research → plan → build → verify → review → learn → commit
    │      └── if plan emits ESCALATE:        agent stops, hand-back has `gate needed pre-build`
    │            ├── orchestrator invokes specialist via Task tool
    │            ├── orchestrator appends `gate outputs` to brief
    │            └── re-dispatch the-looper (resumes at build, skips plan)
    ├── update counters (waves shipped, cumulative blast radius)
    └── if crew_trigger():
        └── crew pass(branch state)           → blocker / warning / nit findings; loop back if blockers
└── final crew pass(cumulative branch)        → before declaring goal-complete
└── report exit state to user
```

`looper-scope`, `looper-plan` (invoked inside the-looper), `the-looper` already exist. Crew = `the-auditor`, `the-chemist`, `the-chronicler`, `the-diamantaire`, `the-improver`, `the-stickler` — six agents invoked in parallel via Task tool per memory `[[the-crew-agent-group]]`.

## Inputs

1. **Goal** — raw user input. Single sentence to single paragraph.
2. **PR context (optional)** — existing PR number if updating a draft. `gh pr view <N>` body becomes scope input.
3. **Resume flag (optional)** — `resume` to continue a prior run. Re-runs scope (queue derived from current git state + memory), skips waves whose commit hash already present.

## Protocol

### Step 1: Scope (once per run)

Invoke `looper-scope` via Skill tool. Pass goal + PR context.

Scope produces 8-section output. Loop de Looper validates:

- Goal restatement matches user intent (orchestrator surfaces to user if drift suspected)
- Classification is non-REFUSE (open-ended goals → scope refuses → Loop de Looper stops)
- Wave queue non-empty (empty queue → goal already met → report + stop)
- `Required, not loopable` items captured (surfaced to user at end, never silently skipped)

If scope's stop conditions fire → Loop de Looper stops. Do NOT improvise around scope's refusal.

### Step 2: Per-wave loop

For each wave in queue, in order:

#### 2a. Dispatch the-looper

Invoke `the-looper` agent via Task tool. Pass wave brief from scope's queue + project target (branch name, PR number).

`the-looper` runs its full protocol internally: research → plan → build → verify → review → learn → commit. Returns hand-back report (`shipped`, `deferred`, `gate needed pre-build`, `gates needed post-build`, `learn`, `flags`).

#### 2b. Handle escalation (if any)

If hand-back contains `gate needed pre-build`:

1. Invoke named specialist (e.g. `accessibility-agents:accessibility-lead`) via Task tool with input the-looper specified
2. Append specialist output to brief as `gate outputs`
3. Re-dispatch the-looper with updated brief. the-looper sees `gate outputs` populated, skips plan, resumes at build.

Repeat 2b only until escalation cleared. Same specialist gate requested twice for same wave → STOP, escalate to user (palette / architecture decision needed beyond what specialist can resolve).

Other stop conditions from the-looper (verify fails twice, review verdict `rethink`, etc) bubble up to Loop de Looper. Do NOT swallow them.

#### 2c. Update counters

Maintain in-context state:

| Counter                    | Updated when                                                                        |
| -------------------------- | ----------------------------------------------------------------------------------- |
| `waves_shipped`            | wave commit succeeds                                                                |
| `waves_since_crew`         | every wave; reset on crew pass                                                      |
| `cumulative_files_changed` | sum of `files changed` from `git diff --stat` for shipped waves; reset on crew pass |
| `last_review_verdict`      | from the-looper's review step                                                       |

Counters in-context only (v1). Resume mode re-derives them from git log.

#### 2d. Crew trigger check

After every wave, evaluate trigger:

- `waves_since_crew >= 4` OR
- `cumulative_files_changed >= 30` OR
- `last_review_verdict == warning-saturated` (multiple consecutive warnings across waves)

Trigger fires → invoke crew (step 3). Threshold tunable per project via CLAUDE.md override; defaults above.

### Step 3: Crew pass (interim OR final)

Invoke six crew agents in parallel via Task tool (one Task call per agent, same message):

- `the-auditor` — a11y audit on cumulative diff
- `the-chemist` — test coverage on cumulative diff
- `the-chronicler` — doc drift on cumulative diff
- `the-diamantaire` — expert correctness review
- `the-improver` — refactor opportunities
- `the-stickler` — convention conformance

Each agent gets cumulative diff since last crew pass (or since `main` for final crew). Findings categorized:

- **Blocker** — must fix before continuing (interim) or before goal-complete (final)
- **Warning** — should fix; track count for warning-saturation trigger
- **Nit** — capture for future scope run; do not loop back

Blockers found → loop back: produce mini-brief for blocker fixes, invoke `the-looper` for one corrective wave, re-run crew on the fix. No "ship anyway" path.

Reset counters after crew pass clean.

### Step 4: Termination

Loop terminates when:

1. **All wave queue items shipped** AND **final crew pass clean** AND **section 5 empty** → goal-complete success path
2. **Stop condition fired** at any layer → escalate to user with state report
3. **All wave queue items shipped** AND **final crew pass clean** AND **section 5 non-empty** → cannot self-complete; surface to user with explicit list

For path 3 (release-readiness goals typically), order is fixed:

1. Run final crew pass FIRST (against cumulative loopable work)
2. Then report to user with the bundle:
   - Loopable waves shipped (list)
   - Final crew result (pass / pass-with-nits / blockers)
   - Required-not-loopable items still blocking (list from scope section 5)
   - Recommended user actions (each line)

Final crew runs before surfacing required-not-loopable so user gets verified loopable work + open human gates in one report — not two round-trips.

User executes section-5 items, returns; Loop de Looper declares goal-complete (or resumes if user introduced new state during human gates).

## State tracking (v1: in-context)

Loop de Looper holds queue + counters in parent's working memory. No file persistence.

Resume mode (`/loop-de-looper resume`) re-derives state:

- Queue: re-run scope, diff against `git log main..HEAD` to find shipped waves
- Counters: re-derive from git stat output
- Last crew pass: grep for "crew pass" in recent commit messages

Persistence (v2) — write state JSON to `local/loops/<run-id>.json` after each step. Out of scope for v1.

## Stop conditions

- **Scope refuses goal** — open-ended, conflicts with rules, candidates all high-risk same-specialist → STOP, surface scope output to user
- **Plan stops** — research output ambiguous, mechanized infra missing, all recovery options fail → STOP, surface plan output
- **the-looper stops** — verify fails twice same root cause, review verdict `rethink`, gate not pre-flighted → STOP, surface agent output
- **Crew finds blocker requiring rollback** — drift past patchable → STOP, escalate to user (do not auto-revert commits)
- **Queue exhausted, required-not-loopable items remain** — surface explicit list, await user action
- **User intervenes** — any user message during run is a stop signal; current wave completes, then halt

Stopping is not failure. Looping past a known blocker is failure.

## What loop-de-looper does NOT do

- Does NOT execute waves directly. Dispatches `the-looper`. No bypass.
- Does NOT skip crew passes. Trigger fires → pass runs. No "trust the loop, ship anyway."
- Does NOT auto-revert commits when crew finds blocker. Surfaces, user decides.
- Does NOT silently swap specialist gates for built-in checks. If `ESCALATE` fires from plan, orchestrator invokes specialist — no "I checked it myself."
- Does NOT flip draft PR to ready-for-review. User decision per `looper-commit` spec.
- Does NOT re-scope mid-run. Goal shifts → user issues new run with new goal.

## Crew trigger tuning

Defaults: every 4 waves OR 30 cumulative file changes, whichever first.

Project can override via CLAUDE.md:

```
## Loop de Looper
- crew-trigger: waves=N, files=M
```

Tighter triggers for high-drift domains (palette, auth surface). Looser for cleanup loops.

## Voice + style

Reports to user: structured, scannable. Per-wave status line. Crew pass summary. Final state report. Match the lean voice of `looper-commit` and `looper-learn`.

Cite agent outputs verbatim when surfacing blockers — do not paraphrase. Per memory `[[feedback-verify-upstream-gate-claims]]` and `[[feedback-task-tool-availability]]`, orchestrator's job is to surface signal, not summarize away.

## Integration prerequisites

Met as of integration pass:

1. ✓ `the-looper` agent: protocol expanded to include plan step (1.5). Hand-back format adds `gate needed pre-build` field for plan-surfaced escalations.
2. ✓ `looper-build`: pre-build gates section reframed. Plan absorbed deterministic portion; specialists fire only on ESCALATE.
3. ✓ Crew agents present at `~/Developer/Repos/agents-of-shield-if-shield-is-ai/agents/` — `the-auditor`, `the-chemist`, `the-chronicler`, `the-diamantaire`, `the-improver`, `the-stickler`.

Loop de Looper ready for end-to-end exercise.
