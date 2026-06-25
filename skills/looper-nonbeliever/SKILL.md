---
name: looper-nonbeliever
description: Adversarial pre-flight. Argue with the orchestrator BEFORE scope — force it to justify the goal + intended approach against CLAUDE.md, existing agents, skills, and directives. Also sizes the goal (inline / single-wave / full-orchestration) so trivial asks skip the full loop. Trigger when the user says "challenge this", "play devil's advocate", "stress-test the goal", or runs before looper-scope inside Loop de Looper.
---

Skeptic gate. Runs ONCE, before `looper-scope`. Input = raw goal + intended approach. Two outputs: a **verdict** (make the orchestrator defend the run before any wave burns) and a **sizing** (how much loop the goal actually warrants). Argue, demand justification, check for contradiction, then YIELD — advisory by default, STOP only on hard conflict.

## Why exists

`looper-scope` refuses vague goals but can't catch the run that is well-formed yet *wrong* — it decomposes, it doesn't interrogate. Nonbeliever interrogates. Cheapest place to kill a bad run is before wave 1.

## Inputs

1. Raw goal (user input or orchestrator handoff)
2. Intended approach (orchestrator's one-paragraph plan: how it means to run this)
3. `CLAUDE.md` — every standing rule + hard constraint
4. Existing agents at `~/Developer/Repos/.../agents/` — names + descriptions
5. Existing skills (`skills/*/SKILL.md`) — names + descriptions
6. Active directives: hooks, system reminders, project memory `MEMORY.md` + `project-*` entries

## The interrogation

Generate challenges across four axes. For each, the orchestrator answers or folds.

| Axis             | Challenge it raises                                                  | Verdict on fold                       |
| ---------------- | ------------------------------------------------------------------- | ------------------------------------- |
| **Redundancy**   | "Skill/agent X already does this. Why a new wave queue?"            | can't name what the run adds → NOTES  |
| **Contradiction**| "CLAUDE.md rule R says the opposite. Why proceed?"                  | hard conflict, no override → STOP     |
| **Authority**    | "This decides scope/palette/architecture — the user's call."       | decision belongs to user → STOP       |
| **Approach**     | "A directive routes this to specialist S. Why self-check?"         | judgment substituted for gate → STOP  |

Cite the conflicting source VERBATIM — rule text, skill description, directive line. A challenge you can't trace to a real line is noise; drop it.

## Sizing

Second output, orthogonal to the verdict. Before any queue gets built, judge how much loop the goal warrants. The full orchestration — scope → per-wave research/plan/build/verify/review/learn → crew passes — is heavy. Swinging it at a one-line fix is its own waste, and nothing downstream self-selects down: `looper-scope` runs the same machinery on a single-wave bugfix as on a cross-cutting refactor. Sizing is the front-door that routes a misfiled small ask off the heavy path.

| Sizing                  | Goal shape                                                                                                  | Orchestrator routes to                                                            |
| ----------------------- | ---------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| **inline**              | Trivial, single understood change — typo, one-line fix, copy tweak, obvious rename. No design judgment, no gate. | Skip scope + the wave loop entirely. Do it inline (or hand back "do this inline"). |
| **single-wave**         | One coherent change a single loop ships end-to-end. Normal bug or small feature increment.                 | One `the-looper` dispatch; skip the scope queue + crew cadence.                   |
| **full-orchestration**  | Multi-wave: cross-cutting refactor, several co-dependent changes, anything needing a queue + drift control. | Proceed to `looper-scope` as normal.                                              |

Bias honestly. Most goals handed to Loop de Looper are genuinely multi-wave — that's why the user reached for it — so `full-orchestration` is the common case; the cheap-out paths exist only so a misfiled small ask doesn't pay full freight. Size by the work, not by how the user phrased it.

Vague is NOT small. A goal with no definition of done ("improve performance") is not `inline` — it is a **STOP** on the Authority axis: route the sizing question back to the user with bounded readings to pick from. Sizing labels work that is *understood and small*; it never silently shrinks work that is merely *unspecified*.

## Output

Two columns (challenge + orchestrator response) plus a verdict line.

```
CHALLENGE 1 [contradiction]: CLAUDE.md "<rule, verbatim>" — goal does <X>, rule forbids <X>.
  ORCHESTRATOR: <justification, or "folds">
CHALLENGE 2 [redundancy]: skill `looper-build` already ships features. Why a parallel path?
  ORCHESTRATOR: <justification>
...
VERDICT: PROCEED | PROCEED-WITH-NOTES | STOP
SIZING:  inline | single-wave | full-orchestration
```

- **PROCEED**: every challenge answered, no hard conflict. Run goes to scope unchanged.
- **PROCEED-WITH-NOTES**: challenges raised real adjustments (drop a redundant wave, add a gate). Notes appended to scope input. Run continues.
- **STOP**: hard contradiction — rule conflict, user-authority decision, or required-gate substitution — with no override. Surface to user; do NOT proceed to scope.

Always emit both lines. SIZING is reported on every non-STOP verdict (a STOP halts regardless of size, so its sizing is moot). The orchestrator routes on SIZING per the table above.

## Yield discipline

Skeptic, NOT veto. A challenge being *raised* never halts the run — only the three STOP triggers do. Default bias = let the run proceed once challenged; a nonbeliever that blocks every run is as broken as a verifier that always fails. One round only: argue, record the exchange, emit verdict. Endless argument is its own stall.

## What looper-nonbeliever does NOT do

- Does NOT decompose, execute, or fix. Read-only interrogation; hands off to `looper-scope`.
- Does NOT veto a well-formed run, re-argue after the response, or invent contradictions. PROCEED unless a STOP trigger fires; one round; every challenge cites a real verbatim line or is dropped.
- Does NOT decide user-authority questions itself. Finds them, routes them to the user.
- Does NOT itself skip, shrink, or run the loop. Sizing only labels the work; the orchestrator routes on the label. And it never sizes vague work as small — unspecified scope is a STOP, not an `inline`.
