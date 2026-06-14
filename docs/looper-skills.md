# [Looper](agents/the-looper.md) skills

## Looper "build"

**File:** `skills/looper-build/SKILL.md`

**Trigger:** "Fix this bug" or "implement this feature"

Apply the plan brief as the smallest possible change. Quality gates before
done. Confirms the rung plan named. If rung 6 (custom) without
justification, stops and sends back to planning. If build reveals a lower
rung that satisfies the requirement, takes it and notes the downgrade.
**Pre-build specialist gates are non-negotiable but invoked only when
plan emits `ESCALATE`.** Plan absorbs the deterministic portion of each
domain check (mechanized contract tests, Squawk dry-run, caller-graph grep,
baseline measurement). Specialists invoked by the orchestrator only for the
residual judgment plan cannot mechanize:

| Touching                  | Plan handles (mechanized)                  | Specialist on ESCALATE                    |
| ------------------------- | ------------------------------------------ | ----------------------------------------- |
| Auth, permissions, tokens | Caller-graph grep, public API inventory    | Security review                           |
| Database migrations       | `npm run lint:migrations` (Squawk) dry-run | Migration-safety review                   |
| Themes, contrast          | Contract test dry-run via culori           | `accessibility-agents:accessibility-lead` |
| Web UI                    | axe / contrast dry-run                     | `accessibility-agents:accessibility-lead` |

Build branches on wave kind: code waves get the full `format → lint → test
→ build` sequence; non-code waves (PR body, docs, external config) take a
shorter validator path. No Bash bypass.

## Looper "commit"

**File:** `skills/looper-commit/SKILL.md`

**Trigger:** "Commit this wave", "create the PR", or "update the existing PR"

Final step of every wave. Always commits any code/doc changes. Auto-detects
PR state. If the branch has an existing PR, just commits to it; if no
existing PR, creates a draft assigned `@me`. External-state waves (PR body
refresh, GitHub release update) skip the commit but still confirm PR
context. Refuses if pre-flight fails (AC check, review verdict, lint/test/
build all passing, no stray untracked files). Never amends, never bypasses
hooks.

Renamed from `looper-pr` in framework v1.2. The commit is the load-bearing
action; PR creation is downstream of it.

## Looper "learn"

**File:** `skills/looper-learn/SKILL.md`

**Trigger:** "Reflect on this" or "remember what we just did here"

Run after a looper suite to capture reusable lessons. Diagnoses each step
and saves lessons at the right persistence layer; memory for
project-specific facts, CLAUDE.md for standing conventions, and agent or
skill definitions for behavioral constraints.

## Looper "plan"

**File:** `skills/looper-plan/SKILL.md`

**Trigger:** "Plan this wave", "spec the wave", or "what's the brief for this change?"

Tactical brief slotted between research and build. Converts research's
abstract constraints into a wave-specific contract: exact files, **named
rung** (1=YAGNI → 6=custom; latter requires justification), mechanized
predictions (run contract tests dry against proposed values), risk
register, recovery options pre-staged, exit criteria. Mechanizes the
deterministic portion of specialist judgment so the loop stays autonomous
unless real judgment is needed. Escalates the residual via explicit
`ESCALATE: <gate>` lines that the orchestrator routes to specialists
before resuming at build.

Added in framework v1.1.

## Looper "research"

**File:** `skills/looper-research/SKILL.md`

**Trigger:** "How do I fix this bug?", or "how do I build this?"

Produces a structured research report that gives looper-plan and looper-
build everything needed to ship without guessing. Layers project context,
authoritative domain references, and community sources. Challenges scope
before recommending the plan.

## Looper "review"

**File:** `skills/looper-review/SKILL.md`

**Trigger:** "Review this bugfix", or "review this feature"

Qualitative review, independent from build and verify. Question is not
"does it work" but "right shape, fits codebase, hidden costs?" Recommends
which specialist reviewers the orchestrator should invoke in parallel
via Task tool. Synthesizes findings.

## Looper "verify"

**File:** `skills/looper-verify/SKILL.md`

**Trigger:** "Verify this bugfix" or "confirm this feature works"

Functional verification only. Does the change do what the spec said?
Distinct from review, which is qualitative. Re-reads the original spec,
lists acceptance criteria, exercises the change against golden path and 2–3
edge cases. For UI changes it starts dev server, clicks through in browser,
and screenshots. For documentation / PR-body / config waves, reads the
resource back and confirms the change applied. Ensures type-checks and
tests pass. Doesn't auto-approve visual regression baselines.

---

## Orchestration skills

The above skills run per-wave inside `the-looper` agent. Two skills sit
above the wave loop to coordinate multi-wave goals:

### Looper "scope"

**File:** `skills/looper-scope/SKILL.md`

**Trigger:** "Scope this work", "plan the waves", or any goal spanning more than one loop

Strategic queue producer. Reads the raw goal + existing state, emits an
ordered list of candidate waves with risk tags + dependencies, and sets
the exit contract. Classifies goals across six shapes (single-wave bugfix,
feature increment, multi-file refactor, cross-cutting initiative,
release-readiness, open-ended). Open-ended goals are refused — bounded
scope is the deliverable. Output distinguishes `required, not loopable`
(human action gates) from `deferred to separate scope run` from
`out of goal scope`.

Added in framework v1.1.

### Loop de Looper

**File:** `skills/loop-de-looper/SKILL.md`

**Trigger:** "Loop de looper", "run all the waves", or any multi-wave goal expecting hands-off execution

Parent orchestrator. Composes looper-scope (queue) + the-looper (per-wave
executor) + the crew (periodic + final). The crew runs every 4 waves or
30 cumulative file changes (whichever first) interim, and once mandatory
before goal-complete. Blocker on crew loops back into a corrective wave;
no "ship anyway" path. Termination surfaces the loopable work shipped
alongside required-not-loopable items so the user gets verified work +
open human gates in one report.

Added in framework v1.1.

---

## The Flow

Per wave: Research → Plan → Build → Verify → Review → Learn → Commit

- Repeat research/plan/build/verify until the bug's fixed or feature's implemented
- Repeat review until satisfied
- Learn captures any lessons
- Commit lands the wave (and opens a draft PR if no existing PR for the branch)

Across waves: Scope → wave loop × N → final crew → terminate

The [Looper agent](agents/the-looper.md) drives the per-wave skills. Loop
de Looper orchestrates the multi-wave loop, invokes pre-build specialist
gates when plan emits `ESCALATE`, schedules crew passes at trigger points,
and reports terminal state to the user.
