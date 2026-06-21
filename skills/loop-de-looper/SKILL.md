---
name: loop-de-looper
description: Orchestrator for multi-wave goals. Composes looper-scope (queue) + looper-plan (per-wave brief) + the-looper agent (per-wave executor) + crew (periodic + final). Trigger when the user says "loop de looper", "run all the waves", "autonomous loop", or hands a multi-wave goal expecting hands-off execution.
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

`looper-scope`, `looper-plan` (invoked inside the-looper), `the-looper` already exist. Crew = `the-auditor`, `the-chemist`, `the-chronicler`, `the-diamantaire`, `the-improver`, `the-stickler`: six agents invoked in parallel via Task tool per memory `[[the-crew-agent-group]]`.

## Inputs

1. **Goal**: raw user input. Single sentence to single paragraph.
2. **PR context (optional)**: existing PR number if updating draft. `gh pr view <N>` body becomes scope input.
3. **Resume flag (optional)**: `resume` to continue prior run. Re-runs scope (queue derived from current git state + memory), skips waves whose commit hash already present.

## Protocol

### Step 1: Scope (once per run)

Invoke `looper-scope` via Skill tool. Pass goal + PR context.

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

#### 2b. Handle escalation (if any)

If hand-back contains `gate needed pre-build`:

1. Invoke named specialist (e.g. `accessibility-agents:accessibility-lead`) via Task tool with input the-looper specified
2. Append specialist output to brief as `gate outputs`
3. Re-dispatch the-looper with updated brief. the-looper sees `gate outputs` populated, skips plan, resumes at build.

Record each pre-build specialist gate in the wave's gate artifact (see `## Gate artifacts`): which specialist, ran-vs-unavailable, verdict. A specialist gate the-looper *requested* but the orchestrator could not actually invoke (no Task tool) must be logged as `available: false` — never recorded as passed.

Repeat 2b only until escalation cleared. Same specialist gate requested twice for same wave → STOP, escalate to user (palette / architecture decision needed beyond specialist resolve).

Other stop conditions from the-looper (verify fails twice, review verdict `rethink`, etc) bubble up to Loop de Looper. Do NOT swallow.

#### 2c. Update counters

Maintain in-context state:

| Counter                    | Updated when                                                                        |
| -------------------------- | ----------------------------------------------------------------------------------- |
| `waves_shipped`            | wave commit succeeds                                                                |
| `waves_since_crew`         | every wave; reset on crew pass                                                      |
| `cumulative_files_changed` | sum of `files changed` from `git diff --stat` for shipped waves; reset on crew pass |
| `last_review_verdict`      | from the-looper's review step                                                       |

Counters in-context only (v1). Resume mode re-derives from git log.

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

Reset counters after crew pass clean.

### Step 4: Termination

Loop terminates when:

1. **All wave queue items shipped** AND **final crew pass clean** AND **section 5 empty** → goal-complete success path
2. **Stop condition fired** at any layer → escalate to user with state report
3. **All wave queue items shipped** AND **final crew pass clean** AND **section 5 non-empty** → cannot self-complete; surface to user with explicit list

For path 3 (release-readiness goals typically), order fixed:

1. Run final crew pass FIRST (against cumulative loopable work)
2. Then report to user with bundle:
   - Loopable waves shipped (list)
   - Final crew result (pass / pass-with-nits / blockers)
   - Required-not-loopable items still blocking (list from scope section 5)
   - Recommended user actions (each line)

Final crew runs before surfacing required-not-loopable so user gets verified loopable work + open human gates in one report, not two round-trips.

User executes section-5 items, returns; Loop de Looper declares goal-complete (or resumes if user introduced new state during human gates).

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

## State tracking (v1: in-context)

Loop de Looper holds queue + counters in parent's working memory. The ONE exception to "no file persistence" is the gate artifact above (`local/loops/<branch>/gates.jsonl`) — counters and queue stay in-context, gate records go to disk because they must outlive the run for audit. Resume mode appends to the existing `gates.jsonl`.

Resume mode (`/loop-de-looper resume`) re-derives state:

- Queue: re-run scope, diff against `git log main..HEAD` to find shipped waves
- Counters: re-derive from git stat output
- Last crew pass: grep for "crew pass" in recent commit messages

Persistence (v2): write state JSON to `local/loops/<run-id>.json` after each step. Out of scope for v1.

## Stop conditions

- **Scope refuses goal**: open-ended, conflicts with rules, candidates all high-risk same-specialist → STOP, surface scope output to user
- **Plan stops**: research output ambiguous, mechanized infra missing, all recovery options fail → STOP, surface plan output
- **the-looper stops**: verify fails twice same root cause, review verdict `rethink`, gate not pre-flighted → STOP, surface agent output
- **Crew finds blocker requiring rollback**: drift past patchable → STOP, escalate to user (no auto-revert commits)
- **Queue exhausted, required-not-loopable items remain**: surface explicit list, await user action
- **User intervenes**: any user message during run = stop signal; current wave completes, then halt

Stopping not failure. Looping past known blocker = failure.

## What loop-de-looper does NOT do

- Does NOT execute waves directly. Dispatches `the-looper`. No bypass.
- Does NOT skip crew passes. Trigger fires → pass runs. No "trust the loop, ship anyway."
- Does NOT auto-revert commits when crew finds blocker. Surfaces, user decides.
- Does NOT silently swap specialist gates for built-in checks. `ESCALATE` fires from plan → orchestrator invokes specialist; no "I checked it myself."
- Does NOT record a gate as passed when it didn't run. Task tool unavailable or agent never invoked → `gates.jsonl` logs `ran: false`, and the final report says the gate did not run. No invented verdicts, no prose-only gate claims.
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

Reports to user: structured, scannable. Per-wave status line. Crew pass summary. Final state report. Match lean voice of `looper-commit` and `looper-learn`.

Cite agent outputs verbatim when surfacing blockers; no paraphrase. Per memory `[[feedback-verify-upstream-gate-claims]]` and `[[feedback-task-tool-availability]]`, orchestrator's job = surface signal, not summarize away.

## Integration prerequisites

Met as of integration pass:

1. ✓ `the-looper` agent: protocol expanded to include plan step (1.5). Hand-back format adds `gate needed pre-build` field for plan-surfaced escalations.
2. ✓ `looper-build`: pre-build gates section reframed. Plan absorbed deterministic portion; specialists fire only on ESCALATE.
3. ✓ Crew agents present at `~/Developer/Repos/agents-of-shield-if-shield-is-ai/agents/`: `the-auditor`, `the-chemist`, `the-chronicler`, `the-diamantaire`, `the-improver`, `the-stickler`.

Loop de Looper ready for end-to-end exercise.
