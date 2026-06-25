# [Looper](../agents/the-looper.md) framework v1

The looper skills + agent compose into a multi-wave orchestrator named
[Loop de Looper](../skills/loop-de-looper/SKILL.md). Hand it a goal that spans
more than one loop and it runs a nonbeliever pre-flight, produces a wave
queue, dispatches `the-looper` per wave, schedules crew passes at trigger
points, emits a plain-language recap, and surfaces required-not-loopable
items to the user at termination.

Per-wave flow inside `the-looper`:

- `research → plan → build → verify → review → learn → commit`

Cross-wave flow inside Loop de Looper:

- `nonbeliever → scope → wave loop × N → final crew → recap → terminate`

The nonbeliever pre-flight challenges the goal + approach against CLAUDE.md,
existing agents, skills, and directives before any wave runs — advisory
unless it hits a hard rule conflict. The recap closes the run with a clean,
shareable summary drawn from the gate log + git history; it narrates, it
never decides.

Plan absorbs the deterministic portion of pre-build specialist judgment so
the loop stays autonomous unless real residual judgment is needed. When
plan emits `ESCALATE: <gate>`, the agent stops; orchestrator invokes the
named specialist, appends its output as `gate outputs`, and re-dispatches.
