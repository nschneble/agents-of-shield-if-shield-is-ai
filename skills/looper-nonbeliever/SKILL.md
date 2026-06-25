---
name: looper-nonbeliever
description: Adversarial pre-flight. Argue with the orchestrator BEFORE scope — force it to justify the goal + intended approach against CLAUDE.md, existing agents, skills, and directives. Trigger when the user says "challenge this", "play devil's advocate", "stress-test the goal", or runs before looper-scope inside Loop de Looper.
---

Skeptic gate. Runs ONCE, before `looper-scope`. Input = raw goal + intended approach. Job = make the orchestrator defend the run before any wave burns. Argue, demand justification, check for contradiction, then YIELD — advisory by default, STOP only on hard conflict.

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

## Output

Two columns (challenge + orchestrator response) plus a verdict line.

```
CHALLENGE 1 [contradiction]: CLAUDE.md "<rule, verbatim>" — goal does <X>, rule forbids <X>.
  ORCHESTRATOR: <justification, or "folds">
CHALLENGE 2 [redundancy]: skill `looper-build` already ships features. Why a parallel path?
  ORCHESTRATOR: <justification>
...
VERDICT: PROCEED | PROCEED-WITH-NOTES | STOP
```

- **PROCEED**: every challenge answered, no hard conflict. Run goes to scope unchanged.
- **PROCEED-WITH-NOTES**: challenges raised real adjustments (drop a redundant wave, add a gate). Notes appended to scope input. Run continues.
- **STOP**: hard contradiction — rule conflict, user-authority decision, or required-gate substitution — with no override. Surface to user; do NOT proceed to scope.

## Yield discipline

Skeptic, NOT veto. A challenge being *raised* never halts the run — only the three STOP triggers do. Default bias = let the run proceed once challenged; a nonbeliever that blocks every run is as broken as a verifier that always fails. One round only: argue, record the exchange, emit verdict. Endless argument is its own stall.

## What looper-nonbeliever does NOT do

- Does NOT decompose, execute, or fix. Read-only interrogation; hands off to `looper-scope`.
- Does NOT veto a well-formed run, re-argue after the response, or invent contradictions. PROCEED unless a STOP trigger fires; one round; every challenge cites a real verbatim line or is dropped.
- Does NOT decide user-authority questions itself. Finds them, routes them to the user.
