# [Looper](agents/the-looper.md) framework v1

The looper skills + agent compose into a multi-wave orchestrator named
[Loop de Looper](skills/loop-de-looper/SKILL.md). Hand it a goal that spans
more than one loop and it produces a wave queue, dispatches `the-looper`
per wave, schedules crew passes at trigger points, and surfaces
required-not-loopable items to the user at termination.

Per-wave flow inside `the-looper`:

- `research → plan → build → verify → review → learn → commit`

Cross-wave flow inside Loop de Looper:

- `scope → wave loop × N → final crew → terminate`

Plan absorbs the deterministic portion of pre-build specialist judgment so
the loop stays autonomous unless real residual judgment is needed. When
plan emits `ESCALATE: <gate>`, the agent stops; orchestrator invokes the
named specialist, appends its output as `gate outputs`, and re-dispatches.
